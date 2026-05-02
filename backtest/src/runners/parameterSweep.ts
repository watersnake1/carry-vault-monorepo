import { Command } from "commander";
const program = new Command();
program
 .name("backtest")
 .description("Carry Vault strategy backtester")
 .option("--start <date>", "start date YYYY-MM-DD")
 .option("--end <date>", "end date YYYY-MM-DD")
 .option("--profile <p>", "conservative | risky", "conservative")
 .action((opts) => {
 console.log("backtest", opts);
 // TODO: load historical, run simulator, write report
 });
program.parse();