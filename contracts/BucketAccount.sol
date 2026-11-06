// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IAssetRegistry, ITemplateRegistry, IVenue, IBucketAccount, BucketParams} from "./IArcTreasury.sol";

/// @notice Individually owned, clone-initialized treasury with permissionless maintenance.
contract BucketAccount is IBucketAccount {
    using SafeERC20 for IERC20;

    uint256 public constant NO_TEMPLATE = type(uint256).max;
    uint256 public constant TIP_CAP = 50_000;
    uint256 public constant TIP_BPS = 10;
    uint256 public constant MAX_ASSETS = 12;
    uint256 public constant MAX_UNIVERSE = 16;
    uint256 private constant BPS = 10_000;

    error AlreadyInitialized();
    error BadParams();
    error TooManyAssets();
    error ReentrantCall();
    error SlippageExceeded(uint256 got, uint256 min);
    error IdOutOfRange();

    event PausedSet(bool paused);

    address public override owner;
    address public factory;
    IAssetRegistry public registry;
    ITemplateRegistry public templates;
    address public usdc;
    bool public initialized;
    bool public paused;
    bool private _entered;
    address[] private _tokens;
    uint16[] private _weights;
    BucketParams private _params;
    bool private _following;
    uint256 private _followId;
    uint32 private _followVersion;
    uint64 public lastRebalance;

    uint256 public sipAmount;
    uint32 public sipInterval;
    uint32 public sipRunsLeft;
    uint64 public sipNextAt;
    bool public sipActive;

    struct Position {
        address token;
        uint256 balance;
        uint256 value;
        uint16 weight;
        uint8 risk;
        int32 drift;
    }

    struct Snapshot {
        Position[] positions;
        uint256 total;
        uint16 maxDrift;
        bool exitHeld;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    // Unlike constructor-initialized guards, zero is the unlocked state in every clone.
    modifier nonReentrant() {
        if (_entered) revert ReentrantCall();
        _entered = true;
        _;
        _entered = false;
    }

    constructor() {
        initialized = true;
    }

    function initialize(
        address owner_,
        IAssetRegistry registry_,
        ITemplateRegistry templates_,
        address[] calldata tokens,
        uint16[] calldata weightsBps,
        BucketParams calldata p,
        uint256 templateId,
        bool follow_
    ) external nonReentrant {
        if (initialized) revert AlreadyInitialized();
        if (owner_ == address(0) || address(registry_) == address(0) || address(templates_) == address(0)) {
            revert BadParams();
        }
        initialized = true;
        owner = owner_;
        factory = msg.sender;
        registry = registry_;
        templates = templates_;
        usdc = registry_.usdc();
        if (usdc == address(0)) revert BadParams();
        registry_.assetOf(usdc);
        _validateParams(p);
        _params = p;
        _followId = templateId;
        if (templateId != NO_TEMPLATE) {
            _followVersion = templates_.templateOf(templateId).version;
        } else if (follow_) {
            revert BadParams();
        }
        _following = follow_;
        _replaceTargets(tokens, weightsBps, templateId, _followVersion);
    }

    function deposit(uint256 usdcAmount) external override nonReentrant {
        if (usdcAmount == 0) revert BadParams();
        IERC20(usdc).safeTransferFrom(msg.sender, address(this), usdcAmount);
        emit Deposited(msg.sender, usdcAmount);
    }

    function withdraw(address token, uint256 amount, address to) external override onlyOwner nonReentrant {
        if (to == address(0)) revert BadParams();
        IERC20(token).safeTransfer(to, amount);
        emit Withdrawn(to, token, amount);
    }

    function withdrawAll(address to) external override onlyOwner nonReentrant {
        if (to == address(0)) revert BadParams();
        // USDC is always a member of the universe, including when its target weight is zero.
        for (uint256 i; i < _tokens.length; ++i) {
            address token = _tokens[i];
            uint256 amount = IERC20(token).balanceOf(address(this));
            if (amount != 0) {
                IERC20(token).safeTransfer(to, amount);
                emit Withdrawn(to, token, amount);
            }
        }
    }

    function setTargets(address[] calldata tokens, uint16[] calldata weightsBps)
        external override onlyOwner nonReentrant
    {
        _following = false;
        _followId = NO_TEMPLATE;
        _followVersion = 0;
        _replaceTargets(tokens, weightsBps, NO_TEMPLATE, 0);
    }

    function followTemplate(uint256 templateId, bool follow_) external override onlyOwner nonReentrant {
        if (!follow_) {
            _following = false;
            return;
        }
        if (templateId >= templates.templateCount()) revert IdOutOfRange();
        ITemplateRegistry.Template memory t = templates.templateOf(templateId);
        _following = true;
        _followId = templateId;
        _followVersion = t.version;
        _replaceTargets(t.tokens, t.weightsBps, templateId, t.version);
    }

    function follow() external view returns (uint256 templateId, bool following, uint32 version) {
        return (_followId, _following, _followVersion);
    }

    function setParams(BucketParams calldata p) external override onlyOwner nonReentrant {
        _validateParams(p);
        _params = p;
    }

    function setPaused(bool p) external override onlyOwner nonReentrant {
        paused = p;
        emit PausedSet(p);
    }

    function targets() external view override returns (address[] memory tokens, uint16[] memory weightsBps) {
        return (_tokens, _weights);
    }

    function params() external view override returns (BucketParams memory) {
        return _params;
    }

    function holdings() external view override returns (
        address[] memory tokens, uint256[] memory amounts, uint256[] memory valuesE18, uint256 totalE18
    ) {
        tokens = _tokens;
        amounts = new uint256[](tokens.length);
        valuesE18 = new uint256[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            amounts[i] = IERC20(tokens[i]).balanceOf(address(this));
            try registry.valueE18(tokens[i], amounts[i]) returns (uint256 value) {
                valuesE18[i] = value;
                totalE18 += value;
            } catch {
                // A missing or stale price must not make the holdings display unusable.
            }
        }
    }

    function driftBps() external view override returns (uint16 maxDriftBps, int32[] memory perAssetBps) {
        Snapshot memory s = _snapshot();
        perAssetBps = new int32[](s.positions.length);
        for (uint256 i; i < s.positions.length; ++i) {
            perAssetBps[i] = s.positions[i].drift;
        }
        return (s.maxDrift, perAssetBps);
    }

    function rebalance() external override nonReentrant returns (uint16 maxDriftBps) {
        if (paused) revert Paused_();
        _syncTemplate();
        Snapshot memory s = _snapshot();
        maxDriftBps = s.maxDrift;
        if (s.total == 0 || (maxDriftBps <= _params.bandBps && !s.exitHeld)) {
            revert NotNeeded(maxDriftBps);
        }
        uint64 readyAt = lastRebalance + uint64(_params.cooldown);
        if (block.timestamp < readyAt) revert Cooldown(readyAt);
        uint256 capValue = uint256(_params.maxTradeBps) * s.total / BPS;
        uint256 trades;
        // All orders use the pre-trade snapshot; sell proceeds fund the subsequent buys.
        for (uint256 i; i < s.positions.length; ++i) {
            Position memory position = s.positions[i];
            if (position.token != usdc && position.drift > 0) {
                if (_sell(position, s.total, capValue)) ++trades;
            }
        }
        for (uint256 i; i < s.positions.length; ++i) {
            Position memory position = s.positions[i];
            if (position.token != usdc && position.drift < 0 && position.risk < 2) {
                uint256 spend = _min(uint256(-int256(position.drift)) * s.total / BPS / 1e12, capValue / 1e12);
                spend = _min(spend, IERC20(usdc).balanceOf(address(this)));
                if (spend != 0) {
                    _buy(position.token, spend);
                    ++trades;
                }
            }
        }
        if (trades == 0) revert NotNeeded(maxDriftBps);
        lastRebalance = uint64(block.timestamp);
        uint256 tip = _payTip(s.total);
        emit Rebalanced(msg.sender, s.total, _totalValue(), maxDriftBps, tip);
    }

    function setSip(uint256 amountUsdc, uint32 interval, uint32 runs) external override onlyOwner nonReentrant {
        if (amountUsdc == 0 || interval < 3600 || runs == 0 || runs > 520) revert BadParams();
        sipAmount = amountUsdc;
        sipInterval = interval;
        sipRunsLeft = runs;
        sipNextAt = uint64(block.timestamp + interval);
        sipActive = true;
        emit SipSet(amountUsdc, interval, runs);
    }

    function cancelSip() external override onlyOwner nonReentrant {
        sipActive = false;
        sipRunsLeft = 0;
        emit SipSet(0, 0, 0);
    }

    function sip() external view override returns (uint256 amountUsdc, uint32 interval, uint32 runsLeft, uint64 nextAt) {
        return (sipAmount, sipInterval, sipRunsLeft, sipNextAt);
    }

    function executeSip() external override nonReentrant {
        if (paused) revert Paused_();
        if (!sipActive || sipRunsLeft == 0) revert SipInactive();
        if (block.timestamp < sipNextAt) revert SipNotDue(sipNextAt);
        --sipRunsLeft;
        uint256 scheduled = uint256(sipNextAt) + sipInterval;
        sipNextAt = uint64(scheduled > block.timestamp ? scheduled : block.timestamp);
        if (sipRunsLeft == 0) sipActive = false;
        uint256 amount = sipAmount;
        IERC20(usdc).safeTransferFrom(owner, address(this), amount);
        // SIP uses stored targets, not risk-redistributed weights or an implicit template sync.
        for (uint256 i; i < _tokens.length; ++i) {
            address token = _tokens[i];
            if (token == usdc || _weights[i] == 0) continue;
            if (registry.riskOf(token) >= 2) continue;
            uint256 share = amount * _weights[i] / BPS;
            if (share != 0) _buy(token, share);
        }
        _payTip(_totalValue());
        emit SipExecuted(msg.sender, amount, sipRunsLeft);
    }

    function _validateParams(BucketParams memory p) private pure {
        if (p.bandBps < 100 || p.bandBps > 2000 || p.maxSlippageBps < 10 || p.maxSlippageBps > 300
            || p.maxTradeBps < 500 || p.maxTradeBps > 5000 || p.cooldown < 600) revert BadParams();
    }

    function _replaceTargets(address[] memory tokens, uint16[] memory weights, uint256 templateId, uint32 version)
        private
    {
        uint256 length = tokens.length;
        if (length == 0 || length > MAX_ASSETS || length != weights.length) revert BadWeights();
        address[] memory universe = new address[](MAX_UNIVERSE);
        uint16[] memory newWeights = new uint16[](MAX_UNIVERSE);
        uint256 sum;
        for (uint256 i; i < length; ++i) {
            if (weights[i] == 0) revert BadWeights();
            if (_contains(universe, i, tokens[i])) revert BadWeights();
            registry.assetOf(tokens[i]);
            universe[i] = tokens[i];
            newWeights[i] = weights[i];
            sum += weights[i];
        }
        if (sum != BPS) revert BadWeights();
        if (!_contains(universe, length, usdc)) universe[length++] = usdc;
        for (uint256 i; i < _tokens.length; ++i) {
            address token = _tokens[i];
            if (!_contains(universe, length, token) && IERC20(token).balanceOf(address(this)) != 0) {
                if (length == MAX_UNIVERSE) revert TooManyAssets();
                universe[length++] = token;
            }
        }
        delete _tokens;
        delete _weights;
        for (uint256 i; i < length; ++i) {
            _tokens.push(universe[i]);
            _weights.push(newWeights[i]);
        }
        emit TargetsSet(_tokens, _weights, templateId, version);
    }

    function _contains(address[] memory tokens, uint256 length, address token) private pure returns (bool) {
        for (uint256 i; i < length; ++i) {
            if (tokens[i] == token) return true;
        }
        return false;
    }

    function _syncTemplate() private {
        if (!_following) return;
        ITemplateRegistry.Template memory t = templates.templateOf(_followId);
        if (t.version > _followVersion) {
            _followVersion = t.version;
            _replaceTargets(t.tokens, t.weightsBps, _followId, t.version);
        }
    }

    function _snapshot() private view returns (Snapshot memory s) {
        uint256 length = _tokens.length;
        s.positions = new Position[](length);
        uint256 cashIndex;
        uint16 exitWeight;
        for (uint256 i; i < length; ++i) {
            Position memory p;
            p.token = _tokens[i];
            p.weight = _weights[i];
            p.balance = IERC20(p.token).balanceOf(address(this));
            p.value = registry.valueE18(p.token, p.balance);
            if (p.token == usdc) {
                cashIndex = i;
            } else {
                p.risk = registry.riskOf(p.token);
                if (p.risk == 3) {
                    exitWeight += p.weight;
                    p.weight = 0;
                    if (p.balance != 0 && p.value != 0) s.exitHeld = true;
                }
            }
            s.total += p.value;
            s.positions[i] = p;
        }
        if (length == 0) return s;
        s.positions[cashIndex].weight += exitWeight;
        if (s.total == 0) return s;
        for (uint256 i; i < length; ++i) {
            int32 drift = int32(int256(s.positions[i].value * BPS / s.total) - int256(uint256(s.positions[i].weight)));
            s.positions[i].drift = drift;
            uint16 magnitude = uint16(uint32(drift < 0 ? -drift : drift));
            if (magnitude > s.maxDrift) s.maxDrift = magnitude;
        }
    }

    function _sell(Position memory p, uint256 total, uint256 capValue) private returns (bool) {
        uint256 sellValue = _min(uint256(int256(p.drift)) * total / BPS, capValue);
        uint256 amount = _min(_amountForValue(p.token, sellValue), p.balance);
        if (amount == 0) return false;
        uint256 referenceOut = registry.valueE18(p.token, amount) / 1e12;
        _swap(p.token, usdc, amount, referenceOut * (BPS - _params.maxSlippageBps) / BPS,
            registry.assetOf(p.token).venue);
        return true;
    }

    function _buy(address token, uint256 spend) private {
        uint256 referenceOut = _amountForValue(token, spend * 1e12);
        _swap(usdc, token, spend, referenceOut * (BPS - _params.maxSlippageBps) / BPS,
            registry.assetOf(token).venue);
    }

    function _amountForValue(address token, uint256 value) private view returns (uint256) {
        IAssetRegistry.Asset memory asset = registry.assetOf(token);
        (uint256 price,) = registry.priceE8(token);
        return value * (10 ** uint256(asset.decimals)) / (price * 1e10);
    }

    function _swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, address venue) private {
        if (venue == address(0)) revert BadParams();
        uint256 beforeOut = IERC20(tokenOut).balanceOf(address(this));
        IERC20(tokenIn).forceApprove(venue, amountIn);
        IVenue(venue).swap(tokenIn, tokenOut, amountIn, minOut, address(this));
        IERC20(tokenIn).forceApprove(venue, 0);
        uint256 afterOut = IERC20(tokenOut).balanceOf(address(this));
        uint256 received = afterOut >= beforeOut ? afterOut - beforeOut : 0;
        if (received < minOut) revert SlippageExceeded(received, minOut);
        emit TradeExecuted(tokenIn, tokenOut, amountIn, received, venue);
    }

    function _totalValue() private view returns (uint256 total) {
        for (uint256 i; i < _tokens.length; ++i) {
            total += registry.valueE18(_tokens[i], IERC20(_tokens[i]).balanceOf(address(this)));
        }
    }

    function _payTip(uint256 valueE18) private returns (uint256 tip) {
        tip = _min(TIP_CAP, (valueE18 / 1e12) * TIP_BPS / BPS);
        if (tip != 0) {
            if (IERC20(usdc).balanceOf(address(this)) >= tip) {
                IERC20(usdc).safeTransfer(msg.sender, tip);
            } else {
                tip = 0;
            }
        }
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }
}
