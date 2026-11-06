// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IV4Quoter} from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";
import {IVenue} from "./IArcTreasury.sol";

contract UniswapV4Venue is IVenue, IUnlockCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using BalanceDeltaLibrary for BalanceDelta;

    IPoolManager public immutable poolManager;
    IV4Quoter public immutable quoter;
    PoolKey public key;

    error InvalidAddress();
    error NotPoolManager();
    error InvalidDelta();

    constructor(IPoolManager pm, IV4Quoter quoter_, PoolKey memory key_) {
        if (address(pm) == address(0) || address(quoter_) == address(0)
            || Currency.unwrap(key_.currency0) == address(0)
            || Currency.unwrap(key_.currency1) == address(0)) revert InvalidAddress();
        if (Currency.unwrap(key_.currency0) >= Currency.unwrap(key_.currency1)) {
            revert Unsupported(Currency.unwrap(key_.currency0), Currency.unwrap(key_.currency1));
        }
        poolManager = pm;
        quoter = quoter_;
        key = key_;
    }

    function name() external pure override returns (string memory) {
        return "Uniswap v4 (Arc testnet)";
    }

    function _validate(address tIn, address tOut, uint256 amtIn) private view returns (bool zeroForOne) {
        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        if (amtIn == 0 || !((tIn == c0 && tOut == c1) || (tIn == c1 && tOut == c0))) {
            revert Unsupported(tIn, tOut);
        }
        return tIn == c0;
    }

    /// @notice A static quote usually fails because the v4 Quoter uses transient storage.
    /// @dev Off-chain callers should eth_call the Quoter directly; its address is exposed by quoter().
    function quote(address tIn, address tOut, uint256 amtIn) external view override returns (uint256 out) {
        bool zeroForOne = _validate(tIn, tOut, amtIn);
        if (amtIn > type(uint128).max) revert Unsupported(tIn, tOut);
        IV4Quoter.QuoteExactSingleParams memory params = IV4Quoter.QuoteExactSingleParams({
            poolKey: key,
            zeroForOne: zeroForOne,
            exactAmount: uint128(amtIn),
            hookData: ""
        });
        (bool ok, bytes memory result) = address(quoter).staticcall(
            abi.encodeCall(IV4Quoter.quoteExactInputSingle, (params))
        );
        if (!ok || result.length < 64) revert Unsupported(tIn, tOut);
        (out,) = abi.decode(result, (uint256, uint256));
    }

    function swap(address tIn, address tOut, uint256 amtIn, uint256 minOut, address to)
        external override nonReentrant returns (uint256 out)
    {
        _validate(tIn, tOut, amtIn);
        if (amtIn > uint256(type(int256).max)) revert Unsupported(tIn, tOut);
        if (to == address(0)) revert InvalidAddress();
        IERC20(tIn).safeTransferFrom(msg.sender, address(this), amtIn);
        out = abi.decode(poolManager.unlock(abi.encode(tIn, amtIn, to, msg.sender)), (uint256));
        if (out < minOut) revert MinOut(out, minOut);
        emit Swapped(msg.sender, tIn, tOut, amtIn, out);
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (address tIn, uint256 amtIn, address to, address payer) = abi.decode(data, (address, uint256, address, address));
        bool zeroForOne = tIn == Currency.unwrap(key.currency0);
        BalanceDelta delta = poolManager.swap(key, SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(amtIn),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        }), "");
        int128 inputDelta = zeroForOne ? delta.amount0() : delta.amount1();
        int128 outputDelta = zeroForOne ? delta.amount1() : delta.amount0();
        if (inputDelta > 0 || outputDelta < 0) revert InvalidDelta();
        uint256 owed = uint256(-int256(inputDelta));
        if (owed > amtIn) revert InvalidDelta();
        uint256 out = uint256(int256(outputDelta));
        poolManager.sync(Currency.wrap(tIn));
        IERC20(tIn).safeTransfer(address(poolManager), owed);
        poolManager.settle();
        if (amtIn > owed) IERC20(tIn).safeTransfer(payer, amtIn - owed);
        poolManager.take(zeroForOne ? key.currency1 : key.currency0, to, out);
        return abi.encode(out);
    }
}
