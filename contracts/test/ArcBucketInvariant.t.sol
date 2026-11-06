// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {BucketAccount} from "../BucketAccount.sol";
import {AssetRegistry} from "../AssetRegistry.sol";
import {ArcBucketBase} from "./helpers/ArcBucketBase.sol";
import {MockERC20} from "./helpers/MockERC20.sol";

/// @dev Drives bounded user/keeper actions against one bucket at constant market prices
///      and tracks the USDC-denominated value that entered and left the system.
contract BucketHandler is Test {
    BucketAccount public b;
    MockERC20 public usdc;
    AssetRegistry public reg;
    address public reporter;
    address public alice;
    address public keeper;
    address[] public toks;
    uint256[] public px;
    uint256 public ghostIn; // USDC (6 dec) deposited or pulled by SIP
    uint256 public ghostOut; // USDC-equivalent value withdrawn by the owner
    uint256 public calls;
    uint256 public successfulRebalances;

    constructor(BucketAccount b_, MockERC20 usdc_, AssetRegistry reg_, address reporter_, address alice_, address keeper_,
        address[] memory toks_, uint256[] memory px_) {
        b = b_; usdc = usdc_; reg = reg_; reporter = reporter_; alice = alice_; keeper = keeper_;
        toks = toks_; px = px_;
    }

    function _refresh() internal {
        vm.prank(reporter);
        reg.onReport("", abi.encode(uint8(1), abi.encode(toks, px, uint64(block.timestamp))));
    }

    function deposit(uint256 amt) external {
        amt = bound(amt, 1e6, 1_500e6);
        usdc.mint(address(this), amt);
        usdc.approve(address(b), amt);
        b.deposit(amt);
        ghostIn += amt;
        ++calls;
    }

    function tick(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 0, 5_000));
        _refresh();
        ++calls;
    }

    function rebalance() external {
        vm.prank(keeper);
        try b.rebalance() {
            ++successfulRebalances;
        } catch {}
        ++calls;
    }

    function sip(uint256 amt, uint256 interval) external {
        amt = bound(amt, 1e6, 300e6);
        interval = bound(interval, 3600, 7200);
        vm.prank(alice);
        b.setSip(amt, uint32(interval), 3);
        (,,, uint64 nextAt) = b.sip();
        vm.warp(nextAt);
        _refresh();
        uint256 before_ = usdc.balanceOf(alice);
        vm.prank(keeper);
        try b.executeSip() {
            ghostIn += before_ - usdc.balanceOf(alice);
        } catch {}
        ++calls;
    }

    function withdrawUsdc(uint256 frac) external {
        uint256 amt = bound(frac, 0, usdc.balanceOf(address(b)));
        if (amt == 0) return;
        vm.prank(alice);
        b.withdraw(address(usdc), amt, alice);
        ghostOut += amt;
        ++calls;
    }

    function withdrawToken(uint256 i, uint256 frac) external {
        address t = toks[i % toks.length];
        uint256 amt = bound(frac, 0, MockERC20(t).balanceOf(address(b)));
        if (amt == 0) return;
        uint256 v = reg.valueE18(t, amt) / 1e12;
        vm.prank(alice);
        b.withdraw(t, amt, alice);
        ghostOut += v;
        ++calls;
    }
}

contract ArcBucketInvariantTest is ArcBucketBase {
    BucketAccount internal b;
    BucketHandler internal h;

    function setUp() public override {
        super.setUp();
        b = _newBucket(alice, _arr(address(mBTC), address(eurc), address(mETH)), _w(3000, 4000, 3000));
        usdc.mint(alice, 10_000_000e6);
        vm.prank(alice);
        usdc.approve(address(b), type(uint256).max);
        address[] memory toks = new address[](3);
        toks[0] = address(mBTC); toks[1] = address(eurc); toks[2] = address(mETH);
        uint256[] memory px = new uint256[](3);
        px[0] = pBTC; px[1] = pEURC; px[2] = pETH;
        h = new BucketHandler(b, usdc, registry, reporter, alice, keeper, toks, px);
        // the handler needs to be allowed to post prices
        vm.prank(owner);
        registry.setReporter(reporter, true);
        targetContract(address(h));
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 60
    /// forge-config: default.invariant.fail_on_revert = false
    function invariant_NoValueCreated_AllValueAccountedFor() public view {
        uint256 held = _total(b) / 1e12;
        uint256 accounted = held + usdc.balanceOf(keeper) + h.ghostOut();
        // inflows are the ceiling: spreads, slippage and tips only ever reduce what is left
        assertLe(accounted, h.ghostIn() + 10 + h.calls() * 3, "value created from nothing");
        assertEq(b.owner(), alice);
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 60
    function invariant_BucketKeepsOnlyUniverseAssetsAndNoVenueAllowance() public view {
        assertEq(usdc.allowance(address(b), address(mvenue)), 0);
        assertEq(usdc.allowance(address(b), address(uvenue)), 0);
        assertEq(mBTC.allowance(address(b), address(mvenue)), 0);
        assertEq(eurc.allowance(address(b), address(uvenue)), 0);
        assertEq(mXAU.balanceOf(address(b)), 0);
    }
}
