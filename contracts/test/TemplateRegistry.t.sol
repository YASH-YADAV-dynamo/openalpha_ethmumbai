// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./TreasuryBase.t.sol";

contract TemplateRegistryTest is TreasuryBase {
    function _tpl(address[] memory t, uint16[] memory w, uint16 band) internal pure returns (ITemplateRegistry.Template memory) {
        return ITemplateRegistry.Template("Blue", "desc", t, w, band, 99, keccak256("r"));
    }

    function _set(uint256 id, ITemplateRegistry.Template memory t) internal {
        vm.prank(curator);
        templates.setTemplate(id, t);
    }

    function test_ConstructorAndCurators() public {
        assertEq(address(templates.registry()), address(registry));
        assertEq(templates.owner(), owner);
        assertEq(templates.templateCount(), 0);
        assertTrue(templates.isCurator(curator));
        assertFalse(templates.isCurator(alice));

        vm.expectRevert(TemplateRegistry.InvalidRegistry.selector);
        new TemplateRegistry(owner, IAssetRegistry(address(0)));
    }

    function test_SetCuratorOwnerOnlyAndEmits() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        templates.setCurator(bob, true);

        vm.expectEmit(true, false, false, true, address(templates));
        emit ITemplateRegistry.CuratorSet(bob, true);
        vm.prank(owner);
        templates.setCurator(bob, true);
        assertTrue(templates.isCurator(bob));
        vm.prank(owner);
        templates.setCurator(bob, false);
        assertFalse(templates.isCurator(bob));
    }

    function test_SetTemplateOnlyCurator() public {
        vm.prank(alice);
        vm.expectRevert(ITemplateRegistry.NotCurator.selector);
        templates.setTemplate(0, _tpl(_addrs(address(btc), address(usdc)), _wts(5000, 5000), 500));
        // the owner is not implicitly a curator
        vm.prank(owner);
        vm.expectRevert(ITemplateRegistry.NotCurator.selector);
        templates.setTemplate(0, _tpl(_addrs(address(btc), address(usdc)), _wts(5000, 5000), 500));
    }

    function test_SetTemplateStoresAndIgnoresIncomingVersion() public {
        vm.expectEmit(true, false, false, true, address(templates));
        emit ITemplateRegistry.TemplateSet(0, 1, keccak256("r"));
        _set(0, _tpl(_addrs(address(btc), address(usdc)), _wts(6000, 4000), 500));

        assertEq(templates.templateCount(), 1);
        ITemplateRegistry.Template memory t = templates.templateOf(0);
        assertEq(t.name, "Blue");
        assertEq(t.description, "desc");
        assertEq(t.tokens.length, 2);
        assertEq(t.tokens[0], address(btc));
        assertEq(t.weightsBps[0], 6000);
        assertEq(t.bandBps, 500);
        assertEq(t.version, 1, "incoming version field ignored");
        assertEq(t.rationaleHash, keccak256("r"));
    }

    function test_VersionBumpsOnEachUpdate() public {
        _set(0, _tpl(_addrs(address(btc), address(usdc)), _wts(6000, 4000), 500));
        vm.expectEmit(true, false, false, true, address(templates));
        emit ITemplateRegistry.TemplateSet(0, 2, keccak256("r"));
        _set(0, _tpl(_addrs(address(eth), address(usdc)), _wts(3000, 7000), 300));
        _set(0, _tpl(_addrs(address(eth), address(usdc)), _wts(3000, 7000), 300));
        ITemplateRegistry.Template memory t = templates.templateOf(0);
        assertEq(t.version, 3);
        assertEq(t.tokens[0], address(eth));
        assertEq(t.weightsBps[1], 7000);
        assertEq(templates.templateCount(), 1);
    }

    function test_IdMustBeAtMostCount() public {
        vm.prank(curator);
        vm.expectRevert(TemplateRegistry.IdOutOfRange.selector);
        templates.setTemplate(1, _tpl(_addrs(address(btc), address(usdc)), _wts(5000, 5000), 500));

        _set(0, _tpl(_addrs(address(btc), address(usdc)), _wts(5000, 5000), 500));
        _set(1, _tpl(_addrs(address(eth), address(usdc)), _wts(5000, 5000), 500)); // append
        assertEq(templates.templateCount(), 2);
        assertEq(templates.templateOf(1).version, 1);

        vm.prank(curator);
        vm.expectRevert(TemplateRegistry.IdOutOfRange.selector);
        templates.setTemplate(3, _tpl(_addrs(address(btc), address(usdc)), _wts(5000, 5000), 500));
    }

    function test_TemplateOfOutOfRangeReverts() public {
        vm.expectRevert(TemplateRegistry.IdOutOfRange.selector);
        templates.templateOf(0);
        _set(0, _tpl(_addrs(address(btc), address(usdc)), _wts(5000, 5000), 500));
        vm.expectRevert(TemplateRegistry.IdOutOfRange.selector);
        templates.templateOf(1);
    }

    function test_BadWeightsCases() public {
        vm.startPrank(curator);
        // length mismatch
        vm.expectRevert(ITemplateRegistry.BadWeights.selector);
        templates.setTemplate(0, _tpl(_addrs(address(btc), address(usdc)), _wts(5000, 3000, 2000), 500));
        // empty
        vm.expectRevert(ITemplateRegistry.BadWeights.selector);
        templates.setTemplate(0, _tpl(new address[](0), new uint16[](0), 500));
        // zero weight
        vm.expectRevert(ITemplateRegistry.BadWeights.selector);
        templates.setTemplate(0, _tpl(_addrs(address(btc), address(usdc)), _wts(0, 10000), 500));
        // sum short / long
        vm.expectRevert(ITemplateRegistry.BadWeights.selector);
        templates.setTemplate(0, _tpl(_addrs(address(btc), address(usdc)), _wts(5000, 4999), 500));
        vm.expectRevert(ITemplateRegistry.BadWeights.selector);
        templates.setTemplate(0, _tpl(_addrs(address(btc), address(usdc)), _wts(5000, 5001), 500));
        // duplicate token
        vm.expectRevert(ITemplateRegistry.BadWeights.selector);
        templates.setTemplate(0, _tpl(_addrs(address(btc), address(btc)), _wts(5000, 5000), 500));
        vm.stopPrank();
    }

    function test_MoreThanTwelveAssetsRejected() public {
        address[] memory t = new address[](13);
        uint16[] memory w = new uint16[](13);
        for (uint256 i; i < 13; ++i) {
            t[i] = address(uint160(0x1000 + i));
            w[i] = i == 0 ? 10000 - 12 * 100 : 100;
        }
        vm.prank(curator);
        vm.expectRevert(ITemplateRegistry.BadWeights.selector);
        templates.setTemplate(0, _tpl(t, w, 500));
    }

    function test_ExactlyTwelveAssetsAccepted() public {
        address[] memory t = new address[](12);
        uint16[] memory w = new uint16[](12);
        t[0] = address(usdc);
        t[1] = address(btc);
        t[2] = address(eth);
        t[3] = address(eurc);
        for (uint256 i = 4; i < 12; ++i) t[i] = address(_listExtra("E", 6, address(mirrorVenue)));
        for (uint256 i; i < 12; ++i) w[i] = i == 0 ? 10000 - 11 * 800 : 800;
        _set(0, _tpl(t, w, 500));
        assertEq(templates.templateOf(0).tokens.length, 12);
    }

    function test_UnlistedTokenBubblesUnknownAsset() public {
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(IAssetRegistry.UnknownAsset.selector, bob));
        templates.setTemplate(0, _tpl(_addrs(address(btc), bob), _wts(5000, 5000), 500));
    }

    function test_BandBounds() public {
        vm.startPrank(curator);
        vm.expectRevert(TemplateRegistry.BadBand.selector);
        templates.setTemplate(0, _tpl(_addrs(address(btc), address(usdc)), _wts(5000, 5000), 99));
        vm.expectRevert(TemplateRegistry.BadBand.selector);
        templates.setTemplate(0, _tpl(_addrs(address(btc), address(usdc)), _wts(5000, 5000), 2001));
        templates.setTemplate(0, _tpl(_addrs(address(btc), address(usdc)), _wts(5000, 5000), 100));
        templates.setTemplate(0, _tpl(_addrs(address(btc), address(usdc)), _wts(5000, 5000), 2000));
        vm.stopPrank();
        assertEq(templates.templateOf(0).version, 2);
    }

    function test_FailedSetTemplateDoesNotAppend() public {
        vm.prank(curator);
        vm.expectRevert(ITemplateRegistry.BadWeights.selector);
        templates.setTemplate(0, _tpl(_addrs(address(btc), address(usdc)), _wts(5000, 4000), 500));
        assertEq(templates.templateCount(), 0);
    }

    function test_TemplateMayIncludeUsdc() public {
        _set(0, _tpl(_addrs(address(usdc), address(eurc)), _wts(5000, 5000), 300));
        assertEq(templates.templateOf(0).tokens[0], address(usdc));
    }
}
