// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Arc Treasury: per-user auto-rebalancing buckets with an on-chain SIP, on Arc Testnet (5042002).
// Stable interfaces. Arc Studio must implement these exactly (names, args, events, errors).
//
// Units
//   - Token amounts: native token decimals (USDC/EURC ERC-20 = 6; mirror tokens declare their own).
//   - Prices: USD per 1 whole token, 8 decimals ("E8", Chainlink style).
//   - Values: USD with 18 decimals ("E18"). value = amount * priceE8 * 1e10 / 10**decimals
//   - Weights / bands / caps: basis points (10000 = 100%).
// Arc rules: no payable functions, never use msg.value, never send native value to address(0).
// block.timestamp is non-decreasing (not strictly increasing).

/// Prices + risk flags for every listed asset. Fed by Chainlink CRE reports (or an allowed relayer).
interface IAssetRegistry {
    enum Category { Cash, FX, Crypto, Yield, RWA }

    struct Asset {
        address token;
        string symbol;        // e.g. "cirBTC.m" for mirrors
        Category category;
        uint8 decimals;
        address venue;        // IVenue that trades this asset against USDC
        bool mirror;          // true = testnet mirror of a mainnet asset (label it in the UI)
        string mainnetRef;    // mainnet token or pool address the price mirrors ("" for real testnet assets)
    }

    event AssetListed(address indexed token, string symbol, Category category, address venue, bool mirror);
    event PriceUpdated(address indexed token, uint256 priceE8, uint64 observedAt);
    event RiskUpdated(address indexed token, uint8 level, bytes32 evidenceHash);
    event ReporterSet(address indexed reporter, bool allowed);

    error NotReporter();
    error UnknownAsset(address token);
    error StalePrice(address token);
    error BadReport();

    function usdc() external view returns (address);
    function listAsset(Asset calldata a) external;                       // owner
    function setReporter(address reporter, bool allowed) external;       // owner (CRE forwarder + relayer)
    function setMaxStaleness(uint64 seconds_) external;                  // owner

    /// Chainlink CRE (Keystone forwarder) entry point. report = abi.encode(uint8 kind, bytes payload)
    ///   kind 1 (prices): abi.encode(address[] tokens, uint256[] pricesE8, uint64 observedAt)
    ///   kind 2 (risk):   abi.encode(address token, uint8 level, bytes32 evidenceHash)  level 0..3
    function onReport(bytes calldata metadata, bytes calldata report) external;

    function assets() external view returns (address[] memory);
    function assetOf(address token) external view returns (Asset memory);
    /// Reverts StalePrice if older than maxStaleness or never set. USDC is always 1e8.
    function priceE8(address token) external view returns (uint256 price, uint64 observedAt);
    function riskOf(address token) external view returns (uint8 level); // 0 ok, 1 watch, 2 no buys, 3 exit
    function valueE18(address token, uint256 amount) external view returns (uint256);
}

/// A place to swap an asset against USDC. One implementation per liquidity source.
interface IVenue {
    event Swapped(address indexed caller, address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut);
    error MinOut(uint256 got, uint256 minOut);
    error Unsupported(address tokenIn, address tokenOut);

    function name() external view returns (string memory);  // "Uniswap v4 (Arc testnet)" | "Mirror (testnet)"
    function quote(address tokenIn, address tokenOut, uint256 amountIn) external view returns (uint256 amountOut);
    /// Pulls amountIn from msg.sender (approve first), sends >= minOut of tokenOut to `to`.
    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, address to) external returns (uint256 amountOut);
}

/// Default buckets curated by the AI curator. Users copy them; following is opt-in.
interface ITemplateRegistry {
    struct Template {
        string name;            // "Blue Chips", "Global FX", ...
        string description;     // plain language, no return promises
        address[] tokens;
        uint16[] weightsBps;    // sum == 10000
        uint16 bandBps;         // rebalance when any |actual - target| > band
        uint32 version;
        bytes32 rationaleHash;  // keccak256 of the AI curator's reasoning text (stored off-chain)
    }

    event TemplateSet(uint256 indexed id, uint32 version, bytes32 rationaleHash);
    event CuratorSet(address indexed curator, bool allowed);
    error NotCurator();
    error BadWeights();

    function setTemplate(uint256 id, Template calldata t) external; // curator; bumps version
    function setCurator(address curator, bool allowed) external;    // owner
    function templateOf(uint256 id) external view returns (Template memory);
    function templateCount() external view returns (uint256);
}

struct BucketParams {
    uint16 bandBps;         // drift band, e.g. 500 = 5%
    uint16 maxSlippageBps;  // vs registry price, e.g. 100 = 1%
    uint16 maxTradeBps;     // max single trade as share of bucket value, e.g. 2500
    uint32 cooldown;        // seconds between rebalances, e.g. 3600
}

/// One user's bucket. Owned by the user (EIP-1167 clone). Funds never pool across users.
interface IBucketAccount {
    event Deposited(address indexed from, uint256 usdcAmount);
    event Withdrawn(address indexed to, address indexed token, uint256 amount);
    event TargetsSet(address[] tokens, uint16[] weightsBps, uint256 templateId, uint32 templateVersion);
    event Rebalanced(address indexed caller, uint256 valueBeforeE18, uint256 valueAfterE18, uint16 maxDriftBps, uint256 tipUsdc);
    event TradeExecuted(address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut, address venue);
    event SipSet(uint256 amountUsdc, uint32 interval, uint32 runsLeft);
    event SipExecuted(address indexed caller, uint256 amountUsdc, uint32 runsLeft);

    error NotOwner();
    error BadWeights();
    error NotNeeded(uint16 maxDriftBps);
    error Cooldown(uint64 readyAt);
    error SipNotDue(uint64 dueAt);
    error SipInactive();
    error Paused_();

    function owner() external view returns (address);
    function deposit(uint256 usdcAmount) external;                          // anyone can top up
    function withdraw(address token, uint256 amount, address to) external;  // owner
    function withdrawAll(address to) external;                              // owner, every asset
    function setTargets(address[] calldata tokens, uint16[] calldata weightsBps) external; // owner (custom)
    function followTemplate(uint256 templateId, bool follow) external;      // owner; follow = auto-apply new versions
    function setParams(BucketParams calldata p) external;                   // owner, bounded (see prompt)
    function setPaused(bool p) external;                                    // owner

    /// Anyone. Reverts NotNeeded / Cooldown. Pays a capped tip in USDC to msg.sender.
    function rebalance() external returns (uint16 maxDriftBps);
    /// Owner sets a recurring buy: pulls `amountUsdc` from the owner (allowance to this bucket) every `interval`.
    function setSip(uint256 amountUsdc, uint32 interval, uint32 runs) external;
    function cancelSip() external;
    /// Anyone (keeper / CRE cron). Pulls USDC from owner, buys toward targets, pays capped tip.
    function executeSip() external;

    function targets() external view returns (address[] memory tokens, uint16[] memory weightsBps);
    function holdings() external view returns (address[] memory tokens, uint256[] memory amounts, uint256[] memory valuesE18, uint256 totalE18);
    function driftBps() external view returns (uint16 maxDriftBps, int32[] memory perAssetBps);
    function sip() external view returns (uint256 amountUsdc, uint32 interval, uint32 runsLeft, uint64 nextAt);
    function params() external view returns (BucketParams memory);
}

interface IBucketFactory {
    event BucketCreated(address indexed owner, address indexed bucket, uint256 templateId, string name);
    function createBucket(string calldata name, address[] calldata tokens, uint16[] calldata weightsBps, BucketParams calldata p) external returns (address bucket);
    function createFromTemplate(uint256 templateId, bool follow) external returns (address bucket);
    function bucketsOf(address owner) external view returns (address[] memory);
}
