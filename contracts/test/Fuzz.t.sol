// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./TreasuryBase.t.sol";

contract FuzzTest is TreasuryBase {
    function setUp() public override {
        super.setUp();
        _fundReserve(10_000_000e6);
    }

    // ------------------------------------------------------------ mirror math
    function testFuzz_MirrorBuyMatchesFormulaAndRoundTripNeverProfits(uint256 price, uint256 amt) public {
        price = bound(price, 1e6, 1e14);
        amt = bound(amt, 1e6, 5_000e6);
        _setPrice(address(btc), price);
        usdc.mint(alice, amt);
        vm.startPrank(alice);
        usdc.approve(address(mirrorVenue), amt);
        uint256 out = mirrorVenue.swap(address(usdc), address(btc), amt, 0, alice);
        assertEq(out, amt * 1e8 * 1e8 / (price * 1e6) * 9970 / 10000);
        if (out > 0) {
            btc.approve(address(mirrorVenue), out);
            uint256 back = mirrorVenue.swap(address(btc), address(usdc), out, 0, alice);
            assertEq(back, out * price * 1e6 / (1e8 * 1e8) * 9970 / 10000);
            assertLe(back, amt, "a round trip can never profit");
        }
        vm.stopPrank();
    }

    // ------------------------------------------------------------ registry ordering
    function testFuzz_OutOfOrderPriceReportNeverOverwrites(uint64 newer, uint64 older, uint256 p) public {
        skip(4000);
        newer = uint64(bound(newer, T0 + 500, T0 + 4000));
        older = uint64(bound(older, 1, newer - 1));
        p = bound(p, 1, type(uint192).max);
        address[] memory t = new address[](1);
        uint256[] memory pr = new uint256[](1);
        t[0] = address(btc);
        pr[0] = 111e8;
        _report(t, pr, newer);
        pr[0] = p;
        vm.expectRevert(IAssetRegistry.BadReport.selector);
        _report(t, pr, older);
        (uint256 stored, uint64 at) = registry.priceE8(address(btc));
        assertEq(stored, 111e8);
        assertEq(at, newer);
    }

    // ------------------------------------------------------------ value conservation across rebalances
    struct Scn {
        uint256 pBtc;
        uint256 pEth;
        uint256 usdcIn;
        uint256 btcUsd;
        uint256 ethUsd;
        uint16 wBtc;
        uint16 wEth;
        uint16 band;
        uint16 slip;
        uint16 maxTrade;
        uint256 rounds;
    }

    function _build(Scn memory s) internal returns (BucketAccount x) {
        s.pBtc = bound(s.pBtc, 1_000e8, 200_000e8);
        s.pEth = bound(s.pEth, 100e8, 10_000e8);
        s.usdcIn = bound(s.usdcIn, 10e6, 2_000e6);
        s.btcUsd = bound(s.btcUsd, 0, 2_000e6);
        s.ethUsd = bound(s.ethUsd, 0, 2_000e6);
        s.wBtc = uint16(bound(s.wBtc, 500, 6000));
        s.wEth = uint16(bound(s.wEth, 500, 3000));
        s.band = uint16(bound(s.band, 100, 2000));
        s.slip = uint16(bound(s.slip, 30, 300)); // below the 30 bps mirror spread no mirror trade can pass minOut
        s.maxTrade = uint16(bound(s.maxTrade, 500, 5000));
        s.rounds = bound(s.rounds, 1, 4);
        _setPrice(address(btc), s.pBtc);
        _setPrice(address(eth), s.pEth);
        x = _bucketFor(
            alice,
            _addrs(address(btc), address(eth), address(usdc)),
            _wts(s.wBtc, s.wEth, 10_000 - s.wBtc - s.wEth),
            BucketParams(s.band, s.slip, s.maxTrade, 600)
        );
        _fund(x, s.usdcIn);
        _mintMirror(address(btc), address(x), s.btcUsd * 1e8 * 1e8 / (s.pBtc * 1e6));
        _mintMirror(address(eth), address(x), s.ethUsd * 1e8 * 1e18 / (s.pEth * 1e6));
    }

    function testFuzz_TotalValueConservedWithinSpreadAcrossRebalances(Scn memory s) public {
        BucketAccount x = _build(s);
        (,,, uint256 v0) = x.holdings();
        for (uint256 r; r < s.rounds; ++r) {
            _warp(600);
            vm.prank(keeper);
            try x.rebalance() {}
            catch (bytes memory err) {
                require(bytes4(err) == IBucketAccount.NotNeeded.selector, "unexpected rebalance revert");
            }
        }
        (,,, uint256 v1) = x.holdings();
        uint256 tips = usdc.balanceOf(keeper) * 1e12;
        assertLe(v1 + tips, v0 + 1e6, "rebalancing never creates value");
        // each round trades at most (sold + bought) <= 2x value at 30 bps spread => <= 0.6% per round
        assertGe(v1 + tips + 1e6, v0 - v0 * 60 * s.rounds / 10_000, "loss bounded by spread");
        // the bucket never ends up with less than it was owed after fee: tip also bounded per round
        assertLe(tips, s.rounds * 50_000 * 1e12);
    }

    function testFuzz_TipNeverExceedsCapOrOnePerMille(uint256 amt) public {
        amt = bound(amt, 10e6, 9_000e6);
        BucketAccount x = _btcUsdcBucket();
        _fund(x, amt);
        vm.prank(keeper);
        x.rebalance();
        uint256 expected = amt * 10 / 10_000;
        if (expected > 50_000) expected = 50_000;
        assertEq(usdc.balanceOf(keeper), expected);
    }

    // ------------------------------------------------------------ isolation between users' clones
    function _two() internal returns (BucketAccount a, BucketAccount c) {
        a = _btcUsdcBucket();
        c = _bucketFor(bob, _addrs(address(btc), address(usdc)), _wts(5000, 5000), _defParams());
        _fund(a, 1_000e6);
        _fund(c, 700e6);
        _mintMirror(address(btc), address(a), 2_000_000);
        _mintMirror(address(btc), address(c), 1_000_000);
        usdc.mint(alice, 5_000e6);
        usdc.mint(bob, 5_000e6);
        vm.prank(alice);
        usdc.approve(address(a), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(c), type(uint256).max);
    }

    function _snap(BucketAccount x) internal view returns (bytes32) {
        return keccak256(abi.encode(usdc.balanceOf(address(x)), btc.balanceOf(address(x)), eth.balanceOf(address(x)), x.paused()));
    }

    function testFuzz_NonOwnerCannotTouchAnyBucket(address caller, uint256 amt, address to) public {
        vm.assume(uint160(caller) > 0xffff && caller != alice && caller != bob);
        vm.assume(to != address(0));
        (BucketAccount a, BucketAccount c) = _two();
        bytes32 sa = _snap(a);
        bytes32 sc = _snap(c);
        vm.startPrank(caller);
        vm.expectRevert(IBucketAccount.NotOwner.selector);
        a.withdraw(address(usdc), amt, to);
        vm.expectRevert(IBucketAccount.NotOwner.selector);
        c.withdraw(address(btc), amt, to);
        vm.expectRevert(IBucketAccount.NotOwner.selector);
        a.withdrawAll(to);
        vm.expectRevert(IBucketAccount.NotOwner.selector);
        c.withdrawAll(to);
        vm.expectRevert(IBucketAccount.NotOwner.selector);
        a.setPaused(true);
        vm.expectRevert(IBucketAccount.NotOwner.selector);
        a.setTargets(_addrs(address(eth), address(usdc)), _wts(5000, 5000));
        vm.expectRevert(IBucketAccount.NotOwner.selector);
        a.setSip(amt, 3600, 1);
        vm.stopPrank();
        assertEq(_snap(a), sa);
        assertEq(_snap(c), sc);
    }

    function testFuzz_OwnerOfOneBucketCannotWithdrawFromAnother(uint256 amt, address to) public {
        vm.assume(to != address(0));
        (BucketAccount a, BucketAccount c) = _two();
        bytes32 sa = _snap(a);
        bytes32 sc = _snap(c);
        vm.startPrank(alice);
        vm.expectRevert(IBucketAccount.NotOwner.selector);
        c.withdraw(address(usdc), amt, to);
        vm.expectRevert(IBucketAccount.NotOwner.selector);
        c.withdrawAll(to);
        vm.stopPrank();
        vm.startPrank(bob);
        vm.expectRevert(IBucketAccount.NotOwner.selector);
        a.withdraw(address(btc), amt, to);
        vm.expectRevert(IBucketAccount.NotOwner.selector);
        a.withdrawAll(to);
        vm.stopPrank();
        assertEq(_snap(a), sa);
        assertEq(_snap(c), sc);
    }

    function testFuzz_ActivityOnOneBucketNeverMovesAnothersFunds(uint256 dep, uint256 sipAmt, uint16 wBtc) public {
        dep = bound(dep, 1e6, 1_000e6);
        sipAmt = bound(sipAmt, 1e6, 500e6);
        wBtc = uint16(bound(wBtc, 100, 9900));
        (BucketAccount a, BucketAccount c) = _two();
        bytes32 sc = _snap(c);
        uint256 bobWallet = usdc.balanceOf(bob);

        // a third party tops up A, then keeper maintains it
        usdc.mint(keeper, dep);
        vm.prank(keeper);
        usdc.approve(address(a), dep);
        vm.prank(keeper);
        a.deposit(dep);
        vm.prank(alice);
        a.setTargets(_addrs(address(btc), address(usdc)), _wts(wBtc, 10_000 - wBtc));
        vm.prank(alice);
        a.setSip(sipAmt, 3600, 3);
        _warp(3600);
        vm.prank(keeper);
        try a.rebalance() {} catch {}
        vm.prank(keeper);
        a.executeSip();
        vm.prank(alice);
        a.withdrawAll(alice);

        assertEq(_snap(c), sc, "other bucket untouched");
        assertEq(usdc.balanceOf(bob), bobWallet, "other owner wallet untouched");
        assertEq(usdc.allowance(address(c), address(mirrorVenue)), 0);
        assertEq(usdc.allowance(bob, address(c)), type(uint256).max, "allowance not consumed by A's SIP");
    }
}
