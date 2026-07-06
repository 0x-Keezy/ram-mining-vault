# RAM Mining Vault — v3 (Phase-2 economy) audit package

This package is the source for the **v3 re-audit** requested by the Flap team ("if it is not covered in the previous audit, we need to perform another audit" — 2026-07-03). It is self-contained: sources, tests, pinned dependencies and build config.

- **Audited base (previous audit):** branch `v2-keeper` @ `87847a4de8c7ed2e32a15624d69ced0797adc57c`
- **Audit target (this package):** branch `v3-economy` — **v3.2** (public repo: https://github.com/0x-Keezy/ram-mining-vault/tree/v3-economy). `src/` and `test/` are **functionally frozen** at v3.2 code commit `7bde569`: the runtime bytecode keccak is unchanged and all 136 tests pass identically. The only deltas since `7bde569` are NatSpec/comment touch-ups (storage-gap prose; the corrected tier power-days-per-$ figures) plus this documentation (AUDIT.md / README / foundry.toml comments) — none affect bytecode (comments don't compile). Verify with `forge build` + the `deployedBytecode` hash.
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
Wear-adjusted power-days per dollar (computed on the exact bucket machinery): Core ≈ 54, Mega ≈ 54,
Hyper ≈ 57 — an approximately flat yield-per-$ across the three paid tiers, with a modest **~+5%**
commitment premium on the 90-day Hyper. The Micro remains the BNB entry gate (§0), not a yield vehicle.

**(b) RAM sinks now charge fixed USD targets.** Growth purchases (rig #2+ / upgrades / repairs, all
RAM-paid) previously charged the tier's BNB reference converted to RAM. They now charge **fixed USD targets**
(`basePriceUsd × 1/5/25/100`, 8-dec, new `vaultData` field — total 10 fields), converted USD → BNB via the
vault's already-hardened Chainlink BNB/USD feed (`_readFeed`, hard staleness ≤ `MAX_BNB_FEED_STALE` = 1d)
and BNB → RAM via the oracle+cage exactly as reviewed. **Fail-closed:** a stale/bad BNB/USD feed reverts the
growth purchase (`StaleFeed`) — never a mis-priced sink; the BNB entry rig and claims have **no** feed
dependency. New view `getPlanUsd(planId)`; quotes revert exactly like the charge would (honest quoting).
This also makes the previously-documented "USD conversion is done by the vault" NatSpec true in code.
The former `_chargeRam` was renamed `_chargeRamUsd` as part of this change; any `_chargeRam` reference in
earlier reports/replies describes the v3.1 source those reviewed. The sinks take no user-side
max-units/slippage parameter by design: the charged price is the manipulation-resistant TWAP+cage oracle
read (not a spot AMM read), so per-tx price manipulation is infeasible and worst-case overpay is bounded by
the guardian-set `cageMax/cageMin` ratio — and any overpay is burned/treasuried, never paid to a caller, so
there is no extraction incentive (callers can preview via `quoteRigInRam`).

**Deployment note:** v3.2 changes bytecode and the `vaultData` layout, so it supersedes the never-used
on-chain v3.1 factory `0x0555A89c4b0b64e08193538e1DC633F4090C4299` (BNB mainnet, zero vaults created); the
partner redeploys from this build before launch. Our version2 reply anticipated USD pricing as a post-launch
Phase-2 beacon upgrade — we chose to land it now, pre-launch, together with the tier rebalance (one
deliberate economic revision, one audit round) precisely to avoid upgrading a live vault.

Suite adds 6 USD-sink tests (130 → 136 total): exact conversion (quote == charge), sticker invariance under
BNB moves, stale-feed fail-closed (growth blocked; the BNB entry and claims unaffected), USD-difference
upgrades + USD-target repairs (one shared test), `basePriceUsd=0 → BadConfig`, and the `getPlanUsd` table;
the mainnet-fork launch rehearsal runs the full USD-sink flow end-to-end.

## 0. v3.1 addendum — entry gate (found in our own live-testnet QA, disclosed proactively)

One change landed after our re-review letter: **`EntryRigMustBeMicro` — a fresh wallet's first (BNB-paid) rig is now restricted to plan 0 (Micro)**, via a single `require`-style check + one custom error + one `public constant ENTRY_PLAN_ID = 0` (16 lines, `buyMiningContract` entry branch). Every later rig / upgrade / repair (any tier) flows through the RAM sinks unchanged.

- **Why:** in live testnet QA a fresh wallet bought the top tier (Hyper, 90d) straight in BNB — one entry purchase yielded sustained top power without ever touching the RAM economy (85% burn / 15% treasury). The gate closes that bypass; the honest growth paths (rigs 2+ / upgrades, RAM-paid) are untouched.
- **Charging logic unchanged:** the BNB entry branch's payment/refund logic is byte-identical apart from the added plan check before any state change; a reverted attempt leaves the wallet fully fresh (test-proven).
- **The audited tier table is untouched** (powers/prices/durations); the gate is purchase *eligibility*, not re-numbering.
- **Operating assumption to note:** with RAM pricing disarmed a fresh wallet can only ever hold 1-day Micros, so production launches arm the oracle + cage at creation via `vaultData` (already the plan; fields 7-9 of the 10-field v3.2 vaultData).

## 1. Scope of the diff to audit (v2-keeper → v3-economy)

`git diff 87847a4..574e206 -- src/` (the v3.2 code diff; the package head adds only bytecode-neutral NatSpec/comment touch-ups on top):

| File | Change | What it is |
|---|---|---|
| `src/RamMiningVault.sol` | +721 / −216 lines | Phase-2 economy on top of the audited vault: two-phase payments (first rig per wallet in BNB and restricted to the Micro entry plan — see §0; later rigs / upgrades / repairs in the RAM tax token, 85% burned to 0xdEaD + 15% to an immutable treasury wallet), time-only wear ladder implemented as partial sub-expirations on the audited bucket machinery, `repairRig`, `upgradeRig`, oracle-caged RAM pricing (disarmed until oracle + cage armed; over-charging is the fail-safe direction; the claim path never touches the oracle), `vaultData` extended to 9 fields (10 in v3.2 — `basePriceUsd`, see §0-bis), and the EIP-170 migration of all developer revert paths to custom errors (1:1 named after the old literal strings — approved by Flap 2026-07-03 given the bespoke UI). |
| `src/RamPriceOracle.sol` | +503 lines (new) | Production RAM/BNB price oracle: curve-phase portal price → post-graduation truncated TWAP30×TWAP5 min-rule on the Pancake pair, with freshness / liquidity-floor / maturity gates; fail-safe to untrusted (vault then falls back to `cageMin` = most-units-charged). Includes the adversarial-review fix: symmetric truncation + anti-flash liquidity floor. |
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
forge test                          # full suite; the 5 RPC-gated tests self-skip without RPC (131 pass, 5 skip)
BNB_RPC_URL=https://bsc-dataseed.bnbchain.org \
NVDAX_ADDRESS=0x02Fca66C1D1aFB4E2A7884261eB00F63598a7436 \
forge test                          # full suite incl. BSC-mainnet fork tests
```

Expected with RPC: **136 passed / 0 failed** across 10 test files (11 suites; incl. the 6 new v3.2 USD-sink
tests and the mainnet-fork launch rehearsal `test/LaunchRehearsal.fork.t.sol`), including:
- `test/RamMiningVaultPhase2.t.sol` — the Phase-2 economy (two-phase payments, the v3.1 entry gate incl. overpay/underpay edges, wear ladder, repair, upgrade, treasury split)
- `test/Adversarial.t.sol` — adversarial edges from our internal review (repair-in-wear-bucket, sequential repairs, claim→repair→claim double-count, last-day upgrade, multi-actor collapse to zero power with `Σ claimed ≤ Σ distributed`)
- `test/RamPriceOracle.t.sol` + `test/RamPriceOracleAdversarial.t.sol` — oracle gates + the manipulation PoCs (single-interval spike truncation, the reseed-after-gap vector reproduced on live Pancake pair state in the fork PoC, and the flash-passable liquidity floor)
- `test/RamMiningVault.fork.t.sol` + `test/RamPriceOracle.fork.t.sol` — against real BSC mainnet state (real NVDAB, real feeds, real Pancake pair)

## 4. Layout

```
src/RamMiningVault.sol      vault (RamMiningVaultUpgradeable) + factory (RamMiningBeaconFactory)
src/RamPriceOracle.sol      production RAM price oracle (standalone, pluggable via vaultData)
src/FlapDeployed.sol        VaultPortal address resolver
src/Test*.sol               testnet mocks only (not deployed to production)
src/flap/                   Flap V2 framework + interfaces — UNMODIFIED vendor code
test/                       10 test files / 11 suites (3,924 lines)
lib/                        pinned dependencies (forge-std, openzeppelin-contracts, openzeppelin-contracts-upgradeable) — NOT bundled in this source-only ZIP; restore with `forge install`, see §2
```

## 5. Prior disclosures that still apply

From our re-review letter (2026-07-02, in the group): (1) upgrade-timing is economic/By-Design (pro-rata game, cannot touch accrued rewards); (2) the 15% treasury share goes to a dedicated immutable treasury wallet (`totalRamTreasuryPaid` public); (3) minimal `vaultUISchema` stub given the bespoke UI (approved 2026-07-03). The deployability finding (EIP-170/EIP-3860 vs Foundry simulation) is documented there too.

Two findings from earlier reports on this vault, still applicable and already answered:
- (4) **Weekend/off-hours frozen-feed arbitrage residual** — report version3 Finding 1, answered **By Design**: the keeper deviation band is structurally blind to a frozen-but-tolerated NVDA/USD feed; the residual is bounded by the per-fill / per-window BNB egress caps + the clamped premium, and Flap #8 explicitly requested that weekend operation not pause. Documented in README ("Weekend / off-hours pricing").
- (5) **Economic-agent loop ships fully disarmed** — report version1 Finding 2, answered **Acknowledged**: `initialize` leaves provider / trigger / fee / interval at zero, enabling is `onlyGuardian`, and spend is self-limiting (`_armNextEpoch` stops re-arming below the fee; `_requestReasoning` reverts below it) — it can never drain the reserve. Documented in README ("Economic Agent") and proven in `test/RamMiningVaultAgent.t.sol`.

## 6. Platform-rule compliance (re-checked on this exact v3.2 source)

| Rule | Status | Evidence (this package) |
|---|---|---|
| 001 No-DOS | complies | Claims never gated (src/RamMiningVault.sol:465-480, nonReentrant, no pause); the BNB entry has zero feed/oracle dependency (the only `bnbPriceFeed` reads are the sink charge :541, sink quote :618 and keeper quote :689); the RAM growth sink is guardian-armed and fail-closed by design (cage :1281-1283, `StaleFeed` :541) — the same disabled-until-armed pattern as the audited keeper egress. Proven: test/RamMiningVaultPhase2.t.sol (stale BNB/USD blocks growth only, never entry/claims). |
| 002 Portal-only `newVault` | complies | src/RamMiningVault.sol:1533 (`OnlyVaultPortal`); reference test test/RamMiningVault.t.sol:350. |
| 003 Fairness | complies (improved in v3.2) | The rebalanced table resolves the original F2 yield-skew (~flat yield-per-$, ~+5% top-tier commitment premium — §0-bis); all tier terms public via `getPlan` / `getPlanUsd`; the Micro-only BNB entry is a disclosed Sybil-limiting eligibility gate (§0), every higher tier reachable by any wallet as rig #2+. |
| 004 Literal revert strings | waived | Custom errors 1:1-named after the old literals; waiver granted by Flap 2026-07-03 given the bespoke UI (§1). |
| 005/006 `receive()` gas | complies | Empty `receive()` (src:378, no external calls/loops); test/RamMiningVault.t.sol:1178-1185 asserts < 1,000,000 gas. |
| 009 Emergency-withdraw | exempt (BeaconProxy) | No hatches by design (src:1179-1184; README "Safety model"); recovery is the Guardian-only beacon upgrade behind the 2-day timelock (all four upgrade fns `OnlyGuardian`); tests :759, :1093. |
| Flap #8 weekend operation | complies | NVDA/USD staleness generous by request (7d default, 30d hard wall) so weekend fills keep operating; BNB/USD kept tight (2h default, 1d hard cap); tests + fork suite. |
