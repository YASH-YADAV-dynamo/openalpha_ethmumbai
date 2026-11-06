// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {AssetRegistry} from "./AssetRegistry.sol";
import {TemplateRegistry} from "./TemplateRegistry.sol";
import {MirrorVenue} from "./MirrorVenue.sol";

/// @notice Testnet bootstrap. Deploys the registries and the mirror venue, owns them while they are seeded,
/// then runs ONE pre-signed batch of owner calls and hands ownership to the final owner.
/// @dev The platform deployer can only send constructors, so the seeding calls are carried by a throwaway
/// contract (`SeedRelay`) whose constructor calls `exec`. The batch is signed off-chain by `signer`, an
/// ephemeral key that is discarded after signing. `exec` works exactly once, and the signer is cleared when it
/// runs, so this contract has no live authority afterwards. It holds no funds.
contract ArcTreasuryCore {
    AssetRegistry public immutable registry;
    TemplateRegistry public immutable templates;
    MirrorVenue public immutable mirrorVenue;
    address public signer;

    error BadSignature();
    error AlreadyExecuted();
    error LengthMismatch();

    event Executed(uint256 calls);

    constructor(address usdc, address signer_) {
        require(signer_ != address(0), "no signer");
        signer = signer_;
        AssetRegistry r = new AssetRegistry(address(this), usdc);
        registry = r;
        mirrorVenue = new MirrorVenue(r, usdc);
        templates = new TemplateRegistry(address(this), r);
    }

    function digest(address[] calldata targets, bytes[] calldata datas) public view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, address(this), targets, datas));
    }

    /// @notice Runs the signed batch once. Anyone may submit it; only the signed content can run.
    function exec(address[] calldata targets, bytes[] calldata datas, bytes calldata sig) external {
        address s = signer;
        if (s == address(0)) revert AlreadyExecuted();
        if (targets.length != datas.length) revert LengthMismatch();
        if (ECDSA.recover(MessageHashUtils.toEthSignedMessageHash(digest(targets, datas)), sig) != s) {
            revert BadSignature();
        }
        signer = address(0);
        for (uint256 i; i < targets.length; ++i) {
            (bool ok, bytes memory ret) = targets[i].call(datas[i]);
            if (!ok) {
                assembly ("memory-safe") {
                    revert(add(ret, 32), mload(ret))
                }
            }
        }
        emit Executed(targets.length);
    }
}
