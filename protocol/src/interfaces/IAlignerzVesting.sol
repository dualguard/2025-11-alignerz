// SPDX-License-Identifier: MIT
pragma solidity =0.8.29;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IAlignerzVesting {

    // TYPE DECLARATIONS
    struct RewardProject {
        IERC20 token; // The TVS token
        IERC20 stablecoin; // The stablecoin
        uint256 vestingPeriod; // The vesting period is the same for all KOLs
        mapping(uint256 => Allocation) allocations; // Mapping of NFT token ID to allocations
        mapping(address => uint256) kolTVSRewards; // Mapping to track the allocated TVS rewards for each KOL
        mapping(address => uint256) kolStablecoinRewards; // Mapping to track the allocated stablecoin rewards for each KOL
        mapping(address => uint256) kolTVSIndexOf; // Mapping to track the KOL address index position inside kolTVSAddresses
        mapping(address => uint256) kolStablecoinIndexOf; // Mapping to track the KOL address index position inside kolStablecoinAddresses
        address[] kolTVSAddresses; // array of kol addresses that are yet to claim TVS allocation
        address[] kolStablecoinAddresses; // array of kol addresses that are yet to claim their stablecoin allocation
        uint256 startTime; // startTime of the vesting periods
        uint256 claimDeadline; // deadline after which it's impossible for users to claim TVS or refund
    }

    struct BiddingProject {
        IERC20 token; // The token being vested
        IERC20 stablecoin; // The token being used for bidding
        uint256 totalStablecoinBalance; // total Stablecoin Balance in the biddingProject
        uint256 poolCount; // Number of vesting pools in the biddingProject
        uint256 startTime; // Start time of the bidding period
        uint256 endTime; // End time of the bidding period and start time of the vesting periods
        mapping(uint256 => VestingPool) vestingPools; // Mapping of pool ID to pool details
        mapping(address => Bid) bids; // Mapping of bidder address to bid details
        mapping(uint256 => Allocation) allocations; // Mapping of NFT token ID to bidder allocations
        bytes32 refundRoot; // Merkle root for refunded bids
        bytes32 endTimeHash; // has depicting the projected biddingProject end time (hidden from end user till biddingProject is closed)
        bool closed; // Whether bidding is closed
        uint256 claimDeadline; // deadline after which it's impossible for users to claim TVS or refund
    }

    /// @notice Represents a vesting pool within a biddingProject
    /// @dev Contains allocation and vesting parameters for a specific pool
    struct VestingPool {
        bytes32 merkleRoot; // Merkle root for allocated bids
        bool hasExtraRefund; // whether pool refunds the winners as well
    }

    /// @notice Represents a bid placed by a user
    /// @dev Tracks the bid status and vesting progress
    struct Bid {
        uint256 amount; // Amount of stablecoin committed
        uint256 vestingPeriod; // Chosen vesting duration in seconds
    }

    /// @notice Represents an allocation
    /// @dev Tracks the allocation status and vesting progress
    struct Allocation {
        uint256[] amounts; // Amount of tokens committed for this allocation for all flows
        uint256[] vestingPeriods; // Chosen vesting duration in seconds for all flows
        uint256[] vestingStartTimes; // start time of the vesting for all flows
        uint256[] claimedSeconds; // Number of seconds already claimed for all flows
        bool[] claimedFlows; // Whether flow is claimed
        bool isClaimed; // Whether TVS is fully claimed
        IERC20 token; // The TVS token
        uint256 assignedPoolId; // Relevant for bidding projects: Id of the Pool (poolId=0; pool#1 / poolId=1; pool#2 /...) - for reward projects it will be 0 as default
    }

    function allocationOf(uint256 nftId) external view returns (Allocation memory);
}