# Arc Treasury, turn 1/2: contracts, tests, Arc Testnet deploy

Build, test and deploy to **Arc Testnet (5042002)** the contracts for per-user auto-rebalancing "buckets" with an on-chain SIP. **Contracts only in this turn** (the frontend is turn 2).

**Do not ask clarifying questions.** Everything is decided here. If something is ambiguous, pick the simplest safe option, note it in `ARC.md` and finish in this one turn.

## Interface (must reuse, do not change)
`context/.../IArcTreasury.sol` is attached. Copy it to `contracts/IArcTreasury.sol` unchanged and implement it exactly.

## Arc facts
- USDC ERC-20: `0x3600000000000000000000000000000000000000` (6 dec). EURC: `0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a` (6 dec).
- No `payable`, never use `msg.value`. Set `maxFeePerGas` ≥ 20 gwei on every deploy and setup tx.
- Uniswap v4 on Arc testnet (I verified the bytecode): PoolManager `0x8366a39CC670B4001A1121B8F6A443A643e40951`, StateView `0xF3334192D15450CdD385c8B70e03f9A6bD9E673b`, Quoter `0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94`. Live pool: USDC/EURC, fee 500, tickSpacing 10, hooks `address(0)`.

## Contracts
**1. `AssetRegistry`** (IAssetRegistry, Ownable2Step).
- `onReport` accepts only `reporters`. Kind 1 = prices; reject any price whose `observedAt` is older than the stored one or later than `block.timestamp`. Kind 2 = risk level 0..3.
- Default `maxStaleness` = 3600.
- USDC is always priced at 1e8.

**2. `UniswapV4Venue`** (IVenue): swaps USDC↔EURC through the PoolManager unlock pattern. Don't depend on the UniversalRouter.
```solidity
function swap(address tIn, address tOut, uint256 amtIn, uint256 minOut, address to) external returns (uint256 out) {
    IERC20(tIn).safeTransferFrom(msg.sender, address(this), amtIn);
    out = abi.decode(poolManager.unlock(abi.encode(tIn, tOut, amtIn, to)), (uint256));
    if (out < minOut) revert MinOut(out, minOut);
}
function unlockCallback(bytes calldata d) external returns (bytes memory) {
    require(msg.sender == address(poolManager));
    (address tIn,, uint256 amtIn, address to) = abi.decode(d, (address,address,uint256,address));
    bool zeroForOne = tIn == Currency.unwrap(key.currency0);
    BalanceDelta delta = poolManager.swap(key, SwapParams({
        zeroForOne: zeroForOne, amountSpecified: -int256(amtIn), // exact input
        sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
    }), "");
    // settle input: sync -> transfer -> settle; take output
    poolManager.sync(Currency.wrap(tIn)); IERC20(tIn).safeTransfer(address(poolManager), amtIn); poolManager.settle();
    uint256 out = uint256(int256(zeroForOne ? delta.amount1() : delta.amount0()));
    poolManager.take(zeroForOne ? key.currency1 : key.currency0, to, out);
    return abi.encode(out);
}
```
`quote` uses the v4 Quoter (a view-safe static call) or reverts `Unsupported`. Use v4-core/v4-periphery as libs.

**3. `MirrorVenue`** (IVenue) for assets with no testnet pool. Every listed mirror is a `MirrorToken` (ERC-20 named e.g. "cirBTC (testnet mirror)", mint/burn only by the venue). Price comes from `AssetRegistry`, with spread `spreadBps` = 30:
```solidity
// buy: USDC in -> mirror out (venue keeps USDC as reserve)
out = usdcIn * 1e8 * 10**dec / (priceE8 * 10**6) * (10000 - spreadBps) / 10000;  // mint `out`
// sell: mirror in -> USDC out from reserve (revert if reserve too small)
out = amtIn * priceE8 * 10**6 / (1e8 * 10**dec) * (10000 - spreadBps) / 10000;   // burn amtIn
```
- Revert if the asset's risk is ≥ 2 on buys, or its price is stale.
- `maxTradeUsdc` cap = 5,000 USDC per swap.
- `name()` = "Mirror (testnet)".

**4. `TemplateRegistry`** (ITemplateRegistry): curators set templates. Weights sum to 10000, at most 12 assets, `bandBps` between 100 and 2000.

**5. `BucketAccount` + `BucketFactory`.** The factory deploys EIP-1167 clones; each clone is owned by `msg.sender`. Users' funds are never pooled.
- **Bounds:**
  - `bandBps` 100..2000
  - `maxSlippageBps` 10..300
  - `maxTradeBps` 500..5000
  - `cooldown` ≥ 600 s
  - assets ≤ 12, all listed in the registry, USDC allowed as "cash"
- **Tip:** `min(0.05 USDC, 0.1% of value)`, paid from the bucket's USDC, and only if USDC ≥ tip.
- **Following a template:** if `follow` is on and the template version increased, `rebalance()` loads the new weights first and emits `TargetsSet`.
- **Rebalance algorithm** (`nonReentrant`, prices via the registry, revert on stale):
```text
targets' = targets; for each asset with risk == 3: move its weight to USDC   // exit
value_i = registry.valueE18(token_i, bal_i); total = sum(value_i)
drift_i = value_i*10000/total - target'_i ; maxDrift = max |drift_i|
if maxDrift <= bandBps and no risk-3 asset held: revert NotNeeded(maxDrift)
require(block.timestamp >= lastRebalance + cooldown)
SELLS first (drift > 0, not USDC): sellValue = min(drift_i*total/10000, maxTradeBps*total/10000)
   amountIn = sellValue -> token amount; minOut = refUSDC * (10000 - maxSlippageBps)/10000
BUYS next (drift < 0, risk < 2):    spend = min(|drift_i|*total/10000, maxTradeBps*total/10000, usdcBalance)
   minOut = refTokenAmount * (10000 - maxSlippageBps)/10000
emit TradeExecuted per trade; emit Rebalanced(caller, before, after, maxDrift, tip)
```
- **SIP:** `executeSip()` requires active, `block.timestamp >= nextAt` and `runsLeft > 0`. It pulls `amountUsdc` from the owner (`safeTransferFrom`), buys every non-USDC asset pro-rata to target (skips risk ≥ 2, keeps that share as USDC), sets `nextAt += interval` (never in the past: `max(nextAt+interval, now)`), and pays the tip. Bounds: `interval` ≥ 3600, `runs` 1..520.
- `withdraw` and `withdrawAll` work even when paused. Pause blocks rebalance and SIP only.

## Seed at deploy
- **Mirror tokens, with the mainnet asset each mirrors** (put the mainnet token address in `mainnetRef`; look them up live on `explorer.arc.io`, never invent):
  - cirBTC.m (Crypto, 8 dec)
  - WETH.m (Crypto, 18)
  - GBPA.m (FX, 6)
  - syrupUSDC.m (Yield, 6)
  - XAUM.m (RWA gold, 18)
  - ASTOCK.m (RWA stocks, 18)
- **Real assets:** EURC (FX, UniswapV4Venue) and USDC (Cash).
- **Initial prices:** fetch live mainnet USD prices once at deploy from `https://api.geckoterminal.com/api/v2/networks/arc/tokens/<mainnetToken>` (`attributes.price_usd`). If a fetch fails, leave that asset unpriced so trading stays disabled until the first report. **Never hardcode or guess a price.**
- **Templates:** names and descriptions only, with **no return claims**:

| id | name | weights (bps) | band |
|---|---|---|---|
| 0 | Blue Chips | cirBTC.m 5000, WETH.m 5000 | 500 |
| 1 | Global FX | USDC 4000, EURC 4000, GBPA.m 2000 | 300 |
| 2 | Stable Yield | USDC 5000, syrupUSDC.m 5000 | 200 |
| 3 | Real Assets | XAUM.m 5000, ASTOCK.m 3000, USDC 2000 | 500 |
| 4 | All-Weather | cirBTC.m 2500, WETH.m 1500, XAUM.m 2000, EURC 2000, syrupUSDC.m 2000 | 500 |

- **Roles:** `0x58ca3EC7BbA9AD5258867D81e387A07C3EBA477d` becomes reporter (AssetRegistry) and curator (TemplateRegistry). After setup, call `transferOwnership(0x58ca3EC7BbA9AD5258867D81e387A07C3EBA477d)` on every Ownable contract (2-step: we accept later). Send nothing else to or from that address.

## Tests (Foundry, mocks for PoolManager where needed)
- **Registry:** reporter-only access, stale and out-of-order reports rejected, risk levels.
- **Mirror:** buy/sell math, spread, reserve shortfall reverts, risk ≥ 2 blocks buys, cap.
- **Bucket:**
  - deposit/withdraw, owner-only paths, parameter bounds
  - rebalance: NotNeeded inside the band, Cooldown, sells before buys, maxTradeBps cap, slippage revert, risk-3 exit to USDC, tip cap
  - SIP: due/not due, runs countdown, pulls from the owner, skips risk ≥ 2, `nextAt` never in the past
  - template follow picks up new versions; pause doesn't block withdrawals
- **Fuzz:** total value is conserved within spread and slippage across rebalances; no clone can touch another user's funds.
- Run `forge test` and show the summary. Fix any failures before deploying.

## Deliver
- Deploy everything to Arc Testnet and report each contract (name, address, tx hash, explorer URL), only as returned by the deploy.
- Run **one live smoke test**: create a bucket from template 1 (Global FX), deposit 5 USDC, call `rebalance()`, and show the real Uniswap v4 USDC→EURC trade tx. If the deployer has under 6 USDC, skip this step and say so.
- Write `ARC.md` with the addresses, the trust model (curator, reporter and owner powers), and the label "testnet; mirror assets are priced from mainnet and are not the real assets; not investment advice".
