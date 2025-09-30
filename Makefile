# ============================================================
# Makefile — AaveV3MultiAssetStrategy (Sepolia)
# ============================================================

-include .env

.PHONY: \
	update build build-zk size \
	inspect selectors \
	test trace gas \
	test-zk trace-zk gas-zk \
	clean snapshot coverage \
	anvil-sepolia \
	deploy-aave-sepolia \
	exec-mint-all exec-supply-weth \
	check-env-sepolia \
	exec-borrow-token \

# ------------- Chain config (Ethereum Sepolia) -------------

SEPOLIA_CHAIN_ID      ?= 11155111
SEPOLIA_RPC_URL       ?= https://ethereum-sepolia.blockpi.network/v1/rpc/public
SEPOLIA_EXPLORER_BASE ?= https://sepolia.etherscan.io
SEPOLIA_VERIFIER_URL  ?= https://api-sepolia.etherscan.io/api

# Required env for deploy/ops
REQUIRED_ENV_SEPOLIA := DEPLOYER_PRIVATE_KEY DEFAULT_ADMIN

# Contract paths / names
CONTRACT_SRC     := src/aave-v3-yield-strategies/AaveV3MultiAssetStrategy.sol
CONTRACT_NAME    := AaveV3MultiAssetStrategy
DEPLOY_SCRIPT    := script/aave-v3-yield-strategies/DeployAaveV3MultiAssetStrategy.s.sol
EXEC_SCRIPT      := script/aave-v3-yield-strategies/ExecuteAaveV3FaucetAndSupply.s.sol

# Deploy report paths (for optional extensions)
REPORT_DIR       ?= reports
REPORT_LATEST    ?= $(REPORT_DIR)/deployment-$(SEPOLIA_CHAIN_ID).json

# ------------- Helpers -------------

check-env-sepolia:
	@set -a; [ -f .env ] && . ./.env; set +a; \
	for var in $(REQUIRED_ENV_SEPOLIA); do \
	  if [ -z "$${!var}" ]; then echo "Missing env: $$var"; exit 1; fi; \
	done

# ------------- Build & Inspect -------------

update: ; forge update

build:  ; forge build
build-zk: ; FOUNDRY_PROFILE=zksync forge build --zksync

size:   ; forge build --sizes

inspect:   ; forge inspect ${CONTRACT_NAME} storage-layout --pretty
selectors: ; forge inspect ${CONTRACT_NAME} methods --pretty

# ------------- Test -------------

test:      ; forge test -vvv
trace:     ; forge test -vvvv
gas:       ; forge test --gas-report

test-zk:   ; FOUNDRY_PROFILE=zksync forge test --zksync --suppress-warnings -vvv
trace-zk:  ; FOUNDRY_PROFILE=zksync forge test --zksync --suppress-warnings -vvvv
gas-zk:    ; FOUNDRY_PROFILE=zksync forge test --zksync --suppress-warnings --gas-report

snapshot:  ; forge snapshot
coverage:  ; forge coverage
clean:     ; forge clean

# ------------- Local dev -------------

anvil-sepolia: ; anvil -m 'test test test test test test test test test test test junk' --chain-id 11155111 --fork-url $(SEPOLIA_RPC_URL) --steps-tracing --block-time 1

# ------------- Deploy -------------

deploy-aave-sepolia: check-env-sepolia
	@echo "Deploying $(CONTRACT_NAME) to Ethereum Sepolia @ $(SEPOLIA_RPC_URL)"; \
	set -a; [ -f .env ] && . ./.env; set +a; \
	forge script $(DEPLOY_SCRIPT) \
		--rpc-url $(SEPOLIA_RPC_URL) \
		--private-key $(DEPLOYER_PRIVATE_KEY) \
		--broadcast \
		--verify --etherscan-api-key ${ETHERSCAN_API_KEY} \
		-vvvv

# ------------- Execution (ops) -------------

## Mint all test assets (USDC, WBTC, DAI, LINK, WETH) via Aave Faucet
exec-mint-all:
	@echo "Minting all test tokens from Aave Sepolia faucet"; \
	set -a; [ -f .env ] && . ./.env; set +a; \
	forge script $(EXEC_SCRIPT) \
		--sig "mintAll()" \
		--rpc-url $(SEPOLIA_RPC_URL) \
		--private-key $(DEPLOYER_PRIVATE_KEY) \
		--broadcast \
		-vvvv

# ------------- AaveV3SepoliaAssets -------------
WETH_TOKEN := 0xC558DBdd856501FCd9aaF1E62eae57A9F0629a3c   # Aave Sepolia WETH
WBTC_TOKEN := 0x29f2D40B0605204364af54EC677bD022dA425d03   # Aave Sepolia WBTC
USDC_TOKEN := 0x94a9D9AC8a22534E3FaCa9F4e7F2E2cf85d5E4C8   # Aave Sepolia USDC
DAI_TOKEN  := 0xFF34B3d4Aee8ddCd6F9AFFFB6Fe49bD371b8a357   # Aave Sepolia DAI
LINK_TOKEN := 0xf8Fb3713D459D7C1018BD0A49D19b4C44290EBE5   # Aave Sepolia LINK

## Generic: supply any token
## Usage: make exec-supply-token TOKEN=0x... AMOUNT=<uint256> [REFERRAL=0] [SETCOLLATERAL=0]
exec-supply-token:
	@if [ -z "$(TOKEN)" ] || [ -z "$(AMOUNT)" ]; then \
		echo "Usage: make exec-supply-token TOKEN=0x<addr> AMOUNT=<uint256> [REFERRAL=0] [SETCOLLATERAL=0]"; \
		exit 1; \
	fi
	@REFERRAL=$${REFERRAL:-0}; \
	SETCOLLATERAL=$${SETCOLLATERAL:-0}; \
	echo "Supplying token $(TOKEN), amount=$(AMOUNT), referral=$$REFERRAL, setCollateral=$$SETCOLLATERAL"; \
	set -a; [ -f .env ] && . ./.env; set +a; \
	forge script $(EXEC_SCRIPT) \
		--sig "supplyToken(address,uint256,uint16,bool)" $(TOKEN) $(AMOUNT) $$REFERRAL $$SETCOLLATERAL \
		--rpc-url $(SEPOLIA_RPC_URL) \
		--private-key $(DEPLOYER_PRIVATE_KEY) \
		--broadcast \
		-vvvv

## Convenience wrappers (so you only pass AMOUNT/flags)
## WETH: 18 decimals; WBTC: 8; USDC: 6; DAI/LINK: 18
exec-supply-weth:
	@if [ -z "$(AMOUNT)" ]; then echo "Usage: make exec-supply-weth AMOUNT=<uint256> [REFERRAL=0] [SETCOLLATERAL=0]"; exit 1; fi
	@$(MAKE) exec-supply-token TOKEN=$(WETH_TOKEN) AMOUNT=$(AMOUNT) REFERRAL=$${REFERRAL:-0} SETCOLLATERAL=$${SETCOLLATERAL:-0}

## make exec-supply-wbtc AMOUNT=1000000000000 REFERRAL=0 SETCOLLATERAL=true
exec-supply-wbtc:
	@if [ -z "$(AMOUNT)" ]; then echo "Usage: make exec-supply-wbtc AMOUNT=<uint256> [REFERRAL=0] [SETCOLLATERAL=0]"; exit 1; fi
	@$(MAKE) exec-supply-token TOKEN=$(WBTC_TOKEN) AMOUNT=$(AMOUNT) REFERRAL=$${REFERRAL:-0} SETCOLLATERAL=$${SETCOLLATERAL:-0}

exec-supply-usdc:
	@if [ -z "$(AMOUNT)" ]; then echo "Usage: make exec-supply-usdc AMOUNT=<uint256> [REFERRAL=0] [SETCOLLATERAL=0]"; exit 1; fi
	@$(MAKE) exec-supply-token TOKEN=$(USDC_TOKEN) AMOUNT=$(AMOUNT) REFERRAL=$${REFERRAL:-0} SETCOLLATERAL=$${SETCOLLATERAL:-0}

exec-supply-dai:
	@if [ -z "$(AMOUNT)" ]; then echo "Usage: make exec-supply-dai AMOUNT=<uint256> [REFERRAL=0] [SETCOLLATERAL=0]"; exit 1; fi
	@$(MAKE) exec-supply-token TOKEN=$(DAI_TOKEN) AMOUNT=$(AMOUNT) REFERRAL=$${REFERRAL:-0} SETCOLLATERAL=$${SETCOLLATERAL:-0}

exec-supply-link:
	@if [ -z "$(AMOUNT)" ]; then echo "Usage: make exec-supply-link AMOUNT=<uint256> [REFERRAL=0] [SETCOLLATERAL=0]"; exit 1; fi
	@$(MAKE) exec-supply-token TOKEN=$(LINK_TOKEN) AMOUNT=$(AMOUNT) REFERRAL=$${REFERRAL:-0} SETCOLLATERAL=$${SETCOLLATERAL:-0}

## Borrow any allowed token using strategy’s approxMaxBorrow (with built-in 90% buffer)
## Usage: make exec-borrow-token TOKEN=0x... [REFERRAL=0]
exec-borrow-token:
	@if [ -z "$(TOKEN)" ]; then \
		echo "Usage: make exec-borrow-token TOKEN=0x<addr> [REFERRAL=0]"; \
		exit 1; \
	fi
	@REFERRAL=$${REFERRAL:-0}; \
	echo "Borrowing token $(TOKEN) with referral=$$REFERRAL"; \
	set -a; [ -f .env ] && . ./.env; set +a; \
	forge script $(EXEC_SCRIPT) \
		--sig "borrowToken(address,uint16)" $(TOKEN) $$REFERRAL \
		--rpc-url $(SEPOLIA_RPC_URL) \
		--private-key $(DEPLOYER_PRIVATE_KEY) \
		--broadcast \
		-vvvv

## Convenience wrappers
exec-borrow-wbtc: ; $(MAKE) exec-borrow-token TOKEN=$(WBTC_TOKEN) REFERRAL=$${REFERRAL:-0}
exec-borrow-usdc: ; $(MAKE) exec-borrow-token TOKEN=$(USDC_TOKEN) REFERRAL=$${REFERRAL:-0}
exec-borrow-dai:  ; $(MAKE) exec-borrow-token TOKEN=$(DAI_TOKEN)  REFERRAL=$${REFERRAL:-0}
exec-borrow-link: ; $(MAKE) exec-borrow-token TOKEN=$(LINK_TOKEN) REFERRAL=$${REFERRAL:-0}

## Repay ALL variable debt for a token via script
## Usage: make exec-repay-all TOKEN=0x...
## Example (use predefined constants if present):
##   make exec-repay-all TOKEN=$(USDC_TOKEN)
exec-repay-all:
	@if [ -z "$(TOKEN)" ]; then \
		echo "Usage: make exec-repay-all TOKEN=0x<addr>"; \
		exit 1; \
	fi
	@echo "Repaying ALL variable debt for TOKEN=$(TOKEN) on Sepolia"; \
	set -a; [ -f .env ] && . ./.env; set +a; \
	forge script $(EXEC_SCRIPT) \
		--sig "repayAllDebt(address)" $(TOKEN) \
		--rpc-url $(SEPOLIA_RPC_URL) \
		--private-key $(DEPLOYER_PRIVATE_KEY) \
		--broadcast \
		-vvvv
