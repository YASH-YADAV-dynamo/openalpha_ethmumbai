// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IVenue, IBucketAccount, BucketParams} from "../../IArcTreasury.sol";
import {BucketAccount} from "../../BucketAccount.sol";
import {ArcBase} from "./ArcBase.sol";

/// @dev Venue that reports success but pays out less than minOut (tests the bucket's own SlippageExceeded check).
contract LyingVenue is IVenue {
    uint256 public payoutBps = 5000;

    function name() external pure returns (string memory) {
        return "Lying";
    }

    function quote(address, address, uint256) external pure returns (uint256) {
        return 0;
    }

    function swap(address tIn, address tOut, uint256 amtIn, uint256 minOut, address to) external returns (uint256) {
        IERC20(tIn).transferFrom(msg.sender, address(this), amtIn);
        IERC20(tOut).transfer(to, minOut * payoutBps / 10_000);
        return minOut;
    }
}

abstract contract ArcBucketBase is ArcBase {
    struct Trade {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint256 amountOut;
        address venue;
    }

    bytes32 internal constant TRADE_SIG = keccak256("TradeExecuted(address,address,uint256,uint256,address)");
    bytes32 internal constant REBAL_SIG = keccak256("Rebalanced(address,uint256,uint256,uint16,uint256)");

    function _trades(Vm.Log[] memory logs, address bucket) internal pure returns (Trade[] memory out) {
        uint256 n;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == bucket && logs[i].topics[0] == TRADE_SIG) ++n;
        }
        out = new Trade[](n);
        uint256 k;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == bucket && logs[i].topics[0] == TRADE_SIG) {
                (uint256 a, uint256 b, address v) = abi.decode(logs[i].data, (uint256, uint256, address));
                out[k++] = Trade(
                    address(uint160(uint256(logs[i].topics[1]))), address(uint160(uint256(logs[i].topics[2]))), a, b, v
                );
            }
        }
    }

    function _rebalanced(Vm.Log[] memory logs, address bucket)
        internal pure returns (bool found, uint256 before_, uint256 after_, uint16 drift, uint256 tip)
    {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == bucket && logs[i].topics[0] == REBAL_SIG) {
                (before_, after_, drift, tip) = abi.decode(logs[i].data, (uint256, uint256, uint16, uint256));
                return (true, before_, after_, drift, tip);
            }
        }
    }

    /// @dev USDC leg of a trade in 6-dec units.
    function _usdcLeg(Trade memory t) internal pure returns (uint256) {
        return t.tokenIn == USDC_ADDR ? t.amountIn : (t.tokenOut == USDC_ADDR ? t.amountOut : 0);
    }

    function _total(BucketAccount b) internal view returns (uint256 total) {
        (,,, total) = b.holdings();
    }

    function _params(uint16 band, uint16 slip, uint16 trade, uint32 cd) internal pure returns (BucketParams memory) {
        return BucketParams(band, slip, trade, cd);
    }

    /// @dev Mint `amt` of a mirror/mock token straight into the bucket (as if a user transferred it in).
    function _giveMirror(address mirror, address to, uint256 usdcSpend) internal {
        usdc.mint(address(this), usdcSpend);
        usdc.approve(address(mvenue), usdcSpend);
        uint256 got = mvenue.swap(address(usdc), mirror, usdcSpend, 0, address(this));
        IERC20(mirror).transfer(to, got);
    }

    /// @dev Make the owner of `b` approve it for SIP pulls and mint them USDC.
    function _prepSipOwner(BucketAccount b, address who, uint256 usdcAmt) internal {
        usdc.mint(who, usdcAmt);
        vm.prank(who);
        usdc.approve(address(b), type(uint256).max);
    }

    function _expectOwnerRevert(address caller, bytes memory callData, address target) internal {
        vm.prank(caller);
        (bool ok, bytes memory ret) = target.call(callData);
        assertFalse(ok);
        assertEq(bytes4(ret), IBucketAccount.NotOwner.selector);
    }
}
