cd /home/christian/Projects/carry-vault/contracts

# Use Anvil account #0 (well-known dev key)
export PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
export ADMIN=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
export ORACLE_ADMIN=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
export STRATEGY_GOVERNOR=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
export DEPLOY_MOCKS=true

forge script script/Deploy.s.sol \
    --tc Deploy \
    --rpc-url http://127.0.0.1:8545 \
    --broadcast \
    --private-key $PRIVATE_KEY
