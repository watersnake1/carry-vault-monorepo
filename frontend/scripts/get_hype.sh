set -e 
set -a
source ../.env.local
set +a

# Mint 1000 HYPE to your connected wallet
cast send $NEXT_PUBLIC_HYPE_ADDRESS \
    "mint(address,uint256)" \
    0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 \
    1000000000000000000000 \
    --rpc-url http://127.0.0.1:8545 \
    --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

# Same for USDC if needed (1000 USDC at 6 decimals)
cast send $NEXT_PUBLIC_USDC_ADDRESS \
    "mint(address,uint256)" \
    0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 \
    1000000000 \
    --rpc-url http://127.0.0.1:8545 \
    --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80