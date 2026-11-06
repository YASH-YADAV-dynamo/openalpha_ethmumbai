// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IVenue, IAssetRegistry} from "../IArcTreasury.sol";
import {MockERC20} from "./MockERC20.sol";

/// @dev Registry-priced venue whose delivered output is `rateBps` of fair value. It can optionally ignore minOut
///      (a misbehaving venue) so the bucket's own post-trade slippage check is exercised. Output tokens are minted.
contract LossyVenue is IVenue {
    IAssetRegistry public immutable registry;
    uint256 public rateBps;
    bool public enforceMinOut;

    constructor(IAssetRegistry registry_, uint256 rateBps_, bool enforceMinOut_) {
        registry = registry_;
        rateBps = rateBps_;
        enforceMinOut = enforceMinOut_;
    }

    function setRate(uint256 r) external {
        rateBps = r;
    }

    function name() external pure returns (string memory) {
        return "Lossy (test)";
    }

    function quote(address tIn, address tOut, uint256 amtIn) public view returns (uint256) {
        uint8 dOut = registry.assetOf(tOut).decimals;
        uint256 valueE18 = registry.valueE18(tIn, amtIn);
        (uint256 pOut,) = registry.priceE8(tOut);
        return valueE18 * (10 ** uint256(dOut)) / (pOut * 1e10) * rateBps / 10_000;
    }

    function swap(address tIn, address tOut, uint256 amtIn, uint256 minOut, address to) external returns (uint256 out) {
        out = quote(tIn, tOut, amtIn);
        if (enforceMinOut && out < minOut) revert MinOut(out, minOut);
        IERC20(tIn).transferFrom(msg.sender, address(this), amtIn);
        MockERC20(tOut).mint(to, out);
        emit Swapped(msg.sender, tIn, tOut, amtIn, out);
    }
}
