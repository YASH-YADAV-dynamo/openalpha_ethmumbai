// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./TreasuryBase.t.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";


/// @dev Drives bucket A (alice) with bounded random actions at constant prices. Tips accrue to this contract.
contract BucketHandler is Test {
    BucketAccount public a;
    MockERC20 public usdc;
    MirrorToken public btc;
    MirrorToken public eth;
    AssetRegistry public registry;
    address public reporter;
    address public alice;

    uint256 public ghostInE18; // USDC value (E18) the owner/third parties put in
    uint256 public rebalances;
    uint256 public sips;
    uint256 public calls;

    constructor(BucketAccount a_, MockERC20 usdc_, MirrorToken btc_, MirrorToken eth_, AssetRegistry reg_, address reporter_, address alice_) {
        a = a_;
        usdc = usdc_;
        btc = btc_;
        eth = eth_;
        registry = reg_;
        reporter = reporter_;
        alice = alice_;
    }

    function _tick() internal {
        vm.warp(block.timestamp + 3600);
        address[] memory t = new address[](2);
        uint256[] memory p = new uint256[](2);
        t[0] = address(btc);
        t[1] = address(eth);
        p[0] = 60_000e8;
        p[1] = 3_000e8;
        vm.prank(reporter);
        registry.onReport("", abi.encode(uint8(1), abi.encode(t, p, uint64(block.timestamp))));
    }

    function tips() public view returns (uint256) {
        return usdc.balanceOf(address(this)) * 1e12;
    }

    function deposit(uint256 amt) external {
        ++calls;
        amt = bound(amt, 1e6, 1_000e6);
        usdc.mint(address(this), amt);
        usdc.approve(address(a), amt);
        a.deposit(amt);
        ghostInE18 += amt * 1e12;
    }

    function rebalance() external {
        ++calls;
        _tick();
        try a.rebalance() {
            ++rebalances;
        } catch {}
    }

    function retarget(uint256 w) external {
        ++calls;
        w = bound(w, 500, 9500);
        vm.prank(alice);
        a.setTargets(_two(address(btc), address(usdc)), _w(uint16(w)));
    }

    function retargetEth(uint256 w) external {
        ++calls;
        w = bound(w, 500, 9500);
        vm.prank(alice);
        a.setTargets(_two(address(eth), address(btc)), _w(uint16(w)));
    }

    function sip(uint256 amt) external {
        ++calls;
        amt = bound(amt, 1e6, 200e6);
        _tick();
        vm.prank(alice);
        a.setSip(amt, 3600, 5);
        _tick();
        usdc.mint(alice, amt);
        try a.executeSip() {
            ++sips;
            ghostInE18 += amt * 1e12;
        } catch {
            usdc.burn(alice, amt);
        }
    }

    function _two(address x, address y) internal pure returns (address[] memory r) {
        r = new address[](2);
        r[0] = x;
        r[1] = y;
    }

    function _w(uint16 w) internal pure returns (uint16[] memory r) {
        r = new uint16[](2);
        r[0] = w;
        r[1] = 10_000 - w;
    }
}

/// forge-config: default.invariant.runs = 40
/// forge-config: default.invariant.depth = 40
contract InvariantTest is TreasuryBase {
    BucketAccount internal a;
    BucketAccount internal c;
    BucketHandler internal h;
    uint256 internal reserve0;

    function setUp() public override {
        super.setUp();
        _fundReserve(100_000e6);
        reserve0 = usdc.balanceOf(address(mirrorVenue));
        a = _btcUsdcBucket();
        c = _bucketFor(bob, _addrs(address(btc), address(usdc)), _wts(5000, 5000), _defParams());
        _fund(c, 700e6);
        usdc.mint(bob, 123e6);
        vm.prank(alice);
        usdc.approve(address(a), type(uint256).max);
        h = new BucketHandler(a, usdc, btc, eth, registry, reporter, alice);

        bytes4[] memory sels = new bytes4[](5);
        sels[0] = BucketHandler.deposit.selector;
        sels[1] = BucketHandler.rebalance.selector;
        sels[2] = BucketHandler.retarget.selector;
        sels[3] = BucketHandler.retargetEth.selector;
        sels[4] = BucketHandler.sip.selector;
        targetSelector(StdInvariant.FuzzSelector({addr: address(h), selectors: sels}));
        targetContract(address(h));
    }

    /// Conservation: the bucket (priced via the registry) plus tips paid never exceeds what was put in.
    function invariant_NoValueCreated() public view {
        (,,, uint256 total) = a.holdings();
        assertLe(total + h.tips(), h.ghostInE18() + 1e9);
    }

    /// ...and what is lost is bounded by the 30 bps mirror spread: <= 0.6% per rebalance, <= 0.3% per SIP.
    function invariant_LossBoundedBySpread() public view {
        (,,, uint256 total) = a.holdings();
        uint256 inE18 = h.ghostInE18();
        uint256 maxLoss = inE18 * (60 * h.rebalances() + 30 * h.sips()) / 10_000;
        if (maxLoss > inE18) maxLoss = inE18;
        // plus per-operation rounding dust: a trade can lose up to ~1 sat of BTC (~$0.0006) to flooring
        uint256 dust = (3 * h.rebalances() + 3 * h.sips() + 1) * 1e15;
        assertGe(total + h.tips() + dust, inE18 - maxLoss);
    }

    /// No clone can touch another user's funds: bucket C and its owner are untouched by all activity on A.
    function invariant_OtherUsersFundsUntouched() public view {
        assertEq(usdc.balanceOf(address(c)), 700e6);
        assertEq(btc.balanceOf(address(c)), 0);
        assertEq(eth.balanceOf(address(c)), 0);
        assertEq(usdc.balanceOf(bob), 123e6);
        assertEq(c.owner(), bob);
        assertEq(a.owner(), alice);
    }

    /// Mirror venue solvency: reserve grew at least as much as the USDC value of the circulating mirrors.
    function invariant_MirrorReserveBacksSupply() public view {
        uint256 supplyUsdc = btc.totalSupply() * 60_000e8 * 1e6 / (1e8 * 1e8) + eth.totalSupply() * 3_000e8 * 1e6 / (1e8 * 1e18);
        assertGe(usdc.balanceOf(address(mirrorVenue)) + 10, reserve0 + supplyUsdc);
    }
}
