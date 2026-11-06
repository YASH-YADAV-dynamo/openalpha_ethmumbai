// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {IBucketAccount, ITemplateRegistry} from "../IArcTreasury.sol";
import {BucketAccount} from "../BucketAccount.sol";
import {ArcBucketBase} from "./helpers/ArcBucketBase.sol";

contract ArcBucketTemplateTest is ArcBucketBase {
    bytes32 internal constant TARGETS_SIG = keccak256("TargetsSet(address[],uint16[],uint256,uint32)");

    BucketAccount internal f; // follows template 0
    BucketAccount internal nf; // copied template 0, does not follow

    function setUp() public override {
        super.setUp();
        vm.prank(curator);
        templates.setTemplate(0, _tpl(_arr(address(mBTC), address(eurc)), _w(6000, 4000), 500));
        vm.prank(alice);
        f = BucketAccount(factory.createFromTemplate(0, true));
        vm.prank(bob);
        nf = BucketAccount(factory.createFromTemplate(0, false));
        _fund(f, 10_000e6);
        _fund(nf, 10_000e6);
    }

    function _updateTemplate() internal {
        vm.prank(curator);
        templates.setTemplate(0, _tpl(_arr(address(mETH), address(mXAU)), _w(5000, 5000), 500));
    }

    function _targetsEvents(Vm.Log[] memory logs, address emitter) internal pure returns (uint256 n) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == emitter && logs[i].topics[0] == TARGETS_SIG) ++n;
        }
    }

    function test_Follow_PicksUpNewVersionOnRebalance() public {
        (, bool fl, uint32 v0) = f.follow();
        assertTrue(fl);
        assertEq(v0, 1);
        _updateTemplate(); // version 2
        // nothing changes until somebody rebalances
        (address[] memory t0,) = f.targets();
        assertEq(t0[0], address(mBTC));

        vm.expectEmit(false, false, false, true, address(f));
        emit IBucketAccount.TargetsSet(_arr(address(mETH), address(mXAU), USDC_ADDR), _w(5000, 5000, 0), 0, 2);
        vm.prank(keeper);
        f.rebalance();

        (address[] memory t, uint16[] memory w) = f.targets();
        assertEq(t[0], address(mETH));
        assertEq(t[1], address(mXAU));
        assertEq(w[0], 5000);
        assertEq(w[1], 5000);
        (uint256 id, bool following, uint32 ver) = f.follow();
        assertEq(id, 0);
        assertTrue(following);
        assertEq(ver, 2);
        // rebalanced into the NEW targets
        assertGt(mETH.balanceOf(address(f)), 0);
        assertGt(mXAU.balanceOf(address(f)), 0);
        assertEq(mBTC.balanceOf(address(f)), 0);
        assertEq(f.params().bandBps, 500); // band stays the bucket's own
    }

    function test_NoFollow_IgnoresNewVersion() public {
        _updateTemplate();
        vm.recordLogs();
        vm.prank(keeper);
        nf.rebalance();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_targetsEvents(logs, address(nf)), 0);
        (address[] memory t,) = nf.targets();
        assertEq(t[0], address(mBTC));
        assertEq(t[1], address(eurc));
        (uint256 id, bool following, uint32 ver) = nf.follow();
        assertEq(id, 0);
        assertFalse(following);
        assertEq(ver, 1);
        assertGt(mBTC.balanceOf(address(nf)), 0);
        assertEq(mETH.balanceOf(address(nf)), 0);
    }

    function test_Follow_NoEventWhenVersionUnchanged() public {
        vm.recordLogs();
        vm.prank(keeper);
        f.rebalance();
        assertEq(_targetsEvents(vm.getRecordedLogs(), address(f)), 0);
        (,, uint32 ver) = f.follow();
        assertEq(ver, 1);
    }

    function test_Follow_OldHoldingsCarriedAtZeroAndSoldDown() public {
        vm.prank(keeper);
        f.rebalance(); // v1: buys mBTC + eurc
        uint256 btc1 = mBTC.balanceOf(address(f));
        uint256 eur1 = eurc.balanceOf(address(f));
        assertGt(btc1, 0);
        vm.warp(block.timestamp + 3601);
        _feedAll();
        _updateTemplate();
        vm.prank(keeper);
        f.rebalance();
        (address[] memory t, uint16[] memory w) = f.targets();
        assertEq(t.length, 5); // mETH, mXAU, USDC, mBTC, eurc
        assertEq(t[2], USDC_ADDR);
        assertEq(t[3], address(mBTC));
        assertEq(w[3], 0);
        assertEq(t[4], address(eurc));
        assertEq(w[4], 0);
        assertLt(mBTC.balanceOf(address(f)), btc1); // being sold down
        assertLt(eurc.balanceOf(address(f)), eur1);
        assertGt(mETH.balanceOf(address(f)), 0);
    }

    function test_Follow_StopsAfterCustomTargets() public {
        vm.prank(alice);
        f.setTargets(_arr(address(mBTC), address(eurc)), _w(5000, 5000));
        _updateTemplate();
        vm.prank(keeper);
        f.rebalance();
        (address[] memory t,) = f.targets();
        assertEq(t[0], address(mBTC));
        assertEq(mETH.balanceOf(address(f)), 0);
    }

    function test_Follow_DisabledViaFollowTemplateFalse() public {
        vm.prank(alice);
        f.followTemplate(0, false);
        _updateTemplate();
        vm.prank(keeper);
        f.rebalance();
        (address[] memory t,) = f.targets();
        assertEq(t[0], address(mBTC));
        (, bool following,) = f.follow();
        assertFalse(following);
    }

    function test_Follow_SyncHappensBeforeCooldownAndNotNeededChecks() public {
        // a reverting rebalance rolls the sync back (state unchanged)
        BucketAccount e = BucketAccount(_mk());
        _updateTemplate();
        vm.prank(keeper);
        vm.expectPartialRevert(IBucketAccount.NotNeeded.selector); // empty bucket
        e.rebalance();
        (address[] memory t,) = e.targets();
        assertEq(t[0], address(mBTC));
    }

    function _mk() internal returns (address) {
        vm.prank(alice);
        return factory.createFromTemplate(0, true);
    }
}
