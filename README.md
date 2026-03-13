# ZTRX Solidity Core

An on-chain core for a decentralized perpetual exchange with protocol-native lifecycle insurance.

This repository focuses on settlement, risk enforcement, liquidation, insurance capacity management, and fee routing.  
It does **not** implement a full on-chain matching engine.

---

## 1) Project Positioning

ZTRX uses a **hybrid design**:

- **Off-chain**: pricing/risk engine computes insurance quotes.
- **On-chain**: contracts verify signatures, enforce constraints, execute state transitions, and settle funds.

This keeps pricing flexible while keeping critical enforcement auditable and deterministic on-chain.

---

## 2) Tech Stack

- Solidity `^0.8.24`
- Foundry
- OpenZeppelin `Ownable2Step` (MVP access model)

Design constraints used in this codebase:

- No upgradeable proxy in MVP
- Explicit constructor wiring for dependencies
- Basis points (`bps`) for ratios (`10000 = 100%`)
- Custom errors instead of revert strings
- CEI pattern around external token interactions

---

## 3) Repository Structure

```text
contracts/
  core/         # business modules
  interfaces/   # narrow cross-module interfaces
  libraries/    # shared types/errors/events/math
test/           # unit + fuzz + invariant tests
script/
```

---

## 4) Core Modules

### ZTRXNFT

- ERC-721 collection with fixed supply `2000`
- Theme buckets:
  `Sentinel 1200`, `Guardian 500`, `Bastion 220`, `Oracle 80`
- Supports offline pre-allocation plus user self-claim on-chain
- Exposes NFT benefit configuration for protocol integrations
- Supports active-benefit-token selection per wallet when a user holds multiple NFTs

### MarginVault

- Custodies user collateral (single collateral token in MVP)
- Tracks `totalBalance`, `lockedMargin`, `availableBalance`
- Authorizes protocol modules to lock/unlock margin

### PositionManager

- Authoritative position lifecycle state
- One active position per user per market (MVP)
- Open/increase/reduce/close/markLiquidated

### RiskConfig

Governance-controlled config source for:

- Market risk parameters
- Global insurance constraints
- Tier- and market-based insurance limits
- Quote signer

### OracleAdapter

- Normalized mark/index prices (`x18`)
- Staleness checks
- Deviation bounds
- Configurable feeds per market

### RiskVault

- Insurance reserve pool
- Tracks `totalAssets`, `totalReserved`, `reservedByPosition`
- Supports LP deposits with share accounting
- Supports principal tracking, yield-only claiming, and full redemption
- Supports NFT-based LP yield boost and LP exit cooldown reduction
- Reserve/release capacity and pay claims

### InsuranceController

- Verifies EIP-712 signed quotes
- Prevents quote replay
- Activates coverage and reserves vault capacity
- Settles premium on profit (no upfront premium)
- Applies NFT insurance premium discount and liquidation protection boost
- Processes liquidation claims with staged activation controls

### LiquidationEngine

- Evaluates maintenance margin breach
- Executes liquidation path
- Triggers insurance claim flow when eligible

### FeeRouter

- Routes premium/protocol fees between treasury and RiskVault
- Uses configured split from RiskConfig
- Supports NFT-based trading fee discounts
- Keeps accounting explicit and queryable

---

## 5) Dependency Graph (Concise)

- `ZTRXNFT -> protocol benefit source for InsuranceController, FeeRouter, RiskVault`
- `PositionManager -> IMarginVault, IRiskConfig, IInsuranceController`
- `LiquidationEngine -> IPositionManager, IOracleAdapter, IRiskConfig, IInsuranceController`
- `InsuranceController -> IRiskConfig, IRiskVault`
- `InsuranceController -> IZTRXNFTBenefits` (optional)
- `RiskVault -> IRiskConfig, IZTRXNFTBenefits` (optional)
- `FeeRouter -> IRiskConfig, IRiskVault, IZTRXNFTBenefits` (optional)

---

## 6) Key Mechanisms

### 6.1 Off-chain pricing, on-chain enforcement

The quote carries pricing/risk outputs (`premiumBps`, `coverageRatioBps`, controls), while chain enforces:

- signature validity
- expiry and nonce replay protection
- max coverage constraints
- max insurable amount
- vault utilization throttle
- cooldown/min-holding/staged-activation restrictions

### 6.2 Premium is not charged upfront

- At coverage registration: only snapshot + reserve capacity.
- Premium is charged later in `settlePremiumOnProfit(...)` only if realized profit > 0.

### 6.3 Staged claim effectiveness

Coverage can scale in over time:

- before `activationDelay`: zero effective coverage
- between `activationDelay` and `fullActivationDelay`: linearly increasing
- after `fullActivationDelay`: full quoted coverage

### 6.4 NFT benefits as protocol-side inputs

The NFT contract is not just collectible metadata. It is also a benefit source for protocol modules.

Current integrations:

- `InsuranceController`
  applies `insurancePremiumDiscountBps` and `liquidationProtectionBoostBps`
- `FeeRouter`
  applies `tradingFeeDiscountBps` through the benefit-aware routing path
- `RiskVault`
  applies `lpYieldBoostBps` on LP share minting and `lpExitCooldownReductionBps` on LP exit timing

The NFT contract exposes:

- address-level active benefit selection
- full benefit profile lookup
- narrower lookup functions for trading, insurance, and liquidity modules

### 6.5 LP vault shares, yield, and claims

`RiskVault` now behaves as an LP-backed insurance pool:

- LPs deposit collateral through `depositLiquidity(...)`
- vault shares are minted proportionally
- premium income increases `totalAssets` and therefore LP share value
- LPs can:
  redeem normally through `redeemLiquidity(...)`
  or claim profit only through `claimYield(...)`

Accounting notes:

- `principalBalanceOf(user)` tracks deposited principal
- `lpAssetValue(user)` returns current share value
- `claimableYieldOf(user)` returns profit above principal
- reserved insurance capacity cannot be withdrawn by LPs

### 6.6 LP cooldown with NFT reduction

The vault supports a governance-controlled base LP exit cooldown.

- LP withdrawals and yield claims are blocked until `lpUnlockTime(user)`
- NFTs can reduce that cooldown through `lpExitCooldownReductionBps`
- cooldown is refreshed on new LP deposits
- this lets higher-tier NFTs enjoy faster LP capital mobility without changing claim reserve safety

---

## 7) Deployment and Wiring

Recommended deployment order:

1. `RiskConfig`
2. `ZTRXNFT`
3. `MarginVault`
4. `RiskVault`
5. `OracleAdapter`
6. `InsuranceController`
7. `PositionManager`
8. `LiquidationEngine`
9. `FeeRouter`

Recommended initialization wiring:

- `ZTRXNFT.setThemeBenefits(theme, config)` for each NFT theme
- `MarginVault.setAuthorizedModule(PositionManager, true)`
- `PositionManager.setRelayer(relayer, true)`
- `PositionManager.setInsuranceController(InsuranceController)`
- `RiskVault.setInsuranceController(InsuranceController)`
- `RiskVault.setPremiumCaller(InsuranceController, true)`
- `RiskVault.setPremiumCaller(FeeRouter, true)` (if used)
- `RiskVault.setBenefitNFT(ZTRXNFT)`
- `RiskVault.setBaseExitCooldown(seconds)` (if LP cooldown is used)
- `InsuranceController.setAuthorizedCaller(orchestrator / engine, true)`
- `InsuranceController.setBenefitNFT(ZTRXNFT)`
- `FeeRouter.setAuthorizedCaller(protocol module, true)`
- `FeeRouter.setBenefitNFT(ZTRXNFT)`

Recommended NFT claim preparation:

- owner pre-assigns token ids with `assignRecipients(...)`
- users connect wallet and call `claim(...)` / `claimBatch(...)`
- if a wallet holds multiple NFTs, it can choose the active rights source via `setActiveBenefitToken(...)`

---

## 8) Text-Based Sequence Diagrams

### 8.1 Open Position + Activate Insurance

1. `User -> MarginVault`: `deposit(amount)`
2. `Relayer -> PositionManager`: `openPosition(params)`
3. `PositionManager -> MarginVault`: `lockMargin(user, margin)`
4. `Orchestrator -> InsuranceController`: `registerCoverage(positionId, signedQuote, signature)`
5. `InsuranceController`: verify signature, expiry, replay, caps, utilization throttle
6. `InsuranceController -> RiskVault`: `reserveCapacity(positionId, reserveAmount)`
7. `InsuranceController`: store coverage snapshot (active)

### 8.2 Profitable Close + Premium Settlement

1. `Relayer -> PositionManager`: `closePosition(...)`
2. `PositionManager -> MarginVault`: `unlockMargin(user, ...)`
3. `Orchestrator -> InsuranceController`: `settlePremiumOnProfit(positionId, user, realizedProfit)`
4. `InsuranceController`: compute `premium = realizedProfit * premiumBps / 10000`
5. `InsuranceController -> Token`: `transferFrom(user, InsuranceController, premium)`
6. `InsuranceController -> RiskVault`: `receivePremium(premium)`
7. `InsuranceController`: mark premium settled

### 8.3 Liquidation + Insurance Claim

1. `Keeper -> LiquidationEngine`: `liquidate(user, marketId)`
2. `LiquidationEngine -> OracleAdapter`: read mark price (freshness/deviation checked)
3. `LiquidationEngine`: check maintenance margin breach
4. `LiquidationEngine -> InsuranceController`: `processLiquidationClaim(positionId, user, realizedLoss, eligible=true)` (if active)
5. `InsuranceController`: enforce min holding, staged activation, cooldown policy
6. `InsuranceController -> RiskVault`: `payClaim(positionId, user, claimAmount)`
7. `LiquidationEngine -> PositionManager`: `markLiquidated(...)`
8. `PositionManager -> MarginVault`: unlock/finalize margin state

---

## 9) Run and Test

Build:

```bash
forge build
```

Run all tests:

```bash
forge test
```

Target specific suites:

```bash
forge test --match-contract PositionManagerTest
forge test --match-contract InsuranceControllerTest
forge test --match-contract RiskVaultTest
forge test --match-contract ZTRXNFTTest
forge test --match-contract ProtocolFuzzTest
forge test --match-contract ProtocolInvariants
```

---

## 10) Current Test Coverage

- Unit tests: access control, state transitions, event assertions, boundary reverts
- Fuzz tests: leverage bounds, premium settlement, claim cap behavior, reserve/release accounting, replay/expiry
- Invariants: margin lock safety, reserve utilization safety, no quote replay success, no double-claim success, no upfront premium charge

---

## 11) Notes and MVP Boundaries

- Single collateral token in current MVP
- Relayer/oracle/signing inputs are trusted infrastructure assumptions
- No on-chain matching engine in this repo
- `bps` is used for all ratios (`10000 = 100%`)
- NFT benefits are optional integrations; protocol modules still work with benefit source unset
- LP yield boost is implemented by minting additional vault shares on deposit
- LP yield claiming is implemented by burning shares against accrued profit while keeping tracked principal unchanged
