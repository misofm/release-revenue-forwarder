# release_revenue_forwarder

Forwards a musicos Release's revenue straight to each track's recording pool, split equally across `release.recording_ids()`.

```
forward<USD>(release, payment)                 // a sale: no crank
redeem_and_forward<USD>(release, cap, root)    // revenue paid to the Release
receive_and_forward<USD>(release, cap, coins)  // coins sent to the Release
```

- `forward<Currency>(release, revenue)` sends `total / n` to each recording's canonical pool address, `pool::derive_address<Currency>(recording_id)` from [`royalty_pool`](https://github.com/misofm/royalty-pool). The funds wait there until the pool exists and has registered stakes, and `pool::settle`, which holders run before claiming, folds them in. The rounding remainder (less than the track count, in base units) goes to the Release. `forward` is permissionless, so a sale can pass its payment straight to it and the revenue needs no crank.
- `redeem_and_forward<Currency>(release, admin_cap, root)` forwards the Release's whole settled accumulator snapshot, through hikida's `redeem_settled_balance`. It takes no amount, because a caller always wants to sweep everything. A remainder goes back to the Release and is included in the next redemption.
- `receive_and_forward<Currency>(release, admin_cap, coins)` forwards coins sent to the Release. An empty vector does nothing.

`redeem_and_forward` and `receive_and_forward` check the `ReleaseAdminCap`, including when there is nothing to redeem. Callers can't choose amounts or recipients.

Each forward that pays the tracks emits one `ReleaseRevenueForwardedEvent { release_id, amount }`, where `amount` is what the tracks receive. Nothing is emitted when no track receives anything. Forwarding uses `send_funds` and writes no shared object, so concurrent sales of one Release don't contend. At the 1,000-track cap a forward makes 1,000 `send_funds` calls and emits one event.

## Accumulator redemption

The settled snapshot is written solely by the settlement system transaction, so it is constant for every transaction in a commit. Redeeming the same Release twice in one PTB, or from two crankers in the same commit, withdraws it twice and the network fails that whole transaction with `InsufficientFundsForWithdraw` (a transaction-level failure with no Move abort code). Include each Release at most once per PTB and treat that status as "retry next commit".

## Testing

The unit-test VM does not settle accumulators. The tests check the reported amounts and run the funded path through `forward` and `receive_and_forward`. Funds arriving at pool addresses, a funded `redeem_and_forward` and the full 1,000-track case need an end-to-end test on a Sui network.

```sh
sui move build
sui move test --coverage
```

## License

[Functional Source License 1.1, ALv2 Future License](./LICENSE.md)
(FSL-1.1-ALv2). Any use except a Competing Use is permitted, and each version
becomes Apache-2.0 two years after its release.
