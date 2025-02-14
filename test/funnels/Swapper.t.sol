// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.16;

import "dss-test/DssTest.sol";
import { Swapper } from "src/funnels/Swapper.sol";
import { SwapperCalleeUniV3 } from "src/funnels/callees/SwapperCalleeUniV3.sol";
import { AllocatorRoles } from "src/AllocatorRoles.sol";
import { AllocatorBuffer } from "src/AllocatorBuffer.sol";

interface GemLike {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external;
}

contract CalleeMock is DssTest {
    function swap(address src, address dst, uint256 amt, uint256, address to, bytes calldata) external {
        GemLike(src).transfer(address(0xDEAD), amt);
        deal(dst, address(this), amt, true);
        GemLike(dst).transfer(to, amt);
    }
}

contract SwapperTest is DssTest {
    event SetLimits(address indexed src, address indexed dst, uint96 cap, uint32 era);
    event Swap(address indexed sender, address indexed src, address indexed dst, uint256 amt, uint256 out);

    AllocatorRoles public roles;
    AllocatorBuffer public buffer;
    Swapper public swapper;
    SwapperCalleeUniV3 public uniV3Callee;

    bytes32 constant ilk = "aaa";
    bytes constant USDC_DAI_PATH = abi.encodePacked(USDC, uint24(100), DAI);
    bytes constant DAI_USDC_PATH = abi.encodePacked(DAI, uint24(100), USDC);

    address constant DAI          = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address constant USDC         = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant UNIV3_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;

    address constant FACILITATOR = address(0x1337);
    address constant KEEPER      = address(0xb0b);

    uint8 constant SWAPPER_ROLE = uint8(1);

    function setUp() public {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"));

        buffer = new AllocatorBuffer();
        roles = new AllocatorRoles();
        swapper = new Swapper(address(roles), ilk, address(buffer));
        uniV3Callee = new SwapperCalleeUniV3(UNIV3_ROUTER);

        roles.setIlkAdmin(ilk, address(this));
        roles.setRoleAction(ilk, SWAPPER_ROLE, address(swapper), swapper.swap.selector, true);
        roles.setUserRole(ilk, FACILITATOR, SWAPPER_ROLE, true);

        swapper.setLimits(DAI, USDC, uint96(10_000 * WAD), 3600 seconds);
        swapper.setLimits(USDC, DAI, uint96(10_000 * 10**6), 3600 seconds);

        deal(DAI,  address(buffer), 1_000_000 * WAD,   true);
        deal(USDC, address(buffer), 1_000_000 * 10**6, true);
        buffer.approve(USDC, address(swapper), type(uint256).max);
        buffer.approve(DAI,  address(swapper), type(uint256).max);
    }

    function testConstructor() public {
        Swapper s = new Swapper(address(0xBEEF), "SubDAO 1", address(0xAAA));
        assertEq(address(s.roles()),  address(0xBEEF));
        assertEq(s.ilk(), "SubDAO 1");
        assertEq(s.buffer(), address(0xAAA));
        assertEq(s.wards(address(this)), 1);
    }

    function testAuth() public {
        checkAuth(address(swapper), "Swapper");
    }

    function testModifiers() public {
        bytes4[] memory authedMethods = new bytes4[](2);
        authedMethods[0] = swapper.setLimits.selector;
        authedMethods[1] = swapper.swap.selector;

        vm.startPrank(address(0xBEEF));
        checkModifier(address(swapper), "Swapper/not-authorized", authedMethods);
        vm.stopPrank();
    }

    function testSetLimits() public {
        // swap to make sure due and end are set
        vm.prank(FACILITATOR); swapper.swap(USDC, DAI, 1_000 * 10**6, 990 * WAD, address(uniV3Callee), USDC_DAI_PATH);
        (,, uint96 dueBefore, uint32 endBefore) = swapper.limits(USDC, DAI);
        assertGt(endBefore, 0);
        assertGt(dueBefore, 0);

        vm.warp(block.timestamp + 1 hours);

        vm.expectEmit(true, true, true, true);
        emit SetLimits(USDC, DAI, 4, 3);
        vm.prank(address(this)); swapper.setLimits(USDC, DAI, 4, 3);
        (uint96 cap, uint32 era, uint96 due, uint32 end) = swapper.limits(USDC, DAI);
        assertEq(cap, 4);
        assertEq(era, 3);
        assertEq(due, 0);
        assertEq(end, 0);
    }

    function testRoles() public {
        vm.expectRevert("Swapper/not-authorized");
        vm.prank(address(0xBEEF)); swapper.setLimits(address(0), address(0), 0, 0);
        roles.setRoleAction(ilk, uint8(0xF1), address(swapper), swapper.setLimits.selector, true);
        roles.setUserRole(ilk, address(0xBEEF), uint8(0xF1), true);
        vm.prank(address(0xBEEF)); swapper.setLimits(address(0), address(0), 0, 0);
    }

    function testSwap() public {
        uint256 prevSrc = GemLike(USDC).balanceOf(address(buffer));
        uint256 prevDst = GemLike(DAI).balanceOf(address(buffer));

        uint32 initialTime = uint32(block.timestamp);

        uint256 snapshot = vm.snapshot();
        vm.prank(FACILITATOR); uint256 expectedOut = swapper.swap(USDC, DAI, 1_000 * 10**6, 990 * WAD, address(uniV3Callee), USDC_DAI_PATH);
        vm.revertTo(snapshot);

        vm.expectEmit(true, true, true, true);
        emit Swap(FACILITATOR, USDC, DAI, 1_000 * 10**6, expectedOut);
        vm.prank(FACILITATOR); uint256 out = swapper.swap(USDC, DAI, 1_000 * 10**6, 990 * WAD, address(uniV3Callee), USDC_DAI_PATH);

        assertGe(out, 990 * WAD);
        assertEq(GemLike(USDC).balanceOf(address(buffer)), prevSrc - 1_000 * 10**6);
        assertEq(GemLike(DAI).balanceOf(address(buffer)), prevDst + out);
        assertEq(GemLike(DAI).balanceOf(address(swapper)), 0);
        assertEq(GemLike(USDC).balanceOf(address(swapper)), 0);
        assertEq(GemLike(DAI).balanceOf(address(uniV3Callee)), 0);
        assertEq(GemLike(USDC).balanceOf(address(uniV3Callee)), 0);
        (,, uint96 due, uint32 end) = swapper.limits(USDC, DAI);
        assertEq(due, 9_000 * 10**6);
        assertEq(end, initialTime + 3600);

        vm.warp(initialTime + 1800);
        vm.prank(FACILITATOR); swapper.swap(USDC, DAI, 5_000 * 10**6, 4_950 * WAD, address(uniV3Callee), USDC_DAI_PATH);
        (,, due, end) = swapper.limits(USDC, DAI);
        assertEq(due, 4_000 * 10**6);
        assertEq(end, initialTime + 3600);

        vm.expectRevert("Swapper/exceeds-due-amt");
        vm.prank(FACILITATOR); swapper.swap(USDC, DAI, 8_000 * 10**6, 7_920 * WAD, address(uniV3Callee), USDC_DAI_PATH);

        vm.warp(initialTime + 3600);
        vm.prank(FACILITATOR); swapper.swap(USDC, DAI, 8_000 * 10**6, 7_920 * WAD, address(uniV3Callee), USDC_DAI_PATH);
        (,, due, end) = swapper.limits(USDC, DAI);
        assertEq(due, 2_000 * 10**6);
        assertEq(end, initialTime + 7200);

        prevSrc = GemLike(DAI).balanceOf(address(buffer));
        prevDst = GemLike(USDC).balanceOf(address(buffer));

        vm.expectEmit(true, true, true, false);
        emit Swap(FACILITATOR, DAI, USDC, 1_000 * WAD, 0);
        vm.prank(FACILITATOR); out = swapper.swap(DAI, USDC, 1_000 * WAD, 990 * 10**6, address(uniV3Callee), DAI_USDC_PATH);
        
        assertGe(out, 990 * 10**6);
        assertEq(GemLike(DAI).balanceOf(address(buffer)), prevSrc - 1_000 * WAD);
        assertEq(GemLike(USDC).balanceOf(address(buffer)), prevDst + out);
        assertEq(GemLike(DAI).balanceOf(address(swapper)), 0);
        assertEq(GemLike(USDC).balanceOf(address(swapper)), 0);
        assertEq(GemLike(DAI).balanceOf(address(uniV3Callee)), 0);
        assertEq(GemLike(USDC).balanceOf(address(uniV3Callee)), 0);
        (,, due, end) = swapper.limits(DAI, USDC);
        assertEq(due, 9_000 * WAD);
        assertEq(end, initialTime + 7200);
    }

    function testSwapAllAferEra() public {
        vm.prank(FACILITATOR); swapper.swap(USDC, DAI, 10_000 * 10**6, 9900 * WAD, address(uniV3Callee), USDC_DAI_PATH);
        (, uint64 era,,) = swapper.limits(USDC, DAI);
        vm.warp(block.timestamp + era);

        vm.expectEmit(true, true, true, false);
        emit Swap(FACILITATOR, USDC, DAI, 10_000 * 10**6, 0);
        vm.prank(FACILITATOR); swapper.swap(USDC, DAI, 10_000 * 10**6, 9900 * WAD, address(uniV3Callee), USDC_DAI_PATH);
    }

    function testSwapExceedingMax() public {
        (uint128 cap,,,) = swapper.limits(USDC, DAI);
        uint256 amt = cap + 1;
        vm.expectRevert("Swapper/exceeds-due-amt");
        vm.prank(FACILITATOR); swapper.swap(USDC, DAI, amt, 0, address(uniV3Callee), USDC_DAI_PATH);
    }

    function testSwapReceivingTooLittle() public {
        CalleeMock callee = new CalleeMock();
        vm.expectRevert("Swapper/too-few-dst-received");
        vm.prank(FACILITATOR); swapper.swap(USDC, DAI, 100 * 10**6, 200 * WAD, address(callee), USDC_DAI_PATH);
    }
}
