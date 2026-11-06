// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {IAssetRegistry, IVenue, IBucketAccount, BucketParams} from "../IArcTreasury.sol";
import {BucketAccount} from "../BucketAccount.sol";
import {ArcBucketBase, LyingVenue} from "./helpers/ArcBucketBase.sol";
import {MockERC20} from "./helpers/MockERC20.sol";
import {MirrorVenue} from "../MirrorVenue.sol";

contract ArcBucketRebalanceTest is ArcBucketBase {
    BucketAccount internal b;

    function setUp() public override {
        super.setUp();
        b = _newBucket(alice, _arr(address(mBTC), address(eurc)), _w(5000, 5000));
        _fund(b, 10_000e6);
    }

    function _rb(BucketAccount x) internal returns (uint16) {
        vm.prank(keeper);
        return x.rebalance();
    }

    function _euroOut(uint256 usdcIn) internal pure returns (uint256) {
        return usdcIn * 925_926 / 1e6 * 999_500 / 1e6;
    }

    function _btcOut(uint256 usdcIn) internal view returns (uint256) {
        return usdcIn * 1e8 * 1e8 / (pBTC * 1e6) * 9970 / 10000;
    }

    function _next() internal {
        vm.warp(block.timestamp + 3601);
        _feedAll();
    }

    // ---------- buys, cap, tip, events ----------
    function test_Rebalance_BuysRespectCapAndPayTip() public {
        vm.recordLogs();
        vm.prank(keeper);
        uint16 d = b.rebalance();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(d, 10_000);
        Trade[] memory t = _trades(logs, address(b));
        assertEq(t.length, 2);
        // maxTradeBps 2500 of 10_000 USDC => 2_500 USDC per trade (target would have been 5_000)
        assertEq(t[0].tokenIn, USDC_ADDR);
        assertEq(t[0].tokenOut, address(mBTC));
        assertEq(t[0].amountIn, 2_500e6);
        assertEq(t[0].amountOut, _btcOut(2_500e6));
        assertEq(t[0].venue, address(mvenue));
        assertEq(t[1].tokenOut, address(eurc));
        assertEq(t[1].amountIn, 2_500e6);
        assertEq(t[1].amountOut, _euroOut(2_500e6));
        assertEq(t[1].venue, address(uvenue));
        assertEq(mBTC.balanceOf(address(b)), t[0].amountOut);
        assertEq(eurc.balanceOf(address(b)), t[1].amountOut);
        // tip = min(0.05 USDC, 0.1% of 10_000 USDC) = 0.05 USDC
        assertEq(usdc.balanceOf(keeper), 50_000);
        assertEq(usdc.balanceOf(address(b)), 5_000e6 - 50_000);
        (bool found, uint256 vb, uint256 va, uint16 dr, uint256 tip) = _rebalanced(logs, address(b));
        assertTrue(found);
        assertEq(vb, 10_000e18);
        assertEq(dr, 10_000);
        assertEq(tip, 50_000);
        assertLt(va, vb);
        assertGt(va, vb - 20e18); // only spread + tip lost
        assertEq(b.lastRebalance(), block.timestamp);
        // venue approvals are reset
        assertEq(usdc.allowance(address(b), address(mvenue)), 0);
        assertEq(usdc.allowance(address(b), address(uvenue)), 0);
    }

    function test_Tip_IsMinOfCapAndTenthPercent() public {
        BucketAccount s = _newBucket(alice, _arr(address(eurc)), _w(10000));
        _fund(s, 10e6); // 0.1% = 0.01 USDC
        vm.prank(keeper);
        s.rebalance();
        assertEq(usdc.balanceOf(keeper), 10_000);
        BucketAccount m = _newBucket(alice, _arr(address(eurc)), _w(10000));
        _fund(m, 49e6); // 0.1% = 0.049 USDC
        vm.prank(bob);
        m.rebalance();
        assertEq(usdc.balanceOf(bob), 49_000);
        BucketAccount l = _newBucket(alice, _arr(address(eurc)), _w(10000));
        _fund(l, 200_000e6); // 0.1% = 200 USDC => capped
        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        l.rebalance();
        assertEq(usdc.balanceOf(alice), before + 50_000);
    }

    function test_Tip_NoneWhenUsdcShort() public {
        BucketAccount c = _newBucketP(alice, _arr(address(eurc), address(mBTC)), _w(5000, 5000), _params(500, 100, 5000, 3600));
        eurc.mint(address(c), 8_000e6); // 8,640 USD of EURC, no USDC
        vm.recordLogs();
        _rb(c);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Trade[] memory t = _trades(logs, address(c));
        assertEq(t.length, 2);
        assertEq(t[0].tokenIn, address(eurc));
        assertEq(t[0].amountIn, 4_000e6); // capped at 50% of value
        assertEq(t[1].amountIn, t[0].amountOut); // all proceeds spent
        assertEq(usdc.balanceOf(address(c)), 0);
        assertEq(usdc.balanceOf(keeper), 0);
        (, , , , uint256 tip) = _rebalanced(logs, address(c));
        assertEq(tip, 0);
    }

    function test_Sell_CappedByMaxTradeBps() public {
        BucketAccount c = _newBucket(alice, _arr(address(eurc), address(mBTC)), _w(5000, 5000));
        eurc.mint(address(c), 10_000e6); // 10,800 USD, no cash
        vm.recordLogs();
        _rb(c);
        Trade[] memory t = _trades(vm.getRecordedLogs(), address(c));
        assertEq(t[0].tokenIn, address(eurc));
        assertEq(t[0].tokenOut, USDC_ADDR);
        assertEq(t[0].amountIn, 2_500e6); // 25% of 10,800 USD = 2,700 USD = 2,500 EURC
        assertEq(t[0].amountOut, 2_500e6 * 1_080_000 / 1e6 * 999_500 / 1e6);
        assertEq(eurc.balanceOf(address(c)), 7_500e6);
        assertEq(eurc.allowance(address(c), address(uvenue)), 0);
    }

    function test_SellsExecuteBeforeBuys() public {
        BucketAccount c = _newBucket(alice, _arr(address(mBTC), address(eurc)), _w(2000, 8000));
        _fund(c, 10_000e6);
        _rb(c);
        assertGt(mBTC.balanceOf(address(c)), 0);
        pBTC = 120_000e8; // BTC doubles -> overweight, EURC underweight
        _next();
        uint256 btcBefore = mBTC.balanceOf(address(c));
        vm.recordLogs();
        _rb(c);
        Trade[] memory t = _trades(vm.getRecordedLogs(), address(c));
        assertGe(t.length, 2);
        bool seenBuy;
        uint256 sells;
        uint256 buys;
        for (uint256 i; i < t.length; ++i) {
            if (t[i].tokenOut == USDC_ADDR) {
                assertFalse(seenBuy); // a sell after a buy would violate the ordering
                ++sells;
            } else {
                assertEq(t[i].tokenIn, USDC_ADDR);
                seenBuy = true;
                ++buys;
            }
        }
        assertGe(sells, 1);
        assertGe(buys, 1);
        assertEq(t[0].tokenIn, address(mBTC));
        assertLt(mBTC.balanceOf(address(c)), btcBefore);
    }

    // ---------- NotNeeded / Cooldown ordering ----------
    function test_NotNeeded_InsideBand() public {
        BucketAccount c = _newBucketP(alice, _arr(address(eurc), USDC_ADDR), _w(5000, 5000), _params(500, 100, 5000, 3600));
        _fund(c, 10_000e6);
        _rb(c);
        (uint16 d,) = c.driftBps();
        assertLe(d, 500);
        // inside the band -> NotNeeded, even immediately (cooldown is only checked afterwards)
        vm.expectRevert(abi.encodeWithSelector(IBucketAccount.NotNeeded.selector, d));
        _rb(c);
        _next();
        (d,) = c.driftBps();
        vm.expectRevert(abi.encodeWithSelector(IBucketAccount.NotNeeded.selector, d));
        _rb(c);
    }

    function test_NotNeeded_EmptyBucket() public {
        BucketAccount c = _newBucket(alice, _arr(address(mBTC)), _w(10000));
        vm.expectRevert(abi.encodeWithSelector(IBucketAccount.NotNeeded.selector, uint16(0)));
        _rb(c);
        BucketAccount u = _newBucket(alice, _arr(USDC_ADDR), _w(10000));
        _fund(u, 100e6);
        vm.expectRevert(abi.encodeWithSelector(IBucketAccount.NotNeeded.selector, uint16(0)));
        _rb(u);
    }

    function test_Cooldown_RevertsThenAllowsAtReadyAt() public {
        _rb(b);
        uint64 readyAt = uint64(block.timestamp) + 3600;
        // still far outside the band, so the cooldown is what blocks it
        vm.expectRevert(abi.encodeWithSelector(IBucketAccount.Cooldown.selector, readyAt));
        _rb(b);
        vm.warp(readyAt - 1);
        vm.expectRevert(abi.encodeWithSelector(IBucketAccount.Cooldown.selector, readyAt));
        _rb(b);
        vm.warp(readyAt);
        vm.recordLogs();
        _rb(b);
        assertEq(_trades(vm.getRecordedLogs(), address(b)).length, 2);
        assertEq(b.lastRebalance(), readyAt);
    }

    function test_NoTradeRebalance_Reverts_AndStateUnchanged() public {
        BucketAccount c = _newBucket(alice, _arr(address(mBTC)), _w(10000));
        _fund(c, 1_000e6);
        _setRisk(address(mBTC), 2); // may be held/sold but never bought
        vm.expectRevert(abi.encodeWithSelector(IBucketAccount.NotNeeded.selector, uint16(10_000)));
        _rb(c);
        assertEq(c.lastRebalance(), 0);
        assertEq(usdc.balanceOf(address(c)), 1_000e6);
        assertEq(usdc.balanceOf(keeper), 0);
    }

    // ---------- risk ----------
    function test_RiskAtLeast2_NotBought() public {
        _setRisk(address(mBTC), 2);
        vm.recordLogs();
        _rb(b);
        Trade[] memory t = _trades(vm.getRecordedLogs(), address(b));
        assertEq(t.length, 1);
        assertEq(t[0].tokenOut, address(eurc));
        assertEq(mBTC.balanceOf(address(b)), 0);
        // same for level 3
        BucketAccount c = _newBucket(alice, _arr(address(mETH), address(eurc)), _w(5000, 5000));
        _fund(c, 1_000e6);
        _setRisk(address(mETH), 3);
        _rb(c);
        assertEq(mETH.balanceOf(address(c)), 0);
        assertGt(eurc.balanceOf(address(c)), 0);
    }

    function test_Risk3_ExitsToUsdcEvenInsideBand() public {
        BucketAccount c = _newBucket(alice, _arr(address(mBTC), USDC_ADDR), _w(100, 9900));
        _fund(c, 9_900e6);
        _giveMirror(address(mBTC), address(c), 100e6); // ~1% of the bucket
        vm.expectPartialRevert(IBucketAccount.NotNeeded.selector); // healthy + in band
        _rb(c);
        uint256 btcBefore = mBTC.balanceOf(address(c));
        uint256 usdcBefore = usdc.balanceOf(address(c));
        _setRisk(address(mBTC), 3);
        (uint16 d,) = c.driftBps();
        assertLe(d, 500); // still inside the band, only the exit rule fires
        uint16 ret = _rb(c);
        assertLe(ret, 500);
        assertLt(mBTC.balanceOf(address(c)), btcBefore / 50); // < 2% left (sub-bps rounding dust)
        assertGt(usdc.balanceOf(address(c)), usdcBefore);
    }

    function test_Risk3_FullExitBeyondBand() public {
        _rb(b); // buys mBTC + eurc
        _next();
        _setRisk(address(mBTC), 3);
        uint256 btcBefore = mBTC.balanceOf(address(b));
        vm.recordLogs();
        _rb(b);
        Trade[] memory t = _trades(vm.getRecordedLogs(), address(b));
        assertEq(t[0].tokenIn, address(mBTC));
        assertEq(t[0].tokenOut, USDC_ADDR);
        assertLt(mBTC.balanceOf(address(b)), btcBefore);
        for (uint256 i; i < t.length; ++i) assertTrue(t[i].tokenOut != address(mBTC)); // never re-bought
    }

    // ---------- slippage vs registry price ----------
    function test_Slippage_MirrorSpreadExceedsTightBound() public {
        BucketAccount c = _newBucketP(alice, _arr(address(mBTC)), _w(10000), _params(500, 10, 2500, 3600));
        _fund(c, 1_000e6);
        // venue charges 0.30% but the bucket tolerates only 0.10%
        vm.expectPartialRevert(IVenue.MinOut.selector);
        _rb(c);
        vm.prank(alice);
        c.setParams(_params(500, 100, 2500, 3600));
        _rb(c);
        assertGt(mBTC.balanceOf(address(c)), 0);
    }

    function test_Slippage_RegistryBelowPool_BuyReverts() public {
        // registry says EURC = 1.00 while the pool sells it at 1.08 => ~7.5% shortfall
        _feedOne(address(eurc), 1e8);
        BucketAccount c = _newBucketP(alice, _arr(address(eurc)), _w(10000), _params(500, 300, 2500, 3600));
        _fund(c, 1_000e6);
        vm.expectPartialRevert(IVenue.MinOut.selector);
        _rb(c);
        assertEq(usdc.balanceOf(address(c)), 1_000e6);
        // moderate (0.5%) disagreement is inside the default 1% tolerance
        _feedOne(address(eurc), 1.075e8);
        _rb(c);
        assertGt(eurc.balanceOf(address(c)), 0);
    }

    function test_Slippage_RegistryAbovePool_SellReverts() public {
        BucketAccount c = _newBucketP(alice, _arr(address(eurc), USDC_ADDR), _w(5000, 5000), _params(500, 100, 5000, 3600));
        eurc.mint(address(c), 10_000e6);
        _feedOne(address(eurc), 1.2e8); // pool still pays 1.08
        vm.expectPartialRevert(IVenue.MinOut.selector);
        _rb(c);
        assertEq(eurc.balanceOf(address(c)), 10_000e6);
    }

    function test_Slippage_BucketChecksReceivedAmountItself() public {
        LyingVenue lv = new LyingVenue();
        MockERC20 lt = new MockERC20("L", "L", 6);
        vm.prank(owner);
        registry.listAsset(IAssetRegistry.Asset(address(lt), "L", IAssetRegistry.Category.Yield, 6, address(lv), false, ""));
        _feedOne(address(lt), 1e8);
        lt.mint(address(lv), 1_000_000e6);
        BucketAccount c = _newBucket(alice, _arr(address(lt)), _w(10000));
        _fund(c, 10_000e6);
        // spend 2,500 USDC (25% cap) => min 2,475; lying venue delivers half of that
        vm.expectRevert(abi.encodeWithSelector(BucketAccount.SlippageExceeded.selector, 1_237_500_000, 2_475_000_000));
        _rb(c);
    }

    // ---------- guards ----------
    function test_StalePrice_RevertsRebalance() public {
        vm.warp(block.timestamp + 3601);
        vm.expectRevert(abi.encodeWithSelector(IAssetRegistry.StalePrice.selector, address(mBTC)));
        _rb(b);
    }

    function test_Paused_BlocksRebalance() public {
        vm.prank(alice);
        b.setPaused(true);
        vm.expectRevert(IBucketAccount.Paused_.selector);
        _rb(b);
        vm.prank(alice);
        b.setPaused(false);
        _rb(b);
        assertGt(mBTC.balanceOf(address(b)), 0);
    }

    function test_Rebalance_CallableByAnyone() public {
        vm.prank(bob);
        b.rebalance();
        assertEq(usdc.balanceOf(bob), 50_000);
        assertEq(b.owner(), alice);
    }

    /// @dev Documents a limitation (reported as a suspected issue): the bucket does not clamp its
    ///      trade size to the MirrorVenue 5,000 USDC cap, so a large bucket's rebalance reverts.
    function test_KnownLimitation_LargeBucketHitsMirrorTradeCap() public {
        BucketAccount c = _newBucket(alice, _arr(address(mBTC)), _w(10000));
        _fund(c, 30_000e6); // 25% cap = 7,500 USDC > venue cap 5,000
        vm.expectPartialRevert(MirrorVenue.TradeTooLarge.selector);
        _rb(c);
    }
}
