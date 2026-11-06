# Arc Treasury

Per-user auto-rebalancing "buckets" on Arc Testnet (chain ID 5042002), with an onchain recurring buy (SIP).

Built with [Arc Studio](https://studio.arc.io)

Testnet only. Mirror assets are priced from Arc mainnet and are not the real assets. Not investment advice.

## What it does

- Each bucket is its own EIP-1167 clone owned by the user who created it. Funds are never pooled between users.
- Start from a default template bucket (Blue Chips, Global FX, Stable Yield, Real Assets, All-Weather) or build a custom one.
- Rebalance: when an asset drifts past the bucket's band, anyone can call `rebalance()`. It sells overweight assets first, then buys underweight ones. Each trade is capped by `maxTradeBps` and bounded by a slippage limit against the registry price. A risk level 3 asset is sold into USDC.
- SIP: the owner sets a recurring USDC buy. Anyone can trigger `executeSip()` when it is due.
- Owners can withdraw at any time, including while a bucket is paused.

## Venues

- Real Uniswap v4 USDC/EURC pool on Arc Testnet.
- MirrorVenue for testnet mirror tokens (cirBTC.m, WETH.m, GBPA.m, syrupUSDC.m, XAUM.m, ASTOCK.m). They trade at Arc mainnet prices and are labelled as testnet mirrors in the app.

## Prices and risk flags

A Chainlink CRE workflow writes signed reports to `AssetRegistry.onReport` (kind 1 prices, kind 2 risk levels). A price older than 1 hour blocks trading for that asset. The app never invents a price.

## Contracts

Addresses are in `src/lib/contracts.ts` (`ADDR`). Details, trust model and known limits are in `ARC.md`.

- CreReceiver — ERC-165 adapter that relays Chainlink CRE forwarder reports into AssetRegistry.onReport (registry owner authorizes it via setReporter).

## Tech stack

Solidity 0.8.28 and Foundry; React, Vite, TypeScript, Tailwind, wagmi and viem. Routes are hash-based: `#/trade/EURC`, `#/portfolio`, `#/buckets/new`, `#/buckets/<address>`.

## Development

Prerequisites: [Bun](https://bun.sh) and [Foundry](https://book.getfoundry.sh).

```bash
bun install
bun run dev               # app on http://localhost:5173
bun run check             # lint + typecheck
bun run contracts:build   # forge build
bun run contracts:test    # forge test
```

## Environment variables

- `RPC_PROXY_BASE_URL`, `RPC_PROXY_TOKEN`: optional outside Arc Studio. Used only by helper scripts in `scripts/`.
