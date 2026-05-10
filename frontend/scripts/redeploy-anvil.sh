#!/bin/bash
set -e

cd ../../contracts

export PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
export ADMIN=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
export ORACLE_ADMIN=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
export STRATEGY_GOVERNOR=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
export DEPLOY_MOCKS=true

forge script script/Deploy.s.sol:Deploy \
    --rpc-url http://127.0.0.1:8545 \
    --broadcast \
    --private-key $PRIVATE_KEY \
    -vv | tee /tmp/deploy.log

# Parse the summary block (lines like "HYPE             : 0x...")
HYPE=$(grep -E "^\s*HYPE\s+:" /tmp/deploy.log | awk '{print $NF}' | tail -1)
USDC=$(grep -E "^\s*USDC\s+:" /tmp/deploy.log | awk '{print $NF}' | tail -1)
VAULT=$(grep -E "^\s*VaultCore\s+:" /tmp/deploy.log | awk '{print $NF}' | tail -1)

if [ -z "$VAULT" ]; then
    echo ""
    echo "ERROR: failed to parse addresses from /tmp/deploy.log"
    echo "Inspect /tmp/deploy.log to see what was actually printed."
    exit 1
fi

cd ../frontend

sed -i.bak "s|^NEXT_PUBLIC_VAULT_ADDRESS=.*|NEXT_PUBLIC_VAULT_ADDRESS=$VAULT|" .env.local
sed -i.bak "s|^NEXT_PUBLIC_HYPE_ADDRESS=.*|NEXT_PUBLIC_HYPE_ADDRESS=$HYPE|" .env.local
sed -i.bak "s|^NEXT_PUBLIC_USDC_ADDRESS=.*|NEXT_PUBLIC_USDC_ADDRESS=$USDC|" .env.local
rm -f .env.local.bak

./scripts/sync-abi.sh

echo ""
echo "=== Redeployed ==="
echo "HYPE:  $HYPE"
echo "USDC:  $USDC"
echo "Vault: $VAULT"
echo ""
echo "Restart Next.js dev server to pick up new addresses."