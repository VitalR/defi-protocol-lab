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
	exec-simulate-liq \
	exec-create-risky \
	exec-liquidate \
	exec-flashloan \
	exec-open-long exec-open-short exec-close

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
LIQ_SCRIPT 		 := script/aave-v3-yield-strategies/LiquidationPlayground.s.sol
FLASH_SCRIPT     := script/aave-v3-yield-strategies/flashloan/ExecuteFlashLoan.s.sol

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

## Repay an exact AMOUNT of variable debt
## Usage: make exec-repay-amount TOKEN=0x... AMOUNT=12345
exec-repay-amount:
	@if [ -z "$(TOKEN)" ] || [ -z "$(AMOUNT)" ]; then \
		echo "Usage: make exec-repay-amount TOKEN=0x<addr> AMOUNT=<uint256>"; \
		exit 1; \
	fi
	@echo "Repaying AMOUNT=$(AMOUNT) for TOKEN=$(TOKEN) on Sepolia"; \
	set -a; [ -f .env ] && . ./.env; set +a; \
	forge script $(EXEC_SCRIPT) \
		--sig "repayAmount(address,uint256)" $(TOKEN) $(AMOUNT) \
		--rpc-url $(SEPOLIA_RPC_URL) \
		--private-key $(DEPLOYER_PRIVATE_KEY) \
		--broadcast \
		-vvvv

## Repay ALL variable debt for a token via the exec script
## Usage: make exec-repay-all-token TOKEN=0x...
exec-repay-all-token:
	@if [ -z "$(TOKEN)" ]; then echo "Usage: make exec-repay-all-token TOKEN=0x<addr>"; exit 1; fi
	@echo "Repaying ALL variable debt for token $(TOKEN)"
	@set -a; [ -f .env ] && . ./.env; set +a; \
	forge script $(EXEC_SCRIPT) \
		--sig "repayAllToken(address)" $(TOKEN) \
		--rpc-url $(SEPOLIA_RPC_URL) \
		--private-key $(DEPLOYER_PRIVATE_KEY) \
		--broadcast \
		-vvvv

## Withdraw ALL of a supplied token via the strategy
## Usage: make exec-withdraw-all TOKEN=0x...
exec-withdraw-all:
	@if [ -z "$(TOKEN)" ]; then \
		echo "Usage: make exec-withdraw-all TOKEN=0x<addr>"; \
		exit 1; \
	fi
	@echo "Withdrawing ALL underlying for TOKEN=$(TOKEN) on Sepolia"; \
	set -a; [ -f .env ] && . ./.env; set +a; \
	forge script $(EXEC_SCRIPT) \
		--sig "withdrawAllToken(address)" $(TOKEN) \
		--rpc-url $(SEPOLIA_RPC_URL) \
		--private-key $(DEPLOYER_PRIVATE_KEY) \
		--broadcast \
		-vvvv

# ---------- Simulate liquidation math for a user ----------
## Usage:
##   make exec-simulate-liq COLL=$(WBTC_TOKEN) DEBT=$(USDC_TOKEN) USER=0x...
exec-simulate-liq:
	@if [ -z "$(COLL)" ] || [ -z "$(DEBT)" ] || [ -z "$(USER)" ]; then \
	  echo "Usage: make exec-simulate-liq COLL=0x<collateral> DEBT=0x<debtToken> USER=0x<address>"; exit 1; fi
	@echo "Simulating liquidation on Sepolia"
	@echo "  collateral: $(COLL)"
	@echo "  debt token: $(DEBT)"
	@echo "  user      : $(USER)"
	@set -a; [ -f .env ] && . ./.env; set +a; \
	forge script $(LIQ_SCRIPT) \
		--sig "simulateLiquidation(address,address,address)" $(COLL) $(DEBT) $(USER) \
		--rpc-url $(SEPOLIA_RPC_URL) \
		--private-key $(DEPLOYER_PRIVATE_KEY) \
		-vvvv

# ---------- Create a risky, liquidatable position (testnets/forks) ----------
## Borrow % of liquidation threshold (bps). Example: 9500 = 95%.
## Amounts are in base units (e.g. 1e8 for WBTC).
## Usage:
##   make exec-create-risky COLL=$(WBTC_TOKEN) DEBT=$(USDC_TOKEN) COLL_AMOUNT=100000000 PCT_BPS=9500
exec-create-risky:
	@if [ -z "$(COLL)" ] || [ -z "$(DEBT)" ] || [ -z "$(COLL_AMOUNT)" ] || [ -z "$(PCT_BPS)" ]; then \
	  echo "Usage: make exec-create-risky COLL=0x<coll> DEBT=0x<debt> COLL_AMOUNT=<uint256> PCT_BPS=<1..10000>"; exit 1; fi
	@echo "Creating risky position on Sepolia"
	@echo "  collateral     : $(COLL)"
	@echo "  debt asset     : $(DEBT)"
	@echo "  collateral amt : $(COLL_AMOUNT)"
	@echo "  borrow % of LT : $(PCT_BPS) bps"
	@set -a; [ -f .env ] && . ./.env; set +a; \
	forge script $(LIQ_SCRIPT) \
		--sig "createLiquidatablePosition(address,address,uint256,uint16)" $(COLL) $(DEBT) $(COLL_AMOUNT) $(PCT_BPS) \
		--rpc-url $(SEPOLIA_RPC_URL) \
		--private-key $(DEPLOYER_PRIVATE_KEY) \
		--broadcast \
		-vvvv

# ---------- Execute a liquidation ----------
## REPAY is the amount of debt token to repay (bounded by close factor; base units).
## RECEIVE_ATOKEN: 0 -> receive underlying collateral, 1 -> receive aTokens
## Usage:
##   make exec-liquidate COLL=$(WBTC_TOKEN) DEBT=$(USDC_TOKEN) USER=0x... REPAY=1000000 RECEIVE_ATOKEN=0
exec-liquidate:
	@if [ -z "$(COLL)" ] || [ -z "$(DEBT)" ] || [ -z "$(USER)" ] || [ -z "$(REPAY)" ]; then \
	  echo "Usage: make exec-liquidate COLL=0x<coll> DEBT=0x<debt> USER=0x<address> REPAY=<uint256> [RECEIVE_ATOKEN=0|1]"; exit 1; fi
	@RA=$${RECEIVE_ATOKEN:-0}; \
	echo "Liquidating on Sepolia"; \
	echo "  collateral : $(COLL)"; \
	echo "  debt asset : $(DEBT)"; \
	echo "  user       : $(USER)"; \
	echo "  repay amt  : $(REPAY)"; \
	echo "  recv aTok? : $$RA"; \
	set -a; [ -f .env ] && . ./.env; set +a; \
	forge script $(LIQ_SCRIPT) \
		--sig "liquidate(address,address,address,uint256,bool)" $(COLL) $(DEBT) $(USER) $(REPAY) $$RA \
		--rpc-url $(SEPOLIA_RPC_URL) \
		--private-key $(DEPLOYER_PRIVATE_KEY) \
		--broadcast \
		-vvvv

# ------------- Flash Loan -------------
## Deploy or re-use FlashLoanExecutor via the script (auto deploy if FLASH_EXECUTOR unset)
## Env (example):
##   FLASH_ASSET=0x...   FLASH_AMOUNT=1000000   FEE_PAYER=0xYourEOA
##   [optional] FLASH_TARGET=0x... FLASH_DATA=0x... FLASH_APPROVE_TARGET=1
exec-flashloan:
	@echo "Executing flash loan on Sepolia"
	@set -a; [ -f .env ] && . ./.env; set +a; \
	forge script $(FLASH_SCRIPT) \
		--rpc-url $(SEPOLIA_RPC_URL) \
		--private-key $(DEPLOYER_PRIVATE_KEY) \
		--broadcast -vvvv


# ----------------- Leverage (Arbitrum/OP mainnet friendly) -----------------

# Required:
#   DEPLOYER_PRIVATE_KEY
#   RPC_URL              (e.g. Arbitrum/OP mainnet)
#   POOL                 (Aave v3 Pool)
#   AAVE_DATA_PROVIDER   (Aave v3 ProtocolDataProvider)
#   UNISWAP_V3_ROUTER    (Uniswap V3 periphery router)
# Optional:
#   MANAGER              (if already deployed)
#   WETH_TOKEN, USDC_TOKEN, WBTC_TOKEN, LINK_TOKEN (or pass via CLI)

EXEC_LEV_SCRIPT := script/leveraged/ExecuteLeveragePositions.s.sol:ExecuteLeveragePositions

# Deploy LeveragePositionManager
deploy-lev:
	@echo "Deploying LeveragePositionManager to $(RPC_URL)"
	@[ -n "$(DEPLOYER_PRIVATE_KEY)" ] || (echo "Missing DEPLOYER_PRIVATE_KEY"; exit 1)
	@[ -n "$(POOL)" ] || (echo "Missing POOL"; exit 1)
	@[ -n "$(AAVE_DATA_PROVIDER)" ] || (echo "Missing AAVE_DATA_PROVIDER"; exit 1)
	@[ -n "$(UNISWAP_V3_ROUTER)" ] || (echo "Missing UNISWAP_V3_ROUTER"; exit 1)
	forge script $(EXEC_LEV_SCRIPT) \
		--sig "deployManager()" \
		--rpc-url $(RPC_URL) \
		--private-key $(DEPLOYER_PRIVATE_KEY) \
		--broadcast -vvv

# Open a leveraged position (generic; use for long/short)
# Example (leveraged long WETH with USDC):
#   make exec-open \
#     COLL=$(WETH_TOKEN) COLL_AMT=100000000000000000 \
#     DEBT=$(USDC_TOKEN) DEBT_AMT=100000000 \
#     UNI_FEE=500 MIN_OUT=1 DEADLINE=$$(( $$(date +%s) + 900 )) MIN_HF=1100000000000000000 RESUPPLY=1
exec-open:
	@[ -n "$(COLL)" ] && [ -n "$(COLL_AMT)" ] && [ -n "$(DEBT)" ] && [ -n "$(DEBT_AMT)" ] || (echo "Usage: make exec-open COLL=0x... COLL_AMT=<wei> DEBT=0x... DEBT_AMT=<units> UNI_FEE=<500|3000|10000> MIN_OUT=<uint> DEADLINE=<unix> MIN_HF=<wad> [RESUPPLY=0|1] [REF=0]"; exit 1)
	@REF=$${REF:-0}; RESUPPLY=$${RESUPPLY:-0}; \
	echo "Opening position: COLL=$(COLL) AMT=$(COLL_AMT) | BORROW=$(DEBT) AMT=$(DEBT_AMT) FEE=$(UNI_FEE) RESUPPLY=$$RESUPPLY"; \
	set -a; [ -f .env ] && . ./.env; set +a; \
	forge script $(EXEC_LEV_SCRIPT) \
		--sig "openPosition(address,address,uint256,address,uint256,uint16,uint24,uint256,uint256,uint256,bool)" \
		$${MANAGER:-0x0000000000000000000000000000000000000000} \
		$(COLL) $(COLL_AMT) $(DEBT) $(DEBT_AMT) $$REF $(UNI_FEE) $(MIN_OUT) $(DEADLINE) $(MIN_HF) $$RESUPPLY \
		--rpc-url $(RPC_URL) \
		--private-key $(DEPLOYER_PRIVATE_KEY) \
		--broadcast -vvv

# Close a leveraged position
# Example:
#   make exec-close COLL=$(WETH_TOKEN) DEBT=$(USDC_TOKEN) ATOK_PULL=115792089237316195423570985008687907853269984665640564039457584007913129639935 WITHDRAW=11579208... UNI_FEE=500 MIN_OUT=1 DEADLINE=$$(( $$(date +%s)+900 )) MAX_REPAY=340000000
exec-close:
	@[ -n "$(COLL)" ] && [ -n "$(DEBT)" ] && [ -n "$(ATOK_PULL)" ] && [ -n "$(WITHDRAW)" ] && [ -n "$(UNI_FEE)" ] && [ -n "$(MIN_OUT)" ] && [ -n "$(DEADLINE)" ] && [ -n "$(MAX_REPAY)" ] || (echo "Usage: make exec-close COLL=0x... DEBT=0x... ATOK_PULL=<amt or MAX> WITHDRAW=<amt or MAX> UNI_FEE=<500|3000|10000> MIN_OUT=<uint> DEADLINE=<unix> MAX_REPAY=<uint>"; exit 1)
	@set -a; [ -f .env ] && . ./.env; set +a; \
	forge script $(EXEC_LEV_SCRIPT) \
		--sig "closePosition(address,address,address,uint256,uint256,uint24,uint256,uint256,uint256)" \
		$${MANAGER:-0x0000000000000000000000000000000000000000} \
		$(COLL) $(DEBT) $(ATOK_PULL) $(WITHDRAW) $(UNI_FEE) $(MIN_OUT) $(DEADLINE) $(MAX_REPAY) \
		--rpc-url $(RPC_URL) \
		--private-key $(DEPLOYER_PRIVATE_KEY) \
		--broadcast -vvv

# Close the position fully
# MAX=115792089237316195423570985008687907853269984665640564039457584007913129639935
# make exec-close \
#   COLL=$(WETH_TOKEN) DEBT=$(USDC_TOKEN) \
#   ATOK_PULL=$MAX WITHDRAW=$MAX \
#   UNI_FEE=500 MIN_OUT=1 DEADLINE=$(( $(date +%s)+900 )) MAX_REPAY=$MAX


# Common defaults (override at call-time if you like)
# amounts are in base units (WETH 18, USDC 6, WBTC 8)
DEFAULT_COLL_AMOUNT ?= 1000000000000000000    # 1 WETH
DEFAULT_BORROW_AMOUNT_LONG ?= 1000000          # 1 USDC (example only; adjust)
DEFAULT_BORROW_AMOUNT_SHORT ?= 10000000        # 0.1 WBTC (8 decimals -> 10,000,000)
DEFAULT_UNI_FEE ?= 3000                        # 0.3% pool
DEFAULT_MIN_OUT ?= 0                           # protect with real slippage for prod
DEFAULT_DEADLINE ?= 0                          # 0 => router will use block.timestamp in wrapper
DEFAULT_MIN_HF ?= 1200000000000000000          # 1.20
DEFAULT_RESUPPLY ?= 1                          # 1=true, re-supply swapped collateral

## Open a *long* on WETH using USDC borrow:
## Supply WETH, borrow USDC, swap USDC->WETH (optionally re-supply).
## Usage:
##   make exec-open-long [COLL_AMOUNT=...] [BORROW_AMOUNT=...] [UNI_FEE=3000] [MIN_OUT=0] [DEADLINE=0] [MIN_HF=1.2e18] [RESUPPLY=1]
exec-open-long:
	@echo "Opening LONG: collateral=WETH borrow=USDC on Sepolia"
	@set -a; [ -f .env ] && . ./.env; set +a; \
	COLL=$${COLL_AMOUNT:-$(DEFAULT_COLL_AMOUNT)}; \
	BORR=$${BORROW_AMOUNT:-$(DEFAULT_BORROW_AMOUNT_LONG)}; \
	FEE=$${UNI_FEE:-$(DEFAULT_UNI_FEE)}; \
	MINO=$${MIN_OUT:-$(DEFAULT_MIN_OUT)}; \
	DL=$${DEADLINE:-$(DEFAULT_DEADLINE)}; \
	MHF=$${MIN_HF:-$(DEFAULT_MIN_HF)}; \
	RS=$${RESUPPLY:-$(DEFAULT_RESUPPLY)}; \
	forge script $(LEVERAGE_SCRIPT) \
		--sig "openLong(address,address,uint256,uint256,uint24,uint256,uint256,uint256,bool)" \
		$(WETH_TOKEN) $(USDC_TOKEN) $$COLL $$BORR $$FEE $$MINO $$DL $$MHF $$RS \
		--rpc-url $${SEPOLIA_RPC_URL} \
		--private-key $${DEPLOYER_PRIVATE_KEY} \
		--broadcast -vvvv

## Open a *short* on WBTC collateralized by WETH:
## Supply WETH, borrow WBTC, swap WBTC->WETH (optionally re-supply).
## Usage:
##   make exec-open-short [COLL_AMOUNT=...] [BORROW_AMOUNT=...] [UNI_FEE=3000] [MIN_OUT=0] [DEADLINE=0] [MIN_HF=1.2e18] [RESUPPLY=1]
exec-open-short:
	@echo "Opening SHORT: collateral=WETH borrow=WBTC on Sepolia"
	@set -a; [ -f .env ] && . ./.env; set +a; \
	COLL=$${COLL_AMOUNT:-$(DEFAULT_COLL_AMOUNT)}; \
	BORR=$${BORROW_AMOUNT:-$(DEFAULT_BORROW_AMOUNT_SHORT)}; \
	FEE=$${UNI_FEE:-$(DEFAULT_UNI_FEE)}; \
	MINO=$${MIN_OUT:-$(DEFAULT_MIN_OUT)}; \
	DL=$${DEADLINE:-$(DEFAULT_DEADLINE)}; \
	MHF=$${MIN_HF:-$(DEFAULT_MIN_HF)}; \
	RS=$${RESUPPLY:-$(DEFAULT_RESUPPLY)}; \
	forge script $(LEVERAGE_SCRIPT) \
		--sig "openShort(address,address,uint256,uint256,uint24,uint256,uint256,uint256,bool)" \
		$(WETH_TOKEN) $(WBTC_TOKEN) $$COLL $$BORR $$FEE $$MINO $$DL $$MHF $$RS \
		--rpc-url $${SEPOLIA_RPC_URL} \
		--private-key $${DEPLOYER_PRIVATE_KEY} \
		--broadcast -vvvv