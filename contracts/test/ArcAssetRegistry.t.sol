// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IAssetRegistry} from "../IArcTreasury.sol";
import {AssetRegistry} from "../AssetRegistry.sol";
import {ArcBase} from "./helpers/ArcBase.sol";
import {MockERC20} from "./helpers/MockERC20.sol";

contract ArcAssetRegistryTest is ArcBase {
    event PriceUpdated(address indexed token, uint256 priceE8, uint64 observedAt);
    event RiskUpdated(address indexed token, uint8 level, bytes32 evidenceHash);
    event ReporterSet(address indexed reporter, bool allowed);
    event AssetListed(address indexed token, string symbol, IAssetRegistry.Category category, address venue, bool mirror);
    event MaxStalenessSet(uint64 seconds_);

    // ---------- deployment ----------
    function test_Deployment() public view {
        assertEq(registry.owner(), owner);
        assertEq(registry.usdc(), USDC_ADDR);
        assertEq(registry.maxStaleness(), 3600);
        address[] memory a = registry.assets();
        assertEq(a[0], USDC_ADDR);
        assertEq(a.length, 5);
        IAssetRegistry.Asset memory u = registry.assetOf(USDC_ADDR);
        assertEq(u.symbol, "USDC");
        assertEq(u.decimals, 6);
        assertEq(u.venue, address(0));
        assertFalse(u.mirror);
        assertEq(uint8(u.category), uint8(IAssetRegistry.Category.Cash));
    }

    function test_Constructor_ZeroUsdcReverts() public {
        vm.expectRevert(AssetRegistry.BadAsset.selector);
        new AssetRegistry(owner, address(0));
    }

    // ---------- reporter access ----------
    function test_OnReport_NonReporterReverts() public {
        bytes memory r = _report(_arr(address(eurc)), _u(1e8), uint64(block.timestamp));
        vm.prank(alice);
        vm.expectRevert(IAssetRegistry.NotReporter.selector);
        registry.onReport("", r);
        vm.prank(owner); // owner is not automatically a reporter
        vm.expectRevert(IAssetRegistry.NotReporter.selector);
        registry.onReport("", r);
    }

    function test_SetReporter_EmitsAndIsReporter() public {
        assertTrue(registry.isReporter(reporter));
        vm.expectEmit(true, false, false, true, address(registry));
        emit ReporterSet(alice, true);
        vm.prank(owner);
        registry.setReporter(alice, true);
        assertTrue(registry.isReporter(alice));
        vm.prank(owner);
        registry.setReporter(alice, false);
        assertFalse(registry.isReporter(alice));
        bytes memory r = _report(_arr(address(eurc)), _u(1e8), uint64(block.timestamp));
        vm.prank(alice);
        vm.expectRevert(IAssetRegistry.NotReporter.selector);
        registry.onReport("", r);
    }

    function test_SetReporter_OnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        registry.setReporter(alice, true);
    }

    // ---------- prices ----------
    function test_PriceReport_StoresAndEmits() public {
        vm.expectEmit(true, false, false, true, address(registry));
        emit PriceUpdated(address(eurc), 1.1e8, uint64(block.timestamp));
        _feedOne(address(eurc), 1.1e8);
        (uint256 p, uint64 t) = registry.priceE8(address(eurc));
        assertEq(p, 1.1e8);
        assertEq(t, uint64(block.timestamp));
    }

    function test_UsdcPriceAlwaysOne() public {
        (uint256 p, uint64 t) = registry.priceE8(USDC_ADDR);
        assertEq(p, 1e8);
        assertEq(t, uint64(block.timestamp));
        vm.warp(block.timestamp + 365 days);
        (p, t) = registry.priceE8(USDC_ADDR);
        assertEq(p, 1e8);
        assertEq(t, uint64(block.timestamp));
    }

    function test_UsdcNotReportable() public {
        _expectBad(_report(_arr(USDC_ADDR), _u(2e8), uint64(block.timestamp)));
        (uint256 p,) = registry.priceE8(USDC_ADDR);
        assertEq(p, 1e8);
        // mixed batch containing USDC also rejected atomically
        _expectBad(_report(_arr(address(eurc), USDC_ADDR), _u(1.5e8, 1e8), uint64(block.timestamp)));
        (p,) = registry.priceE8(address(eurc));
        assertEq(p, pEURC);
    }

    function test_StalePrice_AfterMaxStaleness() public {
        vm.warp(block.timestamp + 3600); // exactly at limit still fresh
        (uint256 p,) = registry.priceE8(address(eurc));
        assertEq(p, pEURC);
        vm.warp(block.timestamp + 1);
        vm.expectRevert(abi.encodeWithSelector(IAssetRegistry.StalePrice.selector, address(eurc)));
        registry.priceE8(address(eurc));
        vm.expectRevert(abi.encodeWithSelector(IAssetRegistry.StalePrice.selector, address(eurc)));
        registry.valueE18(address(eurc), 1e6);
    }

    function test_StalePrice_NeverSet() public {
        MockERC20 t = new MockERC20("N", "N", 6);
        vm.prank(owner);
        registry.listAsset(IAssetRegistry.Asset(address(t), "N", IAssetRegistry.Category.FX, 6, address(uvenue), false, ""));
        vm.expectRevert(abi.encodeWithSelector(IAssetRegistry.StalePrice.selector, address(t)));
        registry.priceE8(address(t));
    }

    function test_UnknownAsset_Reverts() public {
        address x = makeAddr("x");
        vm.expectRevert(abi.encodeWithSelector(IAssetRegistry.UnknownAsset.selector, x));
        registry.priceE8(x);
        vm.expectRevert(abi.encodeWithSelector(IAssetRegistry.UnknownAsset.selector, x));
        registry.riskOf(x);
        vm.expectRevert(abi.encodeWithSelector(IAssetRegistry.UnknownAsset.selector, x));
        registry.assetOf(x);
    }

    function test_SetMaxStaleness_BoundsAndEffect() public {
        vm.startPrank(owner);
        vm.expectRevert(IAssetRegistry.BadReport.selector);
        registry.setMaxStaleness(59);
        vm.expectRevert(IAssetRegistry.BadReport.selector);
        registry.setMaxStaleness(7 days + 1);
        vm.expectEmit(false, false, false, true, address(registry));
        emit MaxStalenessSet(60);
        registry.setMaxStaleness(60);
        vm.stopPrank();
        assertEq(registry.maxStaleness(), 60);
        vm.warp(block.timestamp + 61);
        vm.expectRevert(abi.encodeWithSelector(IAssetRegistry.StalePrice.selector, address(eurc)));
        registry.priceE8(address(eurc));
        vm.prank(owner);
        registry.setMaxStaleness(7 days);
        assertEq(registry.maxStaleness(), 7 days);
        registry.priceE8(address(eurc)); // fresh again under looser window
    }

    function test_SetMaxStaleness_OnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        registry.setMaxStaleness(100);
    }

    function test_OutOfOrderReport_Reverts() public {
        vm.warp(block.timestamp + 100);
        _feedOne(address(eurc), 1.2e8);
        _expectBad(_report(_arr(address(eurc)), _u(1.3e8), uint64(block.timestamp - 1)));
        (uint256 p,) = registry.priceE8(address(eurc));
        assertEq(p, 1.2e8);
    }

    function test_SameObservedAt_Allowed_AndNewerAllowed() public {
        _feedOne(address(eurc), 1.2e8); // same timestamp as setUp feed
        (uint256 p,) = registry.priceE8(address(eurc));
        assertEq(p, 1.2e8);
        vm.warp(block.timestamp + 5);
        _feedOne(address(eurc), 1.25e8);
        (p,) = registry.priceE8(address(eurc));
        assertEq(p, 1.25e8);
    }

    function test_FutureObservedAt_Reverts() public {
        _expectBad(_report(_arr(address(eurc)), _u(1e8), uint64(block.timestamp + 1)));
    }

    function test_PriceReport_BadInputs() public {
        uint64 ts = uint64(block.timestamp);
        _expectBad(_report(_arr(address(eurc)), _u(0), ts)); // zero price
        _expectBad(_report(_arr(address(eurc)), _u(uint256(type(uint192).max) + 1), ts));
        _expectBad(_report(_arr(address(eurc), address(mBTC)), _u(1e8), ts)); // length mismatch
        _expectBad(_report(new address[](0), new uint256[](0), ts)); // empty
        _expectBad(abi.encode(uint8(3), bytes(""))); // unknown kind
        _expectBad(abi.encode(uint8(0), bytes("")));
        _expectBad(hex"deadbeef"); // garbage
        _expectBad(abi.encode(uint8(1), hex"1234"));
        _expectBad(hex"");
    }

    function test_PriceReport_MaxUint192Ok_And51EntriesRejected() public {
        _feedOne(address(eurc), uint256(type(uint192).max));
        address[] memory t = new address[](51);
        uint256[] memory p = new uint256[](51);
        for (uint256 i; i < 51; ++i) { t[i] = address(eurc); p[i] = 1e8; }
        _expectBad(_report(t, p, uint64(block.timestamp)));
        address[] memory t50 = new address[](50);
        uint256[] memory p50 = new uint256[](50);
        for (uint256 i; i < 50; ++i) { t50[i] = address(eurc); p50[i] = 1e8; }
        _feed(t50, p50);
        (uint256 pr,) = registry.priceE8(address(eurc));
        assertEq(pr, 1e8);
    }

    function test_PriceReport_UnknownAsset() public {
        address x = makeAddr("x");
        bytes memory r = _report(_arr(x), _u(1e8), uint64(block.timestamp));
        vm.prank(reporter);
        vm.expectRevert(abi.encodeWithSelector(IAssetRegistry.UnknownAsset.selector, x));
        registry.onReport("", r);
    }

    function _expectBad(bytes memory r) internal {
        vm.prank(reporter);
        vm.expectRevert(IAssetRegistry.BadReport.selector);
        registry.onReport("", r);
    }

    // ---------- risk ----------
    function test_RiskLevels_0to3_Accepted() public {
        for (uint8 l; l <= 3; ++l) {
            vm.expectEmit(true, false, false, true, address(registry));
            emit RiskUpdated(address(mBTC), l, bytes32(uint256(1)));
            _setRisk(address(mBTC), l);
            assertEq(registry.riskOf(address(mBTC)), l);
        }
    }

    function test_RiskLevel4_Rejected() public {
        _expectBad(abi.encode(uint8(2), abi.encode(address(mBTC), uint8(4), bytes32(0))));
        assertEq(registry.riskOf(address(mBTC)), 0);
    }

    function test_Risk_UsdcUnknownAndMalformed() public {
        assertEq(registry.riskOf(USDC_ADDR), 0);
        _expectBad(abi.encode(uint8(2), abi.encode(USDC_ADDR, uint8(1), bytes32(0))));
        address x = makeAddr("x");
        vm.prank(reporter);
        vm.expectRevert(abi.encodeWithSelector(IAssetRegistry.UnknownAsset.selector, x));
        registry.onReport("", abi.encode(uint8(2), abi.encode(x, uint8(1), bytes32(0))));
        _expectBad(abi.encode(uint8(2), hex"01"));
        _expectBad(abi.encode(uint8(2), abi.encode(address(mBTC), uint256(300), bytes32(0))));
    }

    function test_Risk_NonReporterReverts() public {
        vm.prank(alice);
        vm.expectRevert(IAssetRegistry.NotReporter.selector);
        registry.onReport("", abi.encode(uint8(2), abi.encode(address(mBTC), uint8(1), bytes32(0))));
    }

    // ---------- valueE18 ----------
    function test_ValueE18_Decimals() public view {
        assertEq(registry.valueE18(address(mBTC), 1e8), 60_000e18);
        assertEq(registry.valueE18(address(mETH), 2e18), 6_000e18);
        assertEq(registry.valueE18(address(mXAU), 1_500_000), 3_000e18);
        assertEq(registry.valueE18(USDC_ADDR, 10e6), 10e18);
        assertEq(registry.valueE18(address(eurc), 100e6), 108e18);
    }

    // ---------- ownership ----------
    function test_Ownable2Step_RequiresAccept() public {
        vm.prank(owner);
        registry.transferOwnership(alice);
        assertEq(registry.owner(), owner);
        assertEq(registry.pendingOwner(), alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        registry.setMaxStaleness(100);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        registry.acceptOwnership();
        vm.prank(alice);
        registry.acceptOwnership();
        assertEq(registry.owner(), alice);
        assertEq(registry.pendingOwner(), address(0));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        registry.setMaxStaleness(100);
        vm.prank(alice);
        registry.setMaxStaleness(100);
    }

    // ---------- listAsset ----------
    function _asset(address t, uint8 d, address v) internal pure returns (IAssetRegistry.Asset memory) {
        return IAssetRegistry.Asset(t, "X", IAssetRegistry.Category.Yield, d, v, false, "");
    }

    function test_ListAsset_HappyPathEmitsAndOrder() public {
        MockERC20 t = new MockERC20("Y", "Y", 18);
        vm.expectEmit(true, false, false, true, address(registry));
        emit AssetListed(address(t), "X", IAssetRegistry.Category.Yield, address(uvenue), false);
        vm.prank(owner);
        registry.listAsset(_asset(address(t), 18, address(uvenue)));
        address[] memory a = registry.assets();
        assertEq(a[a.length - 1], address(t));
        assertEq(registry.assetOf(address(t)).decimals, 18);
    }

    function test_ListAsset_OnlyOwner() public {
        MockERC20 t = new MockERC20("Y", "Y", 6);
        IAssetRegistry.Asset memory a = _asset(address(t), 6, address(uvenue));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        registry.listAsset(a);
    }

    function test_ListAsset_Rejections() public {
        MockERC20 t6 = new MockERC20("Y", "Y", 6);
        MockERC20 t25 = new MockERC20("Z", "Z", 25);
        MockERC20 t24 = new MockERC20("W", "W", 24);
        vm.startPrank(owner);
        vm.expectRevert(AssetRegistry.BadAsset.selector);
        registry.listAsset(_asset(address(0), 6, address(uvenue)));
        vm.expectRevert(AssetRegistry.BadAsset.selector); // duplicate
        registry.listAsset(_asset(address(eurc), 6, address(uvenue)));
        vm.expectRevert(AssetRegistry.BadAsset.selector); // USDC already listed
        registry.listAsset(_asset(USDC_ADDR, 6, address(0)));
        vm.expectRevert(AssetRegistry.BadAsset.selector); // decimals mismatch vs token
        registry.listAsset(_asset(address(t6), 8, address(uvenue)));
        vm.expectRevert(AssetRegistry.BadAsset.selector); // decimals > 24
        registry.listAsset(_asset(address(t25), 25, address(uvenue)));
        vm.expectRevert(AssetRegistry.BadAsset.selector); // zero venue
        registry.listAsset(_asset(address(t6), 6, address(0)));
        registry.listAsset(_asset(address(t24), 24, address(uvenue))); // 24 is the edge: ok
        vm.stopPrank();
        assertEq(registry.assetOf(address(t24)).decimals, 24);
    }
}
