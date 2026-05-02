import { defineChain } from "viem";
export const hyperevm = defineChain({
 id: 999,
 name: "HyperEVM",
 nativeCurrency: { name: "HYPE", symbol: "HYPE", decimals: 18 },
 rpcUrls: { default: { http: [process.env.NEXT_PUBLIC_HYPEREVM_RPC!] } },
});
export const hyperevmTestnet = defineChain({
 id: 998, // confirm against current Hyperliquid testnet docs
 name: "HyperEVM Testnet",
 nativeCurrency: { name: "HYPE", symbol: "HYPE", decimals: 18 },
 rpcUrls: { default: { http: [process.env.NEXT_PUBLIC_HYPEREVM_TESTNET_RPC!] } },
});
