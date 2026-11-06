// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// Chainlink CRE consumer interface (KeystoneForwarder delivers reports here).
interface IReceiver {
    function onReport(bytes calldata metadata, bytes calldata report) external;
}

interface IERC165 {
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}

/// @title CreReceiver
/// @notice ERC-165-aware adapter between the Chainlink CRE forwarder and AssetRegistry.
///         The forwarder only delivers to receivers that advertise IReceiver via ERC-165; AssetRegistry
///         predates that check, so this contract (an authorized AssetRegistry reporter) relays reports.
///         Only the configured forwarder may call onReport. Report bytes are passed through unchanged:
///         abi.encode(uint8 kind, bytes payload)  kind 1 = prices, kind 2 = risk.
contract CreReceiver is IReceiver, IERC165 {
    address public immutable forwarder;
    IReceiver public immutable registry;

    error NotForwarder();
    error ZeroAddress();

    event Relayed(uint8 kind, uint256 reportBytes);

    constructor(address forwarder_, address registry_) {
        if (forwarder_ == address(0) || registry_ == address(0)) revert ZeroAddress();
        forwarder = forwarder_;
        registry = IReceiver(registry_);
    }

    function onReport(bytes calldata metadata, bytes calldata report) external override {
        if (msg.sender != forwarder) revert NotForwarder();
        registry.onReport(metadata, report);
        emit Relayed(report.length >= 32 ? uint8(uint256(bytes32(report[:32]))) : 0, report.length);
    }

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IReceiver).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}
