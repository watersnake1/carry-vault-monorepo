import { useReadContract } from "wagmi";
import { keccak256, toBytes } from "viem";
import OracleAbi from "@/abi/OracleLayer.json";
import { ORACLE_ADDRESS } from "@/lib/wagmi";

export function useHypePrice() {
  const { data, isLoading } = useReadContract({
    address: ORACLE_ADDRESS,
    abi: OracleAbi,
    functionName: "hypePriceUsdE18",
    query: { refetchInterval: 10_000 },
  });

  // Fallback to $40 stub if oracle not yet populated
  const priceE18 = (data as bigint) ?? 40n * 10n ** 18n;
  const priceUsd = Number(priceE18) / 1e18;

  return { priceE18, priceUsd, isLoading };
}

export function useMarketData(marketName: string) {
  const marketId = keccak256(toBytes(`${marketName}-USDC`));

  const { data, isLoading } = useReadContract({
    address: ORACLE_ADDRESS,
    abi: OracleAbi,
    functionName: "getMarketData",
    args: [marketId],
    query: { refetchInterval: 10_000 },
  });

  const market = data as
    | {
        markPriceE18: bigint;
        fundingHourlyE18: bigint;
        initialMarginBps: number;
        maintenanceMarginBps: number;
        openInterestUsdE18: bigint;
        lastUpdate: bigint;
      }
    | undefined;

  if (!market) return { isLoading };

  const markPrice = Number(market.markPriceE18) / 1e18;
  const fundingHourlyPct = (Number(market.fundingHourlyE18) / 1e18) * 100;
  const fundingAnnualPct = fundingHourlyPct * 24 * 365;
  const oiUsd = Number(market.openInterestUsdE18) / 1e18;

  return {
    markPrice,
    fundingHourlyPct,
    fundingAnnualPct,
    oiUsd,
    initialMarginBps: market.initialMarginBps,
    maintenanceMarginBps: market.maintenanceMarginBps,
    lastUpdate: Number(market.lastUpdate),
    isLoading,
  };
}