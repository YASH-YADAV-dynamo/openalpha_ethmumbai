// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IV4Quoter} from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";

import {
    IAssetRegistry,
    ITemplateRegistry,
    IVenue,
    IBucketAccount,
    IBucketFactory,
    BucketParams
} from "../IArcTreasury.sol";
import {AssetRegistry} from "../AssetRegistry.sol";
import {MirrorToken} from "../MirrorToken.sol";
import {MirrorVenue} from "../MirrorVenue.sol";
import {TemplateRegistry} from "../TemplateRegistry.sol";
import {BucketAccount} from "../BucketAccount.sol";
import {BucketFactory} from "../BucketFactory.sol";
import {UniswapV4Venue} from "../UniswapV4Venue.sol";
import {MockERC20} from "../test-helpers/MockERC20.sol";
import {MockPoolManager, MockQuoter} from "../test-helpers/MockUniswap.sol";
import {LossyVenue} from "../test-helpers/MockVenue.sol";

/// @dev Shared fixture: real registry/venues/factory + mock USDC, EURC and a mock v4 PoolManager/Quoter.
///      Contains no test_* functions (every category file inherits it).
abstract contract TreasuryBase is Test {
    uint64 internal constant T0 = 1_700_000_000;
    uint256 internal constant NO_TEMPLATE = type(uint256).max;

    address internal owner = makeAddr("owner");
    address internal reporter = makeAddr("reporter");
    address internal curator = makeAddr("curator");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal keeper = makeAddr("keeper");

    MockERC20 internal usdc;
    MockERC20 internal eurc;
    AssetRegistry internal registry;
    MirrorVenue internal mirrorVenue;
    MirrorToken internal btc; // 8 dec
    MirrorToken internal eth; // 18 dec
    MockPoolManager internal pm;
    MockQuoter internal quoter;
    UniswapV4Venue internal v4Venue;
    TemplateRegistry internal templates;
    BucketAccount internal impl;
    BucketFactory internal factory;

    mapping(address => uint256) internal px;

    function setUp() public virtual {
        vm.warp(T0);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        eurc = new MockERC20("Euro Coin", "EURC", 6);
        registry = new AssetRegistry(owner, address(usdc));
        mirrorVenue = new MirrorVenue(registry, address(usdc));
        btc = new MirrorToken("cirBTC (testnet mirror)", "cirBTC.m", 8, address(mirrorVenue));
        eth = new MirrorToken("WETH (testnet mirror)", "WETH.m", 18, address(mirrorVenue));

        pm = new MockPoolManager();
        quoter = new MockQuoter();
        (address lo, address hi) = address(usdc) < address(eurc) ? (address(usdc), address(eurc)) : (address(eurc), address(usdc));
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(lo),
            currency1: Currency.wrap(hi),
            fee: 500,
            tickSpacing: 10,
            hooks: IHooks(address(0))
        });
        v4Venue = new UniswapV4Venue(IPoolManager(address(pm)), IV4Quoter(address(quoter)), key);
        pm.setRate(9_995); // 5 bps pool fee
        usdc.mint(address(pm), 1e15);
        eurc.mint(address(pm), 1e15);

        vm.startPrank(owner);
        registry.listAsset(IAssetRegistry.Asset(address(btc), "cirBTC.m", IAssetRegistry.Category.Crypto, 8, address(mirrorVenue), true, "0xbtc"));
        registry.listAsset(IAssetRegistry.Asset(address(eth), "WETH.m", IAssetRegistry.Category.Crypto, 18, address(mirrorVenue), true, "0xeth"));
        registry.listAsset(IAssetRegistry.Asset(address(eurc), "EURC", IAssetRegistry.Category.FX, 6, address(v4Venue), false, ""));
        registry.setReporter(reporter, true);
        vm.stopPrank();

        templates = new TemplateRegistry(owner, registry);
        vm.prank(owner);
        templates.setCurator(curator, true);

        impl = new BucketAccount();
        factory = new BucketFactory(address(impl), registry, templates);

        px[address(btc)] = 60_000e8;
        px[address(eth)] = 3_000e8;
        px[address(eurc)] = 1e8;
        _refresh();
    }

    // ---------------------------------------------------------------- oracle helpers
    function _report(address[] memory t, uint256[] memory p, uint64 at) internal {
        vm.prank(reporter);
        registry.onReport("", abi.encode(uint8(1), abi.encode(t, p, at)));
    }

    /// @dev Re-reports btc/eth/eurc at the current block.timestamp (call after every warp).
    function _refresh() internal {
        address[] memory t = new address[](3);
        uint256[] memory p = new uint256[](3);
        t[0] = address(btc);
        t[1] = address(eth);
        t[2] = address(eurc);
        for (uint256 i; i < 3; ++i) p[i] = px[t[i]];
        _report(t, p, uint64(block.timestamp));
    }

    function _setPrice(address token, uint256 price) internal {
        px[token] = price;
        address[] memory t = new address[](1);
        uint256[] memory p = new uint256[](1);
        t[0] = token;
        p[0] = price;
        _report(t, p, uint64(block.timestamp));
    }

    function _setRisk(address token, uint8 level) internal {
        vm.prank(reporter);
        registry.onReport("", abi.encode(uint8(2), abi.encode(token, level, keccak256("evidence"))));
    }

    function _warp(uint256 secs) internal {
        vm.warp(block.timestamp + secs);
        _refresh();
    }

    // ---------------------------------------------------------------- balances / venue helpers
    function _mintMirror(address token, address to, uint256 amt) internal {
        vm.prank(address(mirrorVenue));
        MirrorToken(token).mint(to, amt);
    }

    function _fundReserve(uint256 amt) internal {
        usdc.mint(address(mirrorVenue), amt);
    }

    // ---------------------------------------------------------------- formulas (spec section 3)
    function _buyOut(uint256 dec, uint256 price, uint256 usdcIn) internal pure returns (uint256) {
        return usdcIn * 1e8 * 10 ** dec / (price * 10 ** 6) * (10000 - 30) / 10000;
    }

    function _sellOut(uint256 dec, uint256 price, uint256 amtIn) internal pure returns (uint256) {
        return amtIn * price * 10 ** 6 / (1e8 * 10 ** dec) * (10000 - 30) / 10000;
    }

    // ---------------------------------------------------------------- array helpers
    function _addrs(address a, address b) internal pure returns (address[] memory r) {
        r = new address[](2);
        r[0] = a;
        r[1] = b;
    }

    function _addrs(address a, address b, address c) internal pure returns (address[] memory r) {
        r = new address[](3);
        r[0] = a;
        r[1] = b;
        r[2] = c;
    }

    function _wts(uint16 a, uint16 b) internal pure returns (uint16[] memory r) {
        r = new uint16[](2);
        r[0] = a;
        r[1] = b;
    }

    function _wts(uint16 a, uint16 b, uint16 c) internal pure returns (uint16[] memory r) {
        r = new uint16[](3);
        r[0] = a;
        r[1] = b;
        r[2] = c;
    }

    // ---------------------------------------------------------------- bucket / template helpers
    function _defParams() internal pure returns (BucketParams memory) {
        return BucketParams(500, 100, 2500, 3600);
    }

    function _bucketFor(address user, address[] memory t, uint16[] memory w, BucketParams memory p)
        internal
        returns (BucketAccount b)
    {
        vm.prank(user);
        b = BucketAccount(factory.createBucket("test", t, w, p));
    }

    /// @dev Default 50/50 BTC/USDC bucket owned by alice.
    function _btcUsdcBucket() internal returns (BucketAccount) {
        return _bucketFor(alice, _addrs(address(btc), address(usdc)), _wts(5000, 5000), _defParams());
    }

    function _fund(BucketAccount b, uint256 usdcAmt) internal {
        usdc.mint(address(b), usdcAmt);
    }

    function _setTemplate(uint256 id, address[] memory t, uint16[] memory w, uint16 band) internal {
        vm.prank(curator);
        templates.setTemplate(id, ITemplateRegistry.Template("T", "desc", t, w, band, 0, keccak256("why")));
    }

    function _listExtra(string memory sym, uint8 dec, address venue) internal returns (MockERC20 tok) {
        tok = new MockERC20(sym, sym, dec);
        vm.prank(owner);
        registry.listAsset(IAssetRegistry.Asset(address(tok), sym, IAssetRegistry.Category.Crypto, dec, venue, false, ""));
    }

    function _usdcOf(address who) internal view returns (uint256) {
        return usdc.balanceOf(who);
    }
}
