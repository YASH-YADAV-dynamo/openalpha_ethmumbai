/**
 * wagmi configuration
 * Built with Arc Studio — https://studio.arc.io
 */

import { http, createConfig } from 'wagmi'
import { mainnet } from 'wagmi/chains'
import { arcTestnet } from 'viem/chains'
import { injected } from 'wagmi/connectors'
import { registerChain } from './tracing'

// viem's arcTestnet already matches what wallet_addEthereumChain needs (checked against viem 2.57.5):
// id 5042002, RPC https://rpc.testnet.arc.io, explorer https://explorer.testnet.arc.io, native USDC with 18 decimals.

// Pre-register chain RPC URLs so trace events show correct chain names immediately
registerChain(arcTestnet.id, arcTestnet.rpcUrls.default.http[0])

export const config = createConfig({
  chains: [arcTestnet, mainnet], // mainnet needed for ENS resolution
  // EIP-6963 discovery stays on (wagmi default), so each installed extension appears as its own connector.
  // shimDisconnect remembers an explicit disconnect so a reload does not silently reconnect.
  connectors: [injected({ shimDisconnect: true })],
  transports: {
    [arcTestnet.id]: http(),
    [mainnet.id]: http(), // ENS resolution uses mainnet
  },
})
