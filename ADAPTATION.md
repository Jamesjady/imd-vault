# Adaptation for the IMD launch (Ethereum, `evm_contracts`)

The launch deploys `src/VaultFactory.sol` alone, with `imd_ = 0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7` and
`feeRecipient_ = $owner`. Its constructor already fits the launch kind: nonpayable, two static arguments, no external
call, no owner, no `msg.sender` or `tx.origin` role, and the factory deploys the two vault contracts itself with
`new`. No launch-driven change to the factory was needed; `VaultFactory.sol` is untouched. Every change below fixes an
audit finding that reproduced on the code as it arrived (checked first with a scratch test for each), with the
smallest change that keeps the design: no owner, admin, pause, upgrade or emergency path was added, and every rule
only got stricter.

Verified with `forge build` and `forge test` (54 tests: the 38 that arrived, the fork test, and 15 new ones in
`test/Audit.t.sol`), with the verifier's fuzz seed and three others.

## Changes

| # | Finding (audit id) | File | Change | Test |
|---|---|---|---|---|
| 1 | medium `55055564` A past `start` unlocked up to 100% in the block that created the vault. | `src/VestingVault.sol` constructor | Reverts `BadSchedule` when `start_ < block.timestamp`. Both factory entry points go through this constructor. A revert, not a clamp, so the stored schedule always equals what the creator asked for and the factory's event stays truthful. | `test_VestingRejectsStartInThePast`, `testFuzz_VestingNeverMoreThan25PercentInFirstWeek` (the audit's proof as a regression) |
| 2 | medium `5dbb3b32` Tokens reaching an open (launch) vault after `start + cliff` were unlocked on arrival; a launch that slipped past the schedule paid out the whole remainder at once. | `src/VestingVault.sol` | Per-asset arrival clock for open vaults only: `arrivedAt[asset]` is recorded once, when the vault holds some of the asset, by the new public `sync(asset)` (anyone) or by `release(asset)`. The linear unlock of that asset starts at `max(start + cliff, arrivedAt)` (`unlockStart(asset)`), and nothing vests before the arrival is recorded. The first `release` of a newly arrived token records it and returns without reverting, so the record is kept. Bound vaults are unchanged: their token arrives in the creating transaction and `start` can no longer be in the past (change 1), and top-ups keep following the calendar schedule as the README documents. A later tranche of a token an open vault already recorded is likewise a top-up on that token's clock; for a launch the first tranche is the launch transaction itself, since the token does not exist before it, so nobody can set the clock earlier with dust. New event `Arrived(token, at)`. | `test_LateArrivalVestsFromArrival`, `test_ArrivalInsideTheCliffKeepsTheSchedule`, `test_FirstReleaseOfANewTokenOnlyStartsItsClock`, `test_SyncIsIdempotentAndNeedsABalance`, `test_EachTokenInAnOpenVaultHasItsOwnClock`, `test_BoundVaultHasNoArrivalClock`, `testFuzz_LateArrivalNeverUnlocksMoreThan25PercentInAWeek` |
| 3 | low `ea7dc628` `start + cliff` overflowing `uint64` passed the constructor and then every `releasable`/`release` reverted forever, trapping the tokens. | `src/VestingVault.sol` constructor and `extendDuration` | Reverts `BadSchedule` unless `start + cliff + duration` fits in `uint64`; `extendDuration` applies the same bound to the new duration. | `test_VestingRejectsOverflowingSchedule`, `test_ExtendDurationCannotOverflowTheSchedule` |
| 4 | low `5f526bd2` `recover()` judged "other token" by address only, so a token with a second entry point to the vested balance (legacy or proxy contract) moved it to the beneficiary during the cliff. | `src/VestingVault.sol` `recover` | Reads the vested token's balance before the transfer and reverts `VestingToken` if it fell. An open vault now reverts `VestingToken` for any input (before, `recover(IERC20(0))` reverted with a bare call to the zero address). | `test_RecoverRefusesASecondEntryPointToTheVestedToken`, `test_OpenVaultRecoverAlwaysRefuses` |
| 5 | info `6a087594` The 24h floor on the treasury delay lived only in the factory; a directly deployed `TreasuryVault` could have delay 0. | `src/TreasuryVault.sol` | New constant `MIN_DELAY = 1 days`, checked in the constructor. The factory's own check stays. | `test_TreasuryConstructorEnforcesMinDelay` |
| 6 | low `9267dfb4` The weekly cap is per fixed calendar epoch, so two withdrawals straddling a boundary can move 43.75% of a balance in two seconds, weaker than "25% per week" read as a rolling week. | `src/TreasuryVault.sol` NatSpec, `README.md` | Documented, not changed. The source comment and README already describe fixed 7-day epochs, so this is the stated design; a rolling window would be a redesign of the cap (a ring of spent amounts and a changed `windows` ABI the radar reads), which the brief's "keep the rules exactly as written in the source and README" rules out. The NatSpec and README now state the real bound, `rate + rate × (1 − rate)` of the balance in any 7 days (43.75% at the 25% ceiling), and that a rate decrease applies from the next epoch once a withdrawal has executed in the current one. | `test_TreasuryEpochBoundaryBoundIsRatePlusRateOfRemainder` pins that bound and that nothing more leaves |

## Findings left alone

- info `3dfe6577` A project that makes a pre-launch vault and later a bound vault pays 5 IMD twice. Reproduces, but it is
  what the brief asks for: "its fee is keyed to the vault address". The contracts can not know a token before it
  exists, and linking later would need a new privileged or self-declared mapping. Documented in the README's launch
  section instead; the existing `test_EachLaunchVaultPaysItsOwnFee` already encodes it.
- info `38e605ba` Coverage note, not a defect. Nothing to change. The fork test against the live IMD token was not
  run here either (no RPC in this environment); it is unchanged and still skips without `FORK_RPC`.

## Test changes

- `test/Vault.t.sol`: the launch stand-in `_launch` now calls `sync(token)` on the vault after minting, as a project
  does after a real launch (change 2), and the open-vault test that sends IMD syncs it too. The treasury launch test
  mints directly, since a treasury has no clock. Two assertions on `arrivedAt` and `unlockStart` were added. No
  expected amount or date changed.
- `test/Audit.t.sol` is new: one test per change above, with a double-entry token mock for change 4.

## Open items for the deployer

- Explorer verification of `VaultFactory` (and of the vaults it creates, which share its compiler settings) after
  the launch, as the security checklist asks. Nothing needs to be called after deployment.
- The radar should prompt projects to call `sync(token)` on an open vesting vault right after their launch, and may
  call it itself: the token's clock runs from the recorded arrival.
