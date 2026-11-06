// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IAssetRegistry, ITemplateRegistry} from "./IArcTreasury.sol";

contract TemplateRegistry is ITemplateRegistry, Ownable2Step {
    IAssetRegistry public immutable registry;
    mapping(address => bool) public curators;
    Template[] private _templates;

    error IdOutOfRange();
    error BadBand();
    error InvalidRegistry();

    constructor(address owner_, IAssetRegistry registry_) Ownable(owner_) {
        if (address(registry_) == address(0)) revert InvalidRegistry();
        registry = registry_;
    }

    function setCurator(address curator, bool allowed) external override onlyOwner {
        curators[curator] = allowed;
        emit CuratorSet(curator, allowed);
    }

    function isCurator(address curator) external view returns (bool) {
        return curators[curator];
    }

    function setTemplate(uint256 id, Template calldata t) external override {
        if (!curators[msg.sender]) revert NotCurator();
        if (id > _templates.length) revert IdOutOfRange();
        uint256 n = t.tokens.length;
        if (n == 0 || n > 12 || n != t.weightsBps.length) revert BadWeights();
        uint256 sum;
        for (uint256 i; i < n; ++i) {
            if (t.weightsBps[i] == 0) revert BadWeights();
            sum += t.weightsBps[i];
            for (uint256 j; j < i; ++j) {
                if (t.tokens[i] == t.tokens[j]) revert BadWeights();
            }
            registry.assetOf(t.tokens[i]);
        }
        if (sum != 10000) revert BadWeights();
        if (t.bandBps < 100 || t.bandBps > 2000) revert BadBand();
        if (id == _templates.length) _templates.push();
        uint32 version = _templates[id].version + 1;
        _templates[id] = t;
        _templates[id].version = version;
        emit TemplateSet(id, version, t.rationaleHash);
    }

    function templateOf(uint256 id) external view override returns (Template memory) {
        if (id >= _templates.length) revert IdOutOfRange();
        return _templates[id];
    }

    function templateCount() external view override returns (uint256) {
        return _templates.length;
    }
}
