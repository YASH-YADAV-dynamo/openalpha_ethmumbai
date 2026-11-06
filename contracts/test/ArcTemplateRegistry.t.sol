// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IAssetRegistry, ITemplateRegistry} from "../IArcTreasury.sol";
import {TemplateRegistry} from "../TemplateRegistry.sol";
import {ArcBase} from "./helpers/ArcBase.sol";
import {MockERC20} from "./helpers/MockERC20.sol";

contract ArcTemplateRegistryTest is ArcBase {
    event TemplateSet(uint256 indexed id, uint32 version, bytes32 rationaleHash);
    event CuratorSet(address indexed curator, bool allowed);

    function _set(uint256 id, address[] memory t, uint16[] memory w, uint16 band) internal {
        ITemplateRegistry.Template memory tpl = _tpl(t, w, band);
        vm.prank(curator);
        templates.setTemplate(id, tpl);
    }

    function _expectSetRevert(uint256 id, address[] memory t, uint16[] memory w, uint16 band, bytes memory err) internal {
        ITemplateRegistry.Template memory tpl = _tpl(t, w, band);
        vm.prank(curator);
        vm.expectRevert(err);
        templates.setTemplate(id, tpl);
    }

    function _two() internal view returns (address[] memory, uint16[] memory) {
        return (_arr(address(mBTC), address(eurc)), _w(6000, 4000));
    }

    function test_Deployment() public {
        assertEq(templates.owner(), owner);
        assertEq(address(templates.registry()), address(registry));
        assertEq(templates.templateCount(), 0);
        vm.expectRevert(TemplateRegistry.InvalidRegistry.selector);
        new TemplateRegistry(owner, IAssetRegistry(address(0)));
    }

    function test_SetCurator_OwnerOnlyAndEmits() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        templates.setCurator(alice, true);
        vm.expectEmit(true, false, false, true, address(templates));
        emit CuratorSet(alice, true);
        vm.prank(owner);
        templates.setCurator(alice, true);
        assertTrue(templates.isCurator(alice));
        vm.prank(owner);
        templates.setCurator(alice, false);
        assertFalse(templates.isCurator(alice));
        // curators cannot add curators
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, curator));
        templates.setCurator(bob, true);
    }

    function test_SetTemplate_OnlyCurator() public {
        (address[] memory t, uint16[] memory w) = _two();
        ITemplateRegistry.Template memory tpl = _tpl(t, w, 500);
        vm.prank(alice);
        vm.expectRevert(ITemplateRegistry.NotCurator.selector);
        templates.setTemplate(0, tpl);
        vm.prank(owner); // owner is not implicitly a curator
        vm.expectRevert(ITemplateRegistry.NotCurator.selector);
        templates.setTemplate(0, tpl);
        vm.prank(owner);
        templates.setCurator(curator, false);
        vm.prank(curator);
        vm.expectRevert(ITemplateRegistry.NotCurator.selector);
        templates.setTemplate(0, tpl);
    }

    function test_SetTemplate_FirstSetStoresAndEmits() public {
        (address[] memory t, uint16[] memory w) = _two();
        vm.expectEmit(true, false, false, true, address(templates));
        emit TemplateSet(0, 1, keccak256("r"));
        _set(0, t, w, 500);
        assertEq(templates.templateCount(), 1);
        ITemplateRegistry.Template memory s = templates.templateOf(0);
        assertEq(s.name, "T");
        assertEq(s.description, "d");
        assertEq(s.tokens.length, 2);
        assertEq(s.tokens[0], address(mBTC));
        assertEq(s.tokens[1], address(eurc));
        assertEq(s.weightsBps[0], 6000);
        assertEq(s.weightsBps[1], 4000);
        assertEq(s.bandBps, 500);
        assertEq(s.version, 1); // incoming 99 ignored
        assertEq(s.rationaleHash, keccak256("r"));
    }

    function test_SetTemplate_UpdateBumpsVersion() public {
        (address[] memory t, uint16[] memory w) = _two();
        _set(0, t, w, 500);
        vm.expectEmit(true, false, false, true, address(templates));
        emit TemplateSet(0, 2, keccak256("r"));
        _set(0, _arr(address(mETH)), _w(10000), 700);
        ITemplateRegistry.Template memory s = templates.templateOf(0);
        assertEq(s.version, 2);
        assertEq(s.tokens.length, 1);
        assertEq(s.tokens[0], address(mETH));
        assertEq(s.bandBps, 700);
        _set(0, t, w, 500);
        assertEq(templates.templateOf(0).version, 3);
        assertEq(templates.templateCount(), 1);
        // an independent template starts at 1
        _set(1, t, w, 500);
        assertEq(templates.templateOf(1).version, 1);
        assertEq(templates.templateOf(0).version, 3);
        assertEq(templates.templateCount(), 2);
    }

    function test_IdOutOfRange() public {
        (address[] memory t, uint16[] memory w) = _two();
        _expectSetRevert(1, t, w, 500, abi.encodeWithSelector(TemplateRegistry.IdOutOfRange.selector));
        _expectSetRevert(100, t, w, 500, abi.encodeWithSelector(TemplateRegistry.IdOutOfRange.selector));
        _set(0, t, w, 500);
        _expectSetRevert(2, t, w, 500, abi.encodeWithSelector(TemplateRegistry.IdOutOfRange.selector));
        vm.expectRevert(TemplateRegistry.IdOutOfRange.selector);
        templates.templateOf(1);
        vm.expectRevert(TemplateRegistry.IdOutOfRange.selector);
        templates.templateOf(type(uint256).max);
        _set(1, t, w, 500); // id == count appends
        assertEq(templates.templateCount(), 2);
    }

    function test_BadWeights_Sum() public {
        bytes memory e = abi.encodeWithSelector(ITemplateRegistry.BadWeights.selector);
        _expectSetRevert(0, _arr(address(mBTC), address(eurc)), _w(6000, 3999), 500, e);
        _expectSetRevert(0, _arr(address(mBTC), address(eurc)), _w(6000, 4001), 500, e);
    }

    function test_BadWeights_LengthEmptyZero() public {
        bytes memory e = abi.encodeWithSelector(ITemplateRegistry.BadWeights.selector);
        _expectSetRevert(0, _arr(address(mBTC), address(eurc)), _w(10000), 500, e);
        _expectSetRevert(0, _arr(address(mBTC)), _w(5000, 5000), 500, e);
        _expectSetRevert(0, new address[](0), new uint16[](0), 500, e);
        _expectSetRevert(0, _arr(address(mBTC), address(eurc)), _w(10000, 0), 500, e);
    }

    function test_BadWeights_Duplicate() public {
        bytes memory e = abi.encodeWithSelector(ITemplateRegistry.BadWeights.selector);
        _expectSetRevert(0, _arr(address(mBTC), address(mBTC)), _w(5000, 5000), 500, e);
        _expectSetRevert(0, _arr(address(mBTC), address(eurc), address(mBTC)), _w(3000, 3000, 4000), 500, e);
    }

    function test_UnlistedAsset_Reverts() public {
        address x = makeAddr("x");
        _expectSetRevert(0, _arr(address(mBTC), x), _w(5000, 5000), 500,
            abi.encodeWithSelector(IAssetRegistry.UnknownAsset.selector, x));
    }

    function test_UsdcAllowedInTemplate() public {
        _set(0, _arr(USDC_ADDR, address(mBTC)), _w(2000, 8000), 500);
        assertEq(templates.templateOf(0).tokens[0], USDC_ADDR);
    }

    function _manyTokens(uint256 n) internal returns (address[] memory t, uint16[] memory w) {
        t = new address[](n);
        w = new uint16[](n);
        t[0] = USDC_ADDR; t[1] = address(eurc); t[2] = address(mBTC); t[3] = address(mETH); t[4] = address(mXAU);
        for (uint256 i = 5; i < n; ++i) {
            MockERC20 m = new MockERC20("M", "M", 6);
            vm.prank(owner);
            registry.listAsset(IAssetRegistry.Asset(address(m), "M", IAssetRegistry.Category.Yield, 6, address(uvenue), false, ""));
            t[i] = address(m);
        }
        uint16 base = uint16(10000 / n);
        uint16 acc;
        for (uint256 i; i < n; ++i) {
            w[i] = base;
            acc += base;
        }
        w[n - 1] += uint16(10000 - acc);
    }

    function test_MaxAssets_12Ok_13Reverts() public {
        (address[] memory t, uint16[] memory w) = _manyTokens(12);
        _set(0, t, w, 500);
        assertEq(templates.templateOf(0).tokens.length, 12);
        (address[] memory t13, uint16[] memory w13) = _manyTokens(13);
        _expectSetRevert(0, t13, w13, 500, abi.encodeWithSelector(ITemplateRegistry.BadWeights.selector));
    }

    function test_BandBoundaries() public {
        (address[] memory t, uint16[] memory w) = _two();
        bytes memory e = abi.encodeWithSelector(TemplateRegistry.BadBand.selector);
        _expectSetRevert(0, t, w, 99, e);
        _expectSetRevert(0, t, w, 0, e);
        _expectSetRevert(0, t, w, 2001, e);
        _set(0, t, w, 100);
        assertEq(templates.templateOf(0).bandBps, 100);
        _set(0, t, w, 2000);
        assertEq(templates.templateOf(0).bandBps, 2000);
    }

    function test_Ownable2Step() public {
        vm.prank(owner);
        templates.transferOwnership(alice);
        assertEq(templates.owner(), owner);
        vm.prank(alice);
        templates.acceptOwnership();
        assertEq(templates.owner(), alice);
    }
}
