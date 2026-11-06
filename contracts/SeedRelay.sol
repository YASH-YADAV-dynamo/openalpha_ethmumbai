// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IArcTreasuryCore {
    function exec(address[] calldata targets, bytes[] calldata datas, bytes calldata sig) external;
}

/// @notice Throwaway carrier: its constructor submits the pre-signed seed batch to `ArcTreasuryCore.exec`.
contract SeedRelay {
    constructor(IArcTreasuryCore core, address[] memory targets, bytes[] memory datas, bytes memory sig) {
        core.exec(targets, datas, sig);
    }
}
