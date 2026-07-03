# RAM Mining Vault — v3 (Phase-2 economy) audit package

This package is the source for the **v3 re-audit** requested by the Flap team ("if it is not covered in the previous audit, we need to perform another audit" — 2026-07-03). It is self-contained: sources, tests, pinned dependencies and build config.

- **Audited base (previous audit):** branch `v2-keeper` @ `87847a4de8c7ed2e32a15624d69ced0797adc57c`
- **Audit target (this package):** branch `v3-economy` @ `72d7d38302bc1c582287ef5005d6cd83e45fa330` (public repo: https://github.com/0x-Keezy/ram-mining-vault/tree/v3-economy — this ZIP adds only this AUDIT.md on top, zero code delta)
- **Contact:** Shilder (dev-lock wallet `0x8216fCD8a714B82Ee9d60793F551957D9abc1CA1`), Telegram group `Shilder <> FLAP`

## 1. Scope of the diff to audit (v2-keeper → v3-economy)

`git diff 87847a4..72d7d38 -- src/`:

| File | Change | What it is |
|---|---|---|
| `src/RamMiningVault.sol` | +844 / −209 lines | Phase-2 economy on top of the audited vault: two-phase payments (first rig per wallet in BNB — audited path unchanged; later rigs / upgrades / repairs in the RAM tax token, 85% burned to 0xdEaD + 15% to an immutable treasury wallet), time-only wear ladder implemented as partial sub-expirations on the audited bucket machinery, `repairRig`, `upgradeRig`, oracle-caged RAM pricing (disarmed until oracle + cage armed; over-charging is the fail-safe direction; the claim path never touches the oracle), `vaultData` extended to 9 fields, and the EIP-170 migration of all developer revert paths to custom errors (1:1 named after the old literal strings — approved by Flap 2026-07-03 given the bespoke UI). |
| `src/RamPriceOracle.sol` | +502 lines (new) | Production RAM/BNB price oracle: curve-phase portal price → post-graduation truncated TWAP30×TWAP5 min-rule on the Pancake pair, with freshness / liquidity-floor / maturity gates; fail-safe to untrusted (vault then falls back to `cageMin` = most-units-charged). Includes the adversarial-review fix: symmetric truncation + anti-flash liquidity floor. |
| `src/TestRamOracle.sol` | +30 lines (new) | Fixed-price mock oracle for testnet only. Not part of the production deployment. |

**What did NOT change (audited surfaces, byte-identical):** the Genesis tier table (powers 10/40/130/420, prices ×1/×3/×8/×20, durations 1/7/30/90 days), the keeper RFQ (`sellRWAToVault`/`quoteRWAToVault`) and every drain guard (hard feed staleness, deviation band, per-fill / per-window caps, `disarmSells`, premium clamp [1.02, 1.04]), unconditional claims (no pause), factory + beacon + 2-day timelock + Step-0 dev-lock. Keeper egress guards still default to 0 at creation (sells disabled until the Guardian arms them) — the launcher-armed `vaultData` fields cover only RAM-sink pricing (oracle, cage, treasury), not BNB egress.

## 2. Build (pinned, reproducible)

```
forge build
```

`foundry.toml` pins everything relevant: `solc 0.8.26`, `evm_version = "cancun"`, `via_ir = true`, `optimizer_runs = 1`, `bytecode_hash = "none"`. These are **deployability requirements** (EIP-170/EIP-3860), not optimization choices — see §4 of our re-review letter (the audited v2 at 99999 runs compiled to 40,004 B runtime, undeployable).

Size gate (run it — it is the pre-broadcast gate we use):

```
forge build --sizes
```

Expected: `RamMiningVaultUpgradeable` runtime ≈ 19.5 KB (EIP-170 margin ≈ +5 KB), `RamMiningBeaconFactory` initcode within EIP-3860, `RamPriceOracle` ≈ 5 KB.

## 3. Tests

```
forge test                          # full suite; the 4 fork tests self-skip without RPC
BNB_RPC_URL=https://bsc-rpc.publicnode.com \
NVDAX_ADDRESS=0x02Fca66C1D1aFB4E2A7884261eB00F63598a7436 \
forge test                          # full suite incl. BSC-mainnet fork tests
```

Expected with RPC: **124 passed / 0 failed** across 9 files, including:
- `test/RamMiningVaultPhase2.t.sol` — the Phase-2 economy (two-phase payments, wear ladder, repair, upgrade, treasury split)
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
