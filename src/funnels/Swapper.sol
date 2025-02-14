// SPDX-FileCopyrightText: © 2023 Dai Foundation <www.daifoundation.org>
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.

pragma solidity ^0.8.16;

interface RolesLike {
    function canCall(bytes32, address, address, bytes4) external view returns (bool);
}

interface GemLike {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external;
    function transferFrom(address, address, uint256) external;
}

interface CalleeLike {
    function swap(address, address, uint256, uint256, address, bytes calldata) external;
}

contract Swapper {
    mapping (address => uint256) public wards;                         // Admins
    mapping (address => mapping (address => PairLimit)) public limits; // Rate limit parameters per src->dst pair

    RolesLike public immutable roles;  // Contract managing access control for this Swapper
    bytes32   public immutable ilk;    // Collateral type
    address   public immutable buffer; // Contract from which the GEM to sell is pulled and to which the bought GEM is pushed

    struct PairLimit {
        uint96  cap; // Maximum amount of src token that can be swapped each era for a src->dst pair
        uint32  era; // Cooldown period it has to wait for renewing the due amount to cap for src to dst swap
        uint96  due; // Pending amount of src token that can still be swapped until next era
        uint32  end; // Timestamp of when the current batch ends
    }

    event Rely(address indexed usr);
    event Deny(address indexed usr);
    event SetLimits(address indexed src, address indexed dst, uint96 cap, uint32 era);
    event Swap(address indexed sender, address indexed src, address indexed dst, uint256 amt, uint256 out);

    constructor(address roles_, bytes32 ilk_, address buffer_) {
        roles = RolesLike(roles_);
        ilk = ilk_;
        buffer = buffer_;
        wards[msg.sender] = 1;
        emit Rely(msg.sender);
    }

    modifier auth() {
        require(roles.canCall(ilk, msg.sender, address(this), msg.sig) || wards[msg.sender] == 1, "Swapper/not-authorized");
        _;
    }

    function rely(address usr) external auth {
        wards[usr] = 1;
        emit Rely(usr);
    }

    function deny(address usr) external auth {
        wards[usr] = 0;
        emit Deny(usr);
    }

    function setLimits(address src, address dst, uint96 cap, uint32 era) external auth {
        limits[src][dst] = PairLimit({
            cap: cap,
            era: era,
            due: 0,
            end: 0
        });
        emit SetLimits(src, dst, cap, era);
    }

    function swap(address src, address dst, uint256 amt, uint256 minOut, address callee, bytes calldata data) external auth returns (uint256 out) {
        PairLimit memory limit = limits[src][dst];

        if (block.timestamp >= limit.end) {
            // Reset batch
            limit.due = limit.cap;
            limit.end = uint32(block.timestamp) + limit.era;
        }

        require(amt <= limit.due, "Swapper/exceeds-due-amt");

        unchecked {
            limits[src][dst].due = limit.due - uint96(amt);
            limits[src][dst].end = limit.end;
        }

        GemLike(src).transferFrom(buffer, callee, amt);

        // Avoid swapping directly to buffer to prevent piggybacking another operation to satisfy the balance check
        CalleeLike(callee).swap(src, dst, amt, minOut, address(this), data);

        out = GemLike(dst).balanceOf(address(this));
        require(out >= minOut, "Swapper/too-few-dst-received");

        GemLike(dst).transfer(buffer, out);
        emit Swap(msg.sender, src, dst, amt, out);
    }
}
