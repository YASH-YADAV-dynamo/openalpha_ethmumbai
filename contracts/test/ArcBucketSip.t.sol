// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {IAssetRegistry, IBucketAccount, BucketParams} from "../IArcTreasury.sol";
import {BucketAccount} from "../BucketAccount.sol";
import {ArcBucketBase} from "./helpers/ArcBucketBase.sol";
import {MirrorVenue} from "../MirrorVenue.sol";

contract ArcBucketSipTest is ArcBucketBase {
    event SipSet(uint256 amountUsdc, uint32 interval, uint32 runsLeft);
    event SipExecuted(address indexed caller, uint256 amountUsdc, uint32 runsLeft);

    BucketAccount internal b;

    function setUp() public override {
        super.setUp();
        b = _newBucket(alice, _arr(address(mBTC), address(mXAU), address(eurc)), _w(5000, 3000, 2000));
        _prepSipOwner(b, alice, 1_000_000e6);
    }

    function _setSip(BucketAccount x, uint256 amt, uint32 interval, uint32 runs) internal {
        vm.prank(alice);
        x.setSip(amt, interval, runs);
    }

    function _exec(BucketAccount x) internal {
        vm.prank(keeper);
        x.executeSip();
    }

    function _refresh() internal {
        _feedAll();
    }

    // ---------- setSip / cancelSip ----------
    function test_SetSip_StoresAndEmits() public {
        vm.expectEmit(false, false, false, true, address(b));
        emit SipSet(100e6, 7200, 12);
        _setSip(b, 100e6, 7200, 12);
        (uint256 a, uint32 i, uint32 r, uint64 n) = b.sip();
        assertEq(a, 100e6);
        assertEq(i, 7200);
        assertEq(r, 12);
        assertEq(n, block.timestamp + 7200); // first run is one interval away
        assertTrue(b.sipActive());
    }

    function test_SetSip_Bounds() public {
        vm.startPrank(alice);
        vm.expectRevert(BucketAccount.BadParams.selector);
        b.setSip(0, 3600, 1);
        vm.expectRevert(BucketAccount.BadParams.selector);
        b.setSip(1e6, 3599, 1);
        vm.expectRevert(BucketAccount.BadParams.selector);
        b.setSip(1e6, 0, 1);
        vm.expectRevert(BucketAccount.BadParams.selector);
        b.setSip(1e6, 3600, 0);
        vm.expectRevert(BucketAccount.BadParams.selector);
        b.setSip(1e6, 3600, 521);
        b.setSip(1, 3600, 1);
        b.setSip(1e6, type(uint32).max, 520);
        vm.stopPrank();
        (, uint32 i, uint32 r,) = b.sip();
        assertEq(i, type(uint32).max);
        assertEq(r, 520);
    }

    function test_Sip_InactiveWhenNeverSet_Cancelled_Finished() public {
        vm.expectRevert(IBucketAccount.SipInactive.selector);
        _exec(b);
        _setSip(b, 10e6, 3600, 2);
        vm.expectEmit(false, false, false, true, address(b));
        emit SipSet(0, 0, 0);
        vm.prank(alice);
        b.cancelSip();
        (,, uint32 r,) = b.sip();
        assertEq(r, 0);
        assertFalse(b.sipActive());
        vm.warp(block.timestamp + 3600);
        vm.expectRevert(IBucketAccount.SipInactive.selector);
        _exec(b);
        // re-arming works after cancel
        _setSip(b, 10e6, 3600, 1);
        vm.warp(block.timestamp + 3600);
        _refresh();
        _exec(b);
        vm.expectRevert(IBucketAccount.SipInactive.selector);
        _exec(b);
    }

    // ---------- due time ----------
    function test_SipNotDue_BeforeNextAt() public {
        _setSip(b, 10e6, 3600, 3);
        (,,, uint64 n) = b.sip();
        vm.expectRevert(abi.encodeWithSelector(IBucketAccount.SipNotDue.selector, n));
        _exec(b);
        vm.warp(n - 1);
        vm.expectRevert(abi.encodeWithSelector(IBucketAccount.SipNotDue.selector, n));
        _exec(b);
        vm.warp(n);
        _refresh();
        _exec(b);
        (,, uint32 r,) = b.sip();
        assertEq(r, 2);
    }

    function test_Sip_RunsCountDownToInactive() public {
        _setSip(b, 10e6, 3600, 3);
        for (uint32 k = 1; k <= 3; ++k) {
            vm.warp(block.timestamp + 3600);
            _refresh();
            vm.expectEmit(true, false, false, true, address(b));
            emit SipExecuted(keeper, 10e6, 3 - k);
            _exec(b);
            (,, uint32 r,) = b.sip();
            assertEq(r, 3 - k);
        }
        assertFalse(b.sipActive());
        vm.warp(block.timestamp + 3600);
        _refresh();
        vm.expectRevert(IBucketAccount.SipInactive.selector);
        _exec(b);
    }

    function test_Sip_NextAtOnTimeAndSlightlyLate() public {
        _setSip(b, 10e6, 3600, 5);
        (,,, uint64 n0) = b.sip();
        vm.warp(n0);
        _refresh();
        _exec(b);
        (,,, uint64 n1) = b.sip();
        assertEq(n1, n0 + 3600);
        vm.warp(n1 + 100); // 100s late, still less than one interval
        _refresh();
        _exec(b);
        (,,, uint64 n2) = b.sip();
        assertEq(n2, n1 + 3600); // schedule is not shifted by lateness
        assertGe(n2, block.timestamp);
    }

    function test_Sip_LateKeeperNextAtNeverInPast() public {
        _setSip(b, 10e6, 3600, 5);
        (,,, uint64 n0) = b.sip();
        vm.warp(n0 + 5 * 3600 + 17); // keeper missed 5 intervals
        _refresh();
        _exec(b);
        (,,, uint64 n1) = b.sip();
        assertEq(n1, uint64(block.timestamp)); // clamped to now, not n0 + 3600
        assertGe(n1, block.timestamp);
        // catch-up run is immediately allowed, then the schedule resumes from now
        _exec(b);
        (,, uint32 r, uint64 n2) = b.sip();
        assertEq(r, 3);
        assertEq(n2, uint64(block.timestamp) + 3600);
    }

    // ---------- money flow ----------
    function test_Sip_PullsFromOwnerAndBuysProRata() public {
        _setSip(b, 1_000e6, 3600, 2);
        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.warp(block.timestamp + 3600);
        _refresh();
        vm.recordLogs();
        _exec(b);
        Trade[] memory t = _trades(vm.getRecordedLogs(), address(b));
        assertEq(usdc.balanceOf(alice), aliceBefore - 1_000e6);
        assertEq(usdc.balanceOf(keeper), 0); // keeper pays nothing, only the owner funds the SIP
        assertEq(t.length, 3);
        assertEq(t[0].tokenOut, address(mBTC));
        assertEq(t[0].amountIn, 500e6);
        assertEq(t[1].tokenOut, address(mXAU));
        assertEq(t[1].amountIn, 300e6);
        assertEq(t[2].tokenOut, address(eurc));
        assertEq(t[2].amountIn, 200e6);
        assertEq(mBTC.balanceOf(address(b)), t[0].amountOut);
        assertEq(mXAU.balanceOf(address(b)), t[1].amountOut);
        assertEq(t[1].amountOut, 300e6 * 1e8 * 1e6 / (pXAU * 1e6) * 9970 / 10000);
        assertEq(usdc.balanceOf(address(b)), 0);
    }

    function test_Sip_RevertsWithoutAllowanceOrBalance() public {
        BucketAccount c = _newBucket(bob, _arr(address(mBTC)), _w(10000));
        vm.prank(bob);
        c.setSip(10e6, 3600, 2);
        vm.warp(block.timestamp + 3600);
        _refresh();
        vm.expectRevert(); // bob never approved the bucket
        _exec(c);
        (,, uint32 r,) = c.sip();
        assertEq(r, 2); // revert rolled back the effects
        _prepSipOwner(c, bob, 5e6); // approved but short of funds
        vm.expectRevert();
        _exec(c);
        usdc.mint(bob, 100e6);
        _exec(c);
        (,, r,) = c.sip();
        assertEq(r, 1);
    }

    function test_Sip_SkipsRiskyAssetsKeepingShareAsUsdc() public {
        _setSip(b, 1_000e6, 3600, 1);
        _setRisk(address(mXAU), 2);
        vm.warp(block.timestamp + 3600);
        _refresh();
        vm.recordLogs();
        _exec(b);
        Trade[] memory t = _trades(vm.getRecordedLogs(), address(b));
        assertEq(t.length, 2);
        assertEq(t[0].tokenOut, address(mBTC));
        assertEq(t[1].tokenOut, address(eurc));
        assertEq(mXAU.balanceOf(address(b)), 0);
        // 300 USDC share stays as cash, minus the 0.05 USDC keeper tip paid from it
        assertEq(usdc.balanceOf(address(b)), 300e6 - 50_000);
        assertEq(usdc.balanceOf(keeper), 50_000);
        // level 3 is skipped as well
        _setRisk(address(mXAU), 3);
        assertEq(registry.riskOf(address(mXAU)), 3);
    }

    function test_Sip_UsdcWeightStaysAsCash() public {
        BucketAccount c = _newBucket(alice, _arr(address(mBTC), USDC_ADDR), _w(4000, 6000));
        _prepSipOwner(c, alice, 0);
        _setSip(c, 1_000e6, 3600, 1);
        vm.warp(block.timestamp + 3600);
        _refresh();
        vm.recordLogs();
        _exec(c);
        Trade[] memory t = _trades(vm.getRecordedLogs(), address(c));
        assertEq(t.length, 1);
        assertEq(t[0].amountIn, 400e6);
        assertEq(usdc.balanceOf(address(c)), 600e6 - usdc.balanceOf(keeper));
    }

    function test_Sip_TipMatchesFormula() public {
        BucketAccount c = _newBucket(alice, _arr(address(mBTC), USDC_ADDR), _w(5000, 5000));
        _prepSipOwner(c, alice, 0);
        uint256[3] memory amts = [uint256(10e6), 60e6, 400e6];
        uint256 lastPaid;
        for (uint256 i; i < 3; ++i) {
            uint256 kBefore = usdc.balanceOf(keeper);
            _setSip(c, amts[i], 3600, 1);
            vm.warp(block.timestamp + 3600);
            _refresh();
            uint256 totalBefore = _total(c);
            _exec(c);
            uint256 paid = usdc.balanceOf(keeper) - kBefore;
            uint256 valueAtTip = _total(c) + paid * 1e12; // bucket value just before the tip left
            uint256 expected = valueAtTip / 1e12 * 10 / 10_000;
            if (expected > 50_000) expected = 50_000;
            assertEq(paid, expected);
            lastPaid = paid;
            assertGt(valueAtTip, totalBefore);
        }
        // the last (400 USDC) run leaves a bucket worth > 50 USDC so the cap binds: tip == 0.05 USDC
        assertEq(lastPaid, 50_000);
    }

    function test_Sip_NoTipWhenNoCashLeft() public {
        _setSip(b, 100e6, 3600, 1); // 100% of weights are risky assets -> all cash is spent
        vm.warp(block.timestamp + 3600);
        _refresh();
        _exec(b);
        assertEq(usdc.balanceOf(address(b)), 0);
        assertEq(usdc.balanceOf(keeper), 0);
    }

    function test_Sip_AnyoneCanExecute_OwnerKeepsControl() public {
        _setSip(b, 10e6, 3600, 2);
        vm.warp(block.timestamp + 3600);
        _refresh();
        vm.prank(bob);
        b.executeSip();
        (,, uint32 r,) = b.sip();
        assertEq(r, 1);
        assertEq(b.owner(), alice);
    }

    // ---------- pause ----------
    function test_Paused_BlocksExecuteSip_WithdrawStillWorks() public {
        _setSip(b, 10e6, 3600, 2);
        vm.warp(block.timestamp + 3600);
        _refresh();
        _exec(b);
        usdc.mint(address(b), 5e6);
        vm.prank(alice);
        b.setPaused(true);
        vm.warp(block.timestamp + 3600);
        _refresh();
        vm.expectRevert(IBucketAccount.Paused_.selector);
        _exec(b);
        uint256 btc = mBTC.balanceOf(address(b));
        assertGt(btc, 0);
        vm.prank(alice);
        b.withdraw(address(mBTC), btc / 2, alice);
        assertEq(mBTC.balanceOf(alice), btc / 2);
        vm.prank(alice);
        b.withdrawAll(alice);
        assertEq(mBTC.balanceOf(address(b)), 0);
        assertEq(usdc.balanceOf(address(b)), 0);
        // un-pausing resumes
        vm.prank(alice);
        b.setPaused(false);
        _exec(b);
    }

    /// @dev Documents a limitation (reported as a suspected issue): a SIP share above the MirrorVenue
    ///      5,000 USDC cap makes the whole executeSip revert (the run can never succeed as configured).
    function test_KnownLimitation_SipShareAboveMirrorCapReverts() public {
        BucketAccount c = _newBucket(alice, _arr(address(mBTC)), _w(10000));
        _prepSipOwner(c, alice, 0);
        _setSip(c, 6_000e6, 3600, 1);
        vm.warp(block.timestamp + 3600);
        _refresh();
        vm.expectPartialRevert(MirrorVenue.TradeTooLarge.selector);
        _exec(c);
    }
}
