// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAssetRegistry, ITemplateRegistry, IBucketAccount, IBucketFactory, BucketParams} from "../IArcTreasury.sol";
import {BucketAccount} from "../BucketAccount.sol";
import {BucketFactory} from "../BucketFactory.sol";
import {TemplateRegistry} from "../TemplateRegistry.sol";
import {ArcBucketBase} from "./helpers/ArcBucketBase.sol";
import {MockERC20} from "./helpers/MockERC20.sol";

contract ArcBucketCoreTest is ArcBucketBase {
    uint256 internal constant NO_TEMPLATE = type(uint256).max;
    event Deposited(address indexed from, uint256 usdcAmount);
    event Withdrawn(address indexed to, address indexed token, uint256 amount);
    event PausedSet(bool paused);

    BucketAccount internal b;

    function setUp() public override {
        super.setUp();
        b = _newBucket(alice, _arr(address(mBTC), address(eurc)), _w(5000, 5000));
        usdc.mint(alice, 1_000_000e6);
        usdc.mint(bob, 1_000_000e6);
        vm.prank(alice);
        usdc.approve(address(b), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(b), type(uint256).max);
    }

    // ================= factory =================
    function test_Factory_CreateBucket_Basics() public {
        address[] memory toks = _arr(address(mBTC), address(eurc));
        uint16[] memory ws = _w(7000, 3000);
        vm.expectEmit(true, false, false, true, address(factory));
        emit IBucketFactory.BucketCreated(bob, address(0), NO_TEMPLATE, "mine");
        vm.prank(bob);
        BucketAccount c = BucketAccount(factory.createBucket("mine", toks, ws, _defParams()));
        assertEq(c.owner(), bob);
        assertEq(c.factory(), address(factory));
        assertEq(c.usdc(), USDC_ADDR);
        assertTrue(c.initialized());
        assertTrue(factory.isBucket(address(c)));
        assertEq(factory.bucketsOf(bob).length, 1);
        assertEq(factory.bucketsOf(bob)[0], address(c));
        assertEq(factory.bucketCount(), 2); // setUp bucket + this one
        assertEq(factory.bucketAt(1), address(c));
        (address[] memory t, uint16[] memory w) = c.targets();
        assertEq(t.length, 3);
        assertEq(t[0], address(mBTC));
        assertEq(t[1], address(eurc));
        assertEq(t[2], USDC_ADDR); // cash appended with weight 0
        assertEq(w[0], 7000);
        assertEq(w[1], 3000);
        assertEq(w[2], 0);
        BucketParams memory p = c.params();
        assertEq(p.bandBps, 500);
        assertEq(p.maxSlippageBps, 100);
        assertEq(p.maxTradeBps, 2500);
        assertEq(p.cooldown, 3600);
        (uint256 id, bool following, uint32 ver) = c.follow();
        assertEq(id, NO_TEMPLATE);
        assertFalse(following);
        assertEq(ver, 0);
    }

    function test_Factory_InitializeOnlyOnce() public {
        vm.expectRevert(BucketAccount.AlreadyInitialized.selector);
        b.initialize(alice, registry, ITemplateRegistry(address(templates)), _arr(address(mBTC)), _w(10000), _defParams(), NO_TEMPLATE, false);
        vm.prank(alice);
        vm.expectRevert(BucketAccount.AlreadyInitialized.selector);
        b.initialize(bob, registry, ITemplateRegistry(address(templates)), _arr(address(mBTC)), _w(10000), _defParams(), NO_TEMPLATE, false);
        // the implementation itself is locked
        assertTrue(impl.initialized());
        vm.expectRevert(BucketAccount.AlreadyInitialized.selector);
        impl.initialize(bob, registry, ITemplateRegistry(address(templates)), _arr(address(mBTC)), _w(10000), _defParams(), NO_TEMPLATE, false);
        assertEq(impl.owner(), address(0));
    }

    function test_Factory_ClonesAreDistinctAndIndependent() public {
        BucketAccount c = _newBucket(bob, _arr(address(mETH)), _w(10000));
        assertTrue(address(c) != address(b));
        assertTrue(address(c) != address(impl));
        assertEq(c.owner(), bob);
        assertEq(b.owner(), alice);
        (address[] memory t,) = c.targets();
        assertEq(t[0], address(mETH));
        (address[] memory t2,) = b.targets();
        assertEq(t2[0], address(mBTC));
        // implementation never records state from the factory
        assertEq(impl.factory(), address(0));
    }

    function test_Factory_BucketsOfTracksEachCreator() public {
        _newBucket(alice, _arr(address(mETH)), _w(10000));
        _newBucket(bob, _arr(address(mETH)), _w(10000));
        _newBucket(alice, _arr(address(mXAU)), _w(10000));
        assertEq(factory.bucketsOf(alice).length, 3); // incl. setUp bucket
        assertEq(factory.bucketsOf(bob).length, 1);
        assertEq(factory.bucketsOf(keeper).length, 0);
        assertEq(factory.bucketCount(), 4);
        for (uint256 i; i < 3; ++i) {
            assertEq(BucketAccount(factory.bucketsOf(alice)[i]).owner(), alice);
        }
        assertFalse(factory.isBucket(address(impl)));
        assertFalse(factory.isBucket(alice));
    }

    function test_Factory_CreateFromTemplate_UsesTemplateBand() public {
        vm.prank(curator);
        templates.setTemplate(0, _tpl(_arr(address(mBTC), address(eurc)), _w(6000, 4000), 700));
        vm.expectEmit(true, false, false, true, address(factory));
        emit IBucketFactory.BucketCreated(bob, address(0), 0, "T");
        vm.prank(bob);
        BucketAccount c = BucketAccount(factory.createFromTemplate(0, true));
        BucketParams memory p = c.params();
        assertEq(p.bandBps, 700);
        assertEq(p.maxSlippageBps, 100);
        assertEq(p.maxTradeBps, 2500);
        assertEq(p.cooldown, 3600);
        (uint256 id, bool following, uint32 ver) = c.follow();
        assertEq(id, 0);
        assertTrue(following);
        assertEq(ver, 1);
        (address[] memory t, uint16[] memory w) = c.targets();
        assertEq(t[0], address(mBTC));
        assertEq(w[0], 6000);
        assertEq(w[1], 4000);
        assertEq(c.owner(), bob);
        assertEq(factory.bucketsOf(bob)[0], address(c));
        vm.prank(bob);
        BucketAccount c2 = BucketAccount(factory.createFromTemplate(0, false));
        (, bool f2,) = c2.follow();
        assertFalse(f2);
    }

    function test_Factory_CreateFromTemplate_BadId() public {
        vm.expectRevert(TemplateRegistry.IdOutOfRange.selector);
        factory.createFromTemplate(0, false);
    }

    function test_Factory_ConstructorValidation() public {
        vm.expectRevert(BucketFactory.BadParams.selector);
        new BucketFactory(alice, IAssetRegistry(address(registry)), ITemplateRegistry(address(templates)));
        vm.expectRevert(BucketFactory.BadParams.selector);
        new BucketFactory(address(impl), IAssetRegistry(address(0)), ITemplateRegistry(address(templates)));
        vm.expectRevert(BucketFactory.BadParams.selector);
        new BucketFactory(address(impl), IAssetRegistry(address(registry)), ITemplateRegistry(address(0)));
        assertEq(factory.implementation(), address(impl));
    }

    function test_Factory_InvalidInitBubblesAndRegistersNothing() public {
        vm.prank(alice);
        vm.expectRevert(BucketAccount.BadParams.selector);
        factory.createBucket("x", _arr(address(mBTC)), _w(10000), BucketParams(99, 100, 2500, 3600));
        assertEq(factory.bucketCount(), 1);
    }

    // ================= parameter bounds =================
    function _badCreate(BucketParams memory p) internal {
        vm.prank(alice);
        vm.expectRevert(BucketAccount.BadParams.selector);
        factory.createBucket("x", _arr(address(mBTC)), _w(10000), p);
        vm.prank(alice);
        vm.expectRevert(BucketAccount.BadParams.selector);
        b.setParams(p);
    }

    function _okCreate(BucketParams memory p) internal {
        vm.prank(alice);
        BucketAccount c = BucketAccount(factory.createBucket("x", _arr(address(mBTC)), _w(10000), p));
        assertEq(c.params().bandBps, p.bandBps);
        vm.prank(alice);
        b.setParams(p);
        BucketParams memory got = b.params();
        assertEq(got.bandBps, p.bandBps);
        assertEq(got.maxSlippageBps, p.maxSlippageBps);
        assertEq(got.maxTradeBps, p.maxTradeBps);
        assertEq(got.cooldown, p.cooldown);
    }

    function test_Params_BandBounds() public {
        _badCreate(BucketParams(99, 100, 2500, 3600));
        _badCreate(BucketParams(2001, 100, 2500, 3600));
        _badCreate(BucketParams(0, 100, 2500, 3600));
        _okCreate(BucketParams(100, 100, 2500, 3600));
        _okCreate(BucketParams(2000, 100, 2500, 3600));
    }

    function test_Params_SlippageBounds() public {
        _badCreate(BucketParams(500, 9, 2500, 3600));
        _badCreate(BucketParams(500, 301, 2500, 3600));
        _okCreate(BucketParams(500, 10, 2500, 3600));
        _okCreate(BucketParams(500, 300, 2500, 3600));
    }

    function test_Params_TradeBounds() public {
        _badCreate(BucketParams(500, 100, 499, 3600));
        _badCreate(BucketParams(500, 100, 5001, 3600));
        _okCreate(BucketParams(500, 100, 500, 3600));
        _okCreate(BucketParams(500, 100, 5000, 3600));
    }

    function test_Params_CooldownBounds() public {
        _badCreate(BucketParams(500, 100, 2500, 599));
        _badCreate(BucketParams(500, 100, 2500, 0));
        _okCreate(BucketParams(500, 100, 2500, 600));
        _okCreate(BucketParams(500, 100, 2500, type(uint32).max));
    }

    // ================= targets =================
    function test_Targets_RejectedInputs() public {
        vm.startPrank(alice);
        bytes memory bw = abi.encodeWithSelector(IBucketAccount.BadWeights.selector);
        vm.expectRevert(bw);
        b.setTargets(_arr(address(mBTC), address(eurc)), _w(5000, 4999));
        vm.expectRevert(bw);
        b.setTargets(_arr(address(mBTC), address(eurc)), _w(5000, 5001));
        vm.expectRevert(bw);
        b.setTargets(_arr(address(mBTC), address(eurc)), _w(10000));
        vm.expectRevert(bw);
        b.setTargets(new address[](0), new uint16[](0));
        vm.expectRevert(bw);
        b.setTargets(_arr(address(mBTC), address(eurc)), _w(10000, 0));
        vm.expectRevert(bw);
        b.setTargets(_arr(address(mBTC), address(mBTC)), _w(5000, 5000));
        address x = makeAddr("x");
        vm.expectRevert(abi.encodeWithSelector(IAssetRegistry.UnknownAsset.selector, x));
        b.setTargets(_arr(address(mBTC), x), _w(5000, 5000));
        vm.stopPrank();
    }

    function _listN(uint256 n) internal returns (address[] memory t) {
        t = new address[](n);
        for (uint256 i; i < n; ++i) {
            MockERC20 m = new MockERC20("M", "M", 6);
            vm.prank(owner);
            registry.listAsset(IAssetRegistry.Asset(address(m), "M", IAssetRegistry.Category.Yield, 6, address(uvenue), false, ""));
            t[i] = address(m);
        }
    }

    function _eq(uint256 n) internal pure returns (uint16[] memory w) {
        w = new uint16[](n);
        uint16 acc;
        for (uint256 i; i < n; ++i) { w[i] = uint16(10000 / n); acc += w[i]; }
        w[n - 1] += uint16(10000 - acc);
    }

    function test_Targets_MaxTwelveAssets() public {
        address[] memory t13 = _listN(13);
        address[] memory t12 = new address[](12);
        for (uint256 i; i < 12; ++i) t12[i] = t13[i];
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IBucketAccount.BadWeights.selector));
        b.setTargets(t13, _eq(13));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IBucketAccount.BadWeights.selector));
        factory.createBucket("x", t13, _eq(13), _defParams());
        vm.prank(alice);
        b.setTargets(t12, _eq(12));
        (address[] memory u,) = b.targets();
        assertEq(u.length, 13); // 12 + USDC cash
        assertEq(u[12], USDC_ADDR);
    }

    function test_Targets_UsdcAsCashTarget() public {
        vm.prank(alice);
        b.setTargets(_arr(address(mBTC), USDC_ADDR), _w(6000, 4000));
        (address[] memory t, uint16[] memory w) = b.targets();
        assertEq(t.length, 2);
        assertEq(t[1], USDC_ADDR);
        assertEq(w[1], 4000);
        vm.prank(alice);
        b.setTargets(_arr(USDC_ADDR), _w(10000));
        (t, w) = b.targets();
        assertEq(t.length, 1);
        assertEq(w[0], 10000);
    }

    function test_Targets_EmitsUniverseAndCarriesHeldTokensAtZero() public {
        _giveMirror(address(mBTC), address(b), 100e6); // bucket now holds mBTC
        vm.prank(alice);
        b.setTargets(_arr(address(mETH), address(eurc)), _w(4000, 6000));
        (address[] memory t, uint16[] memory w) = b.targets();
        // new set, then USDC (weight 0), then previously-held mBTC (weight 0)
        assertEq(t.length, 4);
        assertEq(t[0], address(mETH));
        assertEq(t[1], address(eurc));
        assertEq(t[2], USDC_ADDR);
        assertEq(t[3], address(mBTC));
        assertEq(w[2], 0);
        assertEq(w[3], 0);

        // event carries the universe + (NO_TEMPLATE, 0)
        vm.expectEmit(false, false, false, true, address(b));
        emit IBucketAccount.TargetsSet(_arr(USDC_ADDR, address(mBTC)), _w(10000, 0), NO_TEMPLATE, 0);
        vm.prank(alice);
        b.setTargets(_arr(USDC_ADDR), _w(10000));
    }

    function test_Targets_TooManyAssets() public {
        address[] memory old = _listN(11);
        vm.prank(alice);
        b.setTargets(old, _eq(11));
        for (uint256 i; i < 11; ++i) MockERC20(old[i]).mint(address(b), 1e6);
        address[] memory fresh = _listN(12);
        vm.prank(alice);
        vm.expectRevert(BucketAccount.TooManyAssets.selector);
        b.setTargets(fresh, _eq(12));
    }

    function test_SetTargets_TurnsFollowingOff() public {
        vm.prank(curator);
        templates.setTemplate(0, _tpl(_arr(address(mBTC)), _w(10000), 500));
        vm.startPrank(alice);
        b.followTemplate(0, true);
        (, bool f,) = b.follow();
        assertTrue(f);
        b.setTargets(_arr(address(mETH)), _w(10000));
        vm.stopPrank();
        (, f,) = b.follow();
        assertFalse(f);
    }

    // ================= deposit / withdraw =================
    function test_Deposit_AnyoneCanTopUp() public {
        vm.expectEmit(true, false, false, true, address(b));
        emit Deposited(bob, 250e6);
        vm.prank(bob);
        b.deposit(250e6);
        assertEq(usdc.balanceOf(address(b)), 250e6);
        vm.prank(alice);
        b.deposit(50e6);
        assertEq(usdc.balanceOf(address(b)), 300e6);
    }

    function test_Deposit_ZeroReverts_NoAllowanceReverts() public {
        vm.prank(alice);
        vm.expectRevert(BucketAccount.BadParams.selector);
        b.deposit(0);
        vm.prank(keeper);
        vm.expectRevert();
        b.deposit(1e6);
    }

    function test_Withdraw_OwnerOnly_Happy() public {
        vm.prank(bob);
        b.deposit(100e6);
        _giveMirror(address(mBTC), address(b), 100e6);
        uint256 btcBal = mBTC.balanceOf(address(b));
        vm.expectEmit(true, true, false, true, address(b));
        emit Withdrawn(keeper, USDC_ADDR, 40e6);
        vm.prank(alice);
        b.withdraw(USDC_ADDR, 40e6, keeper);
        assertEq(usdc.balanceOf(keeper), 40e6);
        vm.prank(alice);
        b.withdraw(address(mBTC), btcBal, alice);
        assertEq(mBTC.balanceOf(alice), btcBal);
        // bob deposited but cannot withdraw
        vm.prank(bob);
        vm.expectRevert(IBucketAccount.NotOwner.selector);
        b.withdraw(USDC_ADDR, 1, bob);
    }

    function test_Withdraw_ZeroToAndOverdraw() public {
        vm.prank(bob);
        b.deposit(100e6);
        vm.startPrank(alice);
        vm.expectRevert(BucketAccount.BadParams.selector);
        b.withdraw(USDC_ADDR, 1, address(0));
        vm.expectRevert();
        b.withdraw(USDC_ADDR, 100e6 + 1, alice);
        vm.expectRevert(BucketAccount.BadParams.selector);
        b.withdrawAll(address(0));
        vm.stopPrank();
    }

    function test_WithdrawAll_EmptiesEveryUniverseToken() public {
        vm.prank(bob);
        b.deposit(100e6);
        _giveMirror(address(mBTC), address(b), 50e6);
        eurc.mint(address(b), 7e6);
        uint256 btcBal = mBTC.balanceOf(address(b));
        vm.expectEmit(true, true, false, true, address(b));
        emit Withdrawn(alice, address(mBTC), btcBal);
        vm.expectEmit(true, true, false, true, address(b));
        emit Withdrawn(alice, address(eurc), 7e6);
        vm.expectEmit(true, true, false, true, address(b));
        emit Withdrawn(alice, USDC_ADDR, 100e6);
        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        b.withdrawAll(alice);
        assertEq(usdc.balanceOf(alice), before + 100e6);
        assertEq(usdc.balanceOf(address(b)), 0);
        assertEq(mBTC.balanceOf(address(b)), 0);
        assertEq(eurc.balanceOf(address(b)), 0);
        assertEq(mBTC.balanceOf(alice), btcBal);
        assertEq(eurc.balanceOf(alice), 7e6);
    }

    function test_Paused_WithdrawalsStillWork() public {
        vm.prank(bob);
        b.deposit(100e6);
        vm.expectEmit(false, false, false, true, address(b));
        emit PausedSet(true);
        vm.prank(alice);
        b.setPaused(true);
        assertTrue(b.paused());
        vm.prank(alice);
        b.withdraw(USDC_ADDR, 10e6, alice);
        vm.prank(alice);
        b.withdrawAll(alice);
        assertEq(usdc.balanceOf(address(b)), 0);
    }

    // ================= owner-only =================
    function test_OwnerOnly_AllFunctionsRevertForOthers() public {
        address[] memory t = _arr(address(mBTC));
        uint16[] memory w = _w(10000);
        address[7] memory strangers = [bob, keeper, address(factory), address(impl), owner, curator, address(b)];
        for (uint256 i; i < strangers.length; ++i) {
            address s = strangers[i];
            _expectOwnerRevert(s, abi.encodeCall(b.withdraw, (USDC_ADDR, 1, s)), address(b));
            _expectOwnerRevert(s, abi.encodeCall(b.withdrawAll, (s)), address(b));
            _expectOwnerRevert(s, abi.encodeCall(b.setTargets, (t, w)), address(b));
            _expectOwnerRevert(s, abi.encodeCall(b.followTemplate, (0, true)), address(b));
            _expectOwnerRevert(s, abi.encodeCall(b.setParams, (_defParams())), address(b));
            _expectOwnerRevert(s, abi.encodeCall(b.setPaused, (true)), address(b));
            _expectOwnerRevert(s, abi.encodeCall(b.setSip, (1e6, 3600, 1)), address(b));
            _expectOwnerRevert(s, abi.encodeCall(b.cancelSip, ()), address(b));
        }
        assertFalse(b.paused());
    }

    // ================= follow template (owner paths) =================
    function test_FollowTemplate_IdAndToggle() public {
        vm.prank(alice);
        vm.expectRevert(BucketAccount.IdOutOfRange.selector);
        b.followTemplate(0, true);
        vm.prank(curator);
        templates.setTemplate(0, _tpl(_arr(address(mETH), address(mXAU)), _w(5000, 5000), 900));
        vm.expectEmit(false, false, false, true, address(b));
        emit IBucketAccount.TargetsSet(_arr(address(mETH), address(mXAU), USDC_ADDR), _w(5000, 5000, 0), 0, 1);
        vm.prank(alice);
        b.followTemplate(0, true);
        (uint256 id, bool f, uint32 v) = b.follow();
        assertEq(id, 0);
        assertTrue(f);
        assertEq(v, 1);
        // band is NOT taken from the template when following an existing bucket
        assertEq(b.params().bandBps, 500);
        vm.prank(alice);
        b.followTemplate(0, false);
        (, f,) = b.follow();
        assertFalse(f);
    }

    // ================= views =================
    function test_Views_HoldingsTolerantDriftStrict() public {
        vm.prank(bob);
        b.deposit(1_000e6);
        _giveMirror(address(mBTC), address(b), 500e6);
        (address[] memory t, uint256[] memory amts, uint256[] memory vals, uint256 total) = b.holdings();
        assertEq(t.length, 3);
        assertEq(amts[2], 1_000e6);
        assertEq(vals[2], 1_000e18);
        assertEq(total, vals[0] + vals[1] + vals[2]);
        vm.warp(block.timestamp + 3601); // everything but USDC stale
        (t, amts, vals, total) = b.holdings(); // must not revert
        assertEq(total, 1_000e18);
        assertEq(vals[0], 0);
        vm.expectRevert(abi.encodeWithSelector(IAssetRegistry.StalePrice.selector, address(mBTC)));
        b.driftBps();
    }

    function test_DriftBps_ZeroTotalAndValues() public {
        (uint16 m, int32[] memory per) = b.driftBps();
        assertEq(m, 0);
        assertEq(per.length, 3);
        assertEq(per[0], 0);
        vm.prank(bob);
        b.deposit(1_000e6);
        (m, per) = b.driftBps();
        assertEq(m, 10_000); // all cash vs 0% cash target
        assertEq(per[0], -5000);
        assertEq(per[1], -5000);
        assertEq(per[2], 10_000);
    }
}
