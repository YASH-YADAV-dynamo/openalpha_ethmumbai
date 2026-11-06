// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IV4Quoter} from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";
import {IAssetRegistry, ITemplateRegistry, BucketParams} from "../../IArcTreasury.sol";
import {AssetRegistry} from "../../AssetRegistry.sol";
import {MirrorToken} from "../../MirrorToken.sol";
import {MirrorVenue} from "../../MirrorVenue.sol";
import {UniswapV4Venue} from "../../UniswapV4Venue.sol";
import {TemplateRegistry} from "../../TemplateRegistry.sol";
import {BucketAccount} from "../../BucketAccount.sol";
import {BucketFactory} from "../../BucketFactory.sol";
import {MockERC20} from "./MockERC20.sol";
import {MockPoolManager, MockQuoter} from "./MockPoolManager.sol";

/// @dev Shared fixture: full Arc Treasury stack with mocks. No tests live here.
abstract contract ArcBase is Test {
    address internal constant USDC_ADDR = 0x3600000000000000000000000000000000000000;
    address internal constant EURC_ADDR = 0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a;

    address internal owner = makeAddr("owner");
    address internal reporter = makeAddr("reporter");
    address internal curator = makeAddr("curator");
    address internal keeper = makeAddr("keeper");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    MockERC20 internal usdc;
    MockERC20 internal eurc;
    AssetRegistry internal registry;
    MirrorVenue internal mvenue;
    MirrorToken internal mBTC; // 8 dec
    MirrorToken internal mETH; // 18 dec
    MirrorToken internal mXAU; // 6 dec
    MockPoolManager internal pm;
    MockQuoter internal quoter;
    UniswapV4Venue internal uvenue;
    TemplateRegistry internal templates;
    BucketAccount internal impl;
    BucketFactory internal factory;

    uint256 internal pBTC = 60_000e8;
    uint256 internal pETH = 3_000e8;
    uint256 internal pXAU = 2_000e8;
    uint256 internal pEURC = 1.08e8;

    uint256 internal constant T0 = 1_000_000;

    function setUp() public virtual {
        vm.warp(T0);
        deployCodeTo("contracts/test/helpers/MockERC20.sol:MockERC20", abi.encode("USD Coin", "USDC", uint8(6)), USDC_ADDR);
        deployCodeTo("contracts/test/helpers/MockERC20.sol:MockERC20", abi.encode("Euro Coin", "EURC", uint8(6)), EURC_ADDR);
        usdc = MockERC20(USDC_ADDR);
        eurc = MockERC20(EURC_ADDR);

        registry = new AssetRegistry(owner, USDC_ADDR);
        mvenue = new MirrorVenue(IAssetRegistry(address(registry)), USDC_ADDR);
        mBTC = new MirrorToken("cirBTC (testnet mirror)", "cirBTC.m", 8, address(mvenue));
        mETH = new MirrorToken("cirETH (testnet mirror)", "cirETH.m", 18, address(mvenue));
        mXAU = new MirrorToken("cirXAU (testnet mirror)", "cirXAU.m", 6, address(mvenue));

        pm = new MockPoolManager();
        quoter = new MockQuoter();
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(USDC_ADDR),
            currency1: Currency.wrap(EURC_ADDR),
            fee: 500,
            tickSpacing: 10,
            hooks: IHooks(address(0))
        });
        uvenue = new UniswapV4Venue(IPoolManager(address(pm)), IV4Quoter(address(quoter)), key);
        // USDC -> EURC at 1/1.08, EURC -> USDC at 1.08 (matches registry price), 0.05% pool fee
        pm.setRates(925_926, 1_080_000);
        usdc.mint(address(pm), 100_000_000e6);
        eurc.mint(address(pm), 100_000_000e6);

        vm.startPrank(owner);
        registry.setReporter(reporter, true);
        _list(address(eurc), "EURC", IAssetRegistry.Category.FX, 6, address(uvenue), false);
        _list(address(mBTC), "cirBTC.m", IAssetRegistry.Category.Crypto, 8, address(mvenue), true);
        _list(address(mETH), "cirETH.m", IAssetRegistry.Category.Crypto, 18, address(mvenue), true);
        _list(address(mXAU), "cirXAU.m", IAssetRegistry.Category.RWA, 6, address(mvenue), true);
        vm.stopPrank();

        _feedAll();
        usdc.mint(address(mvenue), 1_000_000e6); // mirror reserve

        templates = new TemplateRegistry(owner, IAssetRegistry(address(registry)));
        vm.prank(owner);
        templates.setCurator(curator, true);
        impl = new BucketAccount();
        factory = new BucketFactory(address(impl), IAssetRegistry(address(registry)), ITemplateRegistry(address(templates)));
    }

    // ---------------- helpers ----------------

    function _list(address t, string memory sym, IAssetRegistry.Category c, uint8 d, address v, bool m) internal {
        registry.listAsset(IAssetRegistry.Asset(t, sym, c, d, v, m, m ? "0xmainnet" : ""));
    }

    function _report(address[] memory toks, uint256[] memory prices, uint64 observedAt) internal pure returns (bytes memory) {
        return abi.encode(uint8(1), abi.encode(toks, prices, observedAt));
    }

    function _feed(address[] memory toks, uint256[] memory prices) internal {
        vm.prank(reporter);
        registry.onReport("", _report(toks, prices, uint64(block.timestamp)));
    }

    function _feedOne(address t, uint256 price) internal {
        _feed(_arr(t), _u(price));
    }

    function _feedAll() internal {
        address[] memory t = new address[](4);
        uint256[] memory p = new uint256[](4);
        t[0] = address(eurc); p[0] = pEURC;
        t[1] = address(mBTC); p[1] = pBTC;
        t[2] = address(mETH); p[2] = pETH;
        t[3] = address(mXAU); p[3] = pXAU;
        _feed(t, p);
    }

    function _setRisk(address t, uint8 level) internal {
        vm.prank(reporter);
        registry.onReport("", abi.encode(uint8(2), abi.encode(t, level, bytes32(uint256(1)))));
    }

    function _arr(address a) internal pure returns (address[] memory r) {
        r = new address[](1);
        r[0] = a;
    }

    function _arr(address a, address b) internal pure returns (address[] memory r) {
        r = new address[](2);
        r[0] = a; r[1] = b;
    }

    function _arr(address a, address b, address c) internal pure returns (address[] memory r) {
        r = new address[](3);
        r[0] = a; r[1] = b; r[2] = c;
    }

    function _w(uint16 a) internal pure returns (uint16[] memory r) {
        r = new uint16[](1);
        r[0] = a;
    }

    function _w(uint16 a, uint16 b) internal pure returns (uint16[] memory r) {
        r = new uint16[](2);
        r[0] = a; r[1] = b;
    }

    function _w(uint16 a, uint16 b, uint16 c) internal pure returns (uint16[] memory r) {
        r = new uint16[](3);
        r[0] = a; r[1] = b; r[2] = c;
    }

    function _u(uint256 a) internal pure returns (uint256[] memory r) {
        r = new uint256[](1);
        r[0] = a;
    }

    function _u(uint256 a, uint256 b) internal pure returns (uint256[] memory r) {
        r = new uint256[](2);
        r[0] = a; r[1] = b;
    }

    function _defParams() internal pure returns (BucketParams memory) {
        return BucketParams(500, 100, 2500, 3600);
    }

    function _newBucket(address who, address[] memory toks, uint16[] memory ws) internal returns (BucketAccount b) {
        return _newBucketP(who, toks, ws, _defParams());
    }

    function _newBucketP(address who, address[] memory toks, uint16[] memory ws, BucketParams memory p)
        internal returns (BucketAccount b)
    {
        vm.prank(who);
        b = BucketAccount(factory.createBucket("test", toks, ws, p));
    }

    function _fund(BucketAccount b, uint256 amt) internal {
        usdc.mint(address(this), amt);
        usdc.approve(address(b), amt);
        b.deposit(amt);
    }

    function _tpl(address[] memory toks, uint16[] memory ws, uint16 band) internal pure returns (ITemplateRegistry.Template memory t) {
        t.name = "T";
        t.description = "d";
        t.tokens = toks;
        t.weightsBps = ws;
        t.bandBps = band;
        t.version = 99; // ignored by registry
        t.rationaleHash = keccak256("r");
    }
}
