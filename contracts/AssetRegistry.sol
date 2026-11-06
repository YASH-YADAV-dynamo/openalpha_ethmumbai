// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IAssetRegistry} from "./IArcTreasury.sol";

contract AssetRegistry is IAssetRegistry, Ownable2Step {
    address public immutable override usdc;
    uint64 public maxStaleness = 3600;
    mapping(address => bool) public reporters;
    mapping(address => bool) private _listed;
    mapping(address => Asset) private _assets;
    address[] private _tokens;
    mapping(address => uint256) private _prices;
    mapping(address => uint64) private _observedAt;
    mapping(address => uint8) private _risk;

    event MaxStalenessSet(uint64 seconds_);
    error BadAsset();

    constructor(address owner_, address usdc_) Ownable(owner_) {
        if (usdc_ == address(0)) revert BadAsset();
        usdc = usdc_;
        _storeAsset(Asset(usdc_, "USDC", Category.Cash, 6, address(0), false, ""));
    }

    function listAsset(Asset calldata a) external override onlyOwner {
        if (a.token == address(0) || _listed[a.token] || a.decimals > 24
            || (a.token != usdc && a.venue == address(0))) revert BadAsset();
        if (IERC20Metadata(a.token).decimals() != a.decimals) revert BadAsset();
        _storeAsset(a);
    }

    function _storeAsset(Asset memory a) private {
        _listed[a.token] = true;
        _assets[a.token] = a;
        _tokens.push(a.token);
        emit AssetListed(a.token, a.symbol, a.category, a.venue, a.mirror);
    }

    function assets() external view override returns (address[] memory) {
        return _tokens;
    }

    function assetOf(address token) external view override returns (Asset memory) {
        _requireListed(token);
        return _assets[token];
    }

    function setReporter(address reporter, bool allowed) external override onlyOwner {
        reporters[reporter] = allowed;
        emit ReporterSet(reporter, allowed);
    }

    function isReporter(address reporter) external view returns (bool) {
        return reporters[reporter];
    }

    function setMaxStaleness(uint64 seconds_) external override onlyOwner {
        if (seconds_ < 60 || seconds_ > 7 days) revert BadReport();
        maxStaleness = seconds_;
        emit MaxStalenessSet(seconds_);
    }

    function onReport(bytes calldata, bytes calldata report) external override {
        if (!reporters[msg.sender]) revert NotReporter();
        uint8 kind;
        bytes memory payload;
        try this.decodeReport(report) returns (uint8 k, bytes memory p) {
            kind = k;
            payload = p;
        } catch { revert BadReport(); }
        if (kind == 1) {
            _pricesReport(payload);
        } else if (kind == 2) {
            _riskReport(payload);
        } else {
            revert BadReport();
        }
    }

    function _pricesReport(bytes memory payload) private {
        address[] memory tokens;
        uint256[] memory prices;
        uint64 observed;
        try this.decodePrices(payload) returns (address[] memory t, uint256[] memory p, uint64 o) {
            tokens = t;
            prices = p;
            observed = o;
        } catch { revert BadReport(); }
        if (tokens.length == 0 || tokens.length > 50 || tokens.length != prices.length
            || observed > block.timestamp) revert BadReport();
        for (uint256 i; i < tokens.length; ++i) {
            address token = tokens[i];
            _requireListed(token);
            if (token == usdc || prices[i] == 0 || prices[i] > type(uint192).max
                || observed < _observedAt[token]) revert BadReport();
            _prices[token] = prices[i];
            _observedAt[token] = observed;
            emit PriceUpdated(token, prices[i], observed);
        }
    }

    function _riskReport(bytes memory payload) private {
        address token;
        uint8 level;
        bytes32 evidence;
        try this.decodeRisk(payload) returns (address t, uint8 l, bytes32 e) {
            token = t;
            level = l;
            evidence = e;
        } catch { revert BadReport(); }
        _requireListed(token);
        if (token == usdc || level > 3) revert BadReport();
        _risk[token] = level;
        emit RiskUpdated(token, level, evidence);
    }

    /// @dev Pure decoding helpers let onReport normalize malformed ABI to BadReport.
    function decodeReport(bytes calldata report) external pure returns (uint8, bytes memory) {
        return abi.decode(report, (uint8, bytes));
    }

    function decodePrices(bytes calldata payload) external pure returns (address[] memory, uint256[] memory, uint64) {
        return abi.decode(payload, (address[], uint256[], uint64));
    }

    function decodeRisk(bytes calldata payload) external pure returns (address, uint8, bytes32) {
        return abi.decode(payload, (address, uint8, bytes32));
    }

    function priceE8(address token) public view override returns (uint256 price, uint64 observedAt) {
        if (token == usdc) return (1e8, uint64(block.timestamp));
        _requireListed(token);
        observedAt = _observedAt[token];
        if (observedAt == 0 || block.timestamp > uint256(observedAt) + maxStaleness) revert StalePrice(token);
        return (_prices[token], observedAt);
    }

    function riskOf(address token) external view override returns (uint8) {
        _requireListed(token);
        return _risk[token];
    }

    function valueE18(address token, uint256 amount) external view override returns (uint256) {
        (uint256 price,) = priceE8(token);
        return amount * price * 1e10 / (10 ** uint256(_assets[token].decimals));
    }

    function _requireListed(address token) private view {
        if (!_listed[token]) revert UnknownAsset(token);
    }
}
