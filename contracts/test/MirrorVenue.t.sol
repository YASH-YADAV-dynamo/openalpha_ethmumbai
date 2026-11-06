// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./TreasuryBase.t.sol";

contract MirrorVenueTest is TreasuryBase {
    function setUp() public override {
        super.setUp();
        usdc.mint(alice, 100_000e6);
        vm.prank(alice);
        usdc.approve(address(mirrorVenue), type(uint256).max);
    }

    function _buy(address token, uint256 amt) internal returns (uint256) {
        vm.prank(alice);
        return mirrorVenue.swap(address(usdc), token, amt, 0, alice);
    }

    function _sell(address token, uint256 amt) internal returns (uint256) {
        vm.prank(alice);
        MirrorToken(token).approve(address(mirrorVenue), type(uint256).max);
        vm.prank(alice);
        return mirrorVenue.swap(token, address(usdc), amt, 0, alice);
    }

    // ------------------------------------------------------------ constants / metadata
    function test_Constants() public view {
        assertEq(mirrorVenue.name(), "Mirror (testnet)");
        assertEq(mirrorVenue.spreadBps(), 30);
        assertEq(mirrorVenue.maxTradeUsdc(), 5_000e6);
        assertEq(address(mirrorVenue.registry()), address(registry));
        assertEq(mirrorVenue.usdc(), address(usdc));
    }

    function test_ConstructorRejectsZero() public {
        vm.expectRevert(MirrorVenue.InvalidAddress.selector);
        new MirrorVenue(IAssetRegistry(address(0)), address(usdc));
        vm.expectRevert(MirrorVenue.InvalidAddress.selector);
        new MirrorVenue(registry, address(0));
    }

    // ------------------------------------------------------------ buy math
    function test_BuyBtcMathExact() public {
        uint256 amt = 1_000e6;
        // 1000 USDC / 60000 = 0.016666.. BTC, minus 30 bps
        uint256 expected = amt * 1e8 * 1e8 / (60_000e8 * 1e6) * 9970 / 10000;
        assertEq(expected, 1_661_666); // hand-computed: 1_666_666 * 0.997
        uint256 out = _buy(address(btc), amt);
        assertEq(out, _buyOut(8, 60_000e8, amt));
        assertEq(out, expected);
        assertEq(btc.balanceOf(alice), out);
        assertEq(btc.totalSupply(), out);
        assertEq(usdc.balanceOf(address(mirrorVenue)), amt, "venue keeps USDC as reserve");
        assertEq(usdc.balanceOf(alice), 100_000e6 - amt);
    }

    function test_BuyEth18DecMathExact() public {
        uint256 amt = 3_000e6; // exactly 1 ETH at $3000 before spread
        uint256 out = _buy(address(eth), amt);
        assertEq(out, 1e18 * 9970 / 10000);
        assertEq(out, _buyOut(18, 3_000e8, amt));
    }

    function test_BuyEmitsSwappedAndRecipientGetsTokens() public {
        uint256 amt = 100e6;
        uint256 out = _buyOut(8, 60_000e8, amt);
        vm.expectEmit(true, true, true, true, address(mirrorVenue));
        emit IVenue.Swapped(alice, address(usdc), address(btc), amt, out);
        vm.prank(alice);
        mirrorVenue.swap(address(usdc), address(btc), amt, out, bob);
        assertEq(btc.balanceOf(bob), out);
        assertEq(btc.balanceOf(alice), 0);
    }

    function test_BuyAtDifferentPrice() public {
        _setPrice(address(btc), 12_345e8);
        uint256 out = _buy(address(btc), 777e6);
        assertEq(out, _buyOut(8, 12_345e8, 777e6));
    }

    // ------------------------------------------------------------ sell math
    function test_SellMathExactAndBurns() public {
        _fundReserve(10_000e6);
        _mintMirror(address(btc), alice, 5_000_000); // 0.05 BTC = $3000
        uint256 reserveBefore = usdc.balanceOf(address(mirrorVenue));
        uint256 aliceBefore = usdc.balanceOf(alice);
        uint256 out = _sell(address(btc), 5_000_000);
        assertEq(out, 5_000_000 * 60_000e8 * 1e6 / (1e8 * 1e8) * 9970 / 10000);
        assertEq(out, _sellOut(8, 60_000e8, 5_000_000));
        assertEq(out, 2_991e6);
        assertEq(btc.balanceOf(alice), 0);
        assertEq(btc.totalSupply(), 0, "mirror burned");
        assertEq(btc.balanceOf(address(mirrorVenue)), 0);
        assertEq(usdc.balanceOf(address(mirrorVenue)), reserveBefore - out);
        assertEq(usdc.balanceOf(alice), aliceBefore + out);
    }

    function test_SellEth18Dec() public {
        _fundReserve(10_000e6);
        _mintMirror(address(eth), alice, 1e18);
        uint256 out = _sell(address(eth), 1e18);
        assertEq(out, 3_000e6 * 9970 / 10000);
    }

    function test_SellEmitsSwapped() public {
        _fundReserve(10_000e6);
        _mintMirror(address(eth), alice, 1e18);
        vm.prank(alice);
        eth.approve(address(mirrorVenue), 1e18);
        uint256 out = _sellOut(18, 3_000e8, 1e18);
        vm.expectEmit(true, true, true, true, address(mirrorVenue));
        emit IVenue.Swapped(alice, address(eth), address(usdc), 1e18, out);
        vm.prank(alice);
        mirrorVenue.swap(address(eth), address(usdc), 1e18, out, bob);
        assertEq(usdc.balanceOf(bob), out);
    }

    function test_RoundTripLosesAboutTwoSpreads() public {
        _fundReserve(10_000e6);
        uint256 amt = 1_000e6;
        uint256 got = _buy(address(btc), amt);
        uint256 back = _sell(address(btc), got);
        // (1 - 0.003)^2 = 0.994009
        // tolerance covers flooring to whole satoshis (1 sat ~ $0.0006 = 600 USDC units)
        assertApproxEqAbs(back, amt * 994_009 / 1_000_000, 1_000);
        assertLt(back, amt);
    }

    // ------------------------------------------------------------ reverts
    function test_SellRevertsWhenReserveTooSmall() public {
        _mintMirror(address(btc), alice, 5_000_000);
        uint256 need = _sellOut(8, 60_000e8, 5_000_000);
        _fundReserve(need - 1);
        vm.prank(alice);
        btc.approve(address(mirrorVenue), type(uint256).max);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MirrorVenue.InsufficientReserve.selector, need - 1, need));
        mirrorVenue.swap(address(btc), address(usdc), 5_000_000, 0, alice);
        // exactly enough works
        _fundReserve(1);
        assertEq(_sell(address(btc), 5_000_000), need);
    }

    function test_SellWithNoReserveRevertsInsufficientReserve() public {
        _mintMirror(address(eth), alice, 1e18);
        vm.prank(alice);
        eth.approve(address(mirrorVenue), 1e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MirrorVenue.InsufficientReserve.selector, 0, _sellOut(18, 3_000e8, 1e18)));
        mirrorVenue.swap(address(eth), address(usdc), 1e18, 0, alice);
    }

    function test_RiskTwoBlocksBuysBothLevels() public {
        _setRisk(address(btc), 2);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MirrorVenue.RiskBlocked.selector, address(btc), uint8(2)));
        mirrorVenue.swap(address(usdc), address(btc), 100e6, 0, alice);
        _setRisk(address(btc), 3);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MirrorVenue.RiskBlocked.selector, address(btc), uint8(3)));
        mirrorVenue.swap(address(usdc), address(btc), 100e6, 0, alice);
    }

    function test_RiskOneStillAllowsBuy() public {
        _setRisk(address(btc), 1);
        assertGt(_buy(address(btc), 100e6), 0);
    }

    function test_RiskThreeDoesNotBlockSells() public {
        _fundReserve(10_000e6);
        _mintMirror(address(btc), alice, 1_000_000);
        _setRisk(address(btc), 3);
        assertEq(_sell(address(btc), 1_000_000), _sellOut(8, 60_000e8, 1_000_000));
        _mintMirror(address(eth), alice, 1e17);
        _setRisk(address(eth), 2);
        assertGt(_sell(address(eth), 1e17), 0);
    }

    function test_BuyCap() public {
        assertGt(_buy(address(btc), 5_000e6), 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MirrorVenue.TradeTooLarge.selector, 5_000e6 + 1, 5_000e6));
        mirrorVenue.swap(address(usdc), address(btc), 5_000e6 + 1, 0, alice);
    }

    function test_SellCapAppliesToUsdcOut() public {
        _fundReserve(100_000e6);
        _mintMirror(address(btc), alice, 1e8); // $60k
        vm.prank(alice);
        btc.approve(address(mirrorVenue), type(uint256).max);
        uint256 out = _sellOut(8, 60_000e8, 1e8);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MirrorVenue.TradeTooLarge.selector, out, 5_000e6));
        mirrorVenue.swap(address(btc), address(usdc), 1e8, 0, alice);
        // an amount whose payout is below the cap succeeds
        _mintMirror(address(eth), alice, 1e18);
        assertGt(_sell(address(eth), 1e18), 0); // $3000 payout
    }

    function test_StalePriceRevertsBuyAndSell() public {
        skip(3601);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAssetRegistry.StalePrice.selector, address(btc)));
        mirrorVenue.swap(address(usdc), address(btc), 1e6, 0, alice);
        _mintMirror(address(btc), alice, 100);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAssetRegistry.StalePrice.selector, address(btc)));
        mirrorVenue.swap(address(btc), address(usdc), 100, 0, alice);
        // fresh price re-enables trading
        _refresh();
        assertGt(_buy(address(btc), 1e6), 0);
    }

    function test_MinOutReverts() public {
        uint256 out = _buyOut(8, 60_000e8, 100e6);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IVenue.MinOut.selector, out, out + 1));
        mirrorVenue.swap(address(usdc), address(btc), 100e6, out + 1, alice);
        // minOut == out passes
        vm.prank(alice);
        assertEq(mirrorVenue.swap(address(usdc), address(btc), 100e6, out, alice), out);
    }

    function test_UnsupportedPairs() public {
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(IVenue.Unsupported.selector, address(btc), address(eth)));
        mirrorVenue.swap(address(btc), address(eth), 1, 0, alice);
        vm.expectRevert(abi.encodeWithSelector(IVenue.Unsupported.selector, address(usdc), address(usdc)));
        mirrorVenue.swap(address(usdc), address(usdc), 1, 0, alice);
        // EURC is on the Uniswap venue, not a mirror of this one
        vm.expectRevert(abi.encodeWithSelector(IVenue.Unsupported.selector, address(usdc), address(eurc)));
        mirrorVenue.swap(address(usdc), address(eurc), 1, 0, alice);
        vm.expectRevert(abi.encodeWithSelector(IVenue.Unsupported.selector, address(eurc), address(usdc)));
        mirrorVenue.swap(address(eurc), address(usdc), 1, 0, alice);
        vm.stopPrank();
    }

    function test_AssetListedWithOtherVenueOrNotMirrorUnsupported() public {
        MockERC20 notMirror = _listExtra("NM", 6, address(mirrorVenue)); // venue == mirrorVenue but mirror == false
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IVenue.Unsupported.selector, address(usdc), address(notMirror)));
        mirrorVenue.swap(address(usdc), address(notMirror), 1e6, 0, alice);
    }

    function test_UnlistedTokenBubblesUnknownAsset() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAssetRegistry.UnknownAsset.selector, bob));
        mirrorVenue.swap(address(usdc), bob, 1e6, 0, alice);
    }

    function test_SwapToZeroAddressReverts() public {
        vm.prank(alice);
        vm.expectRevert(MirrorVenue.InvalidAddress.selector);
        mirrorVenue.swap(address(usdc), address(btc), 1e6, 0, address(0));
    }

    function test_BuyWithoutAllowanceReverts() public {
        vm.prank(bob);
        vm.expectRevert(); // ERC20InsufficientAllowance / balance
        mirrorVenue.swap(address(usdc), address(btc), 1e6, 0, bob);
    }

    // ------------------------------------------------------------ quote
    function test_QuoteMatchesSwap() public {
        uint256 q = mirrorVenue.quote(address(usdc), address(btc), 250e6);
        assertEq(q, _buyOut(8, 60_000e8, 250e6));
        assertEq(_buy(address(btc), 250e6), q);

        _fundReserve(10_000e6);
        uint256 qs = mirrorVenue.quote(address(btc), address(usdc), q);
        assertEq(_sell(address(btc), q), qs);
    }

    function test_QuoteSameRevertsAsSwap() public {
        _setRisk(address(btc), 2);
        vm.expectRevert(abi.encodeWithSelector(MirrorVenue.RiskBlocked.selector, address(btc), uint8(2)));
        mirrorVenue.quote(address(usdc), address(btc), 1e6);
        vm.expectRevert(abi.encodeWithSelector(MirrorVenue.TradeTooLarge.selector, 5_000e6 + 1, 5_000e6));
        mirrorVenue.quote(address(usdc), address(eth), 5_000e6 + 1);
        vm.expectRevert(abi.encodeWithSelector(IVenue.Unsupported.selector, address(btc), address(eth)));
        mirrorVenue.quote(address(btc), address(eth), 1);
        skip(3601);
        vm.expectRevert(abi.encodeWithSelector(IAssetRegistry.StalePrice.selector, address(eth)));
        mirrorVenue.quote(address(usdc), address(eth), 1e6);
    }

    // ------------------------------------------------------------ mirror token permissions
    function test_OnlyVenueCanMintAndBurn() public {
        assertEq(btc.venue(), address(mirrorVenue));
        assertEq(btc.decimals(), 8);
        assertEq(eth.decimals(), 18);
        vm.prank(alice);
        vm.expectRevert(MirrorToken.NotVenue.selector);
        btc.mint(alice, 1);
        _mintMirror(address(btc), alice, 10);
        vm.prank(alice);
        vm.expectRevert(MirrorToken.NotVenue.selector);
        btc.burn(alice, 1);
        vm.prank(owner);
        vm.expectRevert(MirrorToken.NotVenue.selector);
        btc.mint(owner, 1);
        // venue can burn
        vm.prank(address(mirrorVenue));
        btc.burn(alice, 4);
        assertEq(btc.balanceOf(alice), 6);
    }

    function test_MirrorTokenRejectsZeroVenue() public {
        vm.expectRevert(MirrorToken.InvalidVenue.selector);
        new MirrorToken("x", "x", 6, address(0));
    }

    function test_NoWayToWithdrawReserve() public {
        // The venue exposes no owner / withdraw surface: reserve only leaves via sells.
        (bool ok,) = address(mirrorVenue).call(abi.encodeWithSignature("withdraw(address,uint256)", address(usdc), 1));
        assertFalse(ok);
        (ok,) = address(mirrorVenue).call(abi.encodeWithSignature("owner()"));
        assertFalse(ok);
    }
}
