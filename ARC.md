# Arc Treasury: contracts on Arc Testnet (5042002)

**Testnet only. Mirror assets are priced from mainnet and are not the real assets. Not investment advice.**

Per-user auto-rebalancing "buckets" with an onchain SIP. Each bucket is an EIP-1167 clone owned by the user who created it. Funds are never pooled between users.

Explorer: https://explorer.testnet.arc.io

## Deployed contracts

Every address below is as returned by the deploys or read back from the chain. Full tx hashes are listed.

| Contract | Address | Deploy tx |
|---|---|---|
| BucketFactory | `0x6677b355ca5c21c77198bfe62d223d3e8fc23875` | `0x4c71303393e5bd2621c67315fcd6faac75b056d0b37a4a962af08d771830d77e` |
| BucketAccount (clone implementation) | `0x97dc3f2d27e8054c982c71e40db4bce315496554` | `0x90714358997445f49423dd90ca8b19c28c8de81f74781b5da7a9e86540021b7a` |
| UniswapV4Venue (USDC/EURC) | `0x767f4a602d1944409482f57aad56fd5696586208` | `0x8cfc484fd5c705c0135c099c68361cf100ee62475d0c4c4ba31b2a359123704a` |
| ArcTreasuryCore (bootstrap, see below) | `0x1dcb59c9afab2e0f660206a9c8233454d6e3a6fc` | `0xa683fde9b505ca4fc42752d63ad2f8f1de7c05fc3385509992baf5b6dfeed631` |
| MirrorTokenBatch (bootstrap) | `0x6b12ce46563c92ebf9148dd33e41cba9699c24f2` | `0xfc712a8466eceb5b1b542d6754246f7bb659fd93c1bd6c8bed1f988a5b413f5f` |
| SeedRelay (bootstrap) | `0xf1f34a52f70325581736aa5f4ad60423471460a1` | `0x19f424b5e1791a5527c3cf77cf3825512c5757bed46afc180ced1066d8caa00f` |

Created inside the ArcTreasuryCore deploy tx (read from `registry()`, `templates()`, `mirrorVenue()`):

| Contract | Address |
|---|---|
| AssetRegistry | `0x79E37808c2187B949D36c0295C7947154CD85A47` |
| TemplateRegistry | `0xb46DD5FA830b43031f3FF907634963F158D840a5` |
| MirrorVenue | `0xBaF806f5a0020F97ACB16f9f7501495b1473B7a7` |

Created inside the MirrorTokenBatch deploy tx (read from `tokens(i)`):

| Mirror token | Address | Mirrors (mainnet token) |
|---|---|---|
| cirBTC.m (Crypto, 8 dec) | `0x4010e44C6142bdfC9e1b5e9c1eeBF3737aa712fD` | `0x171A4217b86A807A64eB94757Db6849fb4bDbAA0` |
| WETH.m (Crypto, 18) | `0x090E8DfF74c951c4E2aDbc8A49CBCC4F2BE57B69` | `0x128cC466B61f542da60c70e3aA11c10e19B84EDB` |
| GBPA.m (FX, 6) | `0xd953B990354196fef89ee48260839b8aA4EACF43` | `0xbBe6aAB0Ed76e90AeA0d1cd978EC231c8AdCDF8b` |
| syrupUSDC.m (Yield, 6) | `0x58E9A1d957F31d11003edB2aaEDC845e027E7B90` | `0x0dC6b79F3c3854E4d74514fD4d29BE6c96Beee39` |
| XAUM.m (RWA gold, 18) | `0x8D94c619e9DF890d0f285a4529D2e6acaF65eA5A` | `0x178b01f61CBeA1D2a5581Fe1621Be607835EC349` |
| ASTOCK.m (RWA stocks, 18) | `0xC2Ce3d0B6B6e0924c718dcF9a715e5291306d52d` | `0x4C9b47Dbd5933aa4574B2c27F82419E4DBBD0222` |

The mainnet tokens were taken from the Arc docs (cirBTC, WETH) and the Arc mainnet explorer token list (the rest). Several look-alike "ASTOCK" tokens exist on mainnet; the one above is the one the explorer lists as ArcStocks.

Real assets: USDC `0x3600000000000000000000000000000000000000` (Cash) and EURC `0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a` (FX, via UniswapV4Venue). Uniswap v4: PoolManager `0x8366a39CC670B4001A1121B8F6A443A643e40951`, Quoter `0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94`, pool USDC/EURC fee 500, tick spacing 10, no hooks.

## Seed state (read back from the chain after deploy)

- 8 assets listed: USDC, EURC and the 6 mirrors above.
- 5 templates, all version 1: 0 Blue Chips (500 band), 1 Global FX (300), 2 Stable Yield (200), 3 Real Assets (500), 4 All-Weather (500). Names and descriptions only, no return claims.
- Initial prices were fetched live, once, from `https://api.geckoterminal.com/api/v2/networks/arc/tokens/<mainnet token>` right before the seed was signed (`scripts/fetch-seed-prices.ts`). All 7 fetches succeeded. Nothing was hardcoded. `observedAt` is the fetch time.
- **EURC is the one exception.** EURC trades in a real testnet pool whose price differs from mainnet by about 5% (mainnet 1.1178, pool-implied 1.1772 at seed time). With the mainnet price, every USDC to EURC buy would revert on the bucket's 1% slippage check. EURC was therefore seeded with the live price implied by the testnet pool (average of the Quoter's buy and sell sides for 1 unit). The reporter can replace it at any time.
- Roles: `0x58ca3EC7BbA9AD5258867D81e387A07C3EBA477d` is reporter on AssetRegistry and curator on TemplateRegistry. The bootstrap contract holds neither role any more.
- Ownership: `transferOwnership(0x58ca...477d)` was called on AssetRegistry and TemplateRegistry. It is two-step, so **0x58ca...477d must call `acceptOwnership()` on both** (`0x79E3...5A47` and `0xb46D...40a5`). Until then the bootstrap contract is the registered owner. It has no function that can use that ownership (see below). The other contracts (venues, factory, buckets, mirror tokens) have no owner.

## How the deploy was done (bootstrap)

The deploys went out through the Arc Studio platform deployer, which can only send constructor deployments and cannot call functions afterwards. Seeding needs owner calls, so the owner calls were carried by three small one-shot contracts:

1. `ArcTreasuryCore` deploys AssetRegistry, TemplateRegistry and MirrorVenue and owns them while they are seeded. It accepts exactly one batch of calls, signed by an ephemeral key. The key was created in the sandbox, used for one signature, and deleted. The signer is cleared when the batch runs, so `exec` now reverts `AlreadyExecuted` and the contract has no live authority.
2. `MirrorTokenBatch` deploys the six mirror tokens, all bound to the MirrorVenue (the only address that can mint or burn them).
3. `SeedRelay` submitted the signed batch (21 calls: list assets, report prices, write templates, set roles, start ownership transfer) from its constructor.

The whole flow was rehearsed first on a fork of Arc Testnet. The platform submits the fee itself; the two deploy txs I inspected used maxFeePerGas 28.86 gwei, above the 20 gwei floor.

## Trust model

- **Owner (0x58ca...477d once accepted).** On AssetRegistry: list new assets, add or remove reporters, set max staleness (60 s to 7 days). On TemplateRegistry: add or remove curators. The owner cannot move, freeze or read any user's bucket funds.
- **Reporter (0x58ca...477d).** Publishes prices and risk levels. This is the most powerful role. Prices drive every rebalance reference and the MirrorVenue's buy and sell rate, so a wrong or malicious price can make mirror trades unfair and can drain the MirrorVenue's USDC reserve (each trade is capped at 5,000 USDC). Risk level 2 blocks buys of an asset, level 3 makes every bucket sell it into USDC. Reports older than the stored one, or dated in the future, are rejected. Prices go stale after the max staleness (1 hour by default), and a stale price makes rebalances and mirror trades revert rather than trade at a wrong price.
- **Curator (0x58ca...477d).** Writes template weights, bands and descriptions. Buckets only change when their owner follows a template, and a following bucket adopts a new version at its next rebalance. A curator cannot move funds, but can change the target mix of buckets that follow a template, within listed assets.
- **Bucket owner (each user).** Sets targets, bounds, pause, SIP; deposits and withdraws any token at any time, including while paused.
- **Anyone.** Can call `rebalance()` and `executeSip()` (keeper role) and is paid a tip of min(0.05 USDC, 0.1% of bucket value) from that bucket's USDC. Anyone can top up a bucket.
- Bounds enforced in the bucket: band 100 to 2000 bps, slippage 10 to 300 bps, max trade 500 to 5000 bps, cooldown at least 600 s, at most 12 assets, SIP interval at least 3600 s and 1 to 520 runs.

## Known limits (testnet)

- **Prices expire.** The seeded prices are valid for 1 hour from their `observedAt`. After that, trades revert as stale until the reporter publishes new prices. Nothing runs the reporter automatically yet.
- **Slippage below 30 bps breaks mirror trades.** The MirrorVenue always pays 30 bps under the registry price, so a bucket with `maxSlippageBps` of 10 to 29 reverts on every mirror trade. The factory default for template buckets is 100 bps, which works.
- **MirrorVenue trade cap.** A single swap above 5,000 USDC reverts `TradeTooLarge`. A bucket worth more than roughly 20,000 USDC at the default 25% max trade would fail to rebalance mirror assets until the owner lowers `maxTradeBps`.
- **SIP catch-up.** After a long gap, `nextAt` becomes "now", so a keeper can run the remaining SIP runs back to back.
- **EURC pool vs mainnet.** EURC is priced from the testnet pool, mirrors from mainnet. Their relative prices are not a market.
- **Live smoke test: not run.** No funded deployer wallet was available (the faucet is not enabled for this account, and the platform deployer is shared and cannot sign arbitrary transactions), so I did not create a Global FX bucket or trade on the real Uniswap v4 pool. The Quoter answers on the live pool in both directions (1 USDC buys 0.846083 EURC, 1 EURC sells for 1.165253 USDC at seed time).

## Tests

`forge test`: unit, fuzz and invariant suites for the registry, mirror venue and token, template registry, bucket (deposit and withdraw, bounds, rebalance, SIP, template follow, pause), factory, Uniswap v4 venue (against a mock PoolManager) and the bootstrap contracts. Run `bun run contracts:test`.

## Scripts

- `scripts/fetch-seed-prices.ts`: fetches live mainnet prices once.
- `scripts/arc-treasury-seed.ts`: builds and signs the seed batch and rehearses the full flow on a fork.
