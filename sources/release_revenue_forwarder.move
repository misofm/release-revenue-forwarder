// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: FSL-1.1-ALv2

/// Release revenue, forwarded straight to each track's recording pool.
///
/// `forward` splits revenue equally across the Release's tracks and sends each
/// share to the recording's canonical pool address, where `pool::settle` folds
/// it in. A sale can pass its payment to `forward`, so its revenue needs no
/// crank. `redeem_and_forward` and `receive_and_forward` forward revenue paid
/// to the Release itself. The rounding remainder goes to the Release, so no
/// track is favored.
module release_revenue_forwarder::release_revenue_forwarder;

// === Imports ===

use sui::accumulator::AccumulatorRoot;
use sui::balance::Balance;
use sui::coin::Coin;
use sui::event::emit;
use sui::transfer::Receiving;
use hikida::hikida;
use miso_music::release::{Release, ReleaseAdminCap};
use royalty_pool::pool;

// === Events ===

/// Emitted once per forward that pays the tracks: each recording's pool got
/// `value_per_track` and the Release got `remainder`. The recipients are the
/// tracklist from `ReleasePublishedEvent`.
public struct ReleaseRevenueForwardedEvent<phantom Currency> has copy, drop {
    release_id: ID,
    value_per_track: u64,
    remainder: u64,
}

// === Public Functions ===

/// Sends `total / n` to each track's recording pool address and the
/// remainder to the Release. A recording's pool need not exist yet: funds wait
/// at its address until it does. Permissionless.
public fun forward<Currency>(release: &Release, mut revenue: Balance<Currency>) {
    let release_id = object::id(release);
    let recording_ids = release.recording_ids();
    let track_count = recording_ids.length();
    let value_per_track = revenue.value() / track_count;
    if (value_per_track > 0) {
        recording_ids.do_ref!(|recording_id| {
            revenue.split(value_per_track).send_funds(pool::derive_address<Currency>(*recording_id))
        });
        emit(ReleaseRevenueForwardedEvent<Currency> {
            release_id,
            value_per_track,
            remainder: revenue.value(),
        });
    };
    if (revenue.value() == 0) revenue.destroy_zero()
    else revenue.send_funds(release_id.to_address())
}

// === Admin Functions ===

/// Forwards all Release funds settled at the start of the current consensus
/// commit. Redeeming a Release twice in one commit fails the transaction with
/// `InsufficientFundsForWithdraw`, so include each Release at most once per PTB.
public fun redeem_and_forward<Currency>(
    release: &mut Release,
    admin_cap: &ReleaseAdminCap,
    root: &AccumulatorRoot,
) {
    let revenue = hikida::redeem_settled_balance<Currency>(release.uid_mut(admin_cap), root);
    forward(release, revenue)
}

public fun receive_and_forward<Currency>(
    release: &mut Release,
    admin_cap: &ReleaseAdminCap,
    coins: vector<Receiving<Coin<Currency>>>,
) {
    let revenue = hikida::receive_coins_as_balance(release.uid_mut(admin_cap), coins);
    forward(release, revenue)
}

// === Test Functions ===

#[test_only]
public fun forwarded_event_fields<Currency>(
    event: &ReleaseRevenueForwardedEvent<Currency>,
): (ID, u64, u64) {
    (event.release_id, event.value_per_track, event.remainder)
}
