# Arc Treasury contracts: build spec (authoritative)

Target: Arc Testnet (5042002). Solidity 0.8.28, cevm cancun, OpenZeppelin 5.6.1 (node_modules), Uniswap v4-core/v4-periphery
(`@uniswap/v4-core/`, `@uniswap/v4-periphery/` remappings already set). Interfaces: `contracts/IArcTreasury.sol` (DO NOT EDIT; implement exactly:
names, args, events, errors). Extra events/errors/functions beyond the interface are allowed. No `payable`, never `msg.value`, never send to address(0).
USDC ERC-20 = 0x3600000000000000000000000000000000000000 (6 dec). EURC = 0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a (6 dec).
Uniswap v4 Arc testnet: PoolManager 0x8366a39CC670B4001A1121B8F6A443A643e40951, Quoter 0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94,
pool USDC/EURC fee 500 tickSpacing 10 hooks address(0) (USDC is currency0 because its address is lower).
Files are flat in `contracts/`, one contract per file, filename == contract name. No constructor may use msg.sender for ownership (explicit owner arg).

## 1. AssetRegistry (IAssetRegistry, Ownable2Step) - AssetRegistry.sol
- constructor(address owner_, address usdc_). Lists USDC itself (symbol "USDC", Cash, 6 dec, venue address(0), mirror false, mainnetRef "").
- listAsset(Asset) onlyOwner: token != 0, not already listed, decimals <= 24 and equal to IERC20Metadata(token).decimals(), venue != 0 (except USDC),
  emits AssetListed. assets() returns the list in listing order. assetOf reverts UnknownAsset(token) if not listed.
- reporters mapping; setReporter(owner) emits ReporterSet; `isReporter(address)` public view.
- onReport(metadata, report): only reporters else NotReporter. report = abi.encode(uint8 kind, bytes payload).
  Kind 1 prices: abi.encode(address[] tokens, uint256[] pricesE8, uint64 observedAt). Revert BadReport if lengths differ, empty, > 50 entries,
  observedAt > block.timestamp, any price == 0 or > type(uint192).max, token is USDC (USDC always 1e8), or observedAt < the stored observedAt
  for that token (older than stored; equal is allowed). Unlisted token -> UnknownAsset. Emits PriceUpdated.
  Kind 2 risk: abi.encode(address token, uint8 level, bytes32 evidenceHash): level 0..3 else BadReport, token must be listed and not USDC. Emits RiskUpdated.
  Unknown kind -> BadReport. All decode failures -> BadReport (use a try/catch on an external self-decode helper or length checks).
- maxStaleness public, default 3600; setMaxStaleness(uint64) onlyOwner, 60 <= value <= 7 days else BadReport; emits MaxStalenessSet(uint64).
- priceE8(token): USDC -> (1e8, uint64(block.timestamp)). Otherwise unlisted -> UnknownAsset; never set (observedAt 0) or
  block.timestamp > observedAt + maxStaleness -> StalePrice(token).
- riskOf(token): stored level (0 for USDC / unset), unlisted -> UnknownAsset.
- valueE18(token, amount) = amount * priceE8 * 1e10 / 10**decimals (uses priceE8, so reverts when stale).

## 2. UniswapV4Venue (IVenue) - UniswapV4Venue.sol
constructor(IPoolManager pm, IV4Quoter quoter, PoolKey memory key_). `key` public. name() = "Uniswap v4 (Arc testnet)".
Supported pair = {currency0, currency1} in either direction, else revert Unsupported(tIn, tOut). Both tokens must differ. amtIn > 0.
swap(tIn,tOut,amtIn,minOut,to) nonReentrant: pull amtIn from msg.sender (safeTransferFrom), `out = abi.decode(poolManager.unlock(abi.encode(tIn, amtIn, to, msg.sender)), (uint256))`,
`if (out < minOut) revert MinOut(out, minOut)`, emit Swapped(msg.sender, tIn, tOut, amtIn, out).
unlockCallback(bytes): only poolManager. zeroForOne = tIn == currency0. poolManager.swap(key, SwapParams({zeroForOne, amountSpecified: -int256(amtIn),
sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1}), ""). Read the input leg of the delta
(amount0 if zeroForOne else amount1; negative) as `owed = uint256(-int256(inputDelta))`; settle only `owed` (sync(tIn) -> IERC20 transfer owed to poolManager -> settle());
refund `amtIn - owed` (partial fill) to the payer; take the output (amount1 if zeroForOne else amount0, positive) to `to`. Return abi.encode(out).
quote(tIn,tOut,amtIn) is `view`: staticcall quoter.quoteExactInputSingle(QuoteExactSingleParams{key, zeroForOne, uint128 exactAmount, ""}); on any failure or
short returndata revert Unsupported(tIn,tOut) (the v4 Quoter needs transient storage so this will usually fail inside a staticcall; document this in NatSpec:
off-chain callers should eth_call the Quoter directly, address is exposed via public `quoter`). Also expose public `poolManager`.

## 3. MirrorToken + MirrorVenue
MirrorToken.sol: OZ ERC20 with custom decimals, constructor(string name_, string symbol_, uint8 decimals_, address venue_); `venue` immutable public;
mint(to, amt) / burn(from, amt) only callable by venue (custom error NotVenue). Names like "cirBTC (testnet mirror)", symbol "cirBTC.m".
MirrorVenue.sol (IVenue, ReentrancyGuard): constructor(IAssetRegistry registry_, address usdc_). name() = "Mirror (testnet)". `spreadBps` = 30 (public constant),
`maxTradeUsdc` = 5_000e6 (public constant). A mirror token is accepted when registry.assetOf(token) has venue == address(this) && mirror == true.
Pair must be (USDC -> mirror) buy or (mirror -> USDC) sell, else Unsupported. Prices come from the registry priceE8 (reverts StalePrice when stale).
buy (USDC in): require amtIn <= maxTradeUsdc (error TradeTooLarge(uint256 amount, uint256 cap)); registry.riskOf(mirror) >= 2 -> revert RiskBlocked(token, level);
pull USDC from msg.sender (safeTransferFrom; venue keeps it as reserve);
  out = usdcIn * 1e8 * 10**dec / (priceE8 * 10**6) * (10000 - spreadBps) / 10000;  mint `out` to `to`.
sell (mirror in): out = amtIn * priceE8 * 10**6 / (1e8 * 10**dec) * (10000 - spreadBps) / 10000; require out <= maxTradeUsdc (TradeTooLarge);
require USDC reserve >= out else InsufficientReserve(uint256 have, uint256 need); transferFrom the mirror from msg.sender to the venue then burn it from the venue; USDC out to `to`.
Sells are allowed at any risk level. Revert MinOut(out, minOut) if out < minOut. emit Swapped. quote() = same math, view, same reverts (except it does not pull funds).
No owner functions, no way to withdraw the reserve.

## 4. TemplateRegistry (ITemplateRegistry, Ownable2Step) - TemplateRegistry.sol
constructor(address owner_, IAssetRegistry registry_). curators mapping, setCurator onlyOwner emits CuratorSet; isCurator view.
setTemplate(id, Template) callable only by curators else NotCurator. id must be <= templateCount (id == count appends; else revert IdOutOfRange).
Validate (BadWeights): tokens.length == weightsBps.length, 1..12 assets, each weight > 0, sum == 10000, no duplicate tokens, every token listed in the registry
(registry.assetOf reverts UnknownAsset otherwise, let it bubble), bandBps in [100, 2000] (revert BadBand). Stored version = previous version + 1 (first set = 1);
the incoming `version` field is ignored. Emit TemplateSet(id, version, rationaleHash). templateOf(id) reverts IdOutOfRange if id >= count. templateCount().
Template tokens may include USDC.

## 5. BucketAccount (+ BucketFactory) - BucketAccount.sol, BucketFactory.sol
BucketAccount is an EIP-1167 clone implementation: constructor locks the implementation (initialized = true); one-shot
`initialize(address owner_, IAssetRegistry registry_, ITemplateRegistry templates_, address[] tokens, uint16[] weightsBps, BucketParams p, uint256 templateId, bool follow)`
called atomically by the factory (also record factory = msg.sender; initialize reverts if already initialized). It must work behind a clone (no immutables set in constructor
other than constants; use storage). Use OZ SafeERC20, own simple nonReentrant (works with clones; do not rely on constructor init) .
Constants: NO_TEMPLATE = type(uint256).max, TIP_CAP = 0.05e6 (50_000), TIP_BPS = 10 (0.1%), MAX_ASSETS = 12, MAX_UNIVERSE = 16.
Funds never pool: each clone only ever moves its own balances; the owner is the only withdrawer.

Bounds (revert custom error BadParams() on violation, in initialize and setParams):
  bandBps 100..2000, maxSlippageBps 10..300, maxTradeBps 500..5000, cooldown >= 600.
Targets: input tokens.length 1..12, weights each > 0 and sum 10000 (revert BadWeights), no duplicates, every token listed in the registry (assetOf; let UnknownAsset bubble),
USDC is allowed as cash. Internal "universe" = the stored token list: the input tokens, plus USDC with weight 0 if absent, plus any previously held token (balance > 0) that is not in
the new set carried with weight 0 (so it gets sold down). Universe length must be <= MAX_UNIVERSE else revert TooManyAssets(). `targets()` returns the universe and weights.
emit TargetsSet(tokens, weights, templateId (NO_TEMPLATE for custom), templateVersion (0 for custom)) with the universe arrays.
- setTargets (owner): custom targets, turns following off.
- followTemplate(id, follow) owner: follow=true -> require id < templates.templateCount(), load template tokens/weights (NOT the band), following = true, followId = id, followVersion = version, emit TargetsSet.
  follow=false -> following = false.
- `follow()` view returns (uint256 templateId, bool following, uint32 version).
- _syncTemplate(): if following && templates.templateOf(followId).version > followVersion: load the new weights, update followVersion, emit TargetsSet. Called at the start of rebalance().
- Owner-only (error NotOwner): withdraw, withdrawAll, setTargets, followTemplate, setParams, setPaused, setSip, cancelSip. `owner()` view.
- deposit(amount): anyone, amount > 0, safeTransferFrom(msg.sender -> this), emit Deposited(msg.sender, amount).
- withdraw(token, amount, to) owner, nonReentrant, to != 0; safeTransfer; emit Withdrawn(to, token, amount). withdrawAll(to): every universe token + USDC with balance > 0, emits Withdrawn each.
  Both work while paused. setPaused(bool) emits PausedSet(bool). Pause blocks rebalance() and executeSip() only (revert Paused_()).
- Views: holdings() tolerant (uses try/catch on registry.valueE18; a stale token contributes value 0), driftBps() strict (reverts on stale) returning per-asset signed drift in bps vs the
  EFFECTIVE targets (risk-3 weights moved to USDC), sip(), params(), targets(). If total value is 0, driftBps returns (0, zeros).

### rebalance() nonReentrant returns (uint16 maxDriftBps)
```
if paused revert Paused_();  _syncTemplate();
targets' = targets; for each asset with riskOf == 3 (not USDC): move its weight to USDC     // exit
value_i = registry.valueE18(token_i, bal_i); total = sum(value_i)     // reverts on stale; total == 0 -> revert NotNeeded(0)
drift_i = value_i*10000/total - target'_i ; maxDrift = max |drift_i|
if maxDrift <= bandBps and no risk-3 asset held (balance > 0 with value > 0): revert NotNeeded(maxDrift)
require(block.timestamp >= lastRebalance + cooldown) else revert Cooldown(lastRebalance + cooldown)     // checked AFTER NotNeeded
SELLS first (drift > 0, not USDC): sellValue = min(drift_i*total/10000, maxTradeBps*total/10000)
   amountIn = sellValue -> token amount (capped at balance); minOut = refUSDC * (10000 - maxSlippageBps)/10000  (refUSDC = registry value of amountIn / 1e12)
BUYS next (drift < 0, risk < 2, not USDC): spend = min(|drift_i|*total/10000 converted to USDC (/1e12), maxTradeBps*total/10000 (/1e12), usdcBalance now)
   minOut = refTokenAmount * (10000 - maxSlippageBps)/10000   (refTokenAmount = spend converted at registry price)
emit TradeExecuted per trade (tokenIn, tokenOut, amountIn, amountOut measured via balance delta, venue); if zero trades executed revert NotNeeded(maxDrift)
(prevents tip farming on dust); lastRebalance = block.timestamp;
tip = min(0.05 USDC, 0.1% of valueBefore) paid from the bucket's USDC to msg.sender only if USDC balance >= tip (tip may be 0); emit Rebalanced(caller, valueBefore, valueAfter, maxDrift, tip).
```
Conversions: token amount for value V (E18) = V * 10**dec / (priceE8 * 1e10). Venue per token = registry.assetOf(token).venue. Approve venue with forceApprove(amountIn) before each swap and reset to 0 after.
Do not trust venue return values for accounting; use balance deltas, and rely on minOut (the venue enforces it; also re-check received >= minOut and revert MinOut-like error `SlippageExceeded(got, min)`).
USDC is never traded against itself. Skip trades where the computed amountIn/spend is 0. Use memory structs for positions to avoid stack-too-deep (no via_ir).

### SIP
State: sipAmount, sipInterval, sipRunsLeft, sipNextAt, sipActive. setSip(amountUsdc, interval, runs) owner: amount > 0, interval >= 3600, runs 1..520 (revert BadParams), active = true,
nextAt = block.timestamp + interval (first run is one interval after setting), emit SipSet. cancelSip(): active=false, runsLeft=0, emit SipSet(0,0,0).
executeSip() anyone, nonReentrant: paused -> Paused_(); !active || runsLeft == 0 -> SipInactive(); block.timestamp < nextAt -> SipNotDue(nextAt).
Effects first: runsLeft--; nextAt = max(nextAt + interval, block.timestamp); if runsLeft == 0 then active = false.
Pull amountUsdc from the owner (safeTransferFrom(owner -> this); needs the owner's allowance to the bucket). Buy every non-USDC universe asset with weight > 0 pro-rata to its target weight:
share = amount * w_i / 10000; skip (keep as USDC) if riskOf >= 2; other shares (USDC weight, skipped) stay as USDC. Each buy uses the same minOut rule as rebalance (registry price, maxSlippageBps), venue approve/reset.
Then pay the tip (same rule, value = total bucket value after buys) to msg.sender. emit TradeExecuted per buy and SipExecuted(msg.sender, amountUsdc, runsLeft).

## BucketFactory - BucketFactory.sol (IBucketFactory)
constructor(address implementation_, IAssetRegistry registry_, ITemplateRegistry templates_). The implementation is a separately deployed BucketAccount (do NOT `new` it inside the factory).
createBucket(name, tokens, weights, p): `Clones.clone(implementation)`, initialize(msg.sender, ..., NO_TEMPLATE, false), record in bucketsOf[msg.sender], isBucket[bucket] = true, push to an
all-buckets array; emit BucketCreated(msg.sender, bucket, type(uint256).max, name). createFromTemplate(templateId, follow): read the template; params = BucketParams(template.bandBps, 100, 2500, 3600);
initialize with tokens/weights of the template, templateId, follow; name = template.name; emit BucketCreated(msg.sender, bucket, templateId, template.name).
Views: bucketsOf(owner), bucketCount(), bucketAt(i), isBucket(address).

## Notes
- No contract may hold or use msg.value. No tx.origin. Events/Errors as in the interface file.
- Unit tests live in contracts/test (a separate agent writes them). Do not compile-test; keep code compiling against solc 0.8.28 (no via_ir; avoid stack-too-deep with structs).
