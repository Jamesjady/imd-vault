# Adaptation for the IMD launch (Ethereum, `evm_contracts`)

The launch deploys `src/VaultFactory.sol` alone, with `imd_ = 0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7` and
`feeRecipient_ = $owner`. Its constructor already fits the launch kind: nonpayable, two static arguments, no external
call, no owner, no `msg.sender` or `tx.origin` role, and the factory deploys the two vault contracts itself with
`new`. No launch-driven change to the factory was needed; `VaultFactory.sol` is untouched. Every change below fixes an
audit finding that reproduced on the code as it arrived (checked first with a scratch test for each), with the
smallest change that keeps the design: no owner, admin, pause, upgrade or emergency path was added, and every rule
only got stricter.

Verified with `forge build` and `forge test` (62 tests: the 38 that arrived, the fork test, and 23 in
`test/Audit.t.sol`), with the verifier's fuzz seed and three others.

## Revision (independent review, second round)

The reviewer's proof (`Proof_c693ed06fe5a`) failed on the accepted tree as reported and passes now. Each finding was
reproduced first; changes 7 to 11 below answer the ones that held, and `.imd-responses.json` answers every id.

| # | Finding (id) | File | Change | Test |
|---|---|---|---|---|
| 7 | medium `c693ed06` The treasury's weekly cap was keyed per asset address, so a token with two addresses to one balance (legacy forwarder, proxy and target) got a 25% window per address in one epoch: 43.75% in one block. | `src/TreasuryVault.sol` `queue`, `execute`, new `_charge`, `_tryBalance`, `trackedAssets()`, `isTracked`, event `SharedBalanceCharged` | `queue` records every ERC-20 asset once in `_trackedAssets` (only the manager grows it). An ERC-20 `execute` reads the other tracked balances before and after the transfer; a balance that fell is charged against that asset's window for the current epoch, opened on its pre-transfer balance, and reverts `OverWeeklyCap` if it does not fit. So both addresses of one balance share one 25% window as soon as both have been queued, in whichever order they are used; the reviewer's expected outcome (`execute(b)` reverts `OverWeeklyCap(0)`, 25% leaves) is exactly what happens. Balances are read with a `staticcall` and a failure counts as zero, so an asset queued by mistake (no code) never blocks the others. ETH is not tracked: a token transfer can not move it. The cap for an asset never queued is unchanged. | `test_TreasuryCapIsSharedByTwoEntryPointsToOneBalance`, `test_TreasuryCapThroughLegacyAddressFirstIsSharedToo`, `test_TreasuryTrackedAssetsNeverBlockOtherWithdrawals`; the proof itself passes |
| 8 | low `960ccd81` `increaseDelay` moved a queued withdrawal's whole execution window later, so an expired withdrawal came back to life, executable by anyone with no new announcement. Reproduced: with delay 1 day, a withdrawal expired at T0+15d executed at T0+20d after `increaseDelay(20 days)`. | `src/TreasuryVault.sol` `Withdrawal.expiresAt`, `queue`, `execute` | The expiry is fixed when the withdrawal is queued (`queuedAt + delay + GRACE`) and stored in the `Withdrawal`; `execute` checks it instead of `due + GRACE`. The due time still follows the current delay, so a longer delay holds queued withdrawals back and, if it pushes `due` past `expiresAt`, closes them until requeued. The `withdrawals(id)` getter gains the field. | `test_IncreaseDelayNeverRevivesAnExpiredWithdrawal`, `test_IncreaseDelayPastTheExpiryClosesAQueuedWithdrawal` |
| 9 | info `5811a810` A pending manager change kept the delay it was proposed with after `increaseDelay`, unlike queued withdrawals. Reproduced. | `src/TreasuryVault.sol` `pendingManagerProposedAt`, `pendingManagerEta()`, `proposeManager`, `acceptManager` | The proposal time is stored and `pendingManagerEta()` is now a view returning it plus the current delay (same name and return type as the old getter), which `acceptManager` checks. | `test_PendingManagerFollowsTheCurrentDelay` |
| 10 | low `8d4b11e3` Once a token's fee was paid, anyone could file free vaults under it with nothing tying a vault to the project that paid, polluting what the radar shows and growing the unbounded `vaultsByToken` view. Reproduced. | `src/VaultFactory.sol` `creatorOf`, `VestingCreated`/`TreasuryCreated` gain a `creator` field | The registry records the creator of each vault and both creation events carry it, so the radar files a vault under a project only when its creator is the project's (the `FeePaid` payer or a wallet the project names) and reads vaults from events, not the unbounded list (README, seal section). The fee rule ("the first vault for a token; later ones are free") is unchanged: charging per (token, creator) would make a project that uses two wallets pay twice, and the fee is the requester's. | `test_FactoryRecordsTheCreatorOfEveryVault` |
| 11 | info `28e462ee` `VestingCreated` logged the requested amount, not what a fee-on-transfer token delivered. Reproduced. | `src/VaultFactory.sol` `createVesting` | Emits the vault's balance after the transfer minus before. | `test_VestingCreatedLogsWhatTheVaultReceived` |

Documented, not changed (each reproduced as described; the finding itself asks for documentation or an off-chain rule, and a contract change would redesign what the brief says to keep):

- low `93c43379` An open vesting vault accounts per token address, so a double-entry token would vest once per address.
  The finding's option (a): the contracts can not watch "the other assets" without a set that anyone can pad through
  the public `sync()` (and bounding it to released assets is still paddable over the schedule), and binding the vault
  to its first token contradicts "vests every token it receives". README and the `VestingVault` NatSpec now state the
  limitation, and the seal section says the radar refuses its seal to an open vault holding such a token. An
  IMD-launched token has one address, so the launch flow is unaffected.
- low `7f9d9778` Tokens arriving after the unlock has advanced vest by the elapsed fraction (a top-up after the
  schedule is a pass-through). This is the documented design ("later top-ups vest on the same schedule"), which the
  brief says to keep; per-tranche accounting would be the redesign the finding itself does not ask for. The README
  now states it plainly and the seal section counts locked supply as `balance − releasable(token)`.
- info `cc57dd0d` The cap rounds down to zero for a balance below `10_000 / rateBps` units, and an asset decays
  geometrically, so its last dust never leaves. A direct consequence of the rule as written; documented in the README.

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
- `test/Audit.t.sol` is new: one test per change above, with a double-entry token mock for changes 4 and 7 and a
  fee-on-transfer mock for change 11.

## Open items for the deployer

- Explorer verification of `VaultFactory` (and of the vaults it creates, which share its compiler settings) after
  the launch, as the security checklist asks. Nothing needs to be called after deployment.
- The radar should prompt projects to call `sync(token)` on an open vesting vault right after their launch, and may
  call it itself: the token's clock runs from the recorded arrival.
