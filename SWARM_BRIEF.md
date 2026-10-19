# IMD Vault · swarm launch brief (19 Oct)

We wrote and tested the contracts ourselves. The swarm audits them (four specialists and a judge) and deploys the
factory as an `evm_contracts` launch (contracts only: no token, no pool). The factory deploys every vault itself, so
`VaultFactory` is the only contract the swarm deploys.

## Wallet

IMD RADAR's public wallet: `0x75df3d2e7a1d23021e5d7ef06312d13009e9bbb8`.
- Pays the `launch.open` jobs (0.5 IMD each). The user signs them.
- Receives every project's 5 IMD fee. It is fixed in the Ethereum factory at deployment and cannot change later.
- It holds no vault funds and has no power over any vault: losing this key would only redirect future fees.

On 19 Oct it is a plain wallet (EOA) with about 10 IMD and 0.014 ETH.

## Before paying

1. Push `imd-vault` to a new **public** GitHub repository, `imd-vault`.
   - `lib/` goes in as well: OpenZeppelin 5.1.0 and forge-std, vendored.
   - `foundry.toml` already has `bytecode_hash = "none"`, as the import requires.
   - Needs the user's OK: our rule is private repos, but the swarm only imports public ones.
2. Resolve the commit: `POST /requests/import` with the repo URL. It returns `repoUrl` and `baseCommit`.
3. Run the launch body below through `POST /requests/check` (free). Fix anything it refuses; a refused body is a
   spent payment.
4. The radar wallet pays 0.5 IMD for `launch.open`.

## launch.open body (Ethereum)

```json
{
  "objective": "Audit and deploy IMD Vault: ownerless vesting and treasury vaults for identity.md projects. Deploy exactly src/VaultFactory.sol with constructor arguments: imd_=0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7, feeRecipient_=$owner. The factory deploys VestingVault and TreasuryVault itself and charges each project 5 IMD once, paid to feeRecipient_ (IMD RADAR's public wallet); payFor(chainId, token) lets a project on another chain pay on Ethereum. Keep the rules exactly as written in the source and README: no owner, admin, pause, upgrade or emergency withdrawal; vesting unlocks at most 25% a week (duration of at least 4 weeks after the cliff); treasury withdrawals wait at least 24h and at most 25% of a balance can leave per week; every rule can only get stricter. Fix only real findings, and add a Foundry test for each fix.",
  "repoUrl": "https://github.com/Jamesjady/imd-vault",
  "baseCommit": "<from /requests/import>",
  "contracts": ["src/VaultFactory.sol"],
  "references": ["solidity-security-review", "eth-security", "pashov-skill"],
  "onchain": "evm_contracts",
  "chainId": 1,
  "owner": "0x75df3d2e7a1d23021e5d7ef06312d13009e9bbb8",
  "github": true
}
```

- `owner` becomes `$owner` in the constructor, so the radar wallet is the fee recipient. It must be lowercase and
  nonzero. The factory gives the owner no other power.
- Nothing needs to be called after deployment.

## Robinhood (chain 4663)

The Robinhood factory takes no fee: `imd_` and `feeRecipient_` are both zero, and projects pay on Ethereum with
`payFor(4663, token)`. Two ways to deploy it:
- **Through the swarm**, if `/requests/check` accepts `chainId: 4663` for `evm_contracts`: the same body with
  `"chainId": 4663` and the objective's constructor arguments changed to `imd_=0x0000000000000000000000000000000000000000,
  feeRecipient_=0x0000000000000000000000000000000000000000`. Another 0.5 IMD. Same audited code, so ask for no changes.
- **Ourselves**, if it does not: `forge create` from the audited commit, signed by the user. Gas only.

## What we check when it is live

- Etherscan or Blockscout: verified source; `imd()` is IMD; `feeRecipient()` is the radar wallet; `FEE()` is 5e18.
- One real project's first vault: the radar wallet receives exactly 5 IMD, `feePaid(1, token)` is true, and the
  `VestingCreated` or `TreasuryCreated` event lists the vault.
- The radar reads `allVaults`, `vaultsByToken` and the events to show vaults, the seal and queued withdrawals.

## Budget

| Item | IMD |
|---|---|
| `launch.open` Ethereum (audit + deploy) | 0.5 |
| `launch.open` Robinhood (if the swarm supports it) | 0–0.5 |
| Possible `job.continue` rounds if the judge asks for fixes (each 0.5) | 0.5–2 |
| **Total** | **1–3** |

The wallet's 10 IMD covers it. ETH is only needed for the transactions that pay the jobs.

## Timeline

| Day | Work |
|---|---|
| Sun 19 | Contracts, tests, brief ✅; public repo; `/requests/import` + `/requests/check`; pay `launch.open` |
| Mon 20 | Audit findings → fixes (`job.continue` if needed); deployed; Robinhood factory |
| Mon 20 | Radar: vaults on token files, the seal, queued-withdrawal alerts |
| Tue 21 | Hackathon entry and announcement |
