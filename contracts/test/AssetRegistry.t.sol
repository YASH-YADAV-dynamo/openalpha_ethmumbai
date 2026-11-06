// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./TreasuryBase.t.sol";

contract AssetRegistryTest is TreasuryBase {
    // ------------------------------------------------------------ helpers
    function _priceReport(address token, uint256 price, uint64 at) internal {
        address[] memory t = new address[](1);
        uint256[] memory p = new uint256[](1);
        t[0] = token;
        p[0] = price;
        _report(t, p, at);
    }

    function _rawReport(bytes memory report) internal {
        vm.prank(reporter);
        registry.onReport("", report);
    }

    // ------------------------------------------------------------ deployment / listing
    function test_ConstructorListsUsdc() public view {
        address[] memory list = registry.assets();
        assertEq(list[0], address(usdc));
        assertEq(list.length, 4); // usdc, btc, eth, eurc (listing order)
        assertEq(list[1], address(btc));
        assertEq(list[3], address(eurc));
        IAssetRegistry.Asset memory a = registry.assetOf(address(usdc));
        assertEq(a.symbol, "USDC");
        assertEq(uint8(a.category), uint8(IAssetRegistry.Category.Cash));
        assertEq(a.decimals, 6);
        assertEq(a.venue, address(0));
        assertFalse(a.mirror);
        assertEq(registry.usdc(), address(usdc));
        assertEq(registry.maxStaleness(), 3600);
        assertEq(registry.owner(), owner);
    }

    function test_ListAssetEmitsAndStores() public {
        MockERC20 t = new MockERC20("X", "X", 12);
        vm.expectEmit(true, false, false, true, address(registry));
        emit IAssetRegistry.AssetListed(address(t), "X", IAssetRegistry.Category.Yield, address(mirrorVenue), false);
        vm.prank(owner);
        registry.listAsset(IAssetRegistry.Asset(address(t), "X", IAssetRegistry.Category.Yield, 12, address(mirrorVenue), false, ""));
        assertEq(registry.assets().length, 5);
        assertEq(registry.assetOf(address(t)).decimals, 12);
    }

    function test_ListAssetOnlyOwner() public {
        MockERC20 t = new MockERC20("X", "X", 6);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        registry.listAsset(IAssetRegistry.Asset(address(t), "X", IAssetRegistry.Category.Yield, 6, address(mirrorVenue), false, ""));
    }

    function test_ListAssetRejectsBadInputs() public {
        MockERC20 t = new MockERC20("X", "X", 6);
        vm.startPrank(owner);
        // duplicate
        vm.expectRevert(AssetRegistry.BadAsset.selector);
        registry.listAsset(IAssetRegistry.Asset(address(eurc), "EURC", IAssetRegistry.Category.FX, 6, address(v4Venue), false, ""));
        // decimals mismatch vs token.decimals()
        vm.expectRevert(AssetRegistry.BadAsset.selector);
        registry.listAsset(IAssetRegistry.Asset(address(t), "X", IAssetRegistry.Category.FX, 18, address(mirrorVenue), false, ""));
        // zero venue for non-USDC
        vm.expectRevert(AssetRegistry.BadAsset.selector);
        registry.listAsset(IAssetRegistry.Asset(address(t), "X", IAssetRegistry.Category.FX, 6, address(0), false, ""));
        // zero token
        vm.expectRevert(AssetRegistry.BadAsset.selector);
        registry.listAsset(IAssetRegistry.Asset(address(0), "X", IAssetRegistry.Category.FX, 6, address(mirrorVenue), false, ""));
        vm.stopPrank();
    }

    function test_ListAssetRejectsDecimalsAbove24() public {
        MockERC20 t = new MockERC20("X", "X", 25);
        vm.prank(owner);
        vm.expectRevert(AssetRegistry.BadAsset.selector);
        registry.listAsset(IAssetRegistry.Asset(address(t), "X", IAssetRegistry.Category.FX, 25, address(mirrorVenue), false, ""));
    }

    function test_AssetOfUnknownReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IAssetRegistry.UnknownAsset.selector, alice));
        registry.assetOf(alice);
    }

    // ------------------------------------------------------------ reporters
    function test_SetReporterOwnerOnlyAndEmits() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        registry.setReporter(bob, true);

        vm.expectEmit(true, false, false, true, address(registry));
        emit IAssetRegistry.ReporterSet(bob, true);
        vm.prank(owner);
        registry.setReporter(bob, true);
        assertTrue(registry.isReporter(bob));

        vm.prank(owner);
        registry.setReporter(bob, false);
        assertFalse(registry.isReporter(bob));
    }

    function test_OnReportRejectsNonReporter() public {
        vm.prank(alice);
        vm.expectRevert(IAssetRegistry.NotReporter.selector);
        registry.onReport("", abi.encode(uint8(1), abi.encode(new address[](0), new uint256[](0), uint64(1))));
    }

    function test_RemovedReporterRejected() public {
        vm.prank(owner);
        registry.setReporter(reporter, false);
        vm.prank(reporter);
        vm.expectRevert(IAssetRegistry.NotReporter.selector);
        registry.onReport("", "");
    }

    // ------------------------------------------------------------ price reports
    function test_PriceReportStoresAndEmits() public {
        vm.expectEmit(true, false, false, true, address(registry));
        emit IAssetRegistry.PriceUpdated(address(btc), 65_000e8, uint64(block.timestamp));
        _priceReport(address(btc), 65_000e8, uint64(block.timestamp));
        (uint256 p, uint64 at) = registry.priceE8(address(btc));
        assertEq(p, 65_000e8);
        assertEq(at, uint64(block.timestamp));
    }

    function test_PriceReportMultipleTokens() public {
        address[] memory t = new address[](2);
        uint256[] memory p = new uint256[](2);
        t[0] = address(btc);
        t[1] = address(eth);
        p[0] = 1e8;
        p[1] = 2e8;
        _report(t, p, uint64(block.timestamp));
        (uint256 a,) = registry.priceE8(address(btc));
        (uint256 b,) = registry.priceE8(address(eth));
        assertEq(a, 1e8);
        assertEq(b, 2e8);
    }

    function test_PriceReportOutOfOrderRejected() public {
        skip(100);
        _priceReport(address(btc), 61_000e8, uint64(block.timestamp));
        vm.expectRevert(IAssetRegistry.BadReport.selector);
        _priceReport(address(btc), 59_000e8, uint64(block.timestamp - 1));
        (uint256 p,) = registry.priceE8(address(btc));
        assertEq(p, 61_000e8, "old report must not overwrite");
    }

    function test_PriceReportEqualObservedAtAllowed() public {
        _priceReport(address(btc), 61_000e8, uint64(block.timestamp));
        _priceReport(address(btc), 62_000e8, uint64(block.timestamp));
        (uint256 p,) = registry.priceE8(address(btc));
        assertEq(p, 62_000e8);
    }

    function test_PriceReportFutureObservedAtRejected() public {
        vm.expectRevert(IAssetRegistry.BadReport.selector);
        _priceReport(address(btc), 61_000e8, uint64(block.timestamp + 1));
    }

    function test_PriceReportBadPayloads() public {
        address[] memory t1 = new address[](1);
        t1[0] = address(btc);
        uint256[] memory p2 = new uint256[](2);
        p2[0] = 1;
        p2[1] = 1;
        // length mismatch
        vm.expectRevert(IAssetRegistry.BadReport.selector);
        _report(t1, p2, uint64(block.timestamp));
        // empty
        vm.expectRevert(IAssetRegistry.BadReport.selector);
        _report(new address[](0), new uint256[](0), uint64(block.timestamp));
        // zero price
        vm.expectRevert(IAssetRegistry.BadReport.selector);
        _priceReport(address(btc), 0, uint64(block.timestamp));
        // price > uint192 max
        vm.expectRevert(IAssetRegistry.BadReport.selector);
        _priceReport(address(btc), uint256(type(uint192).max) + 1, uint64(block.timestamp));
        // USDC may never be repriced
        vm.expectRevert(IAssetRegistry.BadReport.selector);
        _priceReport(address(usdc), 2e8, uint64(block.timestamp));
    }

    function test_PriceReportUint192MaxAccepted() public {
        _priceReport(address(btc), type(uint192).max, uint64(block.timestamp));
        (uint256 p,) = registry.priceE8(address(btc));
        assertEq(p, type(uint192).max);
    }

    function test_PriceReportTooManyEntries() public {
        address[] memory t = new address[](51);
        uint256[] memory p = new uint256[](51);
        for (uint256 i; i < 51; ++i) {
            t[i] = address(btc);
            p[i] = 1e8;
        }
        vm.expectRevert(IAssetRegistry.BadReport.selector);
        _report(t, p, uint64(block.timestamp));
        // exactly 50 is fine
        assembly {
            mstore(t, 50)
            mstore(p, 50)
        }
        _report(t, p, uint64(block.timestamp));
    }

    function test_PriceReportUnlistedTokenReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IAssetRegistry.UnknownAsset.selector, alice));
        _priceReport(alice, 1e8, uint64(block.timestamp));
    }

    function test_ReportMalformedAndUnknownKind() public {
        vm.expectRevert(IAssetRegistry.BadReport.selector);
        _rawReport(hex"deadbeef");
        vm.expectRevert(IAssetRegistry.BadReport.selector);
        _rawReport("");
        vm.expectRevert(IAssetRegistry.BadReport.selector);
        _rawReport(abi.encode(uint8(3), bytes("")));
        vm.expectRevert(IAssetRegistry.BadReport.selector);
        _rawReport(abi.encode(uint8(0), bytes("")));
        // kind 1 with garbage payload
        vm.expectRevert(IAssetRegistry.BadReport.selector);
        _rawReport(abi.encode(uint8(1), hex"1234"));
        // kind 2 with garbage payload
        vm.expectRevert(IAssetRegistry.BadReport.selector);
        _rawReport(abi.encode(uint8(2), hex"1234"));
    }

    // ------------------------------------------------------------ staleness
    function test_PriceE8UsdcAlways1e8() public {
        (uint256 p, uint64 at) = registry.priceE8(address(usdc));
        assertEq(p, 1e8);
        assertEq(at, uint64(block.timestamp));
        skip(30 days);
        (p, at) = registry.priceE8(address(usdc));
        assertEq(p, 1e8);
        assertEq(at, uint64(block.timestamp));
    }

    function test_StalePriceAfterMaxStaleness() public {
        skip(3600); // exactly observedAt + maxStaleness: still fresh
        (uint256 p,) = registry.priceE8(address(btc));
        assertEq(p, 60_000e8);
        skip(1);
        vm.expectRevert(abi.encodeWithSelector(IAssetRegistry.StalePrice.selector, address(btc)));
        registry.priceE8(address(btc));
        vm.expectRevert(abi.encodeWithSelector(IAssetRegistry.StalePrice.selector, address(btc)));
        registry.valueE18(address(btc), 1e8);
    }

    function test_NeverPricedIsStale() public {
        MockERC20 t = _listExtra("NEW", 6, address(mirrorVenue));
        vm.expectRevert(abi.encodeWithSelector(IAssetRegistry.StalePrice.selector, address(t)));
        registry.priceE8(address(t));
    }

    function test_PriceE8UnknownReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IAssetRegistry.UnknownAsset.selector, alice));
        registry.priceE8(alice);
    }

    function test_SetMaxStalenessBoundsOwnerEmit() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        registry.setMaxStaleness(600);

        vm.startPrank(owner);
        vm.expectRevert(IAssetRegistry.BadReport.selector);
        registry.setMaxStaleness(59);
        vm.expectRevert(IAssetRegistry.BadReport.selector);
        registry.setMaxStaleness(7 days + 1);
        vm.expectEmit(false, false, false, true, address(registry));
        emit AssetRegistry.MaxStalenessSet(60);
        registry.setMaxStaleness(60);
        assertEq(registry.maxStaleness(), 60);
        registry.setMaxStaleness(7 days);
        assertEq(registry.maxStaleness(), 7 days);
        vm.stopPrank();
    }

    function test_ShorterStalenessApplies() public {
        vm.prank(owner);
        registry.setMaxStaleness(60);
        skip(61);
        vm.expectRevert(abi.encodeWithSelector(IAssetRegistry.StalePrice.selector, address(eth)));
        registry.priceE8(address(eth));
    }

    // ------------------------------------------------------------ risk
    function test_RiskLevels0To3Accepted() public {
        for (uint8 l; l <= 3; ++l) {
            vm.expectEmit(true, false, false, true, address(registry));
            emit IAssetRegistry.RiskUpdated(address(btc), l, keccak256("evidence"));
            _setRisk(address(btc), l);
            assertEq(registry.riskOf(address(btc)), l);
        }
    }

    function test_RiskLevel4Rejected() public {
        vm.expectRevert(IAssetRegistry.BadReport.selector);
        _setRisk(address(btc), 4);
        vm.expectRevert(IAssetRegistry.BadReport.selector);
        _setRisk(address(btc), 255);
    }

    function test_RiskForUsdcRejectedAndUnlistedReverts() public {
        vm.expectRevert(IAssetRegistry.BadReport.selector);
        _setRisk(address(usdc), 1);
        vm.expectRevert(abi.encodeWithSelector(IAssetRegistry.UnknownAsset.selector, alice));
        _setRisk(alice, 1);
    }

    function test_RiskOnlyReporter() public {
        vm.prank(alice);
        vm.expectRevert(IAssetRegistry.NotReporter.selector);
        registry.onReport("", abi.encode(uint8(2), abi.encode(address(btc), uint8(1), bytes32(0))));
    }

    function test_RiskDefaultsAndUnknown() public {
        assertEq(registry.riskOf(address(usdc)), 0);
        assertEq(registry.riskOf(address(btc)), 0);
        vm.expectRevert(abi.encodeWithSelector(IAssetRegistry.UnknownAsset.selector, alice));
        registry.riskOf(alice);
    }

    function test_RiskReadableWhenPriceStale() public {
        _setRisk(address(btc), 2);
        skip(30 days);
        assertEq(registry.riskOf(address(btc)), 2);
    }

    // ------------------------------------------------------------ valuation
    function test_ValueE18() public view {
        assertEq(registry.valueE18(address(btc), 1e8), 60_000e18);
        assertEq(registry.valueE18(address(eth), 1e18), 3_000e18);
        assertEq(registry.valueE18(address(eurc), 5e6), 5e18);
        assertEq(registry.valueE18(address(usdc), 5e6), 5e18);
        assertEq(registry.valueE18(address(usdc), 0), 0);
    }

    // ------------------------------------------------------------ ownership (2-step)
    function test_OwnershipTransferIsTwoStep() public {
        vm.prank(owner);
        registry.transferOwnership(bob);
        assertEq(registry.owner(), owner);
        vm.prank(bob);
        registry.acceptOwnership();
        assertEq(registry.owner(), bob);
    }
}
