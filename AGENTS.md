# Arc Treasury

> Built with Arc Studio - money-powered apps in minutes

Project memory for future agents and humans.

## What This App Does

Per-user auto-rebalancing buckets on Arc Testnet (5042002). Each bucket is an EIP-1167 clone owned by its creator; funds are never pooled. Default template buckets (Blue Chips, Global FX, Stable Yield, Real Assets, All-Weather) plus custom buckets. Band-based `rebalance()` (sells first, then buys, `maxTradeBps` cap, slippage bound vs registry price, risk level 3 = exit to USDC) and an onchain SIP (`setSip`, `executeSip`). No performance or profit claims anywhere.

## Venues

- UniswapV4Venue: real USDC/EURC v4 pool on Arc Testnet (fee 500, tick spacing 10, no hooks).
- MirrorVenue: testnet mirror tokens (cirBTC.m, WETH.m, GBPA.m, syrupUSDC.m, XAUM.m, ASTOCK.m) priced from Arc mainnet. Always labelled as testnet mirrors.

## Prices and risk

AssetRegistry gets signed Chainlink CRE reports via `onReport` (kind 1 prices, kind 2 risk). A price older than `maxStaleness` (1 hour) blocks trading for that asset. Never invent prices. Seeded prices expire after 1 hour until the reporter publishes.

## Tech Stack

- Frontend: React 18, Vite, TypeScript, Tailwind CSS, hash routes (`#/trade/EURC`, `#/portfolio`, `#/buckets/new`, `#/buckets/<address>`)
- Web3: wagmi v2, viem v2, ConnectKit
- Contracts: Solidity 0.8.28 + Foundry in `contracts/` (do not edit or redeploy without reason). `bun run contracts:build`, `bun run contracts:test`.
- Chain: Arc Testnet, USDC ERC-20 `0x3600000000000000000000000000000000000000` (6 decimals)

## Contracts (Arc Testnet)

Addresses live in `src/lib/contracts.ts` (`ADDR`). Full table, deploy tx hashes, trust model and known limits are in `ARC.md`.

- BucketFactory `0x6677b355ca5c21c77198bfe62d223d3e8fc23875`
- BucketAccount implementation `0x97dc3f2d27e8054c982c71e40db4bce315496554`
- AssetRegistry `0x79E37808c2187B949D36c0295C7947154CD85A47`
- TemplateRegistry `0xb46DD5FA830b43031f3FF907634963F158D840a5`
- UniswapV4Venue `0x767f4a602d1944409482f57aad56fd5696586208`
- MirrorVenue `0xBaF806f5a0020F97ACB16f9f7501495b1473B7a7`
- Both registries have `0x58ca3EC7BbA9AD5258867D81e387A07C3EBA477d` as pending owner (it must call `acceptOwnership()`), reporter and curator.
- Mirror `maxSlippageBps` below 30 breaks mirror trades; MirrorVenue caps a swap at 5,000 USDC.

## Key Files

- `src/App.tsx`, `src/Shell`, `src/pages/` (Landing, Trade, Portfolio, BucketNew, BucketDetail)
- `src/components/` (bucket, landing, shell, trade), `src/lib/` (contracts, assets, market, router, tx, format)
- `scripts/fetch-seed-prices.ts`, `scripts/arc-treasury-seed.ts` (one-off seed tooling, already used)

## To Run

```bash
bun install
bun run dev
bun run check
```
