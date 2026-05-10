import { getDefaultConfig } from "@rainbow-me/rainbowkit";
import { defineChain } from "viem";

const isLocal = process.env.NEXT_PUBLIC_USE_ANVIL === "true";

export const anvilChain = defineChain({
  id: 31337,
  name: "Anvil",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: ["http://127.0.0.1:8545"] } },
  testnet: true,
});

export const hyperEvmTestnet = defineChain({
  id: Number(process.env.NEXT_PUBLIC_CHAIN_ID ?? 998),
  name: "HyperEVM Testnet",
  nativeCurrency: { name: "HYPE", symbol: "HYPE", decimals: 18 },
  rpcUrls: { default: { http: [process.env.NEXT_PUBLIC_RPC_URL ?? ""] } },
  testnet: true,
});

export const wagmiConfig = getDefaultConfig({
  appName: "Carry Vault",
  projectId: process.env.NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID!,
  chains: isLocal ? [anvilChain] : [hyperEvmTestnet],
  ssr: true,
});

export const VAULT_ADDRESS = process.env.NEXT_PUBLIC_VAULT_ADDRESS as `0x${string}`;
export const HYPE_ADDRESS  = process.env.NEXT_PUBLIC_HYPE_ADDRESS  as `0x${string}`;
export const USDC_ADDRESS  = process.env.NEXT_PUBLIC_USDC_ADDRESS  as `0x${string}`;
export const ORACLE_ADDRESS = process.env.NEXT_PUBLIC_ORACLE_ADDRESS as `0x${string}`;