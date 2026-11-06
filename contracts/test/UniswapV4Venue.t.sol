// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./TreasuryBase.t.sol";

contract UniswapV4VenueTest is TreasuryBase {
    function setUp() public override {
        super.setUp();
        usdc.mint(alice, 10_000e6);
        eurc.mint(alice, 10_000e6);
        vm.startPrank(alice);
        usdc.approve(address(v4Venue), type(uint256).max);
        eurc.approve(address(v4Venue), type(uint256).max);
        vm.stopPrank();
    }

    function _swap(address tIn, address tOut, uint256 amt, uint256 minOut, address to) internal returns (uint256) {
        vm.prank(alice);
        return v4Venue.swap(tIn, tOut, amt, minOut, to);
    }

    function _key() internal view returns (PoolKey memory k) {
        (Currency c0, Currency c1, uint24 fee, int24 ts, IHooks h) = v4Venue.key();
        k = PoolKey(c0, c1, fee, ts, h);
    }

    // ------------------------------------------------------------ constructor / metadata
    function test_ConstructorState() public view {
        assertEq(v4Venue.name(), "Uniswap v4 (Arc testnet)");
        assertEq(address(v4Venue.poolManager()), address(pm));
        assertEq(address(v4Venue.quoter()), address(quoter));
        PoolKey memory k = _key();
        assertEq(k.fee, 500);
        assertEq(k.tickSpacing, 10);
        assertEq(address(k.hooks), address(0));
        (address a, address c) = (Currency.unwrap(k.currency0), Currency.unwrap(k.currency1));
        assertTrue(a < c);
        assertTrue((a == address(usdc) && c == address(eurc)) || (a == address(eurc) && c == address(usdc)));
    }

    function test_ConstructorRejectsBadArgs() public {
        PoolKey memory k = _key();
        vm.expectRevert(UniswapV4Venue.InvalidAddress.selector);
        new UniswapV4Venue(IPoolManager(address(0)), IV4Quoter(address(quoter)), k);
        vm.expectRevert(UniswapV4Venue.InvalidAddress.selector);
        new UniswapV4Venue(IPoolManager(address(pm)), IV4Quoter(address(0)), k);
        PoolKey memory swapped = PoolKey(k.currency1, k.currency0, 500, 10, IHooks(address(0)));
        vm.expectRevert(
            abi.encodeWithSelector(IVenue.Unsupported.selector, Currency.unwrap(k.currency1), Currency.unwrap(k.currency0))
        );
        new UniswapV4Venue(IPoolManager(address(pm)), IV4Quoter(address(quoter)), swapped);
    }

    // ------------------------------------------------------------ swaps
    function test_SwapUsdcForEurc() public {
        uint256 pmUsdc = usdc.balanceOf(address(pm));
        uint256 pmEurc = eurc.balanceOf(address(pm));
        uint256 expected = 100e6 * 9995 / 10_000;
        vm.expectEmit(true, true, true, true, address(v4Venue));
        emit IVenue.Swapped(alice, address(usdc), address(eurc), 100e6, expected);
        uint256 out = _swap(address(usdc), address(eurc), 100e6, expected, bob);
        assertEq(out, expected);
        assertEq(eurc.balanceOf(bob), expected);
        assertEq(usdc.balanceOf(alice), 9_900e6);
        assertEq(usdc.balanceOf(address(pm)), pmUsdc + 100e6);
        assertEq(eurc.balanceOf(address(pm)), pmEurc - expected);
        assertEq(usdc.balanceOf(address(v4Venue)) + eurc.balanceOf(address(v4Venue)), 0, "venue holds nothing");
        assertEq(pm.debt(), 0);
        assertEq(pm.credit(), 0);
    }

    function test_SwapEurcForUsdc() public {
        uint256 expected = 250e6 * 9995 / 10_000;
        uint256 out = _swap(address(eurc), address(usdc), 250e6, 0, alice);
        assertEq(out, expected);
        assertEq(usdc.balanceOf(alice), 10_000e6 + expected);
        assertEq(eurc.balanceOf(alice), 10_000e6 - 250e6);
        assertEq(usdc.balanceOf(address(v4Venue)) + eurc.balanceOf(address(v4Venue)), 0);
    }

    function test_MinOutBoundary() public {
        uint256 expected = 100e6 * 9995 / 10_000;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IVenue.MinOut.selector, expected, expected + 1));
        v4Venue.swap(address(usdc), address(eurc), 100e6, expected + 1, alice);
        assertEq(_swap(address(usdc), address(eurc), 100e6, expected, alice), expected);
    }

    function test_PartialFillRefundsUnusedInputToPayer() public {
        pm.setFill(6000); // pool consumes 60% of the input
        uint256 pmUsdc = usdc.balanceOf(address(pm));
        uint256 out = _swap(address(usdc), address(eurc), 100e6, 0, bob);
        assertEq(out, 60e6 * 9995 / 10_000);
        assertEq(eurc.balanceOf(bob), out);
        assertEq(usdc.balanceOf(alice), 10_000e6 - 60e6, "only the consumed part is spent");
        assertEq(usdc.balanceOf(address(pm)), pmUsdc + 60e6);
        assertEq(usdc.balanceOf(address(v4Venue)), 0, "refund leaves nothing behind");
    }

    function test_UnsupportedPairsAndZeroAmount() public {
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(IVenue.Unsupported.selector, address(btc), address(usdc)));
        v4Venue.swap(address(btc), address(usdc), 1, 0, alice);
        vm.expectRevert(abi.encodeWithSelector(IVenue.Unsupported.selector, address(usdc), address(usdc)));
        v4Venue.swap(address(usdc), address(usdc), 1, 0, alice);
        vm.expectRevert(abi.encodeWithSelector(IVenue.Unsupported.selector, address(eurc), address(btc)));
        v4Venue.swap(address(eurc), address(btc), 1, 0, alice);
        vm.expectRevert(abi.encodeWithSelector(IVenue.Unsupported.selector, address(usdc), address(eurc)));
        v4Venue.swap(address(usdc), address(eurc), 0, 0, alice);
        vm.expectRevert(abi.encodeWithSelector(IVenue.Unsupported.selector, address(usdc), address(eurc)));
        v4Venue.swap(address(usdc), address(eurc), uint256(type(int256).max) + 1, 0, alice);
        vm.stopPrank();
    }

    function test_SwapToZeroAddressReverts() public {
        vm.prank(alice);
        vm.expectRevert(UniswapV4Venue.InvalidAddress.selector);
        v4Venue.swap(address(usdc), address(eurc), 1e6, 0, address(0));
    }

    function test_SwapWithoutAllowanceReverts() public {
        usdc.mint(bob, 1e6);
        vm.prank(bob);
        vm.expectRevert();
        v4Venue.swap(address(usdc), address(eurc), 1e6, 0, bob);
    }

    function test_UnlockCallbackOnlyPoolManager() public {
        vm.prank(alice);
        vm.expectRevert(UniswapV4Venue.NotPoolManager.selector);
        v4Venue.unlockCallback(abi.encode(address(usdc), uint256(1), alice, alice));
    }

    function test_PositiveInputDeltaFromPoolIsRejected() public {
        pm.setBadDelta(true);
        vm.prank(alice);
        vm.expectRevert(UniswapV4Venue.InvalidDelta.selector);
        v4Venue.swap(address(usdc), address(eurc), 1e6, 0, alice);
    }

    // ------------------------------------------------------------ quote
    function test_QuoteForwardsToQuoter() public view {
        assertEq(v4Venue.quote(address(usdc), address(eurc), 100e6), 100e6 * 9995 / 10_000);
        assertEq(v4Venue.quote(address(eurc), address(usdc), 1e6), 999_500);
    }

    function test_QuoteFailureMapsToUnsupported() public {
        quoter.setMode(1);
        vm.expectRevert(abi.encodeWithSelector(IVenue.Unsupported.selector, address(usdc), address(eurc)));
        v4Venue.quote(address(usdc), address(eurc), 1e6);
        quoter.setMode(2); // short returndata
        vm.expectRevert(abi.encodeWithSelector(IVenue.Unsupported.selector, address(usdc), address(eurc)));
        v4Venue.quote(address(usdc), address(eurc), 1e6);
    }

    function test_QuoteRejectsUnsupportedAndHugeAmounts() public {
        vm.expectRevert(abi.encodeWithSelector(IVenue.Unsupported.selector, address(btc), address(usdc)));
        v4Venue.quote(address(btc), address(usdc), 1e6);
        vm.expectRevert(abi.encodeWithSelector(IVenue.Unsupported.selector, address(usdc), address(eurc)));
        v4Venue.quote(address(usdc), address(eurc), 0);
        vm.expectRevert(abi.encodeWithSelector(IVenue.Unsupported.selector, address(usdc), address(eurc)));
        v4Venue.quote(address(usdc), address(eurc), uint256(type(uint128).max) + 1);
    }
}
