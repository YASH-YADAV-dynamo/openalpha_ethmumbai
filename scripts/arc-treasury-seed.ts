// Builds and signs the one-time seed batch for ArcTreasuryCore, and rehearses the whole flow on an anvil fork.
//   bun scripts/arc-treasury-seed.ts signer        -> creates an ephemeral signer, prints its address only
//   bun scripts/arc-treasury-seed.ts relay-args    -> reads /tmp/arc-stage.json, signs, writes /tmp/relay-args.json
//   FORK_RPC=http://127.0.0.1:8545 bun scripts/arc-treasury-seed.ts rehearse
import fs from 'fs';
import {
  type Address, type Hex, createPublicClient, createWalletClient, encodeAbiParameters, encodeDeployData,
  encodeFunctionData, getAddress, http, keccak256, parseAbi,
} from 'viem';
import { generatePrivateKey, privateKeyToAccount } from 'viem/accounts';

const USDC: Address = '0x3600000000000000000000000000000000000000';
const EURC: Address = '0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a';
const QUOTER: Address = '0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94';
const ROLE_HOLDER: Address = '0x58ca3EC7BbA9AD5258867D81e387A07C3EBA477d';
const SIGNER_FILE = '/tmp/arc-seed-signer.key';
const STAGE_FILE = '/tmp/arc-stage.json';
const GAS = { maxFeePerGas: 40_000_000_000n, maxPriorityFeePerGas: 1_000_000_000n };

const art = (n: string) => JSON.parse(fs.readFileSync(`/home/user/app/contracts/out/${n}.sol/${n}.json`, 'utf8'));
const liveRpc = () => `${process.env.RPC_PROXY_BASE_URL}/api/rpc/Arc_Testnet?_rpc_token=${process.env.RPC_PROXY_TOKEN}`;
const redact = (s: string) => s.replace(/_rpc_token=[A-Za-z0-9._-]+/g, '_rpc_token=REDACTED');

// Category enum: Cash 0, FX 1, Crypto 2, Yield 3, RWA 4. Order matches MirrorTokenBatch.
const MIRRORS = [
  { symbol: 'cirBTC.m', category: 2, decimals: 8, ref: '0x171A4217b86A807A64eB94757Db6849fb4bDbAA0', priceKey: 'cirBTC.m' },
  { symbol: 'WETH.m', category: 2, decimals: 18, ref: '0x128cC466B61f542da60c70e3aA11c10e19B84EDB', priceKey: 'WETH.m' },
  { symbol: 'GBPA.m', category: 1, decimals: 6, ref: '0xbBe6aAB0Ed76e90AeA0d1cd978EC231c8AdCDF8b', priceKey: 'GBPA.m' },
  { symbol: 'syrupUSDC.m', category: 3, decimals: 6, ref: '0x0dC6b79F3c3854E4d74514fD4d29BE6c96Beee39', priceKey: 'syrupUSDC.m' },
  { symbol: 'XAUM.m', category: 4, decimals: 18, ref: '0x178b01f61CBeA1D2a5581Fe1621Be607835EC349', priceKey: 'XAUM.m' },
  { symbol: 'ASTOCK.m', category: 4, decimals: 18, ref: '0x4C9b47Dbd5933aa4574B2c27F82419E4DBBD0222', priceKey: 'ASTOCK.m' },
] as const;

interface BatchInput {
  core: Address; registry: Address; templates: Address; mirrorVenue: Address; v4Venue: Address;
  tokens: Address[]; chainId: number; observedAt: number; eurcE8: bigint; mirrorPricesE8: bigint[];
}

function buildBatch(i: BatchInput) {
  const R = art('AssetRegistry').abi;
  const T = art('TemplateRegistry').abi;
  const targets: Address[] = [];
  const datas: Hex[] = [];
  const reg = (fn: string, args: unknown[]) => { targets.push(i.registry); datas.push(encodeFunctionData({ abi: R, functionName: fn, args })); };
  const tpl = (fn: string, args: unknown[]) => { targets.push(i.templates); datas.push(encodeFunctionData({ abi: T, functionName: fn, args })); };

  reg('listAsset', [{ token: EURC, symbol: 'EURC', category: 1, decimals: 6, venue: i.v4Venue, mirror: false, mainnetRef: '' }]);
  MIRRORS.forEach((m, k) => reg('listAsset', [{
    token: i.tokens[k], symbol: m.symbol, category: m.category, decimals: m.decimals, venue: i.mirrorVenue, mirror: true, mainnetRef: m.ref,
  }]));

  // Prices: a zero price means the live fetch failed, so that asset stays unpriced and trading stays disabled.
  const priced: { token: Address; price: bigint }[] = [];
  if (i.eurcE8 > 0n) priced.push({ token: EURC, price: i.eurcE8 });
  MIRRORS.forEach((_, k) => { if (i.mirrorPricesE8[k] > 0n) priced.push({ token: i.tokens[k], price: i.mirrorPricesE8[k] }); });
  reg('setReporter', [i.core, true]);
  if (priced.length > 0) {
    const payload = encodeAbiParameters(
      [{ type: 'address[]' }, { type: 'uint256[]' }, { type: 'uint64' }],
      [priced.map((p) => p.token), priced.map((p) => p.price), BigInt(i.observedAt)],
    );
    reg('onReport', ['0x', encodeAbiParameters([{ type: 'uint8' }, { type: 'bytes' }], [1, payload])]);
  }
  reg('setReporter', [i.core, false]);
  reg('setReporter', [ROLE_HOLDER, true]);

  const [btc, eth, gbp, syrup, xau, stock] = i.tokens;
  const templates: { name: string; description: string; tokens: Address[]; weights: number[]; band: number }[] = [
    { name: 'Blue Chips', description: 'An even split between a Bitcoin mirror and an Ether mirror. Rebalances when either drifts past the band.',
      tokens: [btc, eth], weights: [5000, 5000], band: 500 },
    { name: 'Global FX', description: 'Dollars, euros and a pound mirror held in a fixed mix. Rebalances when the mix drifts past the band.',
      tokens: [USDC, EURC, gbp], weights: [4000, 4000, 2000], band: 300 },
    { name: 'Stable Yield', description: 'Half dollars, half a yield-bearing dollar mirror. Rebalances when the split drifts past the band.',
      tokens: [USDC, syrup], weights: [5000, 5000], band: 200 },
    { name: 'Real Assets', description: 'A gold mirror, a tokenized-stocks mirror and dollars in a fixed mix. Rebalances past the band.',
      tokens: [xau, stock, USDC], weights: [5000, 3000, 2000], band: 500 },
    { name: 'All-Weather', description: 'A spread across crypto, gold, euros and a yield-bearing dollar mirror. Rebalances past the band.',
      tokens: [btc, eth, xau, EURC, syrup], weights: [2500, 1500, 2000, 2000, 2000], band: 500 },
  ];
  tpl('setCurator', [i.core, true]);
  templates.forEach((t, id) => tpl('setTemplate', [BigInt(id), {
    name: t.name, description: t.description, tokens: t.tokens, weightsBps: t.weights, bandBps: t.band, version: 0,
    rationaleHash: keccak256(`0x${Buffer.from(t.description).toString('hex')}`),
  }]));
  tpl('setCurator', [i.core, false]);
  tpl('setCurator', [ROLE_HOLDER, true]);
  reg('transferOwnership', [ROLE_HOLDER]);
  tpl('transferOwnership', [ROLE_HOLDER]);
  return { targets, datas, pricedCount: priced.length };
}

async function sign(core: Address, chainId: number, targets: Address[], datas: Hex[]) {
  const account = privateKeyToAccount(fs.readFileSync(SIGNER_FILE, 'utf8').trim() as Hex);
  const digest = keccak256(encodeAbiParameters(
    [{ type: 'uint256' }, { type: 'address' }, { type: 'address[]' }, { type: 'bytes[]' }],
    [BigInt(chainId), core, targets, datas],
  ));
  return account.signMessage({ message: { raw: digest } });
}

function ensureSigner(): Address {
  if (!fs.existsSync(SIGNER_FILE)) fs.writeFileSync(SIGNER_FILE, generatePrivateKey(), { mode: 0o600 });
  return privateKeyToAccount(fs.readFileSync(SIGNER_FILE, 'utf8').trim() as Hex).address;
}

/** USD per EURC implied by the live USDC/EURC pool: average of the buy side and the sell side (8 decimals). */
async function poolEurcPriceE8(c: ReturnType<typeof createPublicClient>): Promise<bigint> {
  const abi = parseAbi(['function quoteExactInputSingle(((address,address,uint24,int24,address) poolKey,bool zeroForOne,uint128 exactAmount,bytes hookData) p) returns (uint256 amountOut, uint256 gasEstimate)']);
  const key = [USDC, EURC, 500, 10, '0x0000000000000000000000000000000000000000'] as const;
  const q = async (zeroForOne: boolean) => ((await c.simulateContract({
    address: QUOTER, abi, functionName: 'quoteExactInputSingle',
    args: [{ poolKey: key, zeroForOne, exactAmount: 1_000_000n, hookData: '0x' }],
  })).result)[0];
  const buyOut = await q(true);
  const sellOut = await q(false);
  return (10n ** 14n / buyOut + sellOut * 100n) / 2n;
}

async function assemble(
  c: ReturnType<typeof createPublicClient>, quoteClient: ReturnType<typeof createPublicClient>,
  core: Address, tokenBatch: Address, v4Venue: Address,
) {
  const coreAbi = art('ArcTreasuryCore').abi;
  const rd = <T,>(address: Address, abi: unknown, functionName: string, args: unknown[] = []) =>
    c.readContract({ address, abi, functionName, args } as never) as Promise<T>;
  const [registry, templates, mirrorVenue] = await Promise.all([
    rd<Address>(core, coreAbi, 'registry'), rd<Address>(core, coreAbi, 'templates'), rd<Address>(core, coreAbi, 'mirrorVenue'),
  ]);
  const batchAbi = art('MirrorTokenBatch').abi;
  const tokens = await Promise.all([0, 1, 2, 3, 4, 5].map((k) => rd<Address>(tokenBatch, batchAbi, 'tokens', [BigInt(k)])));
  const seed = JSON.parse(fs.readFileSync('/tmp/seed-prices.json', 'utf8')) as {
    fetchedAt: number; prices: Record<string, { priceE8: string }>;
  };
  const blk = await c.getBlock();
  const chainId = await c.getChainId();
  const eurcE8 = await poolEurcPriceE8(quoteClient);
  const observedAt = Math.min(Number(seed.fetchedAt), Number(blk.timestamp) - 5);
  const mirrorPricesE8 = MIRRORS.map((m) => BigInt(seed.prices[m.priceKey]?.priceE8 ?? '0'));
  const batch = buildBatch({ core, registry, templates, mirrorVenue, v4Venue, tokens, chainId, observedAt, eurcE8, mirrorPricesE8 });
  const sig = await sign(core, chainId, batch.targets, batch.datas);
  return { registry, templates, mirrorVenue, tokens, observedAt, eurcE8, mainnetEurcE8: seed.prices.EURC?.priceE8, ...batch, sig };
}

async function main() {
  const cmd = process.argv[2];
  if (cmd === 'signer') { console.log(ensureSigner()); return; }

  if (cmd === 'relay-args') {
    const st = JSON.parse(fs.readFileSync(STAGE_FILE, 'utf8')) as { core: Address; tokenBatch: Address; v4Venue: Address };
    const c = createPublicClient({ transport: http(liveRpc()) });
    const r = await assemble(c, c, st.core, st.tokenBatch, st.v4Venue);
    fs.writeFileSync('/tmp/relay-args.json', JSON.stringify([st.core, r.targets, r.datas, r.sig]));
    fs.rmSync(SIGNER_FILE); // the signature is the only thing the signer was for
    console.log(JSON.stringify({ calls: r.targets.length, priced: r.pricedCount, observedAt: r.observedAt, eurcPoolE8: r.eurcE8.toString(), eurcMainnetE8: r.mainnetEurcE8 }));
    return;
  }

  if (cmd === 'rehearse') {
    const url = process.env.FORK_RPC ?? 'http://127.0.0.1:8545';
    const account = privateKeyToAccount('0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80');
    const pub = createPublicClient({ transport: http(url) });
    const wal = createWalletClient({ account, transport: http(url) });
    const live = createPublicClient({ transport: http(liveRpc()) });
    const deploy = async (name: string, args: unknown[] = []) => {
      const a = art(name);
      const data = encodeDeployData({ abi: a.abi, bytecode: a.bytecode.object, args });
      const gas = await pub.estimateGas({ account, data, ...GAS });
      console.log(name, 'gas estimate', gas.toString());
      const hash = await wal.sendTransaction({ chain: null, data, gas: gas * 12n / 10n, ...GAS });
      const rc = await pub.waitForTransactionReceipt({ hash });
      if (rc.status !== 'success' || !rc.contractAddress) throw new Error(`${name} deploy failed`);
      console.log(name, 'gas used', rc.gasUsed.toString());
      return getAddress(rc.contractAddress);
    };
    const v4Venue = getAddress('0x767f4a602d1944409482f57aad56fd5696586208');
    const signerAddr = ensureSigner();
    const core = await deploy('ArcTreasuryCore', [USDC, signerAddr]);
    const venue = (await pub.readContract({ address: core, abi: art('ArcTreasuryCore').abi, functionName: 'mirrorVenue' })) as Address;
    const tokenBatch = await deploy('MirrorTokenBatch', [venue]);
    const r = await assemble(pub, live, core, tokenBatch, v4Venue);
    console.log('batch calls', r.targets.length, 'priced', r.pricedCount);
    const relay = await deploy('SeedRelay', [core, r.targets, r.datas, r.sig]);
    const impl = getAddress('0x97dc3f2d27e8054c982c71e40db4bce315496554');
    const factory = await deploy('BucketFactory', [impl, r.registry, r.templates]);

    // Verify state
    const R = art('AssetRegistry').abi; const T = art('TemplateRegistry').abi;
    const rd = <X,>(address: Address, abi: unknown, functionName: string, args: unknown[] = []) => pub.readContract({ address, abi, functionName, args } as never) as Promise<X>;
    const assets = await rd<Address[]>(r.registry, R, 'assets');
    const checks: [string, boolean][] = [
      ['8 assets listed', assets.length === 8],
      ['signer cleared', (await rd<Address>(core, art('ArcTreasuryCore').abi, 'signer')) === '0x0000000000000000000000000000000000000000'],
      ['registry pending owner', (await rd<Address>(r.registry, R, 'pendingOwner')) === ROLE_HOLDER],
      ['templates pending owner', (await rd<Address>(r.templates, T, 'pendingOwner')) === ROLE_HOLDER],
      ['core still owner until accepted', (await rd<Address>(r.registry, R, 'owner')) === core],
      ['reporter set', await rd<boolean>(r.registry, R, 'isReporter', [ROLE_HOLDER])],
      ['core not reporter', !(await rd<boolean>(r.registry, R, 'isReporter', [core]))],
      ['curator set', await rd<boolean>(r.templates, T, 'isCurator', [ROLE_HOLDER])],
      ['core not curator', !(await rd<boolean>(r.templates, T, 'isCurator', [core]))],
      ['5 templates', (await rd<bigint>(r.templates, T, 'templateCount')) === 5n],
    ];
    for (const [k, t] of r.tokens.entries()) {
      const p = await rd<readonly [bigint, bigint]>(r.registry, R, 'priceE8', [t]);
      checks.push([`${MIRRORS[k].symbol} priced`, p[0] === r.mirrorPricesE8?.[k] || p[0] > 0n]);
    }
    const eurc = await rd<readonly [bigint, bigint]>(r.registry, R, 'priceE8', [EURC]);
    checks.push(['EURC priced', eurc[0] === r.eurcE8]);
    let bad = 0;
    for (const [k, ok] of checks) { console.log(ok ? 'PASS' : 'FAIL', k); if (!ok) bad++; }
    console.log({ core, tokenBatch, relay, factory, registry: r.registry, templates: r.templates, mirrorVenue: venue });
    fs.rmSync(SIGNER_FILE, { force: true });
    if (bad) throw new Error(`${bad} checks failed`);
    return;
  }
  throw new Error('usage: signer | relay-args | rehearse');
}

main().catch((e) => { console.error(redact(String(e?.shortMessage ?? e?.message ?? e))); process.exit(1); });
