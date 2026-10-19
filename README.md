# IMD Vault

Vaults nobody owns, for the identity.md ecosystem. A project locks its team tokens and its treasury under rules
written in code, and IMD RADAR shows those rules, and every move, on the project's file.

Built for the Identity MD Hackathon (October 2026). See [SWARM_BRIEF.md](SWARM_BRIEF.md) for the audit and deployment through the IMD swarm.

## Contracts (`src`)

| Contract | What it does |
|---|---|
| `VaultFactory` | Creates vaults and charges 5 IMD once per project (the first vault for a token; later ones are free), paid to IMD RADAR's public wallet to fund its servers and swarm jobs. On chains without IMD (Robinhood) vaults are free to create and the project pays on Ethereum with `payFor(chainId, token)`. It keeps a public registry (`allVaults`, `isVault`, `vaultsByToken`). No owner, holds no funds. |
| `VestingVault` | Team tokens: nothing during the cliff, then linear over the duration, which must be at least 4 weeks, so no schedule unlocks more than 25% in any week. Each project picks its own cliff and duration above that floor; `start` can not be in the past, and the whole schedule must fit in a `uint64`. `release()` is callable by anyone and only pays the beneficiary. The duration can only grow. A new beneficiary takes over after 7 days. |
| `TreasuryVault` | Treasuries: anyone deposits tokens or ETH. The manager can only queue a withdrawal; it executes after the delay (at least 24h, at most 30 days, checked by the vault itself), within 14 days, only to an allowed destination, and no more than `rateBps` (at most 25%) of the balance can leave per asset per 7-day epoch. Delay can only grow, rate only shrink, destinations only be removed. A new manager takes over after the delay. |

Nothing has an admin, a pause, an upgrade path or an emergency withdrawal.

### Accounting notes
- Vesting counts `balance + released`, so fee-on-transfer tokens and later top-ups vest on the same schedule.
- The weekly cap is fixed by the first withdrawal executed in an epoch (`rateBps` of the balance at that moment);
  deposits later in the same epoch do not raise it.
- Epochs are fixed calendar weeks (`block.timestamp / 7 days`), not a rolling window. A span of 7 days can straddle
  two epochs, so the most that can leave in any 7 days is `rate + rate × (1 − rate)` of the balance at its start:
  43.75% at the 25% ceiling, in two withdrawals a week apart at most. A rate decrease applies from the next epoch when
  a withdrawal has already executed in the current one.
- Tightening a rule (longer delay, removed destination) also holds back withdrawals already queued.
- A restricted treasury always keeps at least one destination, so it can never freeze itself.
- `recover()` in a bound vault reads the vested token's balance before and after, so a token with a second entry
  point to the same balance (a legacy or proxy contract) can not move it out early.

## Locking a launch's supply before the token exists

When the IMD swarm launches a token, 10% of the supply goes to the swarm, part of the requester's 90% seeds the pool,
and the rest is sent to `remainderTo` in the launch transaction (the paying wallet by default). A project can name a
vault there instead, so its share never passes through the team's wallet:

1. Before launching, create the vault: `createLaunchVesting(beneficiary, start, cliff, duration)`, or
   `createTreasury(address(0), manager, delay, rateBps, destinations)`. It pays the 5 IMD fee, keyed to the vault.
2. Put the vault's address as `remainderTo` in the launch body (`economics.remainderTo`).
3. The remainder arrives in the vault when the token launches, and vests or waits behind the treasury rules from then on.
4. For a vesting vault, call `sync(token)` right after the launch (anyone can; the first `release(token)` does it
   too). The launch does not tell the vault, and the token's clock only runs from the recorded arrival.

An open vesting vault (`token` zero) vests every token it receives on the same schedule, so nothing can be pulled out
early by sending it a different token first. Each token's linear unlock starts at the later of `start + cliff` and
its recorded arrival (`arrivedAt`, see `unlockStart(token)`): a launch that slips past the schedule still vests from
the day it pays the vault, never on it. Pick `start` after the launch you expect and the schedule runs exactly as
chosen. On Robinhood, the free factory creates the vault and the fee is paid on Ethereum with `payFor(4663, vault)`.

The fee is keyed to the open vault's address, so a vault made before the launch and a vault made afterwards for the
launched token (`createVesting` or `createTreasury` with the token) are two projects to the factory: each pays 5 IMD.
The contracts can not know the token before it exists; the radar links the open vault to the token off-chain.

## Build and test

Requires [Foundry](https://getfoundry.sh). Dependencies: OpenZeppelin Contracts 5.1.0 and forge-std in `lib`.

```bash
forge install OpenZeppelin/openzeppelin-contracts@v5.1.0 foundry-rs/forge-std --no-git
forge test
```

The fork test runs against the real IMD token on Ethereum when an RPC is given:

```bash
FORK_RPC=https://rpc.mevblocker.io forge test --match-contract Fork
```

Tests cover the vesting math and cliff, vaults made before a launch that receive its remainder, top-ups, fee-on-transfer tokens, beneficiary and manager timelocks, the
treasury delay, expiry, allowlist, weekly cap and ETH, stricter-only rule changes, the one-time fee (and paying for a Robinhood project), and fuzzing of
the vesting payout, the 25%-a-week vesting ceiling and the treasury weekly cap. `test/Audit.t.sol` holds one test per
audit finding fixed before the launch (see [ADAPTATION.md](ADAPTATION.md)): the start floor, the arrival clock of open
vaults, the schedule overflow, `recover()` against double-entry tokens, the treasury's own 24h floor, and the real
bound of the epoch cap.

## Addresses

- IMD (Ethereum): `0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7`
- VaultFactory: not deployed yet. Ethereum: `new VaultFactory(IMD, radarWallet)`. Robinhood: `new VaultFactory(address(0), address(0))`.

## The IMD RADAR seal

The radar shows "Locked with IMD Vault" on a token when all of these hold (checked by the radar, not the contracts):
- the project paid the fee (`feePaid[chainId][token]` on the Ethereum factory);
- at least 3% of the supply is locked in its vaults;
- the radar has reviewed the token as legit.

Locked or burned liquidity is shown as a plus next to the seal.
