# IMD Vault

Vaults nobody owns, for the identity.md ecosystem. A project locks its team tokens and its treasury under rules
written in code, and IMD RADAR shows those rules, and every move, on the project's file.

Built for the Identity MD Hackathon (October 2026). See [SWARM_BRIEF.md](SWARM_BRIEF.md) for the audit and deployment through the IMD swarm.

## Contracts (`src`)

| Contract | What it does |
|---|---|
| `VaultFactory` | Creates vaults and charges 5 IMD once per project (the first vault for a token; later ones are free), paid to IMD RADAR's public wallet to fund its servers and swarm jobs. On chains without IMD (Robinhood) vaults are free to create and the project pays on Ethereum with `payFor(chainId, token)`. It keeps a public registry (`allVaults`, `isVault`, `vaultsByToken`). No owner, holds no funds. |
| `VestingVault` | Team tokens: nothing during the cliff, then linear over the duration, which must be at least 4 weeks, so no schedule unlocks more than 25% in any week. Each project picks its own cliff and duration above that floor. `release()` is callable by anyone and only pays the beneficiary. The duration can only grow. A new beneficiary takes over after 7 days. |
| `TreasuryVault` | Treasuries: anyone deposits tokens or ETH. The manager can only queue a withdrawal; it executes after the delay (at least 24h, at most 30 days), within 14 days, only to an allowed destination, and no more than `rateBps` (at most 25%) of the balance can leave per asset per 7-day epoch. Delay can only grow, rate only shrink, destinations only be removed. A new manager takes over after the delay. |

Nothing has an admin, a pause, an upgrade path or an emergency withdrawal.

### Accounting notes
- Vesting counts `balance + released`, so fee-on-transfer tokens and later top-ups vest on the same schedule.
- The weekly cap is fixed by the first withdrawal executed in an epoch (`rateBps` of the balance at that moment);
  deposits later in the same epoch do not raise it.
- Tightening a rule (longer delay, removed destination) also holds back withdrawals already queued.
- A restricted treasury always keeps at least one destination, so it can never freeze itself.

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

Tests cover the vesting math and cliff, top-ups, fee-on-transfer tokens, beneficiary and manager timelocks, the
treasury delay, expiry, allowlist, weekly cap and ETH, stricter-only rule changes, the one-time fee (and paying for a Robinhood project), and fuzzing of
the vesting payout, the 25%-a-week vesting ceiling and the treasury weekly cap.

## Addresses

- IMD (Ethereum): `0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7`
- VaultFactory: not deployed yet. Ethereum: `new VaultFactory(IMD, radarWallet)`. Robinhood: `new VaultFactory(address(0), address(0))`.

## The IMD RADAR seal

The radar shows "Locked with IMD Vault" on a token when all of these hold (checked by the radar, not the contracts):
- the project paid the fee (`feePaid[chainId][token]` on the Ethereum factory);
- at least 3% of the supply is locked in its vaults;
- the radar has reviewed the token as legit.

Locked or burned liquidity is shown as a plus next to the seal.
