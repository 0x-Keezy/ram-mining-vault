# RAM — Mining Vault

A **real-yield mining vault** for the [Flap](https://flap.sh) Tax Vault V2 framework on BNB Chain.

## Concept

RAM is a Flap tax token. Instead of buyback-and-burn, a share of its trading fees is routed to this
vault, used to acquire **tokenized NVIDIA (NVDAB)**, and distributed to "miners" in proportion to their
**mining power**. You buy mining power ("rigs") with BNB and earn real tokenized NVIDIA.

- **Real yield** — rewards come from actual trading fees + a real asset, not from token emissions, so
  there is no "dry vault" risk.
- **No burn** — fees buy a productive asset and pay it out, rather than being destroyed.

## Mechanism (reference for review)

- **Reward engine.** A MasterChef-style accumulator (`accRewardPerPower`) splits a variable,
  asynchronously-funded reward pool **pro-rata by each miner's power**. No inflation, no emission.
- **Tier economics (disclosure).** The four rig tiers (Micro/Core/Mega/Hyper) reward capital **and
  duration commitment**: longer / larger tiers earn proportionally more reward per BNB than the entry
  tier (their `power × active-duration` per BNB is higher), so the tiers are **not equal on a
  yield-per-BNB basis** — this is intentional, not a fairness guarantee across tiers. Every tier's
  terms (power, duration, price) are public up-front via `getPlan`. A rig's mining end is capped at
  `seasonEnd`, so a long tier bought mid-season earns only until the season ends. Post-RAM-launch
  (Phase 2), subsequent rigs/upgrades are paid in RAM (BNB-denominated — the RAM cost is the tier's
  BNB value converted to RAM units at the oracle's live BNB-per-RAM price), which rebalances scaling
  incentives and introduces RAM's utility sink. A USD-denominated sink is a planned Phase-2 upgrade.
- **Acquisition — keeper / RFQ (the standard Flap interface).** Tax fees arrive as BNB and accumulate in
  the vault. Instead of swapping on a DEX, the vault acquires NVDAB through a **permissionless keeper
  RFQ**: a keeper sells NVDAB **into** the vault and is paid BNB at the **Chainlink oracle price + a
  small, clamped premium**. This is the surface Flap's own arbitrageurs/keepers fill against, and we can
  run our own keeper for liveness.
  - Interface: `sellRWAToVault(uint256 rwaAmount, uint256 minBnbOut) → uint256 bnbOwed`, quote
    `quoteRWAToVault(uint256 rwaAmount)`, event `RWASoldToVault(keeper, rwaIn, bnbOut)`.
  - **BNB leaves the vault to a permissionless caller**, so every drain guard fires on a fill: a per-fill
    cap, a per-window rate-limit, a price-deviation band (egress requires an armed reference price), hard
    Chainlink staleness/sanity checks, CEI + `nonReentrant`, and fee-on-transfer-safe accounting (the
    vault prices the **real received delta**, never a nominal amount). Egress caps default to `0` — sells
    are disabled until the guardian explicitly arms them.
- **Rig / plan expiration.** Handled by lazy liquidation in time buckets (exact, near-zero keeper cost).
- **Economic Agent (AI oracle).** The vault extends Flap's on-chain AI oracle
  (`FlapAIConsumerBase` + `ITriggerReceiver`). Each epoch runs a **trigger → reason → fulfill** loop in
  which an on-chain LLM reads vault + market state and selects a **discrete, clamped lever**:
  `0 HOLD · 1 RAISE_PREMIUM · 2 LOWER_PREMIUM · 3 RETAIN`. The only state a lever can touch is the keeper
  premium, **hard-clamped to Flap's recommended NVDAB band of 1.02–1.04** (default 1.03). **No pause
  lever, no burn lever** — the AI can never stop the vault, drain it, or move the premium out of band.
  Each decision carries an IPFS proof of its reasoning.
- **Invariant** (enforced in tests): `Σ claimed ≤ Σ distributed`. `claim` is always available.

## Safety model — no pause, no hatch, recovery via upgrade

Per Flap's onboarding guidance, this vault follows the **no-pause** model:

- **No pause anywhere.** There is no acquisition pause and no vault pause. `buyMiningContract` runs for the
  whole season and `claimRewards` is always open — there is no privileged switch that can stop them.
- **No emergency-withdraw hatches.** The vault is deployed behind an OpenZeppelin `BeaconProxy`, so it is
  **exempt from Flap Rule 009** (the emergency-withdraw requirement is for non-upgradeable vaults). It
  intentionally implements no `emergencyWithdrawNative` / `emergencyWithdrawToken` / rescue path.
- **Recovery = Guardian-only beacon upgrade.** The sole emergency mechanism is the upgrade right over the
  factory's `UpgradeableBeacon`, reachable only through `RamMiningBeaconFactory.scheduleUpgrade` /
  `executeUpgrade` — both **Guardian-only**, behind a **2-day timelock** (no instant bait-and-switch).
  `lockVaultUpgrades()` lets the Guardian renounce the beacon to credibly commit to immutability.

Removing the pause and hatches eliminates a guardian DOS/rug vector (Rule 001 No-DOS / Rule 003 fairness)
while keeping the economic egress guards as the wall on keeper fills.

## Weekend / off-hours pricing

NVDA is a US equity: its Chainlink NVDA/USD feed freezes outside market hours. Per Flap's guidance we do
**not** pause buys/fills off-hours (failed txs are bad UX):

- **Interim (Chainlink-only).** `rewardFeedMaxStale` defaults to **7 days**, so fills keep operating over
  the weekend at the last (Friday) print. The residual weekend-arb is **bounded by the per-fill /
  per-window BNB caps**. BNB/USD stays tight (2h, it updates 24/7).
- **Dead-feed wall.** `setOracleGuards` caps the reward-feed staleness at **30 days** (`MAX_REWARD_FEED_STALE`)
  and BNB staleness at **1 day** — a genuinely dead feed always reverts.
- **Target (Flap's 24/7 NVDA feed).** `rewardPriceFeed` is guardian-settable via `setPriceFeeds`; once
  Flap's dedicated 24/7 feed (Pyth Pro + Chainlink cross-check) is wired, staleness can drop to ~12–24h and
  the weekend-arb window closes entirely. `rewardToken` / `rewardPriceFeed` stay Chainlink-trusted.

## Why a keeper, not a DEX swap

v1 swapped BNB→NVDA on a DEX. We retired that path: **no tokenized-NVIDIA asset has real DEX liquidity on
BNB Chain.** Verified on-chain — NVDAB is CEX-only (its liquidity lives on Binance, ~110k/24h), and the
on-chain alternatives are dust (e.g. a Backed xStock NVDA on BNB shows ~$430 TVL with ~-91% slippage on a
single-BNB sell; its real liquidity is on Solana). A DEX swap would either revert or get sandwiched. The
**keeper/RFQ model sources the real asset at the oracle price** and is exactly the native model Flap
endorsed, so the vault is filled by Flap's keepers (and optionally our own) rather than a broken DEX route.

## Contracts

| File | Role |
|------|------|
| `src/RamMiningVault.sol` | Vault (`RamMiningVaultUpgradeable`) + factory (`RamMiningBeaconFactory`) |
| `src/TestNvdaToken.sol`  | Testnet mock for tokenized NVIDIA (no NVDA on testnet) |
| `src/FlapDeployed.sol`   | Chain address resolver (VaultPortal mainnet/testnet) |
| `src/flap/`              | Flap V2 framework interfaces/bases — **REQUIRED & IMMUTABLE**, do not modify |

## Build & test

```bash
forge build
forge test
# mainnet-fork integration test against the REAL NVDAB (needs a BNB mainnet RPC):
BNB_RPC_URL=https://bsc-rpc.publicnode.com \
NVDAX_ADDRESS=0x02Fca66C1D1aFB4E2A7884261eB00F63598a7436 \
forge test --match-path test/RamMiningVault.fork.t.sol -vv
```

The fork test runs the full keeper path against the real asset: a keeper fills NVDAB into the vault for
BNB, the vault distributes it by power, a miner claims real NVDAB, and the dead-feed staleness wall reverts
once the feed is stale beyond the bound.

## Deploy (BNB testnet)

```bash
forge script script/testnet/bnb/DeployRamMining.s.sol:DeployRamMining \
  --rpc-url $BNB_TESTNET_RPC --broadcast
```

## License

MIT — see [LICENSE](LICENSE).
