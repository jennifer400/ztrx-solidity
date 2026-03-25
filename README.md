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
- User margin top-up via `addMargin(...)`
- Blocks position size increases while liquidation grace protection is active

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
- Starts insured liquidation grace protection before executing forced liquidation
- Executes liquidation path after grace expiry if the position remains unsafe
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

### 6.4 Insured liquidation grace protection

Insured positions do not move straight into forced liquidation on the first qualifying breach.

Current implementation:

- only positions with `insuranceStatus == Active` are eligible
- first valid liquidation attempt starts a grace window instead of liquidating
- the default grace window is `5 minutes`
- during the grace window the trader may:
  add margin with `addMargin(...)`
  reduce the position
  close the position
- during the grace window the trader may **not** increase position size
- if the position becomes healthy again, the stored grace state is cleared
- if the grace window expires and the position is still below maintenance margin, liquidation proceeds normally

Why this design is narrow and safe:

- the protocol does not pause liquidation for uninsured positions
- the protocol does not let users use the grace window to add risk
- the vault-backed insurance promise is expressed as temporary protection time, not as an immediate unsecured cash advance

### 6.5 NFT benefits as protocol-side inputs

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

### 6.6 LP vault shares, yield, and claims

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

### 6.7 LP cooldown with NFT reduction

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
- `PositionManager.setLiquidationEngine(LiquidationEngine)`
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

## 8) Business Flows

### 8.1 NFT themes and rights template

The collection is split into four themes:

- `Sentinel`: 1200
- `Guardian`: 500
- `Bastion`: 220
- `Oracle`: 80

Each theme can be configured independently through `setThemeBenefits(...)`.

Current configurable rights fields:

- `tradingFeeDiscountBps`
- `tokenAirdropBonusBps`
- `insurancePremiumDiscountBps`
- `liquidationProtectionBoostBps`
- `tradingCompetitionBoostBps`
- `lpYieldBoostBps`
- `lpExitCooldownReductionBps`
- `partnerWhitelistEligible`
- `priorityAccessEligible`

Suggested business positioning:

- `Sentinel`
  entry-tier utility NFT with light fee and activity boosts
- `Guardian`
  mid-tier trader NFT with stronger trading and insurance discounts
- `Bastion`
  premium risk-protection NFT with stronger insurance and liquidation boosts
- `Oracle`
  highest-tier strategic NFT with strongest fee, LP, whitelist, and early-access rights

### 8.2 User claim flow

Business process:

1. Operations decides which wallet receives which token id off-chain.
2. Owner writes claim assignments through `assignRecipients(...)`.
3. User connects wallet and calls `claim(tokenId)` or `claimBatch(...)`.
4. If the user holds multiple NFTs, the wallet can choose which NFT is the active benefit source through `setActiveBenefitToken(...)`.

Operational implication:

- rights follow the currently selected active NFT, not necessarily every NFT held by the wallet
- if the active NFT is transferred away, the active-rights binding is cleared automatically

### 8.3 Trader rights flow

When the NFT benefit source is configured in protocol modules:

- `FeeRouter` can apply `tradingFeeDiscountBps`
- `InsuranceController` can apply `insurancePremiumDiscountBps`
- `InsuranceController` can raise effective liquidation protection through `liquidationProtectionBoostBps`
- off-chain systems can read:
  `tokenAirdropBonusBps`
  `partnerWhitelistEligible`
  `priorityAccessEligible`
  `tradingCompetitionBoostBps`

This means ZTRX can separate:

- on-chain enforced benefits:
  fee discount, insurance discount, liquidation boost, LP boost, LP cooldown reduction
- off-chain or app-layer benefits:
  airdrops, whitelist campaigns, product beta access, competition point multipliers

### 8.4 LP business flow

An LP interacts with the insurance vault as follows:

1. LP deposits collateral via `depositLiquidity(...)`.
2. The vault mints LP shares.
3. Premium income increases vault assets and therefore increases share value.
4. LP can either:
   redeem part or all of the position with `redeemLiquidity(...)`
   or claim profit only with `claimYield(...)`

Key business behavior:

- principal is tracked separately from profit
- claim payouts for traders are funded from the same vault
- reserved insurance capacity remains non-withdrawable by LPs

### 8.5 Insured liquidation rescue flow

Business behavior for an insured account under stress:

1. The position falls below maintenance margin.
2. A keeper calls `liquidate(user, marketId)`.
3. Instead of immediate liquidation, the protocol opens a 5-minute rescue window.
4. During that window, the trader can:
   add more margin
   reduce size
   close the position voluntarily
5. During that same window, the trader cannot increase size.
6. If the account returns to a safe state, the rescue window is cleared.
7. If the rescue window expires and the account is still unsafe, the next liquidation call executes the liquidation and insurance claim path.

### 8.6 NFT-enhanced LP business flow

If `RiskVault` is connected to `ZTRXNFT`:

- `lpYieldBoostBps`
  mints extra LP shares on deposit, which gives that wallet a larger claim on future premium growth
- `lpExitCooldownReductionBps`
  reduces the effective exit waiting period derived from the vault base cooldown

Business meaning:

- higher-tier NFTs can make LP capital more efficient
- higher-tier NFTs can let LPs exit or claim yield earlier
- the claim reserve safety model still remains enforced because `reserved` liquidity cannot be withdrawn

### 8.7 Operations checklist

Before public launch:

1. Deploy and configure `ZTRXNFT`.
2. Define benefit parameters for all four themes.
3. Upload metadata and image assets.
4. Assign token ids to wallets off-chain and write assignments on-chain.
5. Wire `ZTRXNFT` into:
   `InsuranceController`
   `FeeRouter`
   `RiskVault`
6. Decide whether LP cooldown is enabled and set `RiskVault.setBaseExitCooldown(...)`.
7. Seed the vault with initial assets or LP liquidity.
8. Verify frontend uses:
   active NFT selection
   fee preview
   LP asset value
   LP claimable yield
   LP unlock time

---

## 9) Text-Based Sequence Diagrams

### 9.1 Open Position + Activate Insurance

1. `User -> MarginVault`: `deposit(amount)`
2. `Relayer -> PositionManager`: `openPosition(params)`
3. `PositionManager -> MarginVault`: `lockMargin(user, margin)`
4. `Orchestrator -> InsuranceController`: `registerCoverage(positionId, signedQuote, signature)`
5. `InsuranceController`: verify signature, expiry, replay, caps, utilization throttle
6. `InsuranceController -> RiskVault`: `reserveCapacity(positionId, reserveAmount)`
7. `InsuranceController`: store coverage snapshot (active)

### 9.2 Profitable Close + Premium Settlement

1. `Relayer -> PositionManager`: `closePosition(...)`
2. `PositionManager -> MarginVault`: `unlockMargin(user, ...)`
3. `Orchestrator -> InsuranceController`: `settlePremiumOnProfit(positionId, user, realizedProfit)`
4. `InsuranceController`: compute `premium = realizedProfit * premiumBps / 10000`
5. `InsuranceController -> Token`: `transferFrom(user, InsuranceController, premium)`
6. `InsuranceController -> RiskVault`: `receivePremium(premium)`
7. `InsuranceController`: mark premium settled

### 9.3 Liquidation + Insurance Claim

1. `Keeper -> LiquidationEngine`: `liquidate(user, marketId)`
2. `LiquidationEngine -> OracleAdapter`: read mark price (freshness/deviation checked)
3. `LiquidationEngine`: check maintenance margin breach
4. If insured and no grace window exists yet, `LiquidationEngine` stores `graceExpiry = now + 5 minutes` and returns
5. If insured and grace is active, trader may `addMargin(...)`, `reducePosition(...)`, or `closePosition(...)`
6. If the grace window expires and the account is still unsafe:
7. `LiquidationEngine -> InsuranceController`: `processLiquidationClaim(positionId, user, realizedLoss, eligible=true)` (if active)
8. `InsuranceController`: enforce min holding, staged activation, cooldown policy
9. `InsuranceController -> RiskVault`: `payClaim(positionId, user, claimAmount)`
10. `LiquidationEngine -> PositionManager`: `markLiquidated(...)`
11. `PositionManager -> MarginVault`: unlock/finalize margin state

### 9.4 Liquidation Grace Rescue Window

1. `Keeper -> LiquidationEngine`: `liquidate(user, marketId)`
2. `LiquidationEngine -> OracleAdapter`: fetch mark price
3. `LiquidationEngine`: detect maintenance margin breach
4. `LiquidationEngine`: confirm the position is insured and grace-protected
5. `LiquidationEngine`: store `graceExpiry`
6. `LiquidationEngine -> Event Log`: `LiquidationProtectionActivated(...)`
7. `User -> PositionManager`: `addMargin(marketId, amount)` or `Relayer -> PositionManager`: `reducePosition(...)` / `closePosition(...)`
8. `PositionManager -> MarginVault`: lock or unlock margin as required
9. `PositionManager -> LiquidationEngine`: best-effort `onMarginUpdated(...)` after margin top-up
10. `LiquidationEngine`: clear protection state if the account is healthy again

### 9.5 LP Deposit + Yield Claim

1. `LP -> RiskVault`: `depositLiquidity(amount)`
2. `RiskVault`: mint shares, track principal, refresh unlock timestamp
3. `Protocol -> RiskVault`: `receivePremium(amount)`
4. `RiskVault`: increase `totalAssets`, share value rises
5. `LP -> RiskVault`: `claimYield(amount)` or `redeemLiquidity(shares)`
6. `RiskVault`: enforce cooldown and reserved-liquidity checks
7. `RiskVault -> LP`: transfer withdrawable profit or redeemed assets

---

## 10) Run and Test

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

## 11) Current Test Coverage

- Unit tests: access control, state transitions, event assertions, boundary reverts
- Fuzz tests: leverage bounds, premium settlement, claim cap behavior, reserve/release accounting, replay/expiry
- Invariants: margin lock safety, reserve utilization safety, no quote replay success, no double-claim success, no upfront premium charge

---

## 12) Notes and MVP Boundaries

- Single collateral token in current MVP
- Relayer/oracle/signing inputs are trusted infrastructure assumptions
- No on-chain matching engine in this repo
- `bps` is used for all ratios (`10000 = 100%`)
- NFT benefits are optional integrations; protocol modules still work with benefit source unset
- LP yield boost is implemented by minting additional vault shares on deposit
- LP yield claiming is implemented by burning shares against accrued profit while keeping tracked principal unchanged
