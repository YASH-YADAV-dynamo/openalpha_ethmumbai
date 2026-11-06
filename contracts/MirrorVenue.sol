// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IAssetRegistry, IVenue} from "./IArcTreasury.sol";
import {MirrorToken} from "./MirrorToken.sol";

contract MirrorVenue is IVenue, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IAssetRegistry public immutable registry;
    address public immutable usdc;
    uint256 public constant spreadBps = 30;
    uint256 public constant maxTradeUsdc = 5_000e6;

    error TradeTooLarge(uint256 amount, uint256 cap);
    error RiskBlocked(address token, uint8 level);
    error InsufficientReserve(uint256 have, uint256 need);
    error InvalidAddress();

    constructor(IAssetRegistry registry_, address usdc_) {
        if (address(registry_) == address(0) || usdc_ == address(0)) revert InvalidAddress();
        registry = registry_;
        usdc = usdc_;
    }

    function name() external pure override returns (string memory) {
        return "Mirror (testnet)";
    }

    function quote(address tIn, address tOut, uint256 amtIn) public view override returns (uint256 out) {
        if (tIn == tOut || (tIn != usdc && tOut != usdc)) revert Unsupported(tIn, tOut);
        bool buy = tIn == usdc;
        address token = buy ? tOut : tIn;
        IAssetRegistry.Asset memory a = registry.assetOf(token);
        if (a.venue != address(this) || !a.mirror) revert Unsupported(tIn, tOut);
        (uint256 price,) = registry.priceE8(token);
        uint256 unit = 10 ** uint256(a.decimals);
        if (buy) {
            if (amtIn > maxTradeUsdc) revert TradeTooLarge(amtIn, maxTradeUsdc);
            uint8 level = registry.riskOf(token);
            if (level >= 2) revert RiskBlocked(token, level);
            out = amtIn * 1e8 * unit / (price * 10 ** 6) * (10000 - spreadBps) / 10000;
        } else {
            out = amtIn * price * 10 ** 6 / (1e8 * unit) * (10000 - spreadBps) / 10000;
            if (out > maxTradeUsdc) revert TradeTooLarge(out, maxTradeUsdc);
            uint256 have = IERC20(usdc).balanceOf(address(this));
            if (have < out) revert InsufficientReserve(have, out);
        }
    }

    function swap(address tIn, address tOut, uint256 amtIn, uint256 minOut, address to)
        external override nonReentrant returns (uint256 out)
    {
        if (to == address(0)) revert InvalidAddress();
        out = quote(tIn, tOut, amtIn);
        if (out < minOut) revert MinOut(out, minOut);
        IERC20(tIn).safeTransferFrom(msg.sender, address(this), amtIn);
        if (tIn == usdc) {
            MirrorToken(tOut).mint(to, out);
        } else {
            MirrorToken(tIn).burn(address(this), amtIn);
            IERC20(usdc).safeTransfer(to, out);
        }
        emit Swapped(msg.sender, tIn, tOut, amtIn, out);
    }
}
