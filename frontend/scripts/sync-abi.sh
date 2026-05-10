#!/bin/bash
mkdir -p src/abi
jq '.abi' ../contracts/out/VaultCore.sol/VaultCore.json > src/abi/VaultCore.json
echo "Synced VaultCore.abi to src/abi/VaultCore.json"
jq '.abi' ../contracts/out/VaultCore.sol/VaultCore.json    > src/abi/VaultCore.json
jq '.abi' ../contracts/out/OracleLayer.sol/OracleLayer.json > src/abi/OracleLayer.json
echo "synced"
#jq '.abi' ../contracts/out/VaultCore.sol/VaultCore.json   > src/abi/VaultCore.json
#jq '.abi' ../contracts/out/RiskManager.sol/RiskManager.json > src/abi/RiskManager.json
#jq '.abi' ../contracts/out/OracleLayer.sol/OracleLayer.json > src/abi/OracleLayer.json
#echo "Synced ABIs."
