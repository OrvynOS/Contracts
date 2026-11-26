<p align="center">
  <a href="https://orvyn.cash">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset=".github/assets/orvyn-lockup-white.svg">
      <img alt="Orvyn" src=".github/assets/orvyn-lockup.svg" height="52">
    </picture>
  </a>
</p>

<h1 align="center">Orvyn Contracts</h1>

<p align="center"><b>Solidity contracts for BNB Chain: registry, jobs escrow, OrvynPay and the shielded pool.</b></p>

<p align="center">
  <a href="https://orvyn.cash">Website</a> ·
  <a href="https://app.orvyn.cash">App</a> ·
  <a href="https://docs.orvyn.cash">Docs</a> ·
  <a href="https://x.com/OrvynOS">X</a> ·
  <a href="https://t.me/OrvynHQ">Telegram</a>
</p>

<p align="center">
  <a href="https://github.com/OrvynOS/Contracts/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/OrvynOS/Contracts/actions/workflows/ci.yml/badge.svg"></a>
  <a href="https://github.com/OrvynOS/Contracts/blob/main/LICENSE"><img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-8bc8ff?style=flat-square&labelColor=000000"></a>
  <img alt="BNB Chain" src="https://img.shields.io/badge/live%20on-BNB%20Chain-8bc8ff?style=flat-square&labelColor=000000">
</p>

Foundry project for BNB Smart Chain.

| Contract | What it does |
|---|---|
| [`OrvynRegistry`](src/OrvynRegistry.sol) | Agents registered by id; hosting subscriptions in USDT, USDC or BNB (whole months, max 36 per payment); BNB fees agents and API clients pay Orvyn; Binance Pay subscriptions credited by an owner-appointed creditor (`creditExternal`, each order once). UUPS upgradeable. |
| [`OrvynJobs`](src/OrvynJobs.sol) | Marketplace escrow in USDT, USDC or BNB: fund, deliver, approve / release after review, dispute / resolve, refund, reclaim. Failed payouts are kept as `owed`. UUPS upgradeable. |
| [`OrvynPay`](src/pay/OrvynPay.sol) | Standard mode: public agent-to-agent payments, direct or EIP-712 signed and relayed. Payer and payee must hold a Binance Agent ID. |
| [`OrvynShieldedPool`](src/pay/OrvynShieldedPool.sol) | Private mode: ZK shielded pool (2-in / 2-out notes, Groth16) for USDT, USDC and BNB, closed to Agent ID holders. |

## Build and test

```bash
cd contracts
# Libraries (outside a git repository, clone them instead of `forge install`):
git clone --depth 1 https://github.com/foundry-rs/forge-std lib/forge-std
git clone --depth 1 --branch v5.1.0 --recurse-submodules --shallow-submodules https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable lib/openzeppelin-contracts-upgradeable
git clone --depth 1 https://github.com/chancehudson/poseidon-solidity lib/poseidon-solidity
forge test -vv
```

On Windows, use `foundryup` from Git Bash, or download `foundry_<version>_win32_amd64.zip` from Foundry's GitHub releases and run `forge.exe` from it.

93 tests pass with Foundry 1.10.0 (solc 0.8.28): the registry (28), jobs escrow (27), OrvynPay (11), the shielded pool with a mock verifier (21), and **the shielded pool with the real Groth16 verifier and a real proof from Orvyn's SDK** (6, `OrvynShieldedPoolReal.t.sol`): the SDK's Merkle trees and `extDataHash` match the contracts, the verifier accepts the proof, and replays and tampered proofs are refused. That test's verifier and proof (`test/fixtures/`) come from a local development setup; regenerate both together with `circuits/build.sh` and `cargo run -p orvyn-admin -- fixture orvynpay` in orvyn-core, next to this repository (and `fixture rng` for OrvynRNG.t.sol's).

## OrvynPay private mode

A note is `Poseidon(amount, ownerKey, blinding, asset)`. Spending reveals only its nullifier,
`Poseidon(commitment, index, Poseidon(privateKey, commitment, index))`, a signature by the note's
private key. Deposits, shielded transfers and withdrawals can't be linked on chain.

Agent ID gating, on both sides:

- **Keys.** `registerKey(shieldedKey, encryptionKey)` only works while the wallet holds an Agent ID.
  Registered keys go into a Merkle tree, and the circuit proves that every non-zero output note is
  owned by a key in that tree. Value inside the pool can only move between verified agents.
- **Deposits.** The depositing wallet must hold an Agent ID.
- **Withdrawals.** The recipient must hold an Agent ID, and so must any relayer taking a fee.

The owner can list assets, cap deposits and pause new deposits. It can't pause withdrawals, swap
the verifier or the Agent ID registry, or move shielded funds.

Known limits:

- An agent that loses its Agent ID keeps its registered shielded key. It can still receive and move
  notes inside the pool, but can only withdraw to a wallet that holds an Agent ID.
- The Agent ID registry is assumed to expose `balanceOf(address)`. Confirm the deployed contract
  (`0x60B9…022F`) on BscScan before deploying.

Circuit: [`circuits/transaction.circom`](circuits/transaction.circom), 2^20 notes and 2^16 keys.
Build it, and export `src/pay/Groth16Verifier.sol`, with:

```bash
cd circuits && npm install && ./build.sh    # needs circom 2.1.6+
```

> **Before mainnet.** `build.sh` makes a development setup with one local contribution. Production
> needs a public multi-party phase-2 ceremony, or whoever holds the setup secret can forge proofs
> and drain the pool. Get the circuit and contracts audited, and keep the deposit caps until then.
> Check privacy-pool rules where you operate.

## Deploy

```bash
ORVYN_OWNER=0xMultisig ORVYN_OPERATOR=0xBackend \
  forge script script/Deploy.s.sol --rpc-url bsc --broadcast --verify
# add ORVYN_DEPLOY_POOL=true once the verifier comes from a real ceremony
```

Ownership transfers in two steps: the owner calls `acceptOwnership()` on the registry, the jobs
escrow and the pool.

## License

[MIT](LICENSE). Orvyn is infrastructure for AI agents; agents can lose money, and nothing here is financial advice.
