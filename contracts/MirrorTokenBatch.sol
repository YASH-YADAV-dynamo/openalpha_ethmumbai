// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MirrorToken} from "./MirrorToken.sol";

/// @notice Deploys the six testnet mirror tokens in one transaction. All six are bound to `venue`, the only
/// address that can mint or burn them. Holds no funds and has no functions beyond the token getter.
contract MirrorTokenBatch {
    MirrorToken[6] public tokens;

    constructor(address venue) {
        tokens[0] = new MirrorToken("cirBTC (testnet mirror)", "cirBTC.m", 8, venue);
        tokens[1] = new MirrorToken("WETH (testnet mirror)", "WETH.m", 18, venue);
        tokens[2] = new MirrorToken("GBPA (testnet mirror)", "GBPA.m", 6, venue);
        tokens[3] = new MirrorToken("syrupUSDC (testnet mirror)", "syrupUSDC.m", 6, venue);
        tokens[4] = new MirrorToken("XAUM (testnet mirror)", "XAUM.m", 18, venue);
        tokens[5] = new MirrorToken("ASTOCK (testnet mirror)", "ASTOCK.m", 18, venue);
    }
}
