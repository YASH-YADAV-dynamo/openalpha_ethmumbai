// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IV4Quoter} from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";
import {IVenue} from "../IArcTreasury.sol";
import {UniswapV4Venue} from "../UniswapV4Venue.sol";
import {ArcBase} from "./helpers/ArcBase.sol";
import {CallbackCaller} from "./helpers/MockPoolManager.sol";

contract ArcUniswapVenueTest is ArcBase {
    event Swapped(address indexed caller, address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut);

    function setUp() public override {
        super.setUp();
        usdc.mint(alice, 1_000_000e6);
        eurc.mint(alice, 1_000_000e6);
        vm.startPrank(alice);
        usdc.approve(address(uvenue), type(uint256).max);
        eurc.approve(address(uvenue), type(uint256).max);
        vm.stopPrank();
    }

    function _out01(uint256 amt) internal pure returns (uint256) {
        return amt * 925_926 / 1e6 * (1e6 - 500) / 1e6;
    }

    function _out10(uint256 amt) internal pure returns (uint256) {
        return amt * 1_080_000 / 1e6 * (1e6 - 500) / 1e6;
    }

    function test_Metadata() public view {
        assertEq(uvenue.name(), "Uniswap v4 (Arc testnet)");
        assertEq(address(uvenue.poolManager()), address(pm));
        assertEq(address(uvenue.quoter()), address(quoter));
        (Currency c0, Currency c1, uint24 fee, int24 ts, IHooks h) = uvenue.key();
        assertEq(Currency.unwrap(c0), USDC_ADDR);
        assertEq(Currency.unwrap(c1), EURC_ADDR);
        assertEq(fee, 500);
        assertEq(ts, 10);
        assertEq(address(h), address(0));
    }

    function test_Constructor_Validation() public {
        PoolKey memory k = PoolKey(Currency.wrap(USDC_ADDR), Currency.wrap(EURC_ADDR), 500, 10, IHooks(address(0)));
        vm.expectRevert(UniswapV4Venue.InvalidAddress.selector);
        new UniswapV4Venue(IPoolManager(address(0)), IV4Quoter(address(quoter)), k);
        vm.expectRevert(UniswapV4Venue.InvalidAddress.selector);
        new UniswapV4Venue(IPoolManager(address(pm)), IV4Quoter(address(0)), k);
        PoolKey memory unsorted = PoolKey(Currency.wrap(EURC_ADDR), Currency.wrap(USDC_ADDR), 500, 10, IHooks(address(0)));
        vm.expectRevert(abi.encodeWithSelector(IVenue.Unsupported.selector, EURC_ADDR, USDC_ADDR));
        new UniswapV4Venue(IPoolManager(address(pm)), IV4Quoter(address(quoter)), unsorted);
        PoolKey memory zero = PoolKey(Currency.wrap(address(0)), Currency.wrap(EURC_ADDR), 500, 10, IHooks(address(0)));
        vm.expectRevert(UniswapV4Venue.InvalidAddress.selector);
        new UniswapV4Venue(IPoolManager(address(pm)), IV4Quoter(address(quoter)), zero);
    }

    function test_Swap_ZeroForOne() public {
        uint256 amt = 1_000e6;
        uint256 exp = _out01(amt);
        uint256 aU = usdc.balanceOf(alice);
        uint256 aE = eurc.balanceOf(alice);
        uint256 pmU = usdc.balanceOf(address(pm));
        uint256 pmE = eurc.balanceOf(address(pm));
        vm.expectEmit(true, true, true, true, address(uvenue));
        emit Swapped(alice, USDC_ADDR, EURC_ADDR, amt, exp);
        vm.prank(alice);
        uint256 out = uvenue.swap(USDC_ADDR, EURC_ADDR, amt, exp, alice);
        assertEq(out, exp);
        assertEq(usdc.balanceOf(alice), aU - amt);
        assertEq(eurc.balanceOf(alice), aE + exp);
        assertEq(usdc.balanceOf(address(pm)), pmU + amt);
        assertEq(eurc.balanceOf(address(pm)), pmE - exp);
        assertEq(usdc.balanceOf(address(uvenue)), 0);
        assertEq(eurc.balanceOf(address(uvenue)), 0);
    }

    function test_Swap_OneForZero() public {
        uint256 amt = 500e6;
        uint256 exp = _out10(amt);
        uint256 aU = usdc.balanceOf(alice);
        uint256 aE = eurc.balanceOf(alice);
        vm.expectEmit(true, true, true, true, address(uvenue));
        emit Swapped(alice, EURC_ADDR, USDC_ADDR, amt, exp);
        vm.prank(alice);
        uint256 out = uvenue.swap(EURC_ADDR, USDC_ADDR, amt, 0, bob);
        assertEq(out, exp);
        assertEq(eurc.balanceOf(alice), aE - amt);
        assertEq(usdc.balanceOf(alice), aU);
        assertEq(usdc.balanceOf(bob), exp);
        assertEq(usdc.balanceOf(address(uvenue)) + eurc.balanceOf(address(uvenue)), 0);
    }

    function test_Swap_MinOutReverts() public {
        uint256 exp = _out01(100e6);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IVenue.MinOut.selector, exp, exp + 1));
        uvenue.swap(USDC_ADDR, EURC_ADDR, 100e6, exp + 1, alice);
        uint256 expR = _out10(100e6);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IVenue.MinOut.selector, expR, expR + 1));
        uvenue.swap(EURC_ADDR, USDC_ADDR, 100e6, expR + 1, alice);
    }

    function test_UnlockCallback_OnlyPoolManager() public {
        bytes memory data = abi.encode(USDC_ADDR, uint256(1e6), alice, alice);
        vm.prank(alice);
        vm.expectRevert(UniswapV4Venue.NotPoolManager.selector);
        uvenue.unlockCallback(data);
        CallbackCaller cc = new CallbackCaller();
        vm.expectRevert(UniswapV4Venue.NotPoolManager.selector);
        cc.call(address(uvenue), data);
        vm.prank(address(uvenue));
        vm.expectRevert(UniswapV4Venue.NotPoolManager.selector);
        uvenue.unlockCallback(data);
    }

    function test_PartialFill_RefundsPayerNotRecipient() public {
        pm.setFillBps(6_000); // pool only consumes 60% of the input
        uint256 amt = 1_000e6;
        uint256 used = 600e6;
        uint256 exp = _out01(used);
        uint256 aU = usdc.balanceOf(alice);
        uint256 bobE = eurc.balanceOf(bob);
        vm.expectEmit(true, true, true, true, address(uvenue));
        emit Swapped(alice, USDC_ADDR, EURC_ADDR, amt, exp);
        vm.prank(alice);
        uint256 out = uvenue.swap(USDC_ADDR, EURC_ADDR, amt, 0, bob);
        assertEq(out, exp);
        assertEq(usdc.balanceOf(alice), aU - used); // 400 refunded to the payer
        assertEq(usdc.balanceOf(bob), 0); // recipient got no input-token refund
        assertEq(eurc.balanceOf(bob), bobE + exp);
        assertEq(usdc.balanceOf(address(uvenue)), 0);
        assertEq(eurc.balanceOf(address(uvenue)), 0);
    }

    function test_PartialFill_OneForZero() public {
        pm.setFillBps(2_500);
        uint256 aE = eurc.balanceOf(alice);
        vm.prank(alice);
        uvenue.swap(EURC_ADDR, USDC_ADDR, 400e6, 0, alice);
        assertEq(eurc.balanceOf(alice), aE - 100e6);
    }

    function test_PartialFill_MinOutStillEnforced() public {
        pm.setFillBps(5_000);
        uint256 full = _out01(100e6);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IVenue.MinOut.selector, _out01(50e6), full));
        uvenue.swap(USDC_ADDR, EURC_ADDR, 100e6, full, alice);
    }

    function test_Unsupported_Pairs() public {
        address x = makeAddr("x");
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(IVenue.Unsupported.selector, USDC_ADDR, USDC_ADDR));
        uvenue.swap(USDC_ADDR, USDC_ADDR, 1e6, 0, alice);
        vm.expectRevert(abi.encodeWithSelector(IVenue.Unsupported.selector, USDC_ADDR, x));
        uvenue.swap(USDC_ADDR, x, 1e6, 0, alice);
        vm.expectRevert(abi.encodeWithSelector(IVenue.Unsupported.selector, address(mBTC), USDC_ADDR));
        uvenue.swap(address(mBTC), USDC_ADDR, 1e6, 0, alice);
        vm.expectRevert(abi.encodeWithSelector(IVenue.Unsupported.selector, USDC_ADDR, EURC_ADDR));
        uvenue.swap(USDC_ADDR, EURC_ADDR, 0, 0, alice); // zero amount
        vm.expectRevert(abi.encodeWithSelector(IVenue.Unsupported.selector, USDC_ADDR, EURC_ADDR));
        uvenue.swap(USDC_ADDR, EURC_ADDR, type(uint256).max, 0, alice); // > int256.max
        vm.stopPrank();
    }

    function test_Swap_ZeroRecipient_Reverts() public {
        vm.prank(alice);
        vm.expectRevert(UniswapV4Venue.InvalidAddress.selector);
        uvenue.swap(USDC_ADDR, EURC_ADDR, 1e6, 0, address(0));
    }

    function test_Swap_NoAllowance_Reverts() public {
        usdc.mint(bob, 10e6);
        vm.prank(bob);
        vm.expectRevert();
        uvenue.swap(USDC_ADDR, EURC_ADDR, 10e6, 0, bob);
    }

    // ---------- quote ----------
    function test_Quote_RevertsUnsupportedWhenQuoterFails() public {
        // MockQuoter reverts by default (mimics transient-storage failure in staticcall)
        vm.expectRevert(abi.encodeWithSelector(IVenue.Unsupported.selector, USDC_ADDR, EURC_ADDR));
        uvenue.quote(USDC_ADDR, EURC_ADDR, 1e6);
        vm.expectRevert(abi.encodeWithSelector(IVenue.Unsupported.selector, EURC_ADDR, USDC_ADDR));
        uvenue.quote(EURC_ADDR, USDC_ADDR, 1e6);
    }

    function test_Quote_ShortReturndataReverts() public {
        // quoter without code => staticcall succeeds with empty returndata
        PoolKey memory k = PoolKey(Currency.wrap(USDC_ADDR), Currency.wrap(EURC_ADDR), 500, 10, IHooks(address(0)));
        UniswapV4Venue v = new UniswapV4Venue(IPoolManager(address(pm)), IV4Quoter(makeAddr("eoa")), k);
        vm.expectRevert(abi.encodeWithSelector(IVenue.Unsupported.selector, USDC_ADDR, EURC_ADDR));
        v.quote(USDC_ADDR, EURC_ADDR, 1e6);
    }

    function test_Quote_ReturnsQuoterAmountWhenWorking() public {
        quoter.set(true, 123_456);
        assertEq(uvenue.quote(USDC_ADDR, EURC_ADDR, 1e6), 123_456);
    }

    function test_Quote_InvalidInputsUnsupported() public {
        quoter.set(true, 5);
        address x = makeAddr("x");
        vm.expectRevert(abi.encodeWithSelector(IVenue.Unsupported.selector, USDC_ADDR, x));
        uvenue.quote(USDC_ADDR, x, 1e6);
        vm.expectRevert(abi.encodeWithSelector(IVenue.Unsupported.selector, USDC_ADDR, EURC_ADDR));
        uvenue.quote(USDC_ADDR, EURC_ADDR, 0);
        vm.expectRevert(abi.encodeWithSelector(IVenue.Unsupported.selector, USDC_ADDR, EURC_ADDR));
        uvenue.quote(USDC_ADDR, EURC_ADDR, uint256(type(uint128).max) + 1);
    }

    function testFuzz_Swap_BothDirections(uint256 amt, bool zeroForOne, uint16 fill) public {
        amt = bound(amt, 1e3, 100_000e6);
        fill = uint16(bound(fill, 1, 10_000));
        pm.setFillBps(fill);
        uint256 used = amt * fill / 10_000;
        (address tIn, address tOut) = zeroForOne ? (USDC_ADDR, EURC_ADDR) : (EURC_ADDR, USDC_ADDR);
        uint256 inBefore = MockERC20Like(tIn).balanceOf(alice);
        uint256 exp = zeroForOne ? _out01(used) : _out10(used);
        vm.prank(alice);
        uint256 out = uvenue.swap(tIn, tOut, amt, 0, bob);
        assertEq(out, exp);
        assertEq(MockERC20Like(tIn).balanceOf(alice), inBefore - used);
        assertEq(MockERC20Like(tOut).balanceOf(bob), exp);
        assertEq(MockERC20Like(tIn).balanceOf(address(uvenue)), 0);
        assertEq(MockERC20Like(tOut).balanceOf(address(uvenue)), 0);
    }
}

interface MockERC20Like {
    function balanceOf(address) external view returns (uint256);
}
