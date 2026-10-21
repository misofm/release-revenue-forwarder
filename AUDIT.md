# Security Audit — `release_revenue_forwarder`

Audited at `89e7a52fbdb16c47684e5f3218b578fbc50c4920` (2026-10-21). Scope: package `release_revenue_forwarder`, module `release_revenue_forwarder::release_revenue_forwarder` (`sources/release_revenue_forwarder.move`), and its use of `miso_music::release`, `royalty_pool::pool::derive_address`, `hikida` and `sui::balance::send_funds`.

## What it does

Splits a `Balance<Currency>` equally across a `Release`'s tracks and sends each share, as accumulator funds, to the recording's canonical pool address; the rounding remainder goes to the Release's own address. Two admin entry points pull a Release's accumulated or received funds into the same split. See [README](./README.md).

## Trust model

- **Anyone:** may call `forward` (`release_revenue_forwarder.move:27-44`) with any `Release` and any `Balance<Currency>` they own. The caller chooses nothing but the Release and the funds; recipients are fixed by `release.recording_ids()` and `pool::derive_address<Currency>`.
- **`ReleaseAdminCap` holder:** may call `redeem_and_forward` (`:48-55`) and `receive_and_forward` (`:57-64`). Both authorize through `release.uid_mut(admin_cap)` (`miso_music/release.move:189-192`, `EUnauthorized` on a foreign cap) before touching funds, so a wrong cap aborts even with nothing to move. Neither accepts an amount or a recipient. A cap borrowed from a `vault` works (`a_vaulted_cap_receives`).
- **Nobody** can redirect funds, change the split, or forward a Release's funds to themselves. The package holds no state, no cap and no `UID`; it never claims derived objects or dynamic fields.

## Findings

**F-1 · Low · Open — the README misdescribes how a double redemption fails.** The README ("Accumulator redemption") says redeeming the same Release twice in one PTB or commit fails with the transaction-level status `InsufficientFundsForWithdraw` "with no Move abort code". On the pinned framework (`sui` rev `719fb29`), `hikida::redeem_settled_balance` → `balance::withdraw_funds_from_object` → `funds_accumulator::reserve_object_funds_for_withdrawal`, which aborts in Move with code 5 (`EObjectFundsInsufficient`) in `sui::funds_accumulator` when the reserved amount exceeds the object's available funds (verified by probe). Tooling that waits for the documented status string will misclassify the retry case. Suggested fix: document the Move abort (`sui::funds_accumulator`, code 5) as the retry signal and confirm on localnet.

**F-2 · Info · Accepted — the remainder is dust that only new revenue sweeps.** `forward` sends `revenue mod track_count` (and the whole amount when it is below `track_count`) to the Release's address (`:42-43`). `redeem_and_forward` re-splits it on the next sweep, but a remainder alone is always below `track_count` and loops back. The amount is bounded by 999 base units per currency, and the cap holder can take it out directly through `release.uid_mut(cap)` and `hikida`.

**F-3 · Info · Accepted — funds wait at pool addresses that may not exist yet.** Each share goes to `pool::derive_address<Currency>(recording_id)` (`:34`), an address that only the recording admin can claim via `pool::new_for_recording`, and that `pool::settle` only drains once `staked_shares > 0` (`royalty_pool/pool.move:113-128`). Until then the funds are visible only as an accumulator balance. A `Recording` cannot be deleted, so the pool can always be created later; loss of the `RecordingAdminCap` strands the funds. This is the royalty-pool design, not a property of this package.

**F-4 · Info · Accepted — `forward` is permissionless.** Any address can push any `Currency` to a Release's tracks and emit `ReleaseRevenueForwardedEvent<Currency>` (`:36-40`). Indexers must not read the event as a sale by the Release owner; it records only that the split happened.

**F-5 · Info · Accepted — no event when nothing reaches the tracks.** If `value_per_track == 0` the whole balance moves to the Release address silently (`:32`, `:43`); only the accumulator effects record it.

**F-6 · Info · Accepted — division by zero on an empty tracklist is unreachable on chain.** `revenue.value() / track_count` (`:31`) aborts with an arithmetic error for a zero-track Release (probe). `release::new` rejects empty tracklists (`ENoTracks`, `miso_music/release.move:97`); only `new_for_testing` can build one.

## Checked, no finding

- **Conservation:** `value_per_track * track_count <= revenue.value()`, so the `track_count` sequential `split`s (`:33-35`) cannot underflow and the event's `value_per_track * track_count + remainder` equals the input. `u64::MAX` across 3 and across 1,000 tracks splits without abort (`u64_max_is_split_without_abort`, `max_tracks_split_u64_max`).
- **No zero sends:** `send_funds` is called only with `value_per_track > 0` (`:32`) or a non-zero remainder (`:42-43`); a zero balance is destroyed.
- **Authorization order:** `uid_mut` authorizes before `hikida` reads or receives anything (`:53`, `:62`); foreign caps abort `EUnauthorized` on both paths (`a_foreign_cap_is_rejected_*`).
- **Receiving:** `hikida::receive_coins_as_balance` uses `transfer::public_receive` with the Release's `UID`, so only coins owned by the Release address can be received; an empty vector is a no-op (`empty_receive_does_nothing`).
- **Snapshot semantics:** `settled_funds_value` reads the balance settled at the start of the commit and caps at `u64::MAX`; `hikida::redeem_settled_balance` returns zero without touching the accumulator when nothing has settled (`redeem_with_nothing_settled_does_nothing`).
- **Object lifecycle:** the package creates, shares, freezes, wraps and deletes nothing. `Release` is `key`-only and shared at `publish`; `forward` takes `&Release`, so it also works on an unpublished Release inside the creating PTB and never takes a write lock on a shared one.
- **Derived addresses:** `pool::derive_address<Currency>` is `derived_object::derive_address(recording_id, RoyaltyPoolKey<Currency>())` (`royalty_pool/pool.move:236-238`), the same key `pool::new_for_recording` claims, so the address is the future pool's object address and a pool per (recording, currency) is unique.
- **Events:** exactly one `ReleaseRevenueForwardedEvent<Currency>` per forward that pays the tracks (`forward_reports_its_release_and_split`); the fields are `ID + u64 + u64` = 48 BCS bytes as the README says. Separate currencies on one Release emit separately (probe).
- **Limits:** one event and up to 1,000 `send_funds` native calls per forward; no PTB-command or event-limit interaction. The README's gas figures are localnet measurements and were not re-measured here.

## Operational requirements

- Include each Release at most once per PTB when redeeming; treat a Move abort with code 5 in `sui::funds_accumulator` as "retry next commit" (F-1).
- Create each recording's pool (`pool::new_for_recording`) and register stakes before holders expect to claim forwarded revenue (F-3).
- Index `ReleaseRevenueForwardedEvent` as a split record, not as proof of who paid (F-4), and join it with `ReleasePublishedEvent.recording_ids` for the recipients.

## Verification

- `sui move test --coverage`: 16/16 pass. `sui move coverage summary`: 100.00% (`release_revenue_forwarder`).
- `sui move build -e mainnet --warnings-are-errors` and `-e testnet`: both succeed with no warnings (sui 1.82.1).
- 3 throwaway probe tests (zero-track division by zero, two currencies on one Release with no event below the track count, over-withdrawal abort shape) ran as expected and were not committed.
