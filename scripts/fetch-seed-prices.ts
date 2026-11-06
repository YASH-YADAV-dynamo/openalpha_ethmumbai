// Fetches live mainnet USD prices once, for the initial Arc Treasury seed. Never guesses: a failed fetch stays 0.
// Usage: bun scripts/fetch-seed-prices.ts > /tmp/seed-prices.json
const TOKENS: { key: string; mainnet: string }[] = [
  { key: 'EURC', mainnet: '0xbEf5f6d51CB62b58e6A8f77868681825C6fe21c1' },
  { key: 'cirBTC.m', mainnet: '0x171A4217b86A807A64eB94757Db6849fb4bDbAA0' },
  { key: 'WETH.m', mainnet: '0x128cC466B61f542da60c70e3aA11c10e19B84EDB' },
  { key: 'GBPA.m', mainnet: '0xbBe6aAB0Ed76e90AeA0d1cd978EC231c8AdCDF8b' },
  { key: 'syrupUSDC.m', mainnet: '0x0dC6b79F3c3854E4d74514fD4d29BE6c96Beee39' },
  { key: 'XAUM.m', mainnet: '0x178b01f61CBeA1D2a5581Fe1621Be607835EC349' },
  { key: 'ASTOCK.m', mainnet: '0x4C9b47Dbd5933aa4574B2c27F82419E4DBBD0222' },
];

/** Decimal string -> integer with 8 decimals, truncating extra digits. */
function toE8(s: string): bigint {
  const m = /^(\d+)(?:\.(\d+))?$/.exec(s.trim());
  if (!m) return 0n;
  return BigInt(m[1]) * 10n ** 8n + BigInt((m[2] ?? '').padEnd(8, '0').slice(0, 8));
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const out: Record<string, { mainnet: string; priceUsd: string | null; priceE8: string }> = {};

for (const t of TOKENS) {
  let price: string | null = null;
  for (let attempt = 0; attempt < 5 && !price; attempt++) {
    try {
      const r = await fetch(`https://api.geckoterminal.com/api/v2/networks/arc/tokens/${t.mainnet}`);
      if (r.ok) {
        const j = (await r.json()) as { data?: { attributes?: { price_usd?: string | null } } };
        price = j.data?.attributes?.price_usd ?? null;
        break;
      }
      await sleep(8000 * (attempt + 1));
    } catch {
      await sleep(4000);
    }
  }
  const e8 = price ? toE8(price) : 0n;
  out[t.key] = { mainnet: t.mainnet, priceUsd: price, priceE8: e8.toString() };
  await sleep(3000);
}
console.log(JSON.stringify({ fetchedAt: Math.floor(Date.now() / 1000), prices: out }, null, 2));
