# RAM Mining Vault — v3 (Phase-2 economy) audit package

This package is the source for the **v3 re-audit** requested by the Flap team ("if it is not covered in the previous audit, we need to perform another audit" — 2026-07-03). It is self-contained: sources, tests, pinned dependencies and build config.

- **Audited base (previous audit):** branch `v2-keeper` @ `87847a4de8c7ed2e32a15624d69ced0797adc57c`
- **Audit target (this package):** branch `v3-economy`, code @ `7bde569` — **v3.2** (public repo: https://github.com/0x-Keezy/ram-mining-vault/tree/v3-economy — the branch head adds only this updated AUDIT.md on top, zero code delta)
- **Contact:** Shilder (dev-lock wallet `0x8216fCD8a714B82Ee9d60793F551957D9abc1CA1`), Telegram group `Shilder <> FLAP`

## 0-bis. v3.2 changelog — deliberate tier rebalance + USD-denominated RAM sink (disclosed up-front)

Two deliberate economic changes land in v3.2, on top of the v3.1 package your bot reviewed through report
version3 (rating Low). Everything else is byte-identical to that reviewed source.

**(a) Tier table rebalanced to ~flat yield-per-$ with a mild commitment premium.** The old Genesis table
(prices ×1/×3/×8/×20, powers 10/40/130/420) — previously marked *By Design* in response to the original F2
finding — gave the top tier ~13× more wear-adjusted `power × duration` per dollar than the Core. Our economic
review concluded that is unsustainable for a shared pro-rata pool (top-tier capital structurally dilutes
small miners), so instead of keeping the disclosed skew we now **resolve the F2 finding**: prices
`×1/×5/×25/×100`, powers `100/400/560/1065`, durations UNCHANGED (1d/7d/30d/90d, season-capped).
Wear-adjusted power-days per dollar: Core 50.4 / Mega 53.2 / Hyper 56.6 → up to **~+12%** premium for the
90-day commitment. The Micro remains the BNB entry gate (§0), not a yield vehicle.

**(b) RAM sinks now charge fixed USD targets.** Growth purchases (rig #2+ / upgrades / repairs, all
RAM-paid) previously charged the tier's BNB reference converted to RAM. They now charge **fixed USD targets**
(`basePriceUsd × 1/5/25/100`, 8-dec, new `vaultData` field — total 10 fields), converted USD → BNB via the
vault's already-hardened Chainlink BNB/USD feed (`_readFeed`, hard staleness ≤ `MAX_BNB_FEED_STALE` = 1d)
and BNB → RAM via the oracle+cage exactly as reviewed. **Fail-closed:** a stale/bad BNB/USD feed reverts the
growth purchase (`StaleFeed`) — never a mis-priced sink; the BNB entry rig and claims have **no** feed
dependency. New view `getPlanUsd(planId)`; quotes revert exactly like the charge would (honest quoting).
This also makes the previously-documented "USD conversion is done by the vault" NatSpec true in code.

Suite adds 7 USD-sink tests (exact conversion, sticker invariance under BNB moves, stale-feed fail-closed
incl. entry/claim unaffected, USD-difference upgrades, USD-target repairs, `basePriceUsd=0 → BadConfig`,
`getPlanUsd` table) and the mainnet-fork launch rehearsal runs the full USD-sink flow end-to-end.

## 0. v3.1 addendum — entry gate (found in our own live-testnet QA, disclosed proactively)

One change landed after our re-review letter: **`EntryRigMustBeMicro` — a fresh wallet's first (BNB-paid) rig is now restricted to plan 0 (Micro)**, via a single `require`-style check + one custom error + one `public constant ENTRY_PLAN_ID = 0` (16 lines, `buyMiningContract` entry branch). Every later rig / upgrade / repair (any tier) flows through the RAM sinks unchanged.

- **Why:** in live testnet QA a fresh wallet bought the top tier (Hyper, 90d) straight in BNB — one entry purchase yielded sustained top power without ever touching the RAM economy (85% burn / 15% treasury). The gate closes that bypass; the honest growth paths (rigs 2+ / upgrades, RAM-paid) are untouched.
- **Charging logic unchanged:** the BNB entry branch's payment/refund logic is byte-identical apart from the added plan check before any state change; a reverted attempt leaves the wallet fully fresh (test-proven).
- **The audited tier table is untouched** (powers/prices/durations); the gate is purchase *eligibility*, not re-numbering.
- **Operating assumption to note:** with RAM pricing disarmed a fresh wallet can only ever hold 1-day Micros, so production launches arm the oracle + cage at creation via `vaultData` (already the plan; fields 6-8).

## 1. Scope of the diff to audit (v2-keeper → v3-economy)

`git diff 87847a4..72d7d38 -- src/`:

| File | Change | What it is |
|---|---|---|
| `src/RamMiningVault.sol` | +860 / −209 lines | Phase-2 economy on top of the audited vault: two-phase payments (first rig per wallet in BNB and restricted to the Micro entry plan — see §0; later rigs / upgrades / repairs in the RAM tax token, 85% burned to 0xdEaD + 15% to an immutable treasury wallet), time-only wear ladder implemented as partial sub-expirations on the audited bucket machinery, `repairRig`, `upgradeRig`, oracle-caged RAM pricing (disarmed until oracle + cage armed; over-charging is the fail-safe direction; the claim path never touches the oracle), `vaultData` extended to 9 fields (10 in v3.2 — `basePriceUsd`, see §0-bis), and the EIP-170 migration of all developer revert paths to custom errors (1:1 named after the old literal strings — approved by Flap 2026-07-03 given the bespoke UI). |
| `src/RamPriceOracle.sol` | +502 lines (new) | Production RAM/BNB price oracle: curve-phase portal price → post-graduation truncated TWAP30×TWAP5 min-rule on the Pancake pair, with freshness / liquidity-floor / maturity gates; fail-safe to untrusted (vault then falls back to `cageMin` = most-units-charged). Includes the adversarial-review fix: symmetric truncation + anti-flash liquidity floor. |
| `src/TestRamOracle.sol` | +30 lines (new) | Fixed-price mock oracle for testnet only. Not part of the production deployment. |

**What did NOT change (audited surfaces, byte-identical):** the keeper RFQ (`sellRWAToVault`/`quoteRWAToVault`) and every drain guard (hard feed staleness, deviation band, per-fill / per-window caps, `disarmSells`, premium clamp [1.02, 1.04]), unconditional claims (no pause), the wear/expiry bucket machinery, factory + beacon + 2-day timelock + Step-0 dev-lock, and the tier **durations** (1d/7d/30d/90d, season-capped). Keeper egress guards still default to 0 at creation (sells disabled until the Guardian arms them) — the launcher-armed `vaultData` fields cover only RAM-sink pricing (oracle, cage, treasury, and in v3.2 the USD base), not BNB egress. **What changed deliberately in v3.2** (see §0-bis): the tier price multipliers + powers, and the RAM-sink denomination (fixed USD targets via the BNB/USD feed; `vaultData` extended to 10 fields).

## 2. Build (pinned, reproducible)

```
forge build
```

`foundry.toml` pins everything relevant: `solc 0.8.26`, `evm_version = "cancun"`, `via_ir = true`, `optimizer_runs = 1`, `bytecode_hash = "none"`. These are **deployability requirements** (EIP-170/EIP-3860), not optimization choices — see §4 of our re-review letter (the audited v2 at 99999 runs compiled to 40,004 B runtime, undeployable).

**Dependencies (not bundled in the source-only ZIP — per your request to keep it small):** OpenZeppelin `openzeppelin-contracts` **v4.9.6** + `openzeppelin-contracts-upgradeable` **v4.9.6**, and `forge-std`. Restore with `forge install OpenZeppelin/openzeppelin-contracts@v4.9.6 OpenZeppelin/openzeppelin-contracts-upgradeable@v4.9.6 foundry-rs/forge-std` (or use the full public repo, which vendors them). Remappings are in `remappings.txt`. `src/flap/*` is Flap's own V2 framework, unmodified.

Size gate (run it — it is the pre-broadcast gate we use):

```
forge build --sizes
```

Expected (v3.2): `RamMiningVaultUpgradeable` runtime 19,425 B (EIP-170 margin +5,151), `RamMiningBeaconFactory` initcode 28,790 B (EIP-3860 margin +20,362), `RamPriceOracle` ≈ 5 KB.

## 3. Tests

```
forge test                          # full suite; the 4 fork tests self-skip without RPC
BNB_RPC_URL=https://bsc-rpc.publicnode.com \
NVDAX_ADDRESS=0x02Fca66C1D1aFB4E2A7884261eB00F63598a7436 \
forge test                          # full suite incl. BSC-mainnet fork tests
```

Expected with RPC: **136 passed / 0 failed** across 11 files (incl. the 7 new v3.2 USD-sink tests and the
mainnet-fork launch rehearsal `test/LaunchRehearsal.fork.t.sol`), including:
- `test/RamMiningVaultPhase2.t.sol` — the Phase-2 economy (two-phase payments, the v3.1 entry gate incl. overpay/underpay edges, wear ladder, repair, upgrade, treasury split)
- `test/Adversarial.t.sol` — adversarial edges from our internal review (repair-in-wear-bucket, sequential repairs, claim→repair→claim double-count, last-day upgrade, multi-actor collapse to zero power with `Σ claimed ≤ Σ distributed`)
- `test/RamPriceOracle.t.sol` + `test/RamPriceOracleAdversarial.t.sol` — oracle gates + the manipulation PoCs (spot +100% → oracle +8.33%; reseed 12.5× → 1.00×)
- `test/RamMiningVault.fork.t.sol` + `test/RamPriceOracle.fork.t.sol` — against real BSC mainnet state (real NVDAB, real feeds, real Pancake pair)

## 4. Layout

```
src/RamMiningVault.sol      vault (RamMiningVaultUpgradeable) + factory (RamMiningBeaconFactory)
src/RamPriceOracle.sol      production RAM price oracle (standalone, pluggable via vaultData)
src/FlapDeployed.sol        VaultPortal address resolver
src/Test*.sol               testnet mocks only (not deployed to production)
src/flap/                   Flap V2 framework + interfaces — UNMODIFIED vendor code
test/                       9 test files (~3,400 lines)
lib/                        pinned dependencies (forge-std, openzeppelin-contracts, openzeppelin-contracts-upgradeable) — vendored in this ZIP so the build needs no network
```

## 5. Prior disclosures that still apply

From our re-review letter (2026-07-02, in the group): (1) upgrade-timing is economic/By-Design (pro-rata game, cannot touch accrued rewards); (2) the 15% treasury share goes to a dedicated immutable treasury wallet (`totalRamTreasuryPaid` public); (3) minimal `vaultUISchema` stub given the bespoke UI (approved 2026-07-03). The deployability finding (EIP-170/EIP-3860 vs Foundry simulation) is documented there too.
