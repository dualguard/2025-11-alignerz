// SPDX-License-Identifier: MIT
pragma solidity =0.8.29;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {WhitelistManager} from "./whitelistManager/WhitelistManager.sol";
import {FeesManager} from "./feesManager/FeesManager.sol";
import {IAlignerzNFT} from "../../interfaces/IAlignerzNFT.sol";
import {IAlignerzVesting} from "../../interfaces/IAlignerzVesting.sol";

/// @title AlignerzVesting - A vesting contract for token sales
/// @notice This contract manages token vesting schedules for multiple projects
/// @author 0xjarix | Alignerz
contract AlignerzVesting is Initializable, UUPSUpgradeable, OwnableUpgradeable, WhitelistManager, FeesManager {
    using SafeERC20 for IERC20;
    /// @notice Represents a project with its token and vesting configuration
    /// @dev Contains mappings for pools and bids, along with projects parameters

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

    // STATE VARIABLES
    /// @notice Total number of bidding biddingProjects created
    uint256 public biddingProjectCount;

    /// @notice Total number of reward biddingProjects created
    uint256 public rewardProjectCount;

    /// @notice vesting period can only be multiples of this value
    uint256 public vestingPeriodDivisor;

    /// @notice address of the contract that will reward the TVS holders
    address public treasury;

    /// @notice The NFT contract used for minting vesting certificates
    IAlignerzNFT public nftContract;

    /// @notice Mapping of biddingProject ID to BiddingProject details
    mapping(uint256 => BiddingProject) public biddingProjects;

     /// @notice Mapping of Reward biddingProject ID to Reward BiddingProject details
    mapping(uint256 => RewardProject) public rewardProjects;

    /// @notice Mapping to track claimed refunds
    mapping(bytes32 => bool) public claimedRefund;

    /// @notice Mapping to track claimed NFT
    mapping(bytes32 => bool) public claimedNFT;

    /// @notice Mapping to track whether the NFT belongs to a bidding or reward project
    mapping(uint256 => bool) public NFTBelongsToBiddingProject;

    /// @notice Mapping to fetch the allocation of a TVS given the NFT Id
    mapping(uint256 => Allocation) public allocationOf;

    // EVENTS
    /// @notice Emitted when ETH is received
    /// @param sender Address that sent ETH
    /// @param amount Amount of ETH received
    event EtherReceived(address indexed sender, uint256 amount);

    /// @notice Emitted when a new rewardProject is launched
    /// @param projectId Unique identifier for the rewardProject
    /// @param projectName Token address of the rewardProject
    event RewardProjectLaunched(uint256 indexed projectId, address indexed projectName);

    /// @notice Emitted when a kol is allocated a TVS amount
    /// @param projectId Unique identifier for the rewardProject
    /// @param kol address of the KOL
    /// @param amount TVS amount
    /// @param vestingPeriod duration of the vesting period
    event TVSAllocated(uint256 indexed projectId, address indexed kol, uint256 amount, uint256 vestingPeriod);

    /// @notice Emitted when a kol is allocated a stablecoin amount
    /// @param projectId Unique identifier for the rewardProject
    /// @param kol address of the KOL
    /// @param amount stablecoin amount
    event StablecoinAllocated(uint256 indexed projectId, address indexed kol, uint256 amount);

    /// @notice Emitted when a KOL claims his TVS
    /// @param projectId Unique identifier for the rewardProject
    /// @param kol address of the KOL
    /// @param nftId ID of the claimed nft
    /// @param amount TVS amount
    /// @param vestingPeriod duration of the vesting period
    event RewardTVSClaimed(uint256 indexed projectId, address indexed kol, uint256 nftId, uint256 amount, uint256 vestingPeriod);

    /// @notice Emitted when a KOL claims his stablecoin tokens
    /// @param projectId Unique identifier for the rewardProject
    /// @param kol address of the KOL
    /// @param amount stablecoin amount
    event StablecoinAllocationClaimed(uint256 indexed projectId, address indexed kol, uint256 amount);

    /// @notice Emitted when the owner distributes a TVS to a KOL
    /// @param projectId Unique identifier for the rewardProject
    /// @param kol address of the KOL
    /// @param nftId ID of the distributed nft
    /// @param amount TVS amount
    /// @param vestingPeriod duration of the vesting period
    event RewardTVSDistributed(uint256 indexed projectId, address indexed kol, uint256 nftId, uint256 amount, uint256 vestingPeriod);

    /// @notice Emitted when the owner distributes a stablecoin allocation to a KOL
    /// @param projectId Unique identifier for the rewardProject
    /// @param kol address of the KOL
    /// @param amount stablecoin amount
    event StablecoinAllocationsDistributed(uint256 indexed projectId, address indexed kol, uint256 amount);

    /// @notice Emitted when a new biddingProject is launched
    /// @param projectId Unique identifier for the biddingProject
    /// @param projectName Token address of the biddingProject
    /// @param stablecoinAddress Stablecoin address of the biddingProject
    /// @param startTime Start time for the biddingProject
    /// @param endTimeHash End time hash for the biddingProject (hidden from end user till biddingProject is closed)
    event BiddingProjectLaunched(uint256 indexed projectId, address indexed projectName, address indexed stablecoinAddress, uint256 startTime, bytes32 endTimeHash);

    /// @notice Emitted when a bid is placed
    /// @param projectId ID of the biddingProject
    /// @param user Address of the bidder
    /// @param amount Amount of stablecoin committed
    /// @param vestingPeriod Desired vesting duration
    event BidPlaced(uint256 indexed projectId, address indexed user, uint256 amount, uint256 vestingPeriod);

    /// @notice Emitted when tokens are claimed
    /// @param projectId ID of the biddingProject
    /// @param isBiddingProject whether TVS comes from a bidding project or a reward project
    /// @param poolId ID of the pool
    /// @param isClaimed whether TVS is fully claimed
    /// @param nftId ID of the nft owning the claim
    /// @param claimedSeconds Number of seconds claimed
    /// @param claimTimestamp Timestamp of the claim
    /// @param user Address of the bidder
    /// @param amount Amount of tokens claimed
    event TokensClaimed(
        uint256 indexed projectId,
        bool isBiddingProject,
        uint256 indexed poolId,
        bool isClaimed,
        uint256 indexed nftId,
        uint256[] claimedSeconds,
        uint256 claimTimestamp,
        address user,
        uint256[] amount
    );

    /// @notice Emitted when a bid is refunded
    /// @param projectId ID of the biddingProject
    /// @param user Address of the bidder
    /// @param amount Amount of stablecoin refunded
    event BidRefunded(uint256 indexed projectId, address indexed user, uint256 amount);

    /// @notice Emitted when a new vesting pool is created
    /// @param projectId ID of the biddingProject
    /// @param poolId ID of the pool
    /// @param totalAllocation Total tokens allocated to the pool
    /// @param tokenPrice token price set for this pool
    /// @param hasExtraRefund whether pool has extra refund
    event PoolCreated(uint256 indexed projectId, uint256 indexed poolId, uint256 totalAllocation, uint256 tokenPrice, bool hasExtraRefund);

    /// @notice Emitted when a bid is updated
    /// @param projectId ID of the biddingProject
    /// @param user Address of the bidder
    /// @param oldAmount Previous bid amount
    /// @param newAmount Updated bid amount
    /// @param oldVestingPeriod Previous vesting period
    /// @param newVestingPeriod Updated vesting period
    event BidUpdated(
        uint256 indexed projectId,
        address indexed user,
        uint256 oldAmount,
        uint256 newAmount,
        uint256 oldVestingPeriod,
        uint256 newVestingPeriod
    );

    /// @notice Emitted when bidding is closed and allocations are finalized
    /// @param projectId ID of the biddingProject
    event BiddingClosed(uint256 indexed projectId);

    /// @notice Emitted when an NFT is claimed for an accepted bid
    /// @param projectId ID of the biddingProject
    /// @param user Address of the bidder
    /// @param tokenId ID of the minted NFT
    /// @param poolId ID of the pool allocated to
    /// @param amount Amount allocated
    event NFTClaimed(
        uint256 indexed projectId, address indexed user, uint256 indexed tokenId, uint256 poolId, uint256 amount
    );

    /// @notice Emitted when bidding is closed and merkle roots are set
    /// @param projectId ID of the biddingProject
    /// @param poolId ID of the pool
    /// @param merkleRoot Merkle root for the pool's bid allocations
    event PoolAllocationSet(uint256 indexed projectId, uint256 indexed poolId, bytes32 merkleRoot);

    /// @notice Emitted when a user merges TVSs
    /// @param projectId ID of the biddingProject 
    /// @param isBiddingProject whether the TVS belongs to a or a reward bidding project
    /// @param nftIds IDs of the NFTs that will be burnt after the merge
    /// @param mergedNftId ID of the NFT that will remain after the merged
    /// @param amounts amounts allocated to the merged TVS
    /// @param vestingPeriods vesting periods of the merged TVS
    /// @param vestingStartTimes start time of the vesting periods of the merged TVS
    /// @param claimedSeconds Seconds claimed from the merged TVS
    /// @param claimedFlows Whether the token flow is fully claimed or not
    event TVSsMerged(
        uint256 indexed projectId,
        bool isBiddingProject,
        uint256[] indexed nftIds,
        uint256 indexed mergedNftId,
        uint256[] amounts,
        uint256[] vestingPeriods,
        uint256[] vestingStartTimes,
        uint256[] claimedSeconds,
        bool[] claimedFlows
    );

    /// @notice Emitted when a user splits his TVSs
    /// @param projectId ID of the biddingProject
    /// @param isBiddingProject whether the TVS belongs to a bidding or a reward project
    /// @param splitNftId ID of the NFT to be split
    /// @param nftId ID of the NFT split
    /// @param amounts amounts allocated to this TVS split
    /// @param vestingPeriods vesting periods of this TVS split
    /// @param vestingStartTimes vesting periods' start times of this TVS split
    /// @param claimedSeconds Seconds claimed from this TVS split
    event TVSSplit(
        uint256 indexed projectId,
        bool isBiddingProject,
        uint256 indexed splitNftId,
        uint256 indexed nftId,
        uint256[] amounts,
        uint256[] vestingPeriods,
        uint256[] vestingStartTimes,
        uint256[] claimedSeconds
    );

    /// @notice Emitted when the owner updates the treasury
    /// @param oldTreasury old bidFee
    /// @param newTreasury new bidFee
    event treasuryUpdated(address oldTreasury, address newTreasury);

    /// @notice Emitted when the owner updates the vestingPeriodDivisor
    /// @param oldVestingPeriodDivisor old vestingPeriodDivisor
    /// @param newVestingPeriodDivisor new vestingPeriodDivisor
    event vestingPeriodDivisorUpdated(uint256 oldVestingPeriodDivisor, uint256 newVestingPeriodDivisor);

    /// @notice Emitted when the owner withdraws a profit generated by a project
    /// @param projectId Id of the project to withdraw from
    /// @param amount profit withdrawn from project
    event ProfitWithdrawn(uint256 projectId, uint256 amount);

    /// @notice Emitted when the owner updates the allocations for all the project's pools
    /// @param projectId Id of the project
    event AllPoolAllocationsSet(uint256 projectId);

    // ERRORS
    error Zero_Value();
    error Same_Value();
    error Zero_Address();
    error Percentages_Do_Not_Add_Up_To_One_Hundred();
    error Already_Claimed();
    error Project_Still_Open();
    error Project_Already_Closed();
    error Invalid_Project_Id();
    error Vesting_Period_Is_Not_Multiple_Of_The_Base_Value();
    error New_Vesting_Period_Cannot_Be_Smaller();
    error New_Bid_Cannot_Be_Smaller();
    error No_Bid_Found();
    error Bid_Already_Exists();
    error Merkle_Root_Already_Set();
    error Cannot_Exceed_Ten_Pools_Per_Project();
    error Array_Lengths_Must_Match();
    error Amounts_Do_Not_Add_Up_To_Total_Allocation();
    error Deadline_Has_Passed();
    error Deadline_Has_Not_Passed();
    error Caller_Has_No_TVS_Allocation();
    error Caller_Has_No_Stablecoin_Allocation();
    error Caller_Should_Own_The_NFT();
    error Not_Enough_TVS_To_Merge();
    error Different_Tokens();
    error Invalid_Merkle_Proof();
    error Invalid_Merkle_Roots_Length();
    error No_Claimable_Tokens();
    error Starttime_Must_Be_Smaller_Than_Endtime();
    error Bidding_Period_Is_Not_Active();
    error User_Is_Not_whitelisted();
    error Transfer_Failed();
    error Insufficient_Balance();

    /// @notice Initializes the vesting contract
    /// @param _nftContract Address of the NFT contract
    function initialize(address _nftContract) public initializer {
        __Ownable_init(msg.sender);
        __FeesManager_init();
        __WhitelistManager_init();
        require(_nftContract != address(0), Zero_Address());
        nftContract = IAlignerzNFT(_nftContract);
        vestingPeriodDivisor = 2_592_000; // Set default vesting period multiples to 1 month (2592000 seconds)
    }

    /// @notice Handles direct ETH transfers to the contract
    receive() external payable {
        emit EtherReceived(msg.sender, msg.value);
    }

    /// @notice Handles unknown function calls
    fallback() external payable {
        revert();
    }

    /// @notice Allows owner to withdraw stuck tokens
    /// @param tokenAddress Address of the token to withdraw
    /// @param amount Amount of tokens to withdraw
    function withdrawStuckTokens(address tokenAddress, uint256 amount) external onlyOwner {
        require(amount > 0, Zero_Value());
        require(tokenAddress != address(0), Zero_Address());

        IERC20 token = IERC20(tokenAddress);
        require(token.balanceOf(address(this)) >= amount, Insufficient_Balance());
        token.safeTransfer(msg.sender, amount);
    }

    /// @notice Allows owner to withdraw stuck ETH
    /// @param amount Amount of ETH to withdraw
    function withdrawStuckETH(uint256 amount) external onlyOwner {
        require(amount > 0, Zero_Value());
        require(address(this).balance >= amount, Insufficient_Balance());

        (bool success,) = msg.sender.call{value: amount}("");
        require(success, Transfer_Failed());
    }

    /// @notice Changes the vesting period multiples
    /// @dev Only callable by the owner.
    /// @param newVestingPeriodDivisor the new value
    /// @return bool indicating success of the operation.
    function setVestingPeriodDivisor(uint256 newVestingPeriodDivisor) external onlyOwner returns (bool) {
        require(newVestingPeriodDivisor > 0, Zero_Value());
        uint256 oldVestingPeriodDivisor = vestingPeriodDivisor;
        require(
            newVestingPeriodDivisor != vestingPeriodDivisor,
            Same_Value()
        );
        vestingPeriodDivisor = newVestingPeriodDivisor;
        emit vestingPeriodDivisorUpdated(oldVestingPeriodDivisor, newVestingPeriodDivisor);
        return true;
    }

    
    /// @notice Updates the Diamond Hands Rewarder contract address.
    /// @dev Only callable by the owner.
    /// @param newTreasury The address of the new rewarder contract.
    /// @return bool indicating success of the operation.
    function setTreasury(address newTreasury) external onlyOwner returns (bool) {
        require(newTreasury != address(0), Zero_Address());
        address oldTreasury = treasury;
        require(
            newTreasury != oldTreasury,
            Same_Value()
        );
        treasury = newTreasury;

        emit treasuryUpdated(oldTreasury, newTreasury);
        return true; 
    }

    // Reward Projects
    /// @notice Launches a new vesting biddingProject
    /// @param tokenAddress Address of the token to be vested by KOLs
    /// @param stablecoinAddress Address of the stablecoin to be claimed by KOLs
    /// @param startTime Start time of the vesting periods
    /// @param claimWindow Amount of time the users will have to claim their TVS or refund
    function launchRewardProject(
        address tokenAddress,
        address stablecoinAddress,
        uint256 startTime,
        uint256 claimWindow
    ) external onlyOwner {
        require(tokenAddress != address(0), Zero_Address());
        require(stablecoinAddress != address(0), Zero_Address());

        RewardProject storage rewardProject = rewardProjects[rewardProjectCount];
        rewardProject.startTime = startTime;
        rewardProject.claimDeadline = startTime + claimWindow;
        rewardProject.token = IERC20(tokenAddress);
        rewardProject.stablecoin = IERC20(stablecoinAddress);

        emit RewardProjectLaunched(rewardProjectCount, tokenAddress);
        rewardProjectCount++;
    }

    /// @notice Sets KOLs TVS allocations
    /// @param rewardProjectId Id of the rewardProject
    /// @param totalTVSAllocation total amount to be allocated in TVSs to KOLs
    /// @param vestingPeriod duration the vesting periods
    /// @param kolTVS addresses of the KOLs who chose to be rewarded in TVS
    /// @param TVSamounts token amounts allocated for the KOLs who chose to be rewarded in TVS
    function setTVSAllocation(uint256 rewardProjectId, uint256 totalTVSAllocation, uint256 vestingPeriod, address[] calldata kolTVS, uint256[] calldata TVSamounts) external onlyOwner {
        RewardProject storage rewardProject = rewardProjects[rewardProjectId];
        rewardProject.vestingPeriod = vestingPeriod;
        uint256 length = kolTVS.length;
        require(length == TVSamounts.length, Array_Lengths_Must_Match());
        uint256 totalAmount;
        for (uint256 i = 0; i < length; i++) {
            address kol = kolTVS[i];
            rewardProject.kolTVSAddresses.push(kol);
            uint256 amount = TVSamounts[i];
            rewardProject.kolTVSRewards[kol] = amount;
            rewardProject.kolTVSIndexOf[kol] = i;
            totalAmount += amount;
            emit TVSAllocated(rewardProjectId, kol, amount, vestingPeriod);
        }
        require(
            totalTVSAllocation == totalAmount, Amounts_Do_Not_Add_Up_To_Total_Allocation()
        );
        rewardProject.token.safeTransferFrom(msg.sender, address(this), totalTVSAllocation);
    }

    /// @notice Sets KOLs Stablecoin allocations
    /// @param rewardProjectId Id of the rewardProject
    /// @param totalStablecoinAllocation total amount to be allocated in stablecoin to KOLs
    /// @param kolStablecoin addresses of the KOLs who chose to be rewarded in stablecoin
    /// @param stablecoinAmounts stablecoin amounts allocated for the KOLs who chose to be rewarded in stablecoin
    function setStablecoinAllocation(uint256 rewardProjectId, uint256 totalStablecoinAllocation, address[] calldata kolStablecoin, uint256[] calldata stablecoinAmounts) external onlyOwner {
        RewardProject storage rewardProject = rewardProjects[rewardProjectId];
        uint256 length = kolStablecoin.length;
        require(length == stablecoinAmounts.length, Array_Lengths_Must_Match());
        uint256 totalAmount;
        for (uint256 i = 0; i < length; i++) {
            address kol = kolStablecoin[i];
            rewardProject.kolStablecoinAddresses.push(kol);
            uint256 amount = stablecoinAmounts[i];
            rewardProject.kolStablecoinRewards[kol] = amount;
            rewardProject.kolStablecoinIndexOf[kol] = i;
            totalAmount += amount;
            emit StablecoinAllocated(rewardProjectId, kol, amount);
        }
        require(
            totalStablecoinAllocation == totalAmount, Amounts_Do_Not_Add_Up_To_Total_Allocation()
        );
        rewardProject.stablecoin.safeTransferFrom(msg.sender, address(this), totalStablecoinAllocation);
    }

    /// @notice Allows a KOL to claim his TVS
    /// @param rewardProjectId Id of the rewardProject
    function claimRewardTVS(uint256 rewardProjectId) external {
        RewardProject storage rewardProject = rewardProjects[rewardProjectId];
        require(block.timestamp < rewardProject.claimDeadline, Deadline_Has_Passed());
        address kol = msg.sender;
        _claimRewardTVS(rewardProjectId, kol);
    }

    /// @notice Allows a KOL to claim his stablecoin allocation
    /// @param rewardProjectId Id of the rewardProject
    function claimStablecoinAllocation(uint256 rewardProjectId) external {
        RewardProject storage rewardProject = rewardProjects[rewardProjectId];
        require(block.timestamp < rewardProject.claimDeadline, Deadline_Has_Passed());
        address kol = msg.sender;
        _claimStablecoinAllocation(rewardProjectId, kol);
    }

    /// @notice Allows the owner to distribute the TVS that have not been claimed yet to the KOLs
    /// @param rewardProjectId Id of the rewardProject
    /// @param kol addresses of the KOLs who chose to be rewarded in stablecoin that have not claimed their tokens during the claimWindow
    function distributeRewardTVS(uint256 rewardProjectId, address[] calldata kol) external {
        RewardProject storage rewardProject = rewardProjects[rewardProjectId];
        require(block.timestamp > rewardProject.claimDeadline, Deadline_Has_Not_Passed());
        uint256 len = rewardProject.kolTVSAddresses.length;
        for (uint256 i; i < len;) {
            _claimRewardTVS(rewardProjectId, kol[i]);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Allows the owner to distribute the stablecoin tokens that have not been claimed yet to the KOLs
    /// @param rewardProjectId Id of the rewardProject
    /// @param kol addresses of the KOLs who chose to be rewarded in stablecoin that have not claimed their tokens during the claimWindow
    function distributeStablecoinAllocation(uint256 rewardProjectId, address[] calldata kol) external {
        RewardProject storage rewardProject = rewardProjects[rewardProjectId];
        require(block.timestamp > rewardProject.claimDeadline, Deadline_Has_Not_Passed());
        uint256 len = rewardProject.kolStablecoinAddresses.length;
        for (uint256 i; i < len;) {
            _claimStablecoinAllocation(rewardProjectId, kol[i]);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Allows the owner to distribute the TVS that have not been claimed yet to the KOLs
    /// @param rewardProjectId Id of the rewardProject
    function distributeRemainingRewardTVS(uint256 rewardProjectId) external onlyOwner{
        RewardProject storage rewardProject = rewardProjects[rewardProjectId];
        require(block.timestamp > rewardProject.claimDeadline, Deadline_Has_Not_Passed());
        uint256 len = rewardProject.kolTVSAddresses.length;
        for (uint256 i = len - 1; rewardProject.kolTVSAddresses.length > 0;) {
            address kol = rewardProject.kolTVSAddresses[i];
            uint256 amount = rewardProject.kolTVSRewards[kol];
            rewardProject.kolTVSRewards[kol] = 0;
            uint256 nftId = nftContract.mint(kol);
            rewardProject.allocations[nftId].amounts.push(amount);
            uint256 vestingPeriod = rewardProject.vestingPeriod;
            rewardProject.allocations[nftId].vestingPeriods.push(vestingPeriod);
            rewardProject.allocations[nftId].vestingStartTimes.push(rewardProject.startTime);
            rewardProject.allocations[nftId].claimedSeconds.push(0);
            rewardProject.allocations[nftId].claimedFlows.push(false);
            rewardProject.allocations[nftId].token = rewardProject.token;
            rewardProject.kolTVSAddresses.pop();
            allocationOf[nftId] = rewardProject.allocations[nftId];
            emit RewardTVSDistributed(rewardProjectId, kol, nftId, amount, vestingPeriod);
            unchecked {
                --i;
            }
        }
    }

    /// @notice Allows the owner to distribute the Stablecoin tokens that have not been claimed yet to the KOLs
    /// @param rewardProjectId Id of the rewardProject
    function distributeRemainingStablecoinAllocation(uint256 rewardProjectId) external onlyOwner {
        RewardProject storage rewardProject = rewardProjects[rewardProjectId];
        require(block.timestamp > rewardProject.claimDeadline, Deadline_Has_Not_Passed());
        uint256 len = rewardProject.kolStablecoinAddresses.length;
        for (uint256 i = len - 1; rewardProject.kolStablecoinAddresses.length > 0;) {
            address kol = rewardProject.kolStablecoinAddresses[i];
            uint256 amount = rewardProject.kolStablecoinRewards[kol];
            rewardProject.kolStablecoinRewards[kol] = 0;
            rewardProject.stablecoin.safeTransfer(kol, amount);
            rewardProject.kolStablecoinAddresses.pop();
            emit StablecoinAllocationsDistributed(rewardProjectId, kol, amount);
            unchecked {
                --i;
            }
        }
    }

    /// @notice Internal logic of reward TVS claim
    /// @param rewardProjectId Id of the rewardProject
    /// @param kol address of the KOL who chose to be rewarded in TVS
    function _claimRewardTVS(uint256 rewardProjectId, address kol) internal {
        RewardProject storage rewardProject = rewardProjects[rewardProjectId];
        uint256 amount = rewardProject.kolTVSRewards[kol];
        require(amount > 0, Caller_Has_No_TVS_Allocation());
        rewardProject.kolTVSRewards[kol] = 0;
        uint256 nftId = nftContract.mint(kol);
        rewardProject.allocations[nftId].amounts.push(amount);
        uint256 vestingPeriod = rewardProject.vestingPeriod;
        rewardProject.allocations[nftId].vestingPeriods.push(vestingPeriod);
        rewardProject.allocations[nftId].vestingStartTimes.push(rewardProject.startTime);
        rewardProject.allocations[nftId].claimedSeconds.push(0);
        rewardProject.allocations[nftId].claimedFlows.push(false);
        rewardProject.allocations[nftId].token = rewardProject.token;
        allocationOf[nftId] = rewardProject.allocations[nftId];
        uint256 index = rewardProject.kolTVSIndexOf[kol];
        uint256 arrayLength = rewardProject.kolTVSAddresses.length;
        rewardProject.kolTVSIndexOf[kol] = arrayLength - 1;
        address lastIndexAddress = rewardProject.kolTVSAddresses[arrayLength - 1];
        rewardProject.kolTVSIndexOf[lastIndexAddress] = index;
        rewardProject.kolTVSAddresses[index] = rewardProject.kolTVSAddresses[arrayLength - 1];
        rewardProject.kolTVSAddresses.pop();
        emit RewardTVSClaimed(rewardProjectId, kol, nftId, amount, vestingPeriod);
    }

    /// @notice Internal logic of reward stablecoin tokens claim
    /// @param rewardProjectId Id of the rewardProject
    /// @param kol address of the KOL who chose to be rewarded in stablecoin
    function _claimStablecoinAllocation(uint256 rewardProjectId, address kol) internal {
        RewardProject storage rewardProject = rewardProjects[rewardProjectId];
        uint256 amount = rewardProject.kolStablecoinRewards[kol];
        require(amount > 0, Caller_Has_No_Stablecoin_Allocation());
        rewardProject.kolStablecoinRewards[kol] = 0;
        rewardProject.stablecoin.safeTransfer(kol, amount);
        uint256 index = rewardProject.kolStablecoinIndexOf[kol];
        uint256 arrayLength = rewardProject.kolStablecoinAddresses.length;
        rewardProject.kolStablecoinIndexOf[kol] = arrayLength - 1;
        address lastIndexAddress = rewardProject.kolStablecoinAddresses[arrayLength - 1];
        rewardProject.kolStablecoinIndexOf[lastIndexAddress] = index;
        rewardProject.kolStablecoinAddresses[index] = rewardProject.kolStablecoinAddresses[arrayLength - 1];
        rewardProject.kolStablecoinAddresses.pop();
        emit StablecoinAllocationClaimed(rewardProjectId, kol, amount);
    }
    // Bidding projects
    /// @notice Launches a new vesting biddingProject
    /// @param tokenAddress Address of the token to be vested
    /// @param stablecoinAddress Address of the token used for bidding
    /// @param startTime Start time of the bidding period
    /// @param endTime End time of the bidding period (this is set to far in the future and reset when biddingProject is closed)
    /// @param endTimeHash End time hash for the biddingProject (hidden from end user till biddingProject is closed)
    /// @param whitelistStatus Whether the biddingProject has enabled his whitelisting mechanism or not
    function launchBiddingProject(
        address tokenAddress,
        address stablecoinAddress,
        uint256 startTime,
        uint256 endTime,
        bytes32 endTimeHash,
        bool whitelistStatus
    ) external onlyOwner {
        require(tokenAddress != address(0), Zero_Address());
        require(stablecoinAddress != address(0), Zero_Address());
        require(startTime < endTime, Starttime_Must_Be_Smaller_Than_Endtime());

        BiddingProject storage biddingProject = biddingProjects[biddingProjectCount];
        biddingProject.token = IERC20(tokenAddress);
        biddingProject.stablecoin = IERC20(stablecoinAddress);
        biddingProject.startTime = startTime;
        biddingProject.endTime = endTime;
        biddingProject.poolCount = 0;
        biddingProject.endTimeHash = endTimeHash;
        isWhitelistEnabled[biddingProjectCount] = whitelistStatus;
        emit BiddingProjectLaunched(biddingProjectCount, tokenAddress, stablecoinAddress, startTime, endTimeHash);
        biddingProjectCount++;
    }

    /// @notice Creates a new vesting pool in a biddingProject
    /// @param projectId ID of the biddingProject
    /// @param totalAllocation Total tokens allocated to this pool
    /// @param tokenPrice token price set for this pool
    function createPool(uint256 projectId, uint256 totalAllocation, uint256 tokenPrice, bool hasExtraRefund)
        external
        onlyOwner
    {
        require(projectId < biddingProjectCount, Invalid_Project_Id());
        require(totalAllocation > 0, Zero_Value());
        require(tokenPrice > 0, Zero_Value());

        BiddingProject storage biddingProject = biddingProjects[projectId];
        require(!biddingProject.closed, Project_Already_Closed());
        require(biddingProject.poolCount <= 10, Cannot_Exceed_Ten_Pools_Per_Project());  

        biddingProject.token.safeTransferFrom(msg.sender, address(this), totalAllocation);

        uint256 poolId = biddingProject.poolCount;
        biddingProject.vestingPools[poolId] = VestingPool({
            merkleRoot: bytes32(0), // Initialize with empty merkle root
            hasExtraRefund: hasExtraRefund
        });

        biddingProject.poolCount++;

        emit PoolCreated(projectId, poolId, totalAllocation, tokenPrice, hasExtraRefund);
    }

    /// @notice Places a bid for token vesting
    /// @param projectId ID of the biddingProject
    /// @param amount Amount of stablecoin to commit
    /// @param vestingPeriod Desired vesting duration
    function placeBid(uint256 projectId, uint256 amount, uint256 vestingPeriod) external {
        if (isWhitelistEnabled[projectId]) {
            require(isWhitelisted[msg.sender][projectId], User_Is_Not_whitelisted());
        }
        require(projectId < biddingProjectCount, Invalid_Project_Id());
        require(amount > 0, Zero_Value());

        BiddingProject storage biddingProject = biddingProjects[projectId];
        require(
            block.timestamp >= biddingProject.startTime && block.timestamp <= biddingProject.endTime && !biddingProject.closed,
            Bidding_Period_Is_Not_Active()
        );
        require(biddingProject.bids[msg.sender].amount == 0, Bid_Already_Exists());

        require(vestingPeriod > 0, Zero_Value());

        require (vestingPeriod < 2 || vestingPeriod % vestingPeriodDivisor == 0, Vesting_Period_Is_Not_Multiple_Of_The_Base_Value());

        biddingProject.stablecoin.safeTransferFrom(msg.sender, address(this), amount);
        if (bidFee > 0) {
            biddingProject.stablecoin.safeTransferFrom(msg.sender, treasury, bidFee);
        }
        biddingProject.bids[msg.sender] =
            Bid({amount: amount, vestingPeriod: vestingPeriod});
        biddingProject.totalStablecoinBalance += amount;

        emit BidPlaced(projectId, msg.sender, amount, vestingPeriod);
    }

    /// @notice Updates an existing bid
    /// @param projectId ID of the biddingProject
    /// @param newAmount New amount of stablecoin to commit
    /// @param newVestingPeriod New vesting duration
    function updateBid(uint256 projectId, uint256 newAmount, uint256 newVestingPeriod) external {
        require(projectId < biddingProjectCount, Invalid_Project_Id());
        BiddingProject storage biddingProject = biddingProjects[projectId];
        require(
            block.timestamp >= biddingProject.startTime && block.timestamp <= biddingProject.endTime && !biddingProject.closed,
            Bidding_Period_Is_Not_Active()
        );

        Bid storage bid = biddingProject.bids[msg.sender];
        uint256 oldAmount = bid.amount;
        require(oldAmount > 0, No_Bid_Found());
        require(newAmount >= oldAmount, New_Bid_Cannot_Be_Smaller());
        require(newVestingPeriod > 0, Zero_Value());
        require(newVestingPeriod >= bid.vestingPeriod, New_Vesting_Period_Cannot_Be_Smaller());
        if (newVestingPeriod > 1) {
            require(
                newVestingPeriod % vestingPeriodDivisor == 0, Vesting_Period_Is_Not_Multiple_Of_The_Base_Value()
            );
        }

        uint256 oldVestingPeriod = bid.vestingPeriod;

        if (newAmount > oldAmount) {
            uint256 additionalAmount = newAmount - oldAmount;
            biddingProject.totalStablecoinBalance += additionalAmount;
            biddingProject.stablecoin.safeTransferFrom(msg.sender, address(this), additionalAmount);
        }

        if (updateBidFee > 0) {
            biddingProject.stablecoin.safeTransferFrom(msg.sender, treasury, updateBidFee);
        }
        bid.amount = newAmount;
        bid.vestingPeriod = newVestingPeriod;

        emit BidUpdated(projectId, msg.sender, oldAmount, newAmount, oldVestingPeriod, newVestingPeriod);
    }

    /// @notice Finalizes bids by setting merkle roots for each pool
    /// @param projectId ID of the biddingProject
    /// @param refundRoot merkle root for refunds
    /// @param merkleRoots Array of merkle roots, one per pool
    /// @param claimWindow Amount of time the users will have to claim their TVS or refund
    function finalizeBids(uint256 projectId, bytes32 refundRoot, bytes32[] calldata merkleRoots, uint256 claimWindow)
        external
        onlyOwner
    {
        require(projectId < biddingProjectCount, Invalid_Project_Id());
        BiddingProject storage biddingProject = biddingProjects[projectId];
        require(!biddingProject.closed, Project_Already_Closed());

        uint256 nbOfPools = biddingProject.poolCount;
        require(merkleRoots.length == nbOfPools, Invalid_Merkle_Roots_Length());

        // Set merkle root for each pool
        for (uint256 poolId = 0; poolId < nbOfPools; poolId++) {
            require(biddingProject.vestingPools[poolId].merkleRoot == bytes32(0), Merkle_Root_Already_Set());
            biddingProject.vestingPools[poolId].merkleRoot = merkleRoots[poolId];
            emit PoolAllocationSet(projectId, poolId, merkleRoots[poolId]);
        }

        biddingProject.closed = true;
        biddingProject.endTime = block.timestamp;
        biddingProject.claimDeadline = block.timestamp + claimWindow;
        biddingProject.refundRoot = refundRoot;
        emit BiddingClosed(projectId);
    }

    /// @notice updates biddingProject merkle trees for each pool
    /// @param projectId ID of the biddingProject
    /// @param refundRoot merkle root for refunds
    /// @param merkleRoots Array of merkle roots, one per pool
    function updateProjectAllocations(uint256 projectId, bytes32 refundRoot, bytes32[] calldata merkleRoots)
        external
        onlyOwner
    {
        require(projectId < biddingProjectCount, Invalid_Project_Id());
        BiddingProject storage biddingProject = biddingProjects[projectId];
        require(biddingProject.closed, Project_Still_Open());
        require(merkleRoots.length == biddingProject.poolCount, Invalid_Merkle_Roots_Length());

        // Set merkle root for each pool
        for (uint256 poolId = 0; poolId < biddingProject.poolCount; poolId++) {
            biddingProject.vestingPools[poolId].merkleRoot = merkleRoots[poolId];
            emit PoolAllocationSet(projectId, poolId, merkleRoots[poolId]);
        }

        biddingProject.refundRoot = refundRoot;
        emit AllPoolAllocationsSet(projectId);
    }

    /// @notice Allows users to claim refunds for rejected bids
    /// @param projectId ID of the biddingProject
    /// @param amount Amount allocated
    /// @param merkleProof Merkle proof of refund
    function claimRefund(uint256 projectId, uint256 amount, bytes32[] calldata merkleProof) external {
        BiddingProject storage biddingProject = biddingProjects[projectId];
        require(biddingProject.claimDeadline > block.timestamp, Deadline_Has_Passed());

        Bid storage bid = biddingProject.bids[msg.sender];
        require(bid.amount > 0, No_Bid_Found());

        uint256 poolId = 0;
        // Verify merkle proof
        bytes32 leaf = keccak256(abi.encodePacked(msg.sender, amount, projectId, poolId));
        require(!claimedRefund[leaf], Already_Claimed());
        require(MerkleProof.verify(merkleProof, biddingProject.refundRoot, leaf), Invalid_Merkle_Proof());
        claimedRefund[leaf] = true;

        biddingProject.totalStablecoinBalance -= amount;
        biddingProject.stablecoin.safeTransfer(msg.sender, amount);

        emit BidRefunded(projectId, msg.sender, amount);
    }

    /// @notice Claims an NFT certificate for an accepted bid with merkle proof
    /// @param projectId ID of the biddingProject
    /// @param poolId ID of the pool allocated to
    /// @param amount Amount allocated
    /// @param merkleProof Merkle proof of allocation
    function claimNFT(uint256 projectId, uint256 poolId, uint256 amount, bytes32[] calldata merkleProof)
        external
        returns (uint256)
    {
        BiddingProject storage biddingProject = biddingProjects[projectId];
        require(biddingProject.claimDeadline > block.timestamp, Deadline_Has_Passed());

        Bid storage bid = biddingProject.bids[msg.sender];
        require(bid.amount > 0, No_Bid_Found());

        // Verify merkle proof
        bytes32 leaf = keccak256(abi.encodePacked(msg.sender, amount, projectId, poolId));

        require(!claimedNFT[leaf], Already_Claimed());
        require(MerkleProof.verify(merkleProof, biddingProject.vestingPools[poolId].merkleRoot, leaf), Invalid_Merkle_Proof());

        claimedNFT[leaf] = true;

        uint256 nftId = nftContract.mint(msg.sender);
        biddingProject.allocations[nftId].amounts.push(amount);
        biddingProject.allocations[nftId].vestingPeriods.push(bid.vestingPeriod);
        biddingProject.allocations[nftId].vestingStartTimes.push(biddingProject.endTime);
        biddingProject.allocations[nftId].claimedSeconds.push(0);
        biddingProject.allocations[nftId].claimedFlows.push(false);
        biddingProject.allocations[nftId].assignedPoolId = poolId;
        biddingProject.allocations[nftId].token = biddingProject.token;
        NFTBelongsToBiddingProject[nftId] = true;
        allocationOf[nftId] = biddingProject.allocations[nftId];
        emit NFTClaimed(projectId, msg.sender, nftId, poolId, amount);

        return nftId;
    }

    /// @notice Allows the owner to withdraw all the projects' profits
    function withdrawAllPostDeadlineProfits() external onlyOwner {
        uint256 _projectCount = biddingProjectCount;
        for (uint256 i; i < _projectCount; i++) {
            _withdrawPostDeadlineProfit(i);
        }
    }

    /// @notice Allows the owner to withdraw some projects' profits
    /// @param projectIds IDs of the biddingProjects
    function withdrawPostDeadlineProfits(uint256[] calldata projectIds) external onlyOwner {
        uint256 _projectCount = biddingProjectCount;
        uint256 len = projectIds.length;
        for (uint256 i; i < len; i++) {
            require(projectIds[i] < _projectCount, Invalid_Project_Id());
            _withdrawPostDeadlineProfit(projectIds[i]);
        }
    }

    /// @notice Allows the owner to withdraw a project's profits
    /// @param projectId ID of the biddingProject
    function withdrawPostDeadlineProfit(uint256 projectId) external onlyOwner {
        BiddingProject storage biddingProject = biddingProjects[projectId];
        uint256 deadline = biddingProject.claimDeadline;
        require(block.timestamp > deadline, Deadline_Has_Not_Passed());
        uint256 amount = biddingProject.totalStablecoinBalance;
        biddingProject.stablecoin.safeTransfer(treasury, amount);
        biddingProject.totalStablecoinBalance = 0;
        emit ProfitWithdrawn(projectId, amount);
    }

    /// @notice logic of a project's profits withdrawal
    /// @param projectId ID of the biddingProject
    function _withdrawPostDeadlineProfit(uint256 projectId) internal {
        BiddingProject storage biddingProject = biddingProjects[projectId];
        uint256 deadline = biddingProject.claimDeadline;
        if (block.timestamp > deadline) {
            uint256 amount = biddingProject.totalStablecoinBalance;
            biddingProject.stablecoin.safeTransfer(treasury, amount);
            biddingProject.totalStablecoinBalance = 0;
            emit ProfitWithdrawn(projectId, amount);
        }
    }

    // For both bidding and reward projects
    /// @notice Claims vested tokens
    /// @param projectId ID of the biddingProject
    /// @param nftId ID of the ownership NFT of the bid
    function claimTokens(uint256 projectId, uint256 nftId) external {
        address nftOwner = nftContract.extOwnerOf(nftId);
        require(msg.sender == nftOwner, Caller_Should_Own_The_NFT());
        bool isBiddingProject = NFTBelongsToBiddingProject[nftId];
        (Allocation storage allocation, IERC20 token) = isBiddingProject ? 
        (biddingProjects[projectId].allocations[nftId], biddingProjects[projectId].token) : 
        (rewardProjects[projectId].allocations[nftId], rewardProjects[projectId].token);
        uint256 nbOfFlows = allocation.vestingPeriods.length;
        uint256 claimableAmounts;
        uint256[] memory amountsClaimed = new uint256[](nbOfFlows);
        uint256[] memory allClaimableSeconds = new uint256[](nbOfFlows);
        uint256 flowsClaimed;
        for (uint256 i; i < nbOfFlows; i++) {
            if (allocation.claimedFlows[i]) {
                flowsClaimed++;
                continue;
            }
            (uint256 claimableAmount, uint256 claimableSeconds) = getClaimableAmountAndSeconds(allocation, i);

            allocation.claimedSeconds[i] += claimableSeconds;
            if (allocation.claimedSeconds[i] >= allocation.vestingPeriods[i]) {
                flowsClaimed++;
                allocation.claimedFlows[i] = true;
            }
            allClaimableSeconds[i] = claimableSeconds;
            amountsClaimed[i] = claimableAmount;
            claimableAmounts += claimableAmount;
        }
        if (flowsClaimed == nbOfFlows) {
            nftContract.burn(nftId);
            allocation.isClaimed = true;
        }
        token.safeTransfer(msg.sender, claimableAmounts);
        emit TokensClaimed(projectId, isBiddingProject, allocation.assignedPoolId, allocation.isClaimed, nftId, allClaimableSeconds, block.timestamp, msg.sender, amountsClaimed);
    }

    /// @notice getter for claimable amount and seconds for a certain allocation's flow index
    /// @param allocation the TVS allocation
    /// @param flowIndex index of the token flow for which to get the claimable amount and seconds
    function getClaimableAmountAndSeconds(Allocation memory allocation, uint256 flowIndex) public view returns(uint256 claimableAmount, uint256 claimableSeconds) {
        uint256 secondsPassed;
        uint256 claimedSeconds = allocation.claimedSeconds[flowIndex];
        uint256 vestingPeriod = allocation.vestingPeriods[flowIndex];
        uint256 vestingStartTime = allocation.vestingStartTimes[flowIndex];
        uint256 amount = allocation.amounts[flowIndex];
        if (block.timestamp > vestingPeriod + vestingStartTime) {
            secondsPassed = vestingPeriod;
        } else {
            secondsPassed = block.timestamp - vestingStartTime;
        }

        claimableSeconds = secondsPassed - claimedSeconds;
        claimableAmount = (amount * claimableSeconds) / vestingPeriod;
        require(claimableAmount > 0, No_Claimable_Tokens());
        return (claimableAmount, claimableSeconds);
    }

    /// @notice Allows users to merge one TVS into another
    /// @param projectId ID of the biddingProject
    /// @param nftIds tokenIds of the NFTs that will be merged, these tokens will be burned
    /// @param mergedNftId tokenId of the NFT that will remain after the merge
    function mergeTVS(uint256 projectId, uint256 mergedNftId, uint256[] calldata projectIds, uint256[] calldata nftIds) external returns(uint256) {
        address nftOwner = nftContract.extOwnerOf(mergedNftId);
        require(msg.sender == nftOwner, Caller_Should_Own_The_NFT());
        
        bool isBiddingProject = NFTBelongsToBiddingProject[mergedNftId];
        (Allocation storage mergedTVS, IERC20 token) = isBiddingProject ?
        (biddingProjects[projectId].allocations[mergedNftId], biddingProjects[projectId].token) :
        (rewardProjects[projectId].allocations[mergedNftId], rewardProjects[projectId].token);

        uint256[] memory amounts = mergedTVS.amounts;
        uint256 nbOfFlows = mergedTVS.amounts.length;
        (uint256 feeAmount, uint256[] memory newAmounts) = calculateFeeAndNewAmountForOneTVS(mergeFeeRate, amounts, nbOfFlows);
        mergedTVS.amounts = newAmounts;

        uint256 nbOfNFTs = nftIds.length;
        require(nbOfNFTs > 0, Not_Enough_TVS_To_Merge());
        require(nbOfNFTs == projectIds.length, Array_Lengths_Must_Match());

        for (uint256 i; i < nbOfNFTs; i++) {
            feeAmount += _merge(mergedTVS, projectIds[i], nftIds[i], token);
        }
        token.safeTransfer(treasury, feeAmount);
        emit TVSsMerged(projectId, isBiddingProject, nftIds, mergedNftId, mergedTVS.amounts, mergedTVS.vestingPeriods, mergedTVS.vestingStartTimes, mergedTVS.claimedSeconds, mergedTVS.claimedFlows);
        return mergedNftId;
    }

    function _merge(Allocation storage mergedTVS, uint256 projectId, uint256 nftId, IERC20 token) internal returns (uint256 feeAmount) {
        require(msg.sender == nftContract.extOwnerOf(nftId), Caller_Should_Own_The_NFT());
        
        bool isBiddingProjectTVSToMerge = NFTBelongsToBiddingProject[nftId];
        (Allocation storage TVSToMerge, IERC20 tokenToMerge) = isBiddingProjectTVSToMerge ?
        (biddingProjects[projectId].allocations[nftId], biddingProjects[projectId].token) :
        (rewardProjects[projectId].allocations[nftId], rewardProjects[projectId].token);
        require(address(token) == address(tokenToMerge), Different_Tokens());

        uint256 nbOfFlowsTVSToMerge = TVSToMerge.amounts.length;
        for (uint256 j = 0; j < nbOfFlowsTVSToMerge; j++) {
            uint256 fee = calculateFeeAmount(mergeFeeRate, TVSToMerge.amounts[j]);
            mergedTVS.amounts.push(TVSToMerge.amounts[j] - fee);
            mergedTVS.vestingPeriods.push(TVSToMerge.vestingPeriods[j]);
            mergedTVS.vestingStartTimes.push(TVSToMerge.vestingStartTimes[j]);
            mergedTVS.claimedSeconds.push(TVSToMerge.claimedSeconds[j]);
            mergedTVS.claimedFlows.push(TVSToMerge.claimedFlows[j]);
            feeAmount += fee;
        }
        nftContract.burn(nftId);
    }

    /// @notice Allows users to split a TVS
    /// @param projectId ID of the biddingProject
    /// @param percentages % in basis point of the allocated amount that will be allocated in the TVSs after the split
    /// @param splitNftId tokenId of the NFT that will be split
    function splitTVS(
        uint256 projectId,
        uint256[] calldata percentages,
        uint256 splitNftId
    ) external returns (uint256, uint256[] memory) {
        address nftOwner = nftContract.extOwnerOf(splitNftId);
        require(msg.sender == nftOwner, Caller_Should_Own_The_NFT());

        bool isBiddingProject = NFTBelongsToBiddingProject[splitNftId];
        (Allocation storage allocation, IERC20 token) = isBiddingProject ?
        (biddingProjects[projectId].allocations[splitNftId], biddingProjects[projectId].token) :
        (rewardProjects[projectId].allocations[splitNftId], rewardProjects[projectId].token);

        uint256[] memory amounts = allocation.amounts;
        uint256 nbOfFlows = allocation.amounts.length;
        (uint256 feeAmount, uint256[] memory newAmounts) = calculateFeeAndNewAmountForOneTVS(splitFeeRate, amounts, nbOfFlows);
        allocation.amounts = newAmounts;
        token.safeTransfer(treasury, feeAmount);

        uint256 nbOfTVS = percentages.length;

        // new NFT IDs except the original one
        uint256[] memory newNftIds = new uint256[](nbOfTVS - 1);

        // Allocate outer arrays for the event
        Allocation[] memory allAlloc = new Allocation[](nbOfTVS);

        uint256 sumOfPercentages;
        for (uint256 i; i < nbOfTVS;) {
            uint256 percentage = percentages[i];
            sumOfPercentages += percentage;

            uint256 nftId = i == 0 ? splitNftId : nftContract.mint(msg.sender);
            if (i != 0) newNftIds[i - 1] = nftId;
            Allocation memory alloc = _computeSplitArrays(allocation, percentage, nbOfFlows);
            NFTBelongsToBiddingProject[nftId] = isBiddingProject ? true : false;
            Allocation storage newAlloc = isBiddingProject ? biddingProjects[projectId].allocations[nftId] : rewardProjects[projectId].allocations[nftId];
            _assignAllocation(newAlloc, alloc);
            allocationOf[nftId] = newAlloc;
            allAlloc[i].amounts = alloc.amounts;
            allAlloc[i].vestingPeriods = alloc.vestingPeriods;
            allAlloc[i].vestingStartTimes = alloc.vestingStartTimes;
            allAlloc[i].claimedSeconds = alloc.claimedSeconds;
            allAlloc[i].claimedFlows = alloc.claimedFlows;
            allAlloc[i].assignedPoolId = alloc.assignedPoolId;
            allAlloc[i].token = alloc.token;
            emit TVSSplit(projectId, isBiddingProject, splitNftId, nftId, allAlloc[i].amounts, allAlloc[i].vestingPeriods, allAlloc[i].vestingStartTimes, allAlloc[i].claimedSeconds);
            unchecked {
                ++i;
            }
        }
        require(sumOfPercentages == BASIS_POINT, Percentages_Do_Not_Add_Up_To_One_Hundred());
        return (splitNftId, newNftIds);
    }

    /// @notice 
    /// @param allocation base allocation of the TVS to split
    /// @param percentage split percentage for this new TVS
    /// @param nbOfFlows number of token flows in the TVS to split
    function _computeSplitArrays(
        Allocation storage allocation,
        uint256 percentage,
        uint256 nbOfFlows
    )
        internal
        view
        returns (
            Allocation memory alloc
        )
    {
        uint256[] memory baseAmounts = allocation.amounts;
        uint256[] memory baseVestings = allocation.vestingPeriods;
        uint256[] memory baseVestingStartTimes = allocation.vestingStartTimes;
        uint256[] memory baseClaimed = allocation.claimedSeconds;
        bool[] memory baseClaimedFlows = allocation.claimedFlows;
        alloc.assignedPoolId = allocation.assignedPoolId;
        alloc.token = allocation.token;
        for (uint256 j; j < nbOfFlows;) {
            alloc.amounts[j] = (baseAmounts[j] * percentage) / BASIS_POINT;
            alloc.vestingPeriods[j] = baseVestings[j];
            alloc.vestingStartTimes[j] = baseVestingStartTimes[j];
            alloc.claimedSeconds[j] = baseClaimed[j];
            alloc.claimedFlows[j] = baseClaimedFlows[j];
            unchecked {
                ++j;
            }
        }
    }

    /// @notice Writes to an allocation
    /// @param allocation allocation to overwrite
    /// @param alloc allocation that overwrites `allocation`
    function _assignAllocation(
        Allocation storage allocation,
        Allocation memory alloc
    ) internal {
        allocation.amounts = alloc.amounts;
        allocation.vestingPeriods = alloc.vestingPeriods;
        allocation.vestingStartTimes = alloc.vestingStartTimes;
        allocation.claimedSeconds = alloc.claimedSeconds;
        allocation.claimedFlows = alloc.claimedFlows;
        allocation.assignedPoolId = alloc.assignedPoolId;
        allocation.token = alloc.token;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}