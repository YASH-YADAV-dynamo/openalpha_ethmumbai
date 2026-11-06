// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @dev Minimal fixed-rate pool manager. Moves real mock tokens. Both pool tokens are assumed
///      to have the same decimals unless the rates are set accordingly:
///      out = in * rateE6[zeroForOne] / 1e6 * (1e6 - feePpm) / 1e6, consumed input = in * fillBps / 10000.
contract MockPoolManager {
    uint256 public rate0to1E6 = 1e6;
    uint256 public rate1to0E6 = 1e6;
    uint256 public feePpm = 500; // 0.05%
    uint256 public fillBps = 10_000;

    bool private _unlocked;
    address private _syncedToken;
    uint256 private _syncedBal;
    address private _owedToken;
    uint256 private _owed;
    uint256 private _settled;
    uint256 private _owedOut;
    uint256 private _taken;

    function setRates(uint256 r01, uint256 r10) external {
        rate0to1E6 = r01;
        rate1to0E6 = r10;
    }

    function setFeePpm(uint256 f) external {
        feePpm = f;
    }

    function setFillBps(uint256 f) external {
        fillBps = f;
    }

    function unlock(bytes calldata data) external returns (bytes memory result) {
        require(!_unlocked, "already unlocked");
        _unlocked = true;
        _owed = 0;
        _settled = 0;
        _owedOut = 0;
        _taken = 0;
        result = IUnlockCallback(msg.sender).unlockCallback(data);
        require(_settled == _owed, "unsettled input");
        require(_taken == _owedOut, "untaken output");
        _unlocked = false;
    }

    function swap(PoolKey memory key, SwapParams memory params, bytes calldata) external returns (BalanceDelta) {
        require(_unlocked, "locked");
        require(params.amountSpecified < 0, "exact-in only");
        uint256 amtIn = uint256(-params.amountSpecified);
        uint256 used = amtIn * fillBps / 10_000;
        uint256 rate = params.zeroForOne ? rate0to1E6 : rate1to0E6;
        uint256 out = used * rate / 1e6 * (1e6 - feePpm) / 1e6;
        _owed = used;
        _owedOut = out;
        _owedToken = Currency.unwrap(params.zeroForOne ? key.currency0 : key.currency1);
        if (params.zeroForOne) return toBalanceDelta(-int128(int256(used)), int128(int256(out)));
        return toBalanceDelta(int128(int256(out)), -int128(int256(used)));
    }

    function sync(Currency currency) external {
        _syncedToken = Currency.unwrap(currency);
        _syncedBal = IERC20(_syncedToken).balanceOf(address(this));
    }

    function settle() external payable returns (uint256 paid) {
        require(msg.value == 0, "no native");
        paid = IERC20(_syncedToken).balanceOf(address(this)) - _syncedBal;
        require(_syncedToken == _owedToken, "wrong token settled");
        _settled += paid;
    }

    function take(Currency currency, address to, uint256 amount) external {
        _taken += amount;
        IERC20(Currency.unwrap(currency)).transfer(to, amount);
    }
}

/// @dev Fallback-style quoter: returns (quoteOut, 1) when `works`, otherwise reverts.
contract MockQuoter {
    bool public works;
    uint256 public quoteOut = 777;

    function set(bool w, uint256 q) external {
        works = w;
        quoteOut = q;
    }

    fallback() external {
        require(works, "quoter: transient storage");
        bytes memory r = abi.encode(quoteOut, uint256(1));
        assembly {
            return(add(r, 32), mload(r))
        }
    }
}

/// @dev Calls the venue's unlockCallback from an arbitrary non-pool-manager caller.
contract CallbackCaller {
    function call(address venue, bytes calldata data) external returns (bytes memory) {
        return IUnlockCallback(venue).unlockCallback(data);
    }
}
