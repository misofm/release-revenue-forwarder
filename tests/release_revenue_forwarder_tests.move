// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: FSL-1.1-ALv2

/// The unit-test VM does not settle accumulators, so these tests check the
/// reported amounts; funds arriving at pool addresses, and a funded
/// `redeem_and_forward`, need a network test. `royalty_pool` tests that its
/// derived addresses are the pools'.
#[test_only]
module release_revenue_forwarder::release_revenue_forwarder_tests;

use std::u64;
use std::unit_test::{assert_eq, destroy};
use sui::accumulator::{Self, AccumulatorRoot};
use sui::balance;
use sui::coin::{Self, Coin};
use sui::event::{Self, events_by_type};
use sui::test_scenario::{Self, Scenario};
use miso_music::release::{Self, Release, ReleaseAdminCap};
use vault::vault;
use release_revenue_forwarder::release_revenue_forwarder::{
    Self,
    ReleaseRevenueForwardedEvent,
};

const ARTIST: address = @0xA1;

public struct USD() has drop;

// === Helpers ===

fun id_of(addr: address): ID { object::id_from_address(addr) }

fun begin(): Scenario {
    let mut ts = test_scenario::begin(@0x0);
    accumulator::create_for_testing(ts.ctx());
    ts
}

/// Recording IDs whose pools do not exist yet.
fun recordings(ts: &mut Scenario, n: u64): vector<ID> {
    vector::tabulate!(n, |_| id_of(ts.ctx().fresh_object_address()))
}

fun new_release(ts: &mut Scenario, recording_ids: vector<ID>): (Release, ReleaseAdminCap) {
    let release_id = id_of(ts.ctx().fresh_object_address());
    let consents = recording_ids.map!(|id| release::consent_for_testing(id, release_id));
    release::new_for_testing(consents, ts.ctx())
}

/// The amount each forward reported, in order.
fun forwarded(): vector<u64> {
    events_by_type<ReleaseRevenueForwardedEvent<USD>>().map!(|event| {
        let (_, amount) = release_revenue_forwarder::forwarded_event_fields(&event);
        amount
    })
}

/// Forwards `value` across `n` tracks and returns the reported amounts.
fun forward(n: u64, value: u64): vector<u64> {
    let mut ts = begin();
    let recording_ids = recordings(&mut ts, n);
    let (release, cap) = new_release(&mut ts, recording_ids);
    release_revenue_forwarder::forward(&release, balance::create_for_testing<USD>(value));
    let amounts = forwarded();
    destroy(release);
    destroy(cap);
    ts.end();
    amounts
}

// === Splits ===

#[test]
fun equal_split_is_exact() {
    assert_eq!(forward(4, 10_000), vector[10_000]);
}

#[test]
fun remainder_is_not_reported() {
    assert_eq!(forward(3, 10), vector[9]);
}

#[test]
fun total_below_track_count_forwards_nothing() {
    assert_eq!(forward(3, 2), vector[]);
}

#[test]
fun zero_revenue_emits_nothing() {
    assert_eq!(forward(3, 0), vector[]);
}

#[test]
fun single_track_gets_everything() {
    assert_eq!(forward(1, 10_001), vector[10_001]);
}

#[test]
fun u64_max_is_split_without_abort() {
    let value = u64::max_value!();
    assert_eq!(forward(3, value), vector[value / 3 * 3]);
}

/// A value equal to the track count pays each track 1 with no remainder.
#[test]
fun value_equal_to_track_count_pays_one_each() {
    assert_eq!(forward(5, 5), vector[5]);
}

/// The 1,000-track cap splits `u64::MAX` in one event.
#[test]
fun max_tracks_split_u64_max() {
    let n = release::max_tracks();
    let value = u64::max_value!();
    assert_eq!(forward(n, value), vector[value / n * n]);
}

/// At the 1,000-track cap, 999 base units forward nothing.
#[test]
fun max_tracks_below_one_unit_each_forwards_nothing() {
    assert_eq!(forward(release::max_tracks(), 999), vector[]);
}

#[test]
fun forward_reports_its_release() {
    let mut ts = begin();
    let recording_ids = recordings(&mut ts, 2);
    let (release, cap) = new_release(&mut ts, recording_ids);
    release_revenue_forwarder::forward(&release, balance::create_for_testing<USD>(10));
    let events = events_by_type<ReleaseRevenueForwardedEvent<USD>>();
    let (release_id, _) = release_revenue_forwarder::forwarded_event_fields(&events[0]);
    assert_eq!(release_id, object::id(&release));
    destroy(release);
    destroy(cap);
    ts.end();
}

// === Release revenue ===

#[test]
fun redeem_with_nothing_settled_does_nothing() {
    let mut ts = begin();
    let recording_ids = recordings(&mut ts, 3);
    let (mut release, cap) = new_release(&mut ts, recording_ids);
    ts.next_tx(ARTIST);
    let root = ts.take_shared<AccumulatorRoot>();
    let events_before = event::num_events();
    release_revenue_forwarder::redeem_and_forward<USD>(&mut release, &cap, &root);
    assert_eq!(event::num_events(), events_before);
    test_scenario::return_shared(root);
    destroy(release);
    destroy(cap);
    ts.end();
}

#[test]
fun received_coins_are_combined_and_forwarded() {
    let mut ts = begin();
    let recording_ids = recordings(&mut ts, 2);
    let (mut release, cap) = new_release(&mut ts, recording_ids);
    let coin_a = coin::mint_for_testing<USD>(6_000, ts.ctx());
    let coin_b = coin::mint_for_testing<USD>(4_001, ts.ctx());
    let coin_ids = vector[object::id(&coin_a), object::id(&coin_b)];
    transfer::public_transfer(coin_a, object::id(&release).to_address());
    transfer::public_transfer(coin_b, object::id(&release).to_address());

    ts.next_tx(ARTIST);
    let coins = coin_ids.map!(|id| test_scenario::receiving_ticket_by_id<Coin<USD>>(id));
    release_revenue_forwarder::receive_and_forward(&mut release, &cap, coins);
    assert_eq!(forwarded(), vector[10_000]);

    destroy(release);
    destroy(cap);
    ts.end();
}

#[test]
fun empty_receive_does_nothing() {
    let mut ts = begin();
    let recording_ids = recordings(&mut ts, 1);
    let (mut release, cap) = new_release(&mut ts, recording_ids);
    let events_before = event::num_events();
    release_revenue_forwarder::receive_and_forward<USD>(&mut release, &cap, vector[]);
    assert_eq!(event::num_events(), events_before);
    destroy(release);
    destroy(cap);
    ts.end();
}

#[test]
fun a_vaulted_cap_receives() {
    let mut ts = begin();
    let recording_ids = recordings(&mut ts, 1);
    let (mut release, cap) = new_release(&mut ts, recording_ids);
    let mut registry = vault::new_registry_for_testing(ts.ctx());
    let (mut vault, vault_admin_cap) = vault::new(&mut registry, cap, ts.ctx());
    let coin = coin::mint_for_testing<USD>(7, ts.ctx());
    let coin_id = object::id(&coin);
    transfer::public_transfer(coin, object::id(&release).to_address());

    ts.next_tx(ARTIST);
    let coins = vector[test_scenario::receiving_ticket_by_id<Coin<USD>>(coin_id)];
    let (borrowed_cap, receipt) = vault.borrow_as_admin(&vault_admin_cap);
    release_revenue_forwarder::receive_and_forward(&mut release, &borrowed_cap, coins);
    vault.put_back(borrowed_cap, receipt);
    assert_eq!(forwarded(), vector[7]);

    destroy(vault_admin_cap);
    destroy(vault);
    destroy(registry);
    destroy(release);
    ts.end();
}

// === Aborts ===

#[test, expected_failure(abort_code = release::EUnauthorized)]
fun a_foreign_cap_is_rejected_on_an_empty_snapshot() {
    let mut ts = begin();
    let recording_ids = recordings(&mut ts, 1);
    let (mut release, _cap) = new_release(&mut ts, recording_ids);
    let (_other, other_cap) = new_release(&mut ts, recording_ids);
    ts.next_tx(ARTIST);
    let root = ts.take_shared<AccumulatorRoot>();
    release_revenue_forwarder::redeem_and_forward<USD>(&mut release, &other_cap, &root);
    abort
}

#[test, expected_failure(abort_code = release::EUnauthorized)]
fun a_foreign_cap_is_rejected_on_receive() {
    let mut ts = begin();
    let recording_ids = recordings(&mut ts, 1);
    let (mut release, _cap) = new_release(&mut ts, recording_ids);
    let (_other, other_cap) = new_release(&mut ts, recording_ids);
    release_revenue_forwarder::receive_and_forward<USD>(&mut release, &other_cap, vector[]);
    abort
}
