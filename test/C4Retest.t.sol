// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

/// @notice C4 2025-08 re-tests against the DEPLOYED DistributorV2 / DepositPool (v7).
/// The C4 audit covered the OLD Distributor.sol, not V2. Scope (SCOPE.md §5 #7) requires
/// re-testing M-02 and M-04 against deployed V2; only a residual, demonstrable variant is
/// eligible. Both are FIXED in V2 — these tests prove it (they must PASS).
///
/// M-02 (old): Distributor.supply() stored the REQUESTED amount in deposited/
/// lastUnderlyingBalance instead of the actual stETH balance difference after rounding;
/// distributeRewards() then underflowed (balance - lastUnderlying) and bricked
/// stake/withdraw/lockClaim/claim until yield covered the gap.
/// V2 fix: supply() measures the actual balance delta for BOTH deposited and
/// lastUnderlyingBalance, and distributeRewards() guards
/// `if (lastUnderlyingBalance >= balance_) underlyingYield_ = 0` (no underflow possible).
///
/// M-04 (old): distributeRewards() returned early when rewards_ == 0, so
/// lastUnderlyingBalance was never updated after maxEndTime and all yield accrued after
/// rewards ended was permanently unwithdrawable.
/// V2 fix: the yield loop (which sets lastUnderlyingBalance = balance) runs BEFORE the
/// `if (rewards_ == 0) return;`, so accounting keeps updating after rewards end.
interface IERC20C {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface ILido {
    function submit(address referral) external payable returns (uint256);
}

interface IDistributorC {
    function distributeRewards(uint256 rewardPoolIndex_) external;
    function withdrawYield(uint256 rewardPoolIndex_, address depositPoolAddress_) external;
    function getDistributedRewards(uint256 rewardPoolIndex_, address depositPoolAddress_) external view returns (uint256);
    function rewardPoolLastCalculatedTimestamp(uint256) external view returns (uint128);
    function depositPools(uint256, address)
        external
        view
        returns (address token, string memory chainLinkPath, uint256 tokenPrice, uint256 deposited, uint256 lastUnderlyingBalance, uint8 strategy, address aToken, bool isExist);
}

interface IDepositPoolC {
    function stake(uint256 rewardPoolIndex_, uint256 amount_, uint128 claimLockEnd_, address referrer_) external;
    function withdraw(uint256 rewardPoolIndex_, uint256 amount_) external;
    function rewardPoolsData(uint256) external view returns (uint128 lastUpdate, uint256 rate, uint256 totalVirtualDeposited);
}

interface IRewardPoolC {
    function getPeriodRewards(uint256 index_, uint128 startTime_, uint128 endTime_) external view returns (uint256);
}

interface IAggregator {
    function latestRoundData() external view returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

contract C4RetestTest is Test {
    address constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address constant STETH_POOL = 0x47176B2Af9885dC6C4575d4eFd63895f7Aaa4790;
    address constant DISTRIBUTOR = 0xDf1AC1AC255d91F5f4B1E3B4Aef57c5350F64C7A;
    address constant REWARD_POOL = 0xb7994dE339AEe515C9b2792831CD83f3C9D8df87;

    uint256 constant BLOCK = 26429066;
    // Pool 0 maxEndTime = payoutStart + ceil(initial/decrease)*interval
    //   = 1707393600 + 5833*86400 = 2211364800 (~2040-01-26).
    uint256 constant POOL0_MAX_END = 2211364800;

    address attacker = makeAddr("attacker");

    address constant FEED_STETH_USD = 0xCfE54B5cD566aB89272946F602D76Ea879CAb4a8;
    address constant FEED_WETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address constant FEED_WBTC_BTC = 0xfdFD9C85aD200c506Cf9e21F1FD8dd01932FBB23;
    address constant FEED_BTC_USD = 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c;
    address constant FEED_USDC_USD = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;
    address constant FEED_USDT_USD = 0x3E7d1eAB13ad0104d2750B8863b489D65364e32D;

    int256[6] internal _feedAnswers;
    uint80[6] internal _feedRounds;

    function _snapshotFeeds() internal {
        address[6] memory feeds = [
            FEED_STETH_USD, FEED_WETH_USD, FEED_WBTC_BTC, FEED_BTC_USD, FEED_USDC_USD, FEED_USDT_USD
        ];
        for (uint256 i = 0; i < feeds.length; i++) {
            (uint80 rid, int256 ans,,,) = IAggregator(feeds[i]).latestRoundData();
            _feedRounds[i] = rid;
            _feedAnswers[i] = ans;
        }
    }

    function _refreshFeeds() internal {
        address[6] memory feeds = [
            FEED_STETH_USD, FEED_WETH_USD, FEED_WBTC_BTC, FEED_BTC_USD, FEED_USDC_USD, FEED_USDT_USD
        ];
        for (uint256 i = 0; i < feeds.length; i++) {
            vm.mockCall(
                feeds[i],
                abi.encodeWithSelector(IAggregator.latestRoundData.selector),
                abi.encode(_feedRounds[i], _feedAnswers[i], block.timestamp, block.timestamp, _feedRounds[i])
            );
        }
    }

    function test_m02_stethSupplyUsesActualBalanceDelta() public {
        vm.createSelectFork("mainnet", BLOCK);
        vm.deal(attacker, 10 ether);
        _snapshotFeeds();

        // Get real stETH via Lido submit (no deal() cheat on the rebasing token).
        // NOTE: on this fork 2 ETH mints ~1.6 stETH (Lido share-price state), not 1:1.
        vm.prank(attacker);
        uint256 stethReceived = ILido(STETH).submit{value: 2 ether}(address(0));
        assertGe(stethReceived, 1.5 ether, "lido submit minted too little");

        (,,, uint256 depositedBefore, uint256 lastUnderlyingBefore,,,) =
            IDistributorC(DISTRIBUTOR).depositPools(0, STETH_POOL);
        uint256 distBalBefore = IERC20C(STETH).balanceOf(DISTRIBUTOR);

        // Odd amount chosen to exercise stETH share rounding (the old M-02 trigger).
        uint256 stakeAmount = 1.123456789012345678 ether;
        vm.startPrank(attacker);
        IERC20C(STETH).approve(DISTRIBUTOR, type(uint256).max);
        IDepositPoolC(STETH_POOL).stake(0, stakeAmount, 0, address(0));
        vm.stopPrank();

        (,,, uint256 depositedAfter, uint256 lastUnderlyingAfter,,,) =
            IDistributorC(DISTRIBUTOR).depositPools(0, STETH_POOL);
        uint256 distBalAfter = IERC20C(STETH).balanceOf(DISTRIBUTOR);

        // V2 stores the ACTUAL balance delta, not the requested amount.
        assertEq(depositedAfter - depositedBefore, distBalAfter - distBalBefore, "deposited != actual stETH delta");
        assertEq(lastUnderlyingAfter - lastUnderlyingBefore, distBalAfter - distBalBefore, "lastUnderlying != actual delta");

        // Partial withdraw, then distributeRewards must NOT revert (old bug bricked it).
        // NOTE: withdraw() itself triggers an internal distributeRewards() when the gate
        // is open, so refresh the feeds BEFORE withdrawing (fork artifact only).
        vm.warp(block.timestamp + 8 days); // past the 7d withdraw lock
        _refreshFeeds();
        vm.prank(attacker);
        IDepositPoolC(STETH_POOL).withdraw(0, 0.5 ether);

        uint128 lastCalc = IDistributorC(DISTRIBUTOR).rewardPoolLastCalculatedTimestamp(0);
        vm.warp(uint256(lastCalc) + 86400 + 60);
        _refreshFeeds(); // long warp makes Chainlink rounds look stale on the fork
        IDistributorC(DISTRIBUTOR).distributeRewards(0); // must not revert
        IDistributorC(DISTRIBUTOR).withdrawYield(0, STETH_POOL); // must not revert
        emit log_string("M-02 residual: NONE - V2 uses actual balance deltas, distributeRewards does not revert");
    }

    function test_m04_yieldAccountingContinuesAfterMaxEndTime() public {
        vm.createSelectFork("mainnet", BLOCK);
        _snapshotFeeds();

        // Fast-forward lastCalc to maxEndTime itself in ONE distribution (a single
        // distributeRewards call sets lastCalc = now whenever the gate passes), allocating
        // the remaining ~13 years of emission in one go.
        vm.warp(POOL0_MAX_END);
        _refreshFeeds();
        IDistributorC(DISTRIBUTOR).distributeRewards(0); // must not revert

        // Now past maxEndTime: period rewards are zero, but the yield loop must still run.
        vm.warp(POOL0_MAX_END + 86400);
        _refreshFeeds();
        uint128 lastCalc = IDistributorC(DISTRIBUTOR).rewardPoolLastCalculatedTimestamp(0);
        uint256 rewards = IRewardPoolC(REWARD_POOL).getPeriodRewards(0, lastCalc, uint128(block.timestamp));
        assertEq(rewards, 0, "expected zero rewards after maxEndTime");

        IDistributorC(DISTRIBUTOR).distributeRewards(0); // must not revert
        // The yield loop must have synced lastUnderlyingBalance to the actual balance.
        (,,, uint256 deposited, uint256 lastUnderlying,,,) =
            IDistributorC(DISTRIBUTOR).depositPools(0, STETH_POOL);
        uint256 bal = IERC20C(STETH).balanceOf(DISTRIBUTOR);
        assertEq(lastUnderlying, bal, "lastUnderlying not synced after rewards end");
        assertGe(lastUnderlying, deposited, "lastUnderlying below deposited");
        IDistributorC(DISTRIBUTOR).withdrawYield(0, STETH_POOL); // must not revert
        // A second distribution right after must also work (lastCalc updated, no stuck state).
        IDistributorC(DISTRIBUTOR).distributeRewards(0);
        emit log_string("M-04 residual: NONE - yield accounting keeps updating after rewards end");
    }
}
