// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./TreasuryBase.t.sol";

contract BucketTemplateTest is TreasuryBase {
    function setUp() public override {
        super.setUp();
        _fundReserve(1_000_000e6);
        // template 0: 50% BTC / 50% USDC
        _setTemplate(0, _addrs(address(btc), address(usdc)), _wts(5000, 5000), 500);
    }

    function _follower() internal returns (BucketAccount x) {
        vm.prank(alice);
        x = BucketAccount(factory.createFromTemplate(0, true));
    }

    function _countTargetsSet(Vm.Log[] memory logs, address emitter) internal pure returns (uint256 n) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == emitter && logs[i].topics[0] == IBucketAccount.TargetsSet.selector) ++n;
        }
    }

    // ------------------------------------------------------------ followTemplate
    function test_FollowTemplateLoadsWeightsButKeepsBand() public {
        BucketAccount x = _bucketFor(alice, _addrs(address(eth), address(usdc)), _wts(1000, 9000), BucketParams(800, 50, 1000, 7200));
        address[] memory expT = _addrs(address(btc), address(usdc));
        vm.expectEmit(false, false, false, true, address(x));
        emit IBucketAccount.TargetsSet(expT, _wts(5000, 5000), 0, 1);
        vm.prank(alice);
        x.followTemplate(0, true);

        (address[] memory t, uint16[] memory w) = x.targets();
        assertEq(t[0], address(btc));
        assertEq(w[0], 5000);
        (uint256 id, bool following, uint32 v) = x.follow();
        assertEq(id, 0);
        assertTrue(following);
        assertEq(v, 1);
        assertEq(x.params().bandBps, 800, "template band is not applied");
    }

    function test_FollowTemplateOutOfRangeReverts() public {
        BucketAccount x = _follower();
        vm.prank(alice);
        vm.expectRevert(BucketAccount.IdOutOfRange.selector);
        x.followTemplate(1, true);
    }

    function test_FollowFalseStopsFollowingButKeepsTargets() public {
        BucketAccount x = _follower();
        vm.prank(alice);
        x.followTemplate(0, false);
        (, bool following,) = x.follow();
        assertFalse(following);
        (address[] memory t,) = x.targets();
        assertEq(t[0], address(btc));
    }

    function test_SetTargetsTurnsFollowingOff() public {
        BucketAccount x = _follower();
        vm.prank(alice);
        x.setTargets(_addrs(address(eth), address(usdc)), _wts(4000, 6000));
        (uint256 id, bool following, uint32 v) = x.follow();
        assertFalse(following);
        assertEq(id, NO_TEMPLATE);
        assertEq(v, 0);
    }

    // ------------------------------------------------------------ rebalance picks up new versions
    function test_RebalancePicksUpNewTemplateVersionAndEmitsTargetsSet() public {
        BucketAccount x = _follower();
        usdc.mint(address(x), 1_000e6);
        // curator moves the template to ETH/USDC (version 2)
        _setTemplate(0, _addrs(address(eth), address(usdc)), _wts(5000, 5000), 500);

        vm.expectEmit(false, false, false, true, address(x));
        emit IBucketAccount.TargetsSet(_addrs(address(eth), address(usdc)), _wts(5000, 5000), 0, 2);
        vm.prank(keeper);
        x.rebalance();

        (address[] memory t,) = x.targets();
        assertEq(t[0], address(eth));
        (,, uint32 v) = x.follow();
        assertEq(v, 2);
        assertEq(btc.balanceOf(address(x)), 0);
        assertEq(eth.balanceOf(address(x)), _buyOut(18, 3_000e8, 250e6), "bought the new template asset");
    }

    function test_NoTargetsSetWhenVersionUnchanged() public {
        BucketAccount x = _follower();
        usdc.mint(address(x), 1_000e6);
        vm.recordLogs();
        vm.prank(keeper);
        x.rebalance();
        assertEq(_countTargetsSet(vm.getRecordedLogs(), address(x)), 0);
    }

    function test_NonFollowerIgnoresTemplateUpdates() public {
        vm.prank(alice);
        BucketAccount x = BucketAccount(factory.createFromTemplate(0, false));
        usdc.mint(address(x), 1_000e6);
        _setTemplate(0, _addrs(address(eth), address(usdc)), _wts(5000, 5000), 500);
        vm.recordLogs();
        vm.prank(keeper);
        x.rebalance();
        assertEq(_countTargetsSet(vm.getRecordedLogs(), address(x)), 0);
        (address[] memory t,) = x.targets();
        assertEq(t[0], address(btc));
        assertGt(btc.balanceOf(address(x)), 0);
        assertEq(eth.balanceOf(address(x)), 0);
    }

    function test_FollowerAfterCustomTargetsIgnoresTemplateUpdates() public {
        BucketAccount x = _follower();
        vm.prank(alice);
        x.setTargets(_addrs(address(btc), address(usdc)), _wts(4000, 6000));
        usdc.mint(address(x), 1_000e6);
        _setTemplate(0, _addrs(address(eth), address(usdc)), _wts(5000, 5000), 500);
        vm.prank(keeper);
        x.rebalance();
        (address[] memory t, uint16[] memory w) = x.targets();
        assertEq(t[0], address(btc));
        assertEq(w[0], 4000);
    }

    function test_DroppedHeldAssetIsCarriedAndSoldDown() public {
        BucketAccount x = _follower();
        _mintMirror(address(btc), address(x), 1_666_666); // ~ $1000 of BTC, 100% of the bucket
        _setTemplate(0, _addrs(address(eth), address(usdc)), _wts(5000, 5000), 500);
        vm.prank(keeper);
        x.rebalance();
        (address[] memory t, uint16[] memory w) = x.targets();
        assertEq(t.length, 3);
        assertEq(t[2], address(btc));
        assertEq(w[2], 0);
        assertLt(btc.balanceOf(address(x)), 1_666_666, "BTC sold down");
        assertGt(eth.balanceOf(address(x)), 0, "proceeds rotate into new target");
    }

    function test_FollowerKeepsWorkingAcrossMultipleVersions() public {
        BucketAccount x = _follower();
        usdc.mint(address(x), 1_000e6);
        _setTemplate(0, _addrs(address(eth), address(usdc)), _wts(5000, 5000), 500); // v2
        _setTemplate(0, _addrs(address(eth), address(usdc)), _wts(6000, 4000), 500); // v3
        vm.prank(keeper);
        x.rebalance();
        (, uint16[] memory w) = x.targets();
        assertEq(w[0], 6000);
        (,, uint32 v) = x.follow();
        assertEq(v, 3);
    }
}
