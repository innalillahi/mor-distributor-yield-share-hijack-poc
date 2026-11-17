# Morpheus Distributor — Donated aToken Counted as Pool Yield (PoC)

Proof-of-concept for a bug bounty report to the Morpheus (MOR) program.
A $500 aUSDT donation to the Distributor is counted as USDT-pool "yield",
so the tiny USDT pool captures 53.0% of the day's ~2,858 MOR emission
(fair share ~0.02%). The attacker, an 84.5% staker in that pool, claims
1,280.8 MOR (~$927) — net +$427/day after the lost donation. Repeatable daily.

Targets (Ethereum mainnet, fork block **26429066**):
- Distributor (DistributorV2) `0xDf1AC1AC255d91F5f4B1E3B4Aef57c5350F64C7A`
- USDT DepositPool `0x3B51989212BEdaB926794D6bf8e9E991218cf116`

Fork-only proofs against DEPLOYED contracts. No mainnet transactions,
no real funds, no privileged accounts.

## Run

One pasted line from a clean clone (Foundry 1.9.0; public RPC, no key needed):

```bash
git clone https://github.com/innalillahi/mor-distributor-yield-share-hijack-poc.git
cd mor-distributor-yield-share-hijack-poc
forge install foundry-rs/forge-std
forge test --match-test test_yieldShareHijack -vv
```

`foundry.toml` already points the `mainnet` RPC endpoint at
`https://ethereum.publicnode.com`, so no RPC URL needs to be supplied.

## Tests

| File | Test | Proves |
|---|---|---|
| `test/YieldShareHijack.t.sol` | `test_yieldShareHijack` | **P1-CAPITAL-01 (High):** a $500 aUSDT donation to the Distributor is counted as USDT-pool "yield", so the tiny USDT pool captures 53.0% of the day's ~2,858 MOR emission (fair ~0.02%); the attacker, an 84.5% staker in that pool, claims 1,280.8 MOR (~$927) — net +$427/day after the lost donation. Repeatable daily. |
| `test/C4Retest.t.sol` | `test_m02_stethSupplyUsesActualBalanceDelta` | C4 2025-08 M-02 is FIXED in deployed V2: `supply()` stores the actual stETH balance delta; an odd-amount stake + partial withdraw + `distributeRewards` does not revert. |
| `test/C4Retest.t.sol` | `test_m04_yieldAccountingContinuesAfterMaxEndTime` | C4 2025-08 M-04 is FIXED in deployed V2: after pool-0 maxEndTime (2211364800, ~2040-01-26) `distributeRewards` still runs the yield loop (`lastUnderlyingBalance` syncs to balance) and `withdrawYield` still sweeps. |

## Chainlink mock — a fork artifact, not a protocol assumption

Forking freezes Chainlink rounds at the fork block. Warping past the daily
distribution gate (~19h) makes the feeds look stale to ChainLinkDataConsumer
(`allowedPriceUpdateDelay`), and `distributeRewards()` reverts with
"DR: price for pair is zero". On live mainnet the feeds post fresh rounds
continuously, so at gate-open time they are fresh.

Both test files therefore snapshot the six feeds' real `latestRoundData`
answers at fork time and re-mock them with `updatedAt = block.timestamp`
after each warp (`_snapshotFeeds` / `_refreshFeeds`, `vm.mockCall` on the
Chainlink aggregators ONLY — no in-scope contract is mocked; prices are the
real on-fork values, only the timestamp is renewed).

Two related fork notes:
- `withdraw()` / `stake()` / `claim()` trigger an internal `distributeRewards()`
  when the daily gate is open, so feeds must be refreshed BEFORE any such call
  after a warp, not only before the explicit `distributeRewards()` call.
- In `YieldShareHijack`, the claim at +14 days triggers a second distribution,
  but yields on a frozen fork are ~0, so that second distribution allocates
  nothing (`totalYield_ == 0` → rewards go to `undistributedRewards`); the
  claimed amount is exactly the hijacked amount from the first distribution.
  On live mainnet the attacker would get slightly more (14 days of real yield).

## USDT quirk

USDT `approve`/`transfer` return no bool. A Solidity interface declaring
`returns (bool)` reverts on empty-returndata decode. The PoCs use raw
low-level calls (`_safeApprove` / `_safeTransfer`) that tolerate empty
returndata. Same trap applies to any future USDT interaction.

## Aave quirk

Supplying 500 USDT to Aave mints slightly less than 500e6 aUSDT
(exchange rate > 1). The PoC donates the full aUSDT balance (~499,999,999)
rather than exactly 500e6, which would revert on insufficient balance.

## Fix (one sentence)

Track the Distributor's expected yield-token balance after each supply/withdraw
and exclude any excess over expected from the yield measurement (or cap each
pool's measured yield per distribution at deposited × max-APY × elapsed).
