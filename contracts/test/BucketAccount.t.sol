// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./TreasuryBase.t.sol";

contract BucketAccountTest is TreasuryBase {
    BucketAccount internal b;

    function setUp() public override {
        super.setUp();
        b = _btcUsdcBucket();
        usdc.mint(alice, 1_000e6);
        usdc.mint(bob, 1_000e6);
        vm.prank(alice);
        usdc.approve(address(b), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(b), type(uint256).max);
    }

    // ------------------------------------------------------------ initial state
    function test_InitialState() public view {
        assertEq(b.owner(), alice);
        assertEq(b.factory(), address(factory));
        assertEq(address(b.registry()), address(registry));
        assertEq(address(b.templates()), address(templates));
        assertEq(b.usdc(), address(usdc));
        assertFalse(b.paused());
        (address[] memory t, uint16[] memory w) = b.targets();
        assertEq(t.length, 2);
        assertEq(t[0], address(btc));
        assertEq(t[1], address(usdc));
        assertEq(w[0], 5000);
        assertEq(w[1], 5000);
        BucketParams memory p = b.params();
        assertEq(p.bandBps, 500);
        assertEq(p.maxSlippageBps, 100);
        assertEq(p.maxTradeBps, 2500);
        assertEq(p.cooldown, 3600);
        (uint256 id, bool following, uint32 v) = b.follow();
        assertEq(id, NO_TEMPLATE);
        assertFalse(following);
        assertEq(v, 0);
        (uint256 a, uint32 i, uint32 r, uint64 n) = b.sip();
        assertEq(a + i + r + n, 0);
    }

    // ------------------------------------------------------------ deposit
    function test_DepositByOwnerAndAnyone() public {
        vm.expectEmit(true, false, false, true, address(b));
        emit IBucketAccount.Deposited(alice, 100e6);
        vm.prank(alice);
        b.deposit(100e6);
        vm.expectEmit(true, false, false, true, address(b));
        emit IBucketAccount.Deposited(bob, 50e6);
        vm.prank(bob);
        b.deposit(50e6);
        assertEq(usdc.balanceOf(address(b)), 150e6);
        assertEq(usdc.balanceOf(alice), 900e6);
        assertEq(usdc.balanceOf(bob), 950e6);
        assertEq(b.owner(), alice, "depositor does not gain ownership");
    }

    function test_DepositZeroReverts() public {
        vm.prank(alice);
        vm.expectRevert(BucketAccount.BadParams.selector);
        b.deposit(0);
    }

    function test_DepositWithoutAllowanceReverts() public {
        vm.prank(keeper);
        vm.expectRevert();
        b.deposit(1e6);
    }

    // ------------------------------------------------------------ withdraw
    function test_WithdrawUsdcToRecipient() public {
        vm.prank(alice);
        b.deposit(200e6);
        vm.expectEmit(true, true, false, true, address(b));
        emit IBucketAccount.Withdrawn(bob, address(usdc), 80e6);
        vm.prank(alice);
        b.withdraw(address(usdc), 80e6, bob);
        assertEq(usdc.balanceOf(address(b)), 120e6);
        assertEq(usdc.balanceOf(bob), 1_080e6);
    }

    function test_WithdrawOtherHeldToken() public {
        _mintMirror(address(btc), address(b), 12345);
        vm.prank(alice);
        b.withdraw(address(btc), 12345, alice);
        assertEq(btc.balanceOf(alice), 12345);
        assertEq(btc.balanceOf(address(b)), 0);
    }

    function test_WithdrawNonOwnerReverts() public {
        vm.prank(alice);
        b.deposit(10e6);
        vm.prank(bob);
        vm.expectRevert(IBucketAccount.NotOwner.selector);
        b.withdraw(address(usdc), 1e6, bob);
        assertEq(usdc.balanceOf(address(b)), 10e6);
    }

    function test_WithdrawToZeroAndOverBalanceRevert() public {
        vm.prank(alice);
        b.deposit(10e6);
        vm.startPrank(alice);
        vm.expectRevert(BucketAccount.BadParams.selector);
        b.withdraw(address(usdc), 1e6, address(0));
        vm.expectRevert();
        b.withdraw(address(usdc), 10e6 + 1, alice);
        vm.stopPrank();
    }

    function test_WithdrawAllSendsEveryUniverseAsset() public {
        vm.prank(alice);
        b.deposit(100e6);
        _mintMirror(address(btc), address(b), 777);
        // universe order is [btc, usdc]
        vm.expectEmit(true, true, false, true, address(b));
        emit IBucketAccount.Withdrawn(bob, address(btc), 777);
        vm.expectEmit(true, true, false, true, address(b));
        emit IBucketAccount.Withdrawn(bob, address(usdc), 100e6);
        vm.prank(alice);
        b.withdrawAll(bob);
        assertEq(usdc.balanceOf(address(b)), 0);
        assertEq(btc.balanceOf(address(b)), 0);
        assertEq(btc.balanceOf(bob), 777);
        assertEq(usdc.balanceOf(bob), 1_100e6);
    }

    function test_WithdrawAllIncludesCarriedOutTokenAndEmptyIsNoop() public {
        vm.prank(alice);
        b.withdrawAll(alice); // nothing held: no revert
        // move to {btc, eth}, hold eth, then drop eth from the targets -> carried with weight 0
        vm.prank(alice);
        b.setTargets(_addrs(address(btc), address(eth)), _wts(5000, 5000));
        _mintMirror(address(eth), address(b), 5e17);
        vm.prank(alice);
        b.setTargets(_addrs(address(btc), address(usdc)), _wts(5000, 5000));
        vm.prank(alice);
        b.withdrawAll(alice);
        assertEq(eth.balanceOf(alice), 5e17);
    }

    function test_WithdrawAllNonOwnerAndZeroRecipient() public {
        vm.prank(bob);
        vm.expectRevert(IBucketAccount.NotOwner.selector);
        b.withdrawAll(bob);
        vm.prank(alice);
        vm.expectRevert(BucketAccount.BadParams.selector);
        b.withdrawAll(address(0));
    }

    // ------------------------------------------------------------ owner-only matrix
    function test_AllOwnerOnlyFunctionsRejectOthers() public {
        vm.startPrank(bob);
        vm.expectRevert(IBucketAccount.NotOwner.selector);
        b.withdraw(address(usdc), 1, bob);
        vm.expectRevert(IBucketAccount.NotOwner.selector);
        b.withdrawAll(bob);
        vm.expectRevert(IBucketAccount.NotOwner.selector);
        b.setTargets(_addrs(address(btc), address(usdc)), _wts(5000, 5000));
        vm.expectRevert(IBucketAccount.NotOwner.selector);
        b.followTemplate(0, true);
        vm.expectRevert(IBucketAccount.NotOwner.selector);
        b.setParams(_defParams());
        vm.expectRevert(IBucketAccount.NotOwner.selector);
        b.setPaused(true);
        vm.expectRevert(IBucketAccount.NotOwner.selector);
        b.setSip(1e6, 3600, 1);
        vm.expectRevert(IBucketAccount.NotOwner.selector);
        b.cancelSip();
        vm.stopPrank();
    }

    function test_OwnerOnlyAlsoRejectsFactoryAndKeeper() public {
        vm.prank(address(factory));
        vm.expectRevert(IBucketAccount.NotOwner.selector);
        b.setPaused(true);
        vm.prank(keeper);
        vm.expectRevert(IBucketAccount.NotOwner.selector);
        b.setParams(_defParams());
    }

    // ------------------------------------------------------------ params bounds
    function _tryParams(uint16 band, uint16 slip, uint16 maxTrade, uint32 cd, bool ok) internal {
        vm.prank(alice);
        if (!ok) vm.expectRevert(BucketAccount.BadParams.selector);
        b.setParams(BucketParams(band, slip, maxTrade, cd));
        if (ok) {
            BucketParams memory p = b.params();
            assertEq(p.bandBps, band);
            assertEq(p.maxSlippageBps, slip);
            assertEq(p.maxTradeBps, maxTrade);
            assertEq(p.cooldown, cd);
        }
    }

    function test_ParamBounds() public {
        _tryParams(99, 100, 2500, 3600, false);
        _tryParams(100, 100, 2500, 3600, true);
        _tryParams(2000, 100, 2500, 3600, true);
        _tryParams(2001, 100, 2500, 3600, false);

        _tryParams(500, 9, 2500, 3600, false);
        _tryParams(500, 10, 2500, 3600, true);
        _tryParams(500, 300, 2500, 3600, true);
        _tryParams(500, 301, 2500, 3600, false);

        _tryParams(500, 100, 499, 3600, false);
        _tryParams(500, 100, 500, 3600, true);
        _tryParams(500, 100, 5000, 3600, true);
        _tryParams(500, 100, 5001, 3600, false);

        _tryParams(500, 100, 2500, 599, false);
        _tryParams(500, 100, 2500, 600, true);
        _tryParams(500, 100, 2500, type(uint32).max, true);
    }

    function test_CreateBucketRejectsBadParams() public {
        vm.startPrank(alice);
        address[] memory t = _addrs(address(btc), address(usdc));
        uint16[] memory w = _wts(5000, 5000);
        vm.expectRevert(BucketAccount.BadParams.selector);
        factory.createBucket("x", t, w, BucketParams(50, 100, 2500, 3600));
        vm.expectRevert(BucketAccount.BadParams.selector);
        factory.createBucket("x", t, w, BucketParams(500, 5, 2500, 3600));
        vm.expectRevert(BucketAccount.BadParams.selector);
        factory.createBucket("x", t, w, BucketParams(500, 100, 6000, 3600));
        vm.expectRevert(BucketAccount.BadParams.selector);
        factory.createBucket("x", t, w, BucketParams(500, 100, 2500, 60));
        vm.stopPrank();
    }

    // ------------------------------------------------------------ targets
    function test_SetTargetsAppendsUsdcAndEmitsUniverse() public {
        address[] memory expT = _addrs(address(btc), address(eth), address(usdc));
        uint16[] memory expW = _wts(6000, 4000, 0);
        vm.expectEmit(false, false, false, true, address(b));
        emit IBucketAccount.TargetsSet(expT, expW, NO_TEMPLATE, 0);
        vm.prank(alice);
        b.setTargets(_addrs(address(btc), address(eth)), _wts(6000, 4000));
        (address[] memory t, uint16[] memory w) = b.targets();
        assertEq(t, expT);
        assertEq(w.length, 3);
        assertEq(w[2], 0);
    }

    function test_SetTargetsCarriesHeldAssetWithZeroWeight() public {
        vm.prank(alice);
        b.setTargets(_addrs(address(btc), address(eth)), _wts(5000, 5000));
        _mintMirror(address(eth), address(b), 1e18);
        vm.prank(alice);
        b.setTargets(_addrs(address(btc), address(usdc)), _wts(5000, 5000));
        (address[] memory t, uint16[] memory w) = b.targets();
        assertEq(t.length, 3);
        assertEq(t[2], address(eth));
        assertEq(w[2], 0);
    }

    function test_SetTargetsDropsUnheldAsset() public {
        vm.prank(alice);
        b.setTargets(_addrs(address(btc), address(eth)), _wts(5000, 5000));
        vm.prank(alice);
        b.setTargets(_addrs(address(btc), address(usdc)), _wts(5000, 5000));
        (address[] memory t,) = b.targets();
        assertEq(t.length, 2, "unheld eth is not carried");
    }

    function test_SetTargetsBadWeights() public {
        vm.startPrank(alice);
        vm.expectRevert(IBucketAccount.BadWeights.selector);
        b.setTargets(new address[](0), new uint16[](0));
        vm.expectRevert(IBucketAccount.BadWeights.selector);
        b.setTargets(_addrs(address(btc), address(usdc)), new uint16[](1));
        vm.expectRevert(IBucketAccount.BadWeights.selector);
        b.setTargets(_addrs(address(btc), address(usdc)), _wts(0, 10000));
        vm.expectRevert(IBucketAccount.BadWeights.selector);
        b.setTargets(_addrs(address(btc), address(usdc)), _wts(5000, 4999));
        vm.expectRevert(IBucketAccount.BadWeights.selector);
        b.setTargets(_addrs(address(btc), address(btc)), _wts(5000, 5000));
        vm.expectRevert(abi.encodeWithSelector(IAssetRegistry.UnknownAsset.selector, bob));
        b.setTargets(_addrs(address(btc), bob), _wts(5000, 5000));
        vm.stopPrank();
    }

    function _extras(uint256 n) internal returns (address[] memory ex) {
        ex = new address[](n);
        for (uint256 i; i < n; ++i) ex[i] = address(_listExtra("X", 6, address(mirrorVenue)));
    }

    function test_SetTargetsMoreThanTwelveReverts() public {
        address[] memory ex = _extras(13);
        uint16[] memory w = new uint16[](13);
        for (uint256 i; i < 13; ++i) w[i] = i == 0 ? 8800 : 100;
        vm.prank(alice);
        vm.expectRevert(IBucketAccount.BadWeights.selector);
        b.setTargets(ex, w);
    }

    function test_SetTargetsTwelveAccepted() public {
        address[] memory ex = _extras(12);
        uint16[] memory w = new uint16[](12);
        for (uint256 i; i < 12; ++i) w[i] = i == 0 ? 10000 - 11 * 800 : 800;
        vm.prank(alice);
        b.setTargets(ex, w);
        (address[] memory t,) = b.targets();
        assertEq(t.length, 13); // + USDC
    }

    function test_TooManyAssetsWhenCarriedUniverseExceeds16() public {
        address[] memory ex = _extras(16);
        address[] memory first = new address[](4);
        uint16[] memory fw = new uint16[](4);
        for (uint256 i; i < 4; ++i) {
            first[i] = ex[i];
            fw[i] = 2500;
        }
        BucketAccount b2 = _bucketFor(alice, first, fw, _defParams());
        for (uint256 i; i < 4; ++i) MockERC20(ex[i]).mint(address(b2), 1);
        address[] memory rest = new address[](12);
        uint16[] memory rw = new uint16[](12);
        for (uint256 i; i < 12; ++i) {
            rest[i] = ex[i + 4];
            rw[i] = i == 0 ? 10000 - 11 * 833 : 833;
        }
        vm.prank(alice);
        vm.expectRevert(BucketAccount.TooManyAssets.selector);
        b2.setTargets(rest, rw);
    }

    // ------------------------------------------------------------ pause
    function test_SetPausedEmitsAndToggles() public {
        vm.expectEmit(false, false, false, true, address(b));
        emit BucketAccount.PausedSet(true);
        vm.prank(alice);
        b.setPaused(true);
        assertTrue(b.paused());
        vm.prank(alice);
        b.setPaused(false);
        assertFalse(b.paused());
    }

    function test_PauseBlocksRebalanceAndSipButNotWithdrawals() public {
        vm.prank(alice);
        b.deposit(500e6);
        _mintMirror(address(btc), address(b), 1000);
        vm.startPrank(alice);
        b.setSip(10e6, 3600, 3);
        b.setPaused(true);
        vm.stopPrank();

        vm.expectRevert(IBucketAccount.Paused_.selector);
        b.rebalance();
        skip(3600);
        _refresh();
        vm.expectRevert(IBucketAccount.Paused_.selector);
        b.executeSip();

        vm.prank(alice);
        b.withdraw(address(usdc), 100e6, alice);
        assertEq(usdc.balanceOf(address(b)), 400e6);
        vm.prank(alice);
        b.withdrawAll(alice);
        assertEq(usdc.balanceOf(address(b)), 0);
        assertEq(btc.balanceOf(alice), 1000);
        assertEq(btc.balanceOf(address(b)), 0);
    }

    function test_UnpauseRestoresRebalance() public {
        vm.prank(alice);
        b.deposit(500e6);
        vm.prank(alice);
        b.setPaused(true);
        vm.prank(alice);
        b.setPaused(false);
        _fundReserve(0);
        vm.prank(keeper);
        b.rebalance(); // would revert Paused_ if still paused
        assertGt(btc.balanceOf(address(b)), 0);
    }

    // ------------------------------------------------------------ views
    function test_HoldingsAndDriftViews() public {
        vm.prank(alice);
        b.deposit(1_000e6);
        (address[] memory t, uint256[] memory amts, uint256[] memory vals, uint256 total) = b.holdings();
        assertEq(t.length, 2);
        assertEq(amts[1], 1_000e6);
        assertEq(vals[0], 0);
        assertEq(vals[1], 1_000e18);
        assertEq(total, 1_000e18);

        (uint16 maxDrift, int32[] memory per) = b.driftBps();
        assertEq(maxDrift, 5000);
        assertEq(per[0], -5000); // btc underweight
        assertEq(per[1], 5000); // usdc overweight
    }

    function test_HoldingsValueMirrorsPrice() public {
        _fundBtcAndUsdc(500e6, 833_333); // ~ $500 each
        (,, uint256[] memory vals, uint256 total) = b.holdings();
        assertEq(vals[0], registry.valueE18(address(btc), 833_333));
        assertEq(total, vals[0] + 500e18);
    }

    function _fundBtcAndUsdc(uint256 u, uint256 btcAmt) internal {
        usdc.mint(address(b), u);
        _mintMirror(address(btc), address(b), btcAmt);
    }

    function test_HoldingsToleratesStalePriceButDriftIsStrict() public {
        _fundBtcAndUsdc(100e6, 1_000_000);
        skip(3601); // btc stale; usdc priced 1e8 always
        (, uint256[] memory amts, uint256[] memory vals, uint256 total) = b.holdings();
        assertEq(amts[0], 1_000_000);
        assertEq(vals[0], 0, "stale token contributes 0");
        assertEq(total, 100e18);
        vm.expectRevert(abi.encodeWithSelector(IAssetRegistry.StalePrice.selector, address(btc)));
        b.driftBps();
    }

    function test_DriftOfEmptyBucketIsZero() public view {
        (uint16 maxDrift, int32[] memory per) = b.driftBps();
        assertEq(maxDrift, 0);
        assertEq(per.length, 2);
        assertEq(per[0], 0);
        assertEq(per[1], 0);
    }

    function test_DriftUsesEffectiveTargetsWhenRisk3() public {
        // 50/50 holdings; btc risk-3 => effective target usdc 100%, btc 0%
        _fundBtcAndUsdc(300e6, 500_000); // 500_000 sat = $300
        (uint16 before,) = b.driftBps();
        assertLe(before, 5);
        _setRisk(address(btc), 3);
        (uint16 afterDrift, int32[] memory per) = b.driftBps();
        assertApproxEqAbs(afterDrift, 5000, 5);
        assertGt(per[0], 0);
        assertLt(per[1], 0);
    }
}
