import "dotenv/config";
import pino from "pino";
import cron from "node-cron";
const log = pino({ name: "keeper" });
async function rebalance() {
 log.info("rebalance tick");
 // TODO: oracle.refresh, riskManager.checkLtv, strategy.computeTarget,
 // positionManager.executeRotation. See Technical Spec §3.2.
}
// every 60 seconds
cron.schedule("*/60 * * * * *", () => { rebalance().catch(e => log.error(e)); });
log.info("keeper started");
