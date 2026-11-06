// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./TreasuryBase.t.sol";

contract BucketRebalanceTest is TreasuryBase {
    BucketAccount internal b;

    function setUp() public override {
        super.setUp();
        _fundReserve(1_000_000e6);
        b = _btcUsdcBucket();
    }

    function _rb(BucketAccount x) internal returns (uint16) {
        vm.prank(keeper);
        return x.rebalance();
    }

    // ------------------------------------------------------------ NotNeeded
    function test_EmptyBucketNotNeeded() public {
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IBucketAccount.NotNeeded.selector, uint16(0)));
        b.rebalance();
    }

    function test_InsideBandNotNeeded() public {
        vm.prank(alice);
        b.setTargets(_addrs(address(btc), address(usdc)), _wts(300, 9700));
        _fund(b, 1_000e6);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IBucketAccount.NotNeeded.selector, uint16(300)));
        b.rebalance();
    }

    function test_ExactlyAtBandNotNeededAndJustAboveRebalances() public {
        _fund(b, 1_000e6);
        vm.prank(alice);
        b.setTargets(_addrs(address(btc), address(usdc)), _wts(500, 9500));
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IBucketAccount.NotNeeded.selector, uint16(500)));
        b.rebalance();

        vm.prank(alice);
        b.setTargets(_addrs(address(btc), address(usdc)), _wts(501, 9499));
        assertEq(_rb(b), 501);
        // spend is the drift (501 bps of 1000 USDC), below the 25% cap
        assertEq(btc.balanceOf(address(b)), _buyOut(8, 60_000e8, 50_100_000));
    }

    function test_NotNeededCheckedBeforeCooldown() public {
        _fund(b, 1_000e6);
        _rb(b);
        vm.startPrank(alice);
        b.setParams(BucketParams(2000, 100, 2500, 3600));
        b.setTargets(_addrs(address(btc), address(usdc)), _wts(3000, 7000));
        vm.stopPrank();
        (uint16 d,) = b.driftBps();
        assertLe(d, 2000);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IBucketAccount.NotNeeded.selector, d));
        b.rebalance(); // inside cooldown, but band check wins
    }

    function test_StalePriceRevertsRebalance() public {
        _fund(b, 1_000e6);
        skip(3601);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IAssetRegistry.StalePrice.selector, address(btc)));
        b.rebalance();
    }

    // ------------------------------------------------------------ happy path / math / tip
    function test_BuyPathExactAmountsEventsAndTipCap() public {
        _fund(b, 1_000e6);
        uint256 spend = 250e6; // min(5000 bps drift = 500 USDC, 25% cap = 250 USDC, balance)
        uint256 btcOut = _buyOut(8, 60_000e8, spend);
        uint256 tip = 50_000; // min(0.05 USDC, 0.1% of 1000 USDC = 1 USDC)
        uint256 valueAfter = registry.valueE18(address(btc), btcOut) + (1_000e6 - spend - tip) * 1e12;

        vm.expectEmit(true, true, false, true, address(b));
        emit IBucketAccount.TradeExecuted(address(usdc), address(btc), spend, btcOut, address(mirrorVenue));
        vm.expectEmit(true, false, false, true, address(b));
        emit IBucketAccount.Rebalanced(keeper, 1_000e18, valueAfter, 5000, tip);
        uint16 drift = _rb(b);

        assertEq(drift, 5000);
        assertEq(btc.balanceOf(address(b)), btcOut);
        assertEq(usdc.balanceOf(address(b)), 1_000e6 - spend - tip);
        assertEq(usdc.balanceOf(keeper), tip);
        assertEq(b.lastRebalance(), uint64(block.timestamp));
        assertEq(usdc.allowance(address(b), address(mirrorVenue)), 0, "venue approval reset");
    }

    function test_TipIsProportionalForSmallBuckets() public {
        _fund(b, 10e6);
        _rb(b);
        assertEq(usdc.balanceOf(keeper), 10_000); // 0.1% of 10 USDC = 0.01 USDC < cap
    }

    function test_TipGoesToCallerNotOwner() public {
        _fund(b, 1_000e6);
        vm.prank(alice);
        b.rebalance();
        assertEq(usdc.balanceOf(alice), 50_000);
        assertEq(usdc.balanceOf(keeper), 0);
    }

    function test_MaxTradeBpsCapsTheBuy() public {
        _fund(b, 1_000e6);
        vm.prank(alice);
        b.setParams(BucketParams(500, 100, 500, 3600)); // 5% per trade
        _rb(b);
        assertEq(btc.balanceOf(address(b)), _buyOut(8, 60_000e8, 50e6));
        // with the max cap 50%, drift (50%) is the binding limit
        BucketAccount b2 = _btcUsdcBucket();
        _fund(b2, 1_000e6);
        vm.prank(alice);
        b2.setParams(BucketParams(500, 100, 5000, 3600));
        _rb(b2);
        assertEq(btc.balanceOf(address(b2)), _buyOut(8, 60_000e8, 500e6));
    }

    // ------------------------------------------------------------ cooldown
    function test_CooldownEnforcedThenReleased() public {
        _fund(b, 1_000e6);
        _rb(b);
        uint64 ready = uint64(T0 + 3600);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IBucketAccount.Cooldown.selector, ready));
        b.rebalance();

        vm.warp(ready - 1);
        _refresh();
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IBucketAccount.Cooldown.selector, ready));
        b.rebalance();

        vm.warp(ready);
        _refresh();
        uint256 btcBefore = btc.balanceOf(address(b));
        _rb(b);
        assertGt(btc.balanceOf(address(b)), btcBefore);
        assertEq(b.lastRebalance(), ready);
    }

    // ------------------------------------------------------------ sells before buys
    function _sellFirstBucket() internal returns (BucketAccount x) {
        x = _bucketFor(alice, _addrs(address(btc), address(eth)), _wts(5000, 5000), _defParams());
        _mintMirror(address(btc), address(x), 1_000_000); // 0.01 BTC = $600
        vm.prank(alice);
        x.setTargets(_addrs(address(eth), address(usdc)), _wts(5000, 5000)); // btc carried at weight 0
    }

    function test_SellsExecuteBeforeBuysAndFundThem() public {
        BucketAccount x = _sellFirstBucket();
        (address[] memory ts,) = x.targets();
        assertEq(ts.length, 3);
        assertEq(ts[2], address(btc));
        assertEq(usdc.balanceOf(address(x)), 0, "no cash: buy can only be funded by the sell");

        vm.recordLogs();
        uint16 drift = _rb(x);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(drift, 10_000);

        address[2] memory tIn;
        address[2] memory tOut;
        uint256 n;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(x) && logs[i].topics[0] == IBucketAccount.TradeExecuted.selector) {
                tIn[n] = address(uint160(uint256(logs[i].topics[1])));
                tOut[n] = address(uint160(uint256(logs[i].topics[2])));
                ++n;
            }
        }
        assertEq(n, 2);
        assertEq(tIn[0], address(btc), "first trade is a sell");
        assertEq(tOut[0], address(usdc));
        assertEq(tIn[1], address(usdc), "second trade is a buy");
        assertEq(tOut[1], address(eth));

        // sell cap = 25% of $600 = $150 => 250_000 sats; proceeds fund the whole ETH buy
        uint256 sold = 250_000;
        uint256 proceeds = _sellOut(8, 60_000e8, sold);
        assertEq(btc.balanceOf(address(x)), 1_000_000 - sold);
        assertEq(eth.balanceOf(address(x)), _buyOut(18, 3_000e8, proceeds));
        assertEq(usdc.balanceOf(address(x)), 0, "all proceeds spent; nothing left for a tip");
        assertEq(usdc.balanceOf(keeper), 0, "tip only paid when bucket USDC >= tip");
    }

    // ------------------------------------------------------------ slippage
    function _lossBucket(uint256 rateBps, bool enforce) internal returns (BucketAccount y) {
        LossyVenue lossy = new LossyVenue(registry, rateBps, enforce);
        MockERC20 loss = _listExtra("LOSS", 6, address(lossy));
        _setPrice(address(loss), 1e8);
        y = _bucketFor(alice, _addrs(address(loss), address(usdc)), _wts(5000, 5000), _defParams());
        _fund(y, 1_000e6);
    }

    function test_SlippageExceededWhenVenueUnderDelivers() public {
        BucketAccount y = _lossBucket(9000, false); // venue ignores minOut and sends 90%
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(BucketAccount.SlippageExceeded.selector, 225e6, 247_500_000));
        y.rebalance();
        assertEq(usdc.balanceOf(address(y)), 1_000e6, "reverted: funds untouched");
        assertEq(y.lastRebalance(), 0);
    }

    function test_VenueMinOutRevertsWhenEnforced() public {
        BucketAccount y = _lossBucket(9000, true);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IVenue.MinOut.selector, 225e6, 247_500_000));
        y.rebalance();
    }

    function test_SlippageBoundaryExactlyAtLimitPasses() public {
        BucketAccount y = _lossBucket(9900, false); // 1.00% == maxSlippageBps
        _rb(y);
        (, uint256[] memory amts,,) = y.holdings();
        assertEq(amts[0], 247_500_000);
    }

    function test_SlippageJustOverLimitReverts() public {
        BucketAccount y = _lossBucket(9899, false);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(BucketAccount.SlippageExceeded.selector, 247_475_000, 247_500_000));
        y.rebalance();
    }

    /// Mirror trades always lose the 30 bps spread, so a bucket whose maxSlippageBps < 30 can never trade a mirror asset.
    function test_SlippageBelowMirrorSpreadMakesMirrorTradesRevert() public {
        _fund(b, 1_000e6);
        vm.prank(alice);
        b.setParams(BucketParams(500, 29, 2500, 3600));
        uint256 spend = 250e6;
        uint256 ref = spend * 1e8 * 1e8 / (60_000e8 * 1e6);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IVenue.MinOut.selector, _buyOut(8, 60_000e8, spend), ref * 9971 / 10_000));
        b.rebalance();
        // exactly 30 bps works
        vm.prank(alice);
        b.setParams(BucketParams(500, 30, 2500, 3600));
        _rb(b);
        assertEq(btc.balanceOf(address(b)), _buyOut(8, 60_000e8, spend));
    }

    function test_TighterSlippageParamRejectsSmallLoss() public {
        BucketAccount y = _lossBucket(9970, false); // 0.3% loss
        vm.prank(alice);
        y.setParams(BucketParams(500, 10, 2500, 3600)); // 0.10% max
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(BucketAccount.SlippageExceeded.selector, 249_250_000, 249_750_000));
        y.rebalance();
    }

    // ------------------------------------------------------------ risk
    function test_Risk2BlocksBuysSoNothingToDo() public {
        _setRisk(address(btc), 2);
        _fund(b, 1_000e6);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IBucketAccount.NotNeeded.selector, uint16(5000)));
        b.rebalance();
        assertEq(btc.balanceOf(address(b)), 0);
    }

    function test_Risk2StillAllowsSells() public {
        _mintMirror(address(btc), address(b), 1_666_666); // ~ $1000, 100% btc
        _setRisk(address(btc), 2);
        _rb(b);
        assertLt(btc.balanceOf(address(b)), 1_666_666);
        assertGt(usdc.balanceOf(address(b)), 0);
    }

    function test_Risk3ExitsToUsdcEvenInsideBand() public {
        vm.prank(alice);
        b.setTargets(_addrs(address(btc), address(usdc)), _wts(500, 9500));
        _fund(b, 1_140e6);
        _mintMirror(address(btc), address(b), 100_000); // $60 = exactly 5%
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IBucketAccount.NotNeeded.selector, uint16(0)));
        b.rebalance();

        _setRisk(address(btc), 3);
        uint256 out = _sellOut(8, 60_000e8, 100_000);
        vm.expectEmit(true, true, false, true, address(b));
        emit IBucketAccount.TradeExecuted(address(btc), address(usdc), 100_000, out, address(mirrorVenue));
        assertEq(_rb(b), 500);
        assertEq(btc.balanceOf(address(b)), 0);
        assertEq(usdc.balanceOf(address(b)), 1_140e6 + out - 50_000);
    }

    function test_Risk3ExitsAcrossRebalancesAndIsNotRebought() public {
        BucketAccount x = _bucketFor(alice, _addrs(address(btc), address(eth)), _wts(5000, 5000), _defParams());
        _mintMirror(address(btc), address(x), 1_666_666); // ~ $1000
        _setRisk(address(btc), 3);
        uint256 b0 = btc.balanceOf(address(x));
        _rb(x);
        uint256 b1 = btc.balanceOf(address(x));
        assertLt(b1, b0);
        _warp(3600);
        _rb(x);
        uint256 b2 = btc.balanceOf(address(x));
        assertLt(b2, b1);
        assertGt(eth.balanceOf(address(x)), 0); // proceeds rotated into the healthy asset
    }

    function test_Risk3AssetIsNotBoughtAndFullyExitedBucketIsNotNeeded() public {
        _setRisk(address(btc), 3);
        _fund(b, 1_000e6); // 100% USDC; btc target (50%) is moved to cash
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IBucketAccount.NotNeeded.selector, uint16(0)));
        b.rebalance();
        assertEq(btc.balanceOf(address(b)), 0);
    }

    // ------------------------------------------------------------ real v4 venue via mock pool manager
    function test_RebalanceBuysEurcThroughV4Venue() public {
        BucketAccount x = _bucketFor(alice, _addrs(address(eurc), address(usdc)), _wts(5000, 5000), _defParams());
        _fund(x, 1_000e6);
        uint256 pmUsdc = usdc.balanceOf(address(pm));
        vm.expectEmit(true, true, false, true, address(x));
        emit IBucketAccount.TradeExecuted(address(usdc), address(eurc), 250e6, 249_875_000, address(v4Venue));
        _rb(x);
        assertEq(eurc.balanceOf(address(x)), 249_875_000);
        assertEq(usdc.balanceOf(address(pm)), pmUsdc + 250e6);
        assertEq(usdc.balanceOf(address(v4Venue)) + eurc.balanceOf(address(v4Venue)), 0);
    }

    function test_RebalanceSellsEurcThroughV4Venue() public {
        BucketAccount x = _bucketFor(alice, _addrs(address(eurc), address(usdc)), _wts(2000, 8000), _defParams());
        eurc.mint(address(x), 1_000e6); // 100% EURC vs 20% target
        _rb(x);
        assertEq(eurc.balanceOf(address(x)), 750e6); // sold 25% cap
        assertEq(usdc.balanceOf(address(x)), 249_875_000 - 50_000); // proceeds minus tip
    }

    function test_V4SlippageGuardReverts() public {
        BucketAccount x = _bucketFor(alice, _addrs(address(eurc), address(usdc)), _wts(5000, 5000), _defParams());
        _fund(x, 1_000e6);
        pm.setRate(9800); // 2% worse than par; limit is 1%
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IVenue.MinOut.selector, 245e6, 247_500_000));
        x.rebalance();
    }
}
