// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IV4Quoter} from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";

/// @dev Minimal PoolManager: fixed-rate swaps with flash-accounting checks (debt/credit must net to zero on unlock exit).
///      outBps: output per unit of filled input (10000 = 1:1). fillBps: share of amountSpecified actually consumed.
contract MockPoolManager {
    uint256 public outBps = 10_000;
    uint256 public fillBps = 10_000;
    bool public badDelta;
    int256 public debt;
    int256 public credit;
    uint256 private _syncedBalance;
    address private _syncedCurrency;
    uint256 public swapCalls;

    function setRate(uint256 outBps_) external {
        outBps = outBps_;
    }

    function setFill(uint256 fillBps_) external {
        fillBps = fillBps_;
    }

    function setBadDelta(bool b) external {
        badDelta = b;
    }

    function unlock(bytes calldata data) external returns (bytes memory r) {
        r = IUnlockCallback(msg.sender).unlockCallback(data);
        require(debt == 0, "MockPM: unsettled debt");
        require(credit == 0, "MockPM: untaken credit");
    }

    function swap(PoolKey memory, SwapParams memory p, bytes calldata) external returns (BalanceDelta) {
        require(p.amountSpecified < 0, "MockPM: exact-in only");
        ++swapCalls;
        uint256 owed = uint256(-p.amountSpecified) * fillBps / 10_000;
        uint256 out = owed * outBps / 10_000;
        debt += int256(owed);
        credit += int256(out);
        int128 inD = badDelta ? int128(int256(owed)) : -int128(int256(owed));
        int128 outD = int128(int256(out));
        return p.zeroForOne ? toBalanceDelta(inD, outD) : toBalanceDelta(outD, inD);
    }

    function sync(Currency c) external {
        _syncedCurrency = Currency.unwrap(c);
        _syncedBalance = IERC20(_syncedCurrency).balanceOf(address(this));
    }

    function settle() external payable returns (uint256 paid) {
        paid = IERC20(_syncedCurrency).balanceOf(address(this)) - _syncedBalance;
        debt -= int256(paid);
    }

    function take(Currency c, address to, uint256 amount) external {
        credit -= int256(amount);
        require(IERC20(Currency.unwrap(c)).transfer(to, amount), "MockPM: transfer");
    }
}

/// @dev Mock v4 Quoter: returns amountIn * outBps / 10000 (view, so it works under staticcall).
contract MockQuoter {
    uint256 public outBps = 9_995;
    uint8 public mode; // 0 ok, 1 revert, 2 short returndata

    function setOutBps(uint256 b) external {
        outBps = b;
    }

    function setMode(uint8 m) external {
        mode = m;
    }

    function quoteExactInputSingle(IV4Quoter.QuoteExactSingleParams memory params)
        external
        view
        returns (uint256 amountOut, uint256 gasEstimate)
    {
        if (mode == 1) revert("MockQuoter: fail");
        if (mode == 2) {
            assembly {
                return(0, 32)
            }
        }
        return (uint256(params.exactAmount) * outBps / 10_000, 100_000);
    }
}
