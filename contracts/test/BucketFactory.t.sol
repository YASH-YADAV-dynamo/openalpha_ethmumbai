// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./TreasuryBase.t.sol";

contract BucketFactoryTest is TreasuryBase {
    function _initArgsTokens() internal view returns (address[] memory) {
        return _addrs(address(btc), address(usdc));
    }

    // ------------------------------------------------------------ constructor
    function test_ConstructorState() public view {
        assertEq(factory.implementation(), address(impl));
        assertEq(address(factory.registry()), address(registry));
        assertEq(address(factory.templates()), address(templates));
        assertEq(factory.bucketCount(), 0);
    }

    function test_ConstructorRejectsBadArgs() public {
        vm.expectRevert(BucketFactory.BadParams.selector);
        new BucketFactory(alice, registry, templates); // no code at implementation
        vm.expectRevert(BucketFactory.BadParams.selector);
        new BucketFactory(address(impl), IAssetRegistry(address(0)), templates);
        vm.expectRevert(BucketFactory.BadParams.selector);
        new BucketFactory(address(impl), registry, ITemplateRegistry(address(0)));
    }

    // ------------------------------------------------------------ createBucket
    function test_CreateBucketOwnedByCallerAndRecorded() public {
        vm.expectEmit(true, false, false, true, address(factory));
        emit IBucketFactory.BucketCreated(alice, address(0), NO_TEMPLATE, "My bucket");
        vm.prank(alice);
        address bucket = factory.createBucket("My bucket", _initArgsTokens(), _wts(7000, 3000), _defParams());

        assertEq(BucketAccount(bucket).owner(), alice);
        assertEq(BucketAccount(bucket).factory(), address(factory));
        assertTrue(factory.isBucket(bucket));
        assertEq(factory.bucketCount(), 1);
        assertEq(factory.bucketAt(0), bucket);
        address[] memory mine = factory.bucketsOf(alice);
        assertEq(mine.length, 1);
        assertEq(mine[0], bucket);
        assertEq(factory.bucketsOf(bob).length, 0);
        (address[] memory t, uint16[] memory w) = BucketAccount(bucket).targets();
        assertEq(t[0], address(btc));
        assertEq(w[0], 7000);
        (uint256 id, bool following,) = BucketAccount(bucket).follow();
        assertEq(id, NO_TEMPLATE);
        assertFalse(following);
    }

    function test_BucketCreatedEventCarriesBucketAddress() public {
        vm.recordLogs();
        vm.prank(alice);
        address bucket = factory.createBucket("n", _initArgsTokens(), _wts(5000, 5000), _defParams());
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(factory) && logs[i].topics[0] == IBucketFactory.BucketCreated.selector) {
                found = true;
                assertEq(address(uint160(uint256(logs[i].topics[1]))), alice);
                assertEq(address(uint160(uint256(logs[i].topics[2]))), bucket);
            }
        }
        assertTrue(found);
    }

    function test_CloneIsMinimalProxyWithIndependentStorage() public {
        BucketAccount a = _bucketFor(alice, _initArgsTokens(), _wts(5000, 5000), _defParams());
        BucketAccount c = _bucketFor(bob, _initArgsTokens(), _wts(2000, 8000), _defParams());
        assertEq(address(a).code.length, 45, "EIP-1167 runtime is 45 bytes");
        assertTrue(address(a) != address(c));
        assertEq(a.owner(), alice);
        assertEq(c.owner(), bob);
        (, uint16[] memory wa) = a.targets();
        (, uint16[] memory wc) = c.targets();
        assertEq(wa[0], 5000);
        assertEq(wc[0], 2000);
        assertEq(impl.owner(), address(0), "implementation itself is never owned");
    }

    function test_OneUserMayHaveManyBuckets() public {
        BucketAccount a = _bucketFor(alice, _initArgsTokens(), _wts(5000, 5000), _defParams());
        BucketAccount c = _bucketFor(alice, _initArgsTokens(), _wts(5000, 5000), _defParams());
        BucketAccount d = _bucketFor(bob, _initArgsTokens(), _wts(5000, 5000), _defParams());
        address[] memory mine = factory.bucketsOf(alice);
        assertEq(mine.length, 2);
        assertEq(mine[0], address(a));
        assertEq(mine[1], address(c));
        assertEq(factory.bucketCount(), 3);
        assertEq(factory.bucketAt(2), address(d));
        assertTrue(factory.isBucket(address(d)));
        assertFalse(factory.isBucket(alice));
    }

    function test_CreateBucketBadWeightsBubblesAndRecordsNothing() public {
        vm.prank(alice);
        vm.expectRevert(IBucketAccount.BadWeights.selector);
        factory.createBucket("x", _initArgsTokens(), _wts(5000, 4000), _defParams());
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAssetRegistry.UnknownAsset.selector, bob));
        factory.createBucket("x", _addrs(address(btc), bob), _wts(5000, 5000), _defParams());
        assertEq(factory.bucketCount(), 0);
        assertEq(factory.bucketsOf(alice).length, 0);
    }

    // ------------------------------------------------------------ initialization guard
    function test_ImplementationCannotBeInitialized() public {
        vm.expectRevert(BucketAccount.AlreadyInitialized.selector);
        impl.initialize(alice, registry, templates, _initArgsTokens(), _wts(5000, 5000), _defParams(), NO_TEMPLATE, false);
        vm.prank(alice);
        vm.expectRevert(BucketAccount.AlreadyInitialized.selector);
        impl.initialize(alice, registry, templates, _initArgsTokens(), _wts(5000, 5000), _defParams(), NO_TEMPLATE, false);
        assertTrue(impl.initialized());
    }

    function test_CloneCannotBeReinitialized() public {
        BucketAccount a = _bucketFor(alice, _initArgsTokens(), _wts(5000, 5000), _defParams());
        vm.prank(bob);
        vm.expectRevert(BucketAccount.AlreadyInitialized.selector);
        a.initialize(bob, registry, templates, _initArgsTokens(), _wts(5000, 5000), _defParams(), NO_TEMPLATE, false);
        vm.prank(alice);
        vm.expectRevert(BucketAccount.AlreadyInitialized.selector);
        a.initialize(alice, registry, templates, _initArgsTokens(), _wts(5000, 5000), _defParams(), NO_TEMPLATE, false);
        assertEq(a.owner(), alice);
    }

    function test_UninitializedImplementationOwnerFunctionsUnusable() public {
        vm.prank(bob);
        vm.expectRevert(IBucketAccount.NotOwner.selector);
        impl.setPaused(true);
        vm.prank(bob);
        vm.expectRevert(IBucketAccount.NotOwner.selector);
        impl.withdrawAll(bob);
    }

    // ------------------------------------------------------------ createFromTemplate
    function test_CreateFromTemplateUsesTemplateTargetsBandAndDefaults() public {
        _setTemplate(0, _addrs(address(btc), address(usdc)), _wts(6000, 4000), 300);
        vm.expectEmit(true, false, false, true, address(factory));
        emit IBucketFactory.BucketCreated(alice, address(0), 0, "T");
        vm.prank(alice);
        BucketAccount a = BucketAccount(factory.createFromTemplate(0, true));

        assertEq(a.owner(), alice);
        BucketParams memory p = a.params();
        assertEq(p.bandBps, 300);
        assertEq(p.maxSlippageBps, 100);
        assertEq(p.maxTradeBps, 2500);
        assertEq(p.cooldown, 3600);
        (address[] memory t, uint16[] memory w) = a.targets();
        assertEq(t[0], address(btc));
        assertEq(w[0], 6000);
        assertEq(w[1], 4000);
        (uint256 id, bool following, uint32 v) = a.follow();
        assertEq(id, 0);
        assertTrue(following);
        assertEq(v, 1);
        assertEq(factory.bucketsOf(alice)[0], address(a));
    }

    function test_CreateFromTemplateWithoutFollow() public {
        _setTemplate(0, _addrs(address(eth), address(usdc)), _wts(5000, 5000), 500);
        vm.prank(alice);
        BucketAccount a = BucketAccount(factory.createFromTemplate(0, false));
        (uint256 id, bool following, uint32 v) = a.follow();
        assertEq(id, 0);
        assertFalse(following);
        assertEq(v, 1);
    }

    function test_CreateFromUnknownTemplateReverts() public {
        vm.prank(alice);
        vm.expectRevert(TemplateRegistry.IdOutOfRange.selector);
        factory.createFromTemplate(0, true);
    }
}
