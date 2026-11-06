// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./TreasuryBase.t.sol";

contract BucketSipTest is TreasuryBase {
    BucketAccount internal b;
    uint256 internal constant AMT = 100e6;

    function setUp() public override {
        super.setUp();
        _fundReserve(1_000_000e6);
        b = _bucketFor(alice, _addrs(address(btc), address(eth), address(usdc)), _wts(5000, 3000, 2000), _defParams());
        usdc.mint(alice, 100_000e6);
        vm.prank(alice);
        usdc.approve(address(b), type(uint256).max);
    }

    function _startSip(uint32 runs) internal {
        vm.prank(alice);
        b.setSip(AMT, 3600, runs);
    }

    function _run() internal {
        vm.prank(keeper);
        b.executeSip();
    }

    // ------------------------------------------------------------ setSip / cancelSip
    function test_SetSipStoresAndEmits() public {
        vm.expectEmit(false, false, false, true, address(b));
        emit IBucketAccount.SipSet(AMT, 3600, 5);
        vm.prank(alice);
        b.setSip(AMT, 3600, 5);
        (uint256 a, uint32 i, uint32 r, uint64 n) = b.sip();
        assertEq(a, AMT);
        assertEq(i, 3600);
        assertEq(r, 5);
        assertEq(n, uint64(block.timestamp + 3600), "first run is one interval after setting");
        assertTrue(b.sipActive());
    }

    function test_SetSipBounds() public {
        vm.startPrank(alice);
        vm.expectRevert(BucketAccount.BadParams.selector);
        b.setSip(0, 3600, 1);
        vm.expectRevert(BucketAccount.BadParams.selector);
        b.setSip(AMT, 3599, 1);
        vm.expectRevert(BucketAccount.BadParams.selector);
        b.setSip(AMT, 3600, 0);
        vm.expectRevert(BucketAccount.BadParams.selector);
        b.setSip(AMT, 3600, 521);
        b.setSip(AMT, 3600, 520);
        b.setSip(1, type(uint32).max, 1);
        vm.stopPrank();
    }

    function test_CancelSipDeactivates() public {
        _startSip(3);
        vm.expectEmit(false, false, false, true, address(b));
        emit IBucketAccount.SipSet(0, 0, 0);
        vm.prank(alice);
        b.cancelSip();
        assertFalse(b.sipActive());
        (,, uint32 r,) = b.sip();
        assertEq(r, 0);
        skip(3600);
        _refresh();
        vm.prank(keeper);
        vm.expectRevert(IBucketAccount.SipInactive.selector);
        b.executeSip();
    }

    function test_ExecuteWithoutSipIsInactive() public {
        vm.prank(keeper);
        vm.expectRevert(IBucketAccount.SipInactive.selector);
        b.executeSip();
    }

    // ------------------------------------------------------------ due / not due
    function test_NotDueUntilNextAt() public {
        _startSip(3);
        (,,, uint64 nextAt) = b.sip();
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IBucketAccount.SipNotDue.selector, nextAt));
        b.executeSip();

        vm.warp(nextAt - 1);
        _refresh();
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IBucketAccount.SipNotDue.selector, nextAt));
        b.executeSip();

        vm.warp(nextAt);
        _refresh();
        _run(); // exactly due
        (,, uint32 r,) = b.sip();
        assertEq(r, 2);
    }

    // ------------------------------------------------------------ execution
    function test_ExecuteBuysProRataPullsFromOwnerAndPaysTip() public {
        _startSip(3);
        (,,, uint64 firstDue) = b.sip();
        skip(3600);
        _refresh();
        uint256 aliceBefore = usdc.balanceOf(alice);
        uint256 btcOut = _buyOut(8, 60_000e8, 50e6);
        uint256 ethOut = _buyOut(18, 3_000e8, 30e6);

        vm.expectEmit(true, true, false, true, address(b));
        emit IBucketAccount.TradeExecuted(address(usdc), address(btc), 50e6, btcOut, address(mirrorVenue));
        vm.expectEmit(true, true, false, true, address(b));
        emit IBucketAccount.TradeExecuted(address(usdc), address(eth), 30e6, ethOut, address(mirrorVenue));
        vm.expectEmit(true, false, false, true, address(b));
        emit IBucketAccount.SipExecuted(keeper, AMT, 2);
        _run();

        assertEq(usdc.balanceOf(alice), aliceBefore - AMT, "pulled from the owner");
        assertEq(usdc.balanceOf(keeper), 50_000, "tip = min(0.05 USDC, 0.1% of value)");
        assertEq(btc.balanceOf(address(b)), btcOut);
        assertEq(eth.balanceOf(address(b)), ethOut);
        assertEq(usdc.balanceOf(address(b)), AMT - 50e6 - 30e6 - 50_000, "USDC share stays as cash");
        (,, uint32 r, uint64 nextAt) = b.sip();
        assertEq(r, 2);
        assertEq(nextAt, firstDue + 3600);
        assertEq(usdc.allowance(address(b), address(mirrorVenue)), 0);
    }

    function test_CallerPaysNothingAndNeedsNoAllowance() public {
        _startSip(1);
        skip(3600);
        _refresh();
        usdc.mint(keeper, 5e6);
        _run();
        assertEq(usdc.balanceOf(keeper), 5e6 + 50_000);
    }

    function test_ExecuteRevertsWithoutOwnerAllowanceAndKeepsState() public {
        _startSip(3);
        vm.prank(alice);
        usdc.approve(address(b), AMT - 1);
        skip(3600);
        _refresh();
        (,, uint32 rBefore, uint64 nBefore) = b.sip();
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(b), AMT - 1, AMT));
        b.executeSip();
        (,, uint32 r, uint64 n) = b.sip();
        assertEq(r, rBefore);
        assertEq(n, nBefore);
    }

    function test_ExecuteRevertsWhenOwnerLacksFunds() public {
        _startSip(1);
        uint256 bal = usdc.balanceOf(alice);
        vm.prank(alice);
        usdc.transfer(bob, bal);
        skip(3600);
        _refresh();
        vm.prank(keeper);
        vm.expectRevert();
        b.executeSip();
    }

    function test_StalePriceRevertsExecute() public {
        _startSip(1);
        skip(3601); // prices not refreshed
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IAssetRegistry.StalePrice.selector, address(btc)));
        b.executeSip();
    }

    // ------------------------------------------------------------ runs countdown
    function test_RunsCountDownThenInactive() public {
        _startSip(3);
        for (uint32 i = 1; i <= 3; ++i) {
            _warp(3600);
            _run();
            (,, uint32 r,) = b.sip();
            assertEq(r, 3 - i);
        }
        assertFalse(b.sipActive());
        _warp(3600);
        vm.prank(keeper);
        vm.expectRevert(IBucketAccount.SipInactive.selector);
        b.executeSip();
        // pulled exactly 3 x AMT
        assertEq(usdc.balanceOf(alice), 100_000e6 - 3 * AMT);
    }

    function test_ReArmAfterCancel() public {
        _startSip(2);
        vm.prank(alice);
        b.cancelSip();
        _startSip(2);
        _warp(3600);
        _run();
        (,, uint32 r,) = b.sip();
        assertEq(r, 1);
    }

    // ------------------------------------------------------------ risk skip
    function test_RiskTwoAndThreeAssetsAreSkippedAndShareStaysCash() public {
        _setRisk(address(eth), 2);
        _startSip(1);
        skip(3600);
        _refresh();
        _run();
        assertEq(eth.balanceOf(address(b)), 0);
        assertEq(btc.balanceOf(address(b)), _buyOut(8, 60_000e8, 50e6));
        assertEq(usdc.balanceOf(address(b)), AMT - 50e6 - 50_000);
    }

    function test_RiskThreeSkippedAndRiskOneBought() public {
        _setRisk(address(btc), 3);
        _setRisk(address(eth), 1);
        _startSip(1);
        skip(3600);
        _refresh();
        _run();
        assertEq(btc.balanceOf(address(b)), 0);
        assertEq(eth.balanceOf(address(b)), _buyOut(18, 3_000e8, 30e6));
    }

    // ------------------------------------------------------------ nextAt never in the past
    function test_NextAtAdvancesByIntervalWhenOnTime() public {
        _startSip(5);
        (,,, uint64 n0) = b.sip();
        vm.warp(n0 + 1800); // half an interval late
        _refresh();
        _run();
        (,,, uint64 n1) = b.sip();
        assertEq(n1, n0 + 3600);
        assertGt(n1, block.timestamp);
    }

    function test_NextAtNeverInThePastAfterLongDelay() public {
        _startSip(5);
        (,,, uint64 n0) = b.sip();
        vm.warp(n0 + 100 days);
        _refresh();
        _run();
        (,, uint32 r, uint64 n1) = b.sip();
        assertGe(n1, block.timestamp, "nextAt must not lag block.timestamp");
        assertEq(n1, uint64(block.timestamp), "max(nextAt + interval, now)");
        assertEq(r, 4);
    }

    // ------------------------------------------------------------ pause
    function test_PausedBlocksSipEvenWhenNotConfigured() public {
        vm.prank(alice);
        b.setPaused(true);
        vm.prank(keeper);
        vm.expectRevert(IBucketAccount.Paused_.selector);
        b.executeSip();
        // unpausing restores normal behaviour
        vm.prank(alice);
        b.setPaused(false);
        vm.prank(keeper);
        vm.expectRevert(IBucketAccount.SipInactive.selector);
        b.executeSip();
    }
}
