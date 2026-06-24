# RAM — Mining Vault

A **real-yield mining vault** for the [Flap](https://flap.sh) Tax Vault V2 framework on BNB Chain.

## Concept

RAM is a Flap tax token. Instead of buyback-and-burn, a share of its trading fees is routed to this
vault, swapped into **tokenized NVIDIA (NVDAx / bStocks)**, and distributed to "miners" in proportion
to their **mining power**. You buy mining power ("rigs") with BNB and earn real NVIDIA.

- **Real yield** — rewards come from actual trading fees + a real asset, not from token emissions, so
  there is no "dry vault" risk.
- **No burn** — fees buy a productive asset and pay it out, rather than being destroyed.

## Mechanism (reference for review)

- **Reward engine.** A MasterChef-style accumulator (`accRewardPerPower`) splits a variable,
  asynchronously-funded reward pool fairly by each miner's power. No inflation, no emission.
- **Fee flow.** Tax fees arrive as BNB → the vault swaps BNB → NVDAx on a DEX router → distributes by
  power share.
- **Rig / plan expiration.** Handled by lazy liquidation in time buckets (exact, near-zero keeper cost).
- **Economic Agent (AI oracle).** The vault extends Flap's on-chain AI oracle
  (`FlapAIConsumerBase` + `ITriggerReceiver`). Each epoch runs a **trigger → reason → fulfill** loop in
  which an on-chain LLM reads vault + market state and selects a **discrete, clamped lever**:
  hold / DCA-buy NVDA / retain reserves / raise–lower DCA aggressiveness / pause sales — **never burn**.
  - **Tiered autonomy:** low-impact moves execute autonomously; high-impact moves (e.g. pausing sales)
    are queued behind a **timelock** and executed by the **guardian**.
  - **Funds are never trapped:** `claim` is always available, even if sales are paused.
  - Each decision carries an **IPFS proof** of its reasoning.
- **Invariant** (enforced in tests): `Σ claimed ≤ Σ distributed`.
- **Upgradeability.** Implementation behind OpenZeppelin `BeaconProxy` + `UpgradeableBeacon`, with
  **Guardian-only** upgrade authority and a timelock — fits Flap's beacon "launch-first" safety model.

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
# mainnet-fork integration test against real NVDAx (needs a BNB RPC):
forge test --match-path test/RamMiningVault.fork.t.sol --fork-url $BNB_RPC -vvv
```

## Deploy (BNB testnet)

```bash
forge script script/testnet/bnb/DeployRamMining.s.sol:DeployRamMining \
  --rpc-url $BNB_TESTNET_RPC --broadcast
```

## License

MIT — see [LICENSE](LICENSE).
