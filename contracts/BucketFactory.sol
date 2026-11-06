// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IAssetRegistry, ITemplateRegistry, IBucketFactory, BucketParams} from "./IArcTreasury.sol";

/// @notice Atomically creates and initializes separately funded EIP-1167 buckets.
contract BucketFactory is IBucketFactory {
    uint256 public constant NO_TEMPLATE = type(uint256).max;
    bytes4 private constant INITIALIZE_SELECTOR = bytes4(keccak256(
        "initialize(address,address,address,address[],uint16[],(uint16,uint16,uint16,uint32),uint256,bool)"
    ));

    error BadParams();

    address public immutable implementation;
    IAssetRegistry public immutable registry;
    ITemplateRegistry public immutable templates;
    mapping(address => address[]) private _bucketsOf;
    mapping(address => bool) public isBucket;
    address[] private _allBuckets;

    struct Creation {
        address[] tokens;
        uint16[] weights;
        BucketParams params;
        uint256 templateId;
        bool follow;
    }

    constructor(address implementation_, IAssetRegistry registry_, ITemplateRegistry templates_) {
        if (implementation_.code.length == 0 || address(registry_) == address(0)
            || address(templates_) == address(0)) revert BadParams();
        implementation = implementation_;
        registry = registry_;
        templates = templates_;
    }

    function createBucket(
        string calldata name,
        address[] calldata tokens,
        uint16[] calldata weightsBps,
        BucketParams calldata p
    ) external override returns (address bucket) {
        Creation memory c;
        c.tokens = tokens;
        c.weights = weightsBps;
        c.params = p;
        c.templateId = NO_TEMPLATE;
        bucket = _create(c);
        emit BucketCreated(msg.sender, bucket, NO_TEMPLATE, name);
    }

    function createFromTemplate(uint256 templateId, bool follow_)
        external override returns (address bucket)
    {
        ITemplateRegistry.Template memory t = templates.templateOf(templateId);
        Creation memory c;
        c.tokens = t.tokens;
        c.weights = t.weightsBps;
        c.params = BucketParams(t.bandBps, 100, 2500, 3600);
        c.templateId = templateId;
        c.follow = follow_;
        bucket = _create(c);
        emit BucketCreated(msg.sender, bucket, templateId, t.name);
    }

    function bucketsOf(address owner_) external view override returns (address[] memory) {
        return _bucketsOf[owner_];
    }

    function bucketCount() external view returns (uint256) {
        return _allBuckets.length;
    }

    function bucketAt(uint256 i) external view returns (address) {
        return _allBuckets[i];
    }

    function _create(Creation memory c) private returns (address bucket) {
        bucket = Clones.clone(implementation);
        // initialize is intentionally not part of the stable IBucketAccount interface.
        // Encode its specified ABI directly rather than importing an implementation.
        (bool success, bytes memory result) = bucket.call(abi.encodeWithSelector(
            INITIALIZE_SELECTOR, msg.sender, registry, templates,
            c.tokens, c.weights, c.params, c.templateId, c.follow
        ));
        if (!success) {
            assembly ("memory-safe") {
                revert(add(result, 32), mload(result))
            }
        }
        _bucketsOf[msg.sender].push(bucket);
        isBucket[bucket] = true;
        _allBuckets.push(bucket);
    }
}
