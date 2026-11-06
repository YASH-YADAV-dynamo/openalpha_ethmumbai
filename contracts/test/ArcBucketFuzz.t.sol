// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {IBucketAccount} from "../IArcTreasury.sol";
import {BucketAccount} from "../BucketAccount.sol";
import {ArcBucketBase} from "./helpers/ArcBucketBase.sol";

contract ArcBucketFuzzTest is ArcBucketBase {
    struct Snap {
        uint256 usdcBal;
        uint256 btc;
        uint256 eth;
        uint256 xau;
        uint256 eur;
        uint256 params;
        uint256 targetsHash;
        uint256 sipHash;
        address owner;
    }

    uint256 internal okRebalances;
    uint256 internal okSips;
    BucketAccount internal a; // alice
    BucketAccount internal c; // bob

    function _rnd(uint256 seed, uint256 salt, uint256 lo, uint256 hi) internal pure returns (uint256) {
        return lo + uint256(keccak256(abi.encode(seed, salt))) % (hi - lo + 1);
    }

    function _movePrices(uint256 seed) internal {
        pBTC = pBTC * _rnd(seed, 1, 8500, 11500) / 10000;
        pETH = pETH * _rnd(seed, 2, 8500, 11500) / 10000;
        pXAU = pXAU * _rnd(seed, 3, 8500, 11500) / 10000;
        pEURC = pEURC * _rnd(seed, 4, 9800, 10200) / 10000;
        // the pool tracks the (new) market price so only fee/spread losses remain
        pm.setRates(1e6 * 1e8 / pEURC, pEURC * 1e6 / 1e8);
        _feedAll();
    }

    // ================= value conservation =================
    function _check(BucketAccount x, uint256 before_, uint256 inflowE18, uint256 tipUsdc, Vm.Log[] memory logs) internal view {
        Trade[] memory t = _trades(logs, address(x));
        uint256 notional;
        for (uint256 i; i < t.length; ++i) notional += _usdcLeg(t[i]) * 1e12;
        uint256 afterV = _total(x);
        uint256 tol = 1e12 * (t.length + 1);
        // never creates value beyond rounding
        assertLe(afterV, before_ + inflowE18 + tol, "value created");
        // loses at most spread+slippage (0.31% of traded notional) and the tip
        assertGe(afterV + tipUsdc * 1e12 + notional * 31 / 10_000 + tol, before_ + inflowE18, "loss exceeds spread bound");
        assertLe(tipUsdc, 50_000, "tip above cap");
    }

    function _doRebalance(uint256 before_) internal {
        vm.recordLogs();
        vm.prank(keeper);
        try a.rebalance() {
            Vm.Log[] memory logs = vm.getRecordedLogs();
            (, , , , uint256 tip) = _rebalanced(logs, address(a));
            _check(a, before_, 0, tip, logs);
            ++okRebalances;
        } catch {
            vm.getRecordedLogs();
        }
    }

    function _doSip(uint256 before_, uint256 sipAmt) internal {
        uint256 kBefore = usdc.balanceOf(keeper);
        vm.recordLogs();
        vm.prank(keeper);
        try a.executeSip() {
            _check(a, before_, sipAmt * 1e12, usdc.balanceOf(keeper) - kBefore, vm.getRecordedLogs());
            ++okSips;
        } catch {
            vm.getRecordedLogs();
        }
    }

    function _round(uint256 seed, uint256 r, uint256 sipAmt) internal {
        uint256 s = uint256(keccak256(abi.encode(seed, r)));
        vm.warp(block.timestamp + _rnd(s, 5, 600, 5000));
        _movePrices(s);
        uint256 dep = _rnd(s, 6, 0, 500e6);
        if (dep != 0) _fund(a, dep);
        _doRebalance(_total(a));
        _doSip(_total(a), sipAmt);
    }

    function testFuzz_ValueConservedAcrossRebalancesAndSips(uint256 seed, uint256 dep0) public {
        dep0 = bound(dep0, 500e6, 3_000e6);
        a = _newBucketP(alice, _arr(address(mBTC), address(mETH), address(eurc), address(mXAU)), _w4(), _params(100, 300, 5000, 600));
        _prepSipOwner(a, alice, 100_000e6);
        _fund(a, dep0);
        uint256 sipAmt = _rnd(seed, 99, 10e6, 300e6);
        vm.prank(alice);
        a.setSip(sipAmt, 3600, 6);
        for (uint256 r; r < 6; ++r) _round(seed, r, sipAmt);
        assertGt(okRebalances, 0, "fuzz run never rebalanced");
        // keeper tips are bounded: at most 0.05 USDC per call, 12 calls max
        assertLe(usdc.balanceOf(keeper), 12 * 50_000);
    }

    function _arr(address a_, address b_, address c_, address d_) internal pure returns (address[] memory r) {
        r = new address[](4);
        r[0] = a_; r[1] = b_; r[2] = c_; r[3] = d_;
    }

    function _w4() internal pure returns (uint16[] memory w) {
        w = new uint16[](4);
        w[0] = 3000; w[1] = 2000; w[2] = 3000; w[3] = 2000;
    }

    // ================= no cross-user access =================
    function _snap(BucketAccount x) internal view returns (Snap memory s) {
        address x_ = address(x);
        s.usdcBal = usdc.balanceOf(x_);
        s.btc = mBTC.balanceOf(x_);
        s.eth = mETH.balanceOf(x_);
        s.xau = mXAU.balanceOf(x_);
        s.eur = eurc.balanceOf(x_);
        s.params = uint256(keccak256(abi.encode(x.params())));
        (address[] memory t, uint16[] memory w) = x.targets();
        s.targetsHash = uint256(keccak256(abi.encode(t, w)));
        (uint256 am, uint32 iv, uint32 rl, uint64 na) = x.sip();
        s.sipHash = uint256(keccak256(abi.encode(am, iv, rl, na, x.paused())));
        s.owner = x.owner();
    }

    function _assertSame(Snap memory p, Snap memory q) internal pure {
        assertEq(p.usdcBal, q.usdcBal, "usdc");
        assertEq(p.btc, q.btc, "btc");
        assertEq(p.eth, q.eth, "eth");
        assertEq(p.xau, q.xau, "xau");
        assertEq(p.eur, q.eur, "eur");
        assertEq(p.params, q.params, "params");
        assertEq(p.targetsHash, q.targetsHash, "targets");
        assertEq(p.sipHash, q.sipHash, "sip");
        assertEq(p.owner, q.owner, "owner");
    }

    function _allOwnerCalls(BucketAccount x, address who) internal {
        address t = address(x);
        _expectOwnerRevert(who, abi.encodeCall(x.withdraw, (USDC_ADDR, 1, who)), t);
        _expectOwnerRevert(who, abi.encodeCall(x.withdraw, (address(mBTC), 1, who)), t);
        _expectOwnerRevert(who, abi.encodeCall(x.withdrawAll, (who)), t);
        _expectOwnerRevert(who, abi.encodeCall(x.setTargets, (_arr(address(mBTC)), _w(10000))), t);
        _expectOwnerRevert(who, abi.encodeCall(x.followTemplate, (0, false)), t);
        _expectOwnerRevert(who, abi.encodeCall(x.setParams, (_defParams())), t);
        _expectOwnerRevert(who, abi.encodeCall(x.setPaused, (true)), t);
        _expectOwnerRevert(who, abi.encodeCall(x.setSip, (1e6, 3600, 1)), t);
        _expectOwnerRevert(who, abi.encodeCall(x.cancelSip, ()), t);
    }

    function testFuzz_NoCloneCanTouchAnotherUsersFunds(uint256 seed, uint256 depA, uint256 depB) public {
        depA = bound(depA, 100e6, 4_000e6);
        depB = bound(depB, 100e6, 4_000e6);
        address stranger = address(uint160(uint256(keccak256(abi.encode(seed, "stranger")))));
        vm.assume(stranger != alice && stranger != address(0) && stranger.code.length == 0);
        a = _newBucket(alice, _arr(address(mBTC), address(eurc)), _w(5000, 5000));
        c = _newBucket(bob, _arr(address(mETH), address(mXAU), address(eurc)), _w(3000, 2000, 5000));
        _prepSipOwner(a, alice, 50_000e6);
        _prepSipOwner(c, bob, 50_000e6);
        _fund(a, depA);
        _fund(c, depB);
        vm.prank(keeper);
        a.rebalance();
        vm.prank(keeper);
        c.rebalance();

        Snap memory bobBucket = _snap(c);
        uint256 bobWallet = usdc.balanceOf(bob);

        // 1. everybody else (bob, the stranger, the factory, the other clone) is rejected on every owner function of A
        _allOwnerCalls(a, bob);
        _allOwnerCalls(a, stranger);
        _allOwnerCalls(a, address(c));
        _allOwnerCalls(a, address(factory));
        // 2. a heavy sequence of legitimate operations on A leaves B untouched
        vm.startPrank(alice);
        a.setParams(_params(100, 300, 5000, 600));
        a.setSip(_rnd(seed, 1, 5e6, 500e6), 3600, 4);
        vm.stopPrank();
        vm.warp(block.timestamp + 4000);
        _movePrices(seed);
        _fund(a, _rnd(seed, 2, 1e6, 500e6));
        vm.prank(stranger);
        try a.rebalance() {} catch {}
        vm.prank(stranger);
        try a.executeSip() {} catch {}
        vm.startPrank(alice);
        a.setTargets(_arr(address(mETH), address(mXAU)), _w(7000, 3000));
        a.setPaused(true);
        a.withdraw(USDC_ADDR, usdc.balanceOf(address(a)) / 2, alice);
        a.withdrawAll(alice);
        vm.stopPrank();
        _assertSame(bobBucket, _snap(c));
        assertEq(usdc.balanceOf(bob), bobWallet); // A's SIP never pulls from bob

        // 3. and the reverse: bob's operations never touch A, alice cannot administer B
        Snap memory aliceBucket = _snap(a);
        uint256 aliceWallet = usdc.balanceOf(alice);
        _allOwnerCalls(c, alice);
        _allOwnerCalls(c, stranger);
        vm.startPrank(bob);
        c.setSip(20e6, 3600, 2);
        c.setPaused(false);
        vm.stopPrank();
        vm.warp(block.timestamp + 4000);
        _movePrices(uint256(keccak256(abi.encode(seed, "again"))));
        vm.prank(stranger);
        try c.rebalance() {} catch {}
        vm.prank(stranger);
        try c.executeSip() {} catch {}
        vm.prank(bob);
        c.withdrawAll(bob);
        _assertSame(aliceBucket, _snap(a));
        assertEq(usdc.balanceOf(alice), aliceWallet);
        assertEq(a.owner(), alice);
        assertEq(c.owner(), bob);
    }
}
