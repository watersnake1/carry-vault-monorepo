import { z } from "zod";
export const RiskProfile = z.enum(["conservative", "risky"]);
export type RiskProfile = z.infer<typeof RiskProfile>;
export const HypeLegDirection = z.enum(["none", "long", "short"]);
export type HypeLegDirection = z.infer<typeof HypeLegDirection>;
export interface UserPosition {
 user: `0x${string}`;
 hypeDeposit: bigint;
 hypeLegDirection: HypeLegDirection;
 allocationSplitBps: number;
 riskProfile: RiskProfile;
 termPreferenceMonths: number;
 usdcDebt: bigint;
 smoothingReserveBalance: bigint;
}
