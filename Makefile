-include .env

.PHONY: deploy

deploy :; forge script script/DeployDTsla.s.sol --sender 0x50e80fd1a15e2957954a4C23769B5745f3B20B64 --account defaultKey --rpc-url ${SEPOLIA_RPC_URL} --etherscan-api-key ${ETHERSCAN_API_KEY} --verify --broadcast