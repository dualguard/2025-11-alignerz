// SPDX-License-Identifier: MIT
pragma solidity =0.8.29;

import {IAlignerzVesting} from "../../interfaces/IAlignerzVesting.sol";
import {IAlignerzNFT} from "../../interfaces/IAlignerzNFT.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
contract A26ZDividendDistributor is Ownable {
    using SafeERC20 for IERC20;

    // TYPE DEF
    /// @notice dividends struct
    struct Dividend {
        uint256 amount; // amount in USD in 1e6
        uint256 claimedSeconds; // seconds claimed
    }

    // STATE VARIABLES
    /// @notice Start time of the vesting period
    uint256 public startTime;

    /// @notice length of the vesting period (usually 3 months)
    uint256 public vestingPeriod;

    /// @notice total value yet to be claimed by TVS holders
    uint256 public totalUnclaimedAmounts;

    /// @notice total stablecoin amount reserved for TVS holders as dividends
    uint256 public stablecoinAmountToDistribute;

    /// @notice vesting interface
    IAlignerzVesting public vesting;

    /// @notice nft interface
    IAlignerzNFT public nft;

    /// @notice stablecoin to be distributed
    IERC20 stablecoin;

    /// @notice token inside the TVS
    IERC20 token;

    /// @notice stablecoin balances allocated to TVS holders (dividends)
    mapping(address => Dividend) dividendsOf;

    /// @notice tracks unclaimed amounts of a TVS
    mapping(uint256 => uint256) unclaimedAmountsIn;

    // EVENTS
    event stablecoinSet(address stablecoin);
    event tokenSet(address stablecoin);
    event startTimeSet(uint256 _startTime);
    event vestingPeriodSet(uint256 _vestingPeriod);
    event amountsSet(uint256 _stablecoinAmountToDistribute, uint256 _totalUnclaimedAmounts);
    event dividendsSet();
    event dividendsClaimed(address user, uint256 amountClaimed);

    // ERRORS
    error Array_Lengths_Must_Match();
    error Zero_Address();
    error Zero_Value();

    /// @notice Initializes the DiamondHandsRewarder contract
    /// @param _vesting Address of the vesting contract
    /// @param _nft Address of the NFT contract
    /// @param _stablecoin Address of the stablecoin used to reward the TVS holders
    /// @param _startTime start time of the vesting period
    /// @param _vestingPeriod length of the vesting period
    constructor(address _vesting, address _nft, address _stablecoin, uint256 _startTime, uint256 _vestingPeriod, address _token) Ownable(msg.sender) {
        require(_vesting != address(0), Zero_Address());
        require(_nft != address(0), Zero_Address());
        require(_stablecoin != address(0), Zero_Address());
        vesting = IAlignerzVesting(_vesting);
        nft = IAlignerzNFT(_nft);
        stablecoin = IERC20(_stablecoin);
        startTime = _startTime;
        vestingPeriod = _vestingPeriod;
        token = IERC20(_token);
    }

    /// @notice allows the owner to change the stablecoin
    /// @param _stablecoin Address of the stablecoin used to reward the TVS holders
    function setStablecoin(address _stablecoin) external onlyOwner {
        stablecoin = IERC20(_stablecoin);
        emit stablecoinSet(_stablecoin);
    }

    /// @notice allows the owner to change the token
    /// @param _token Address of the TVS token
    function setToken(address _token) external onlyOwner {
        token = IERC20(_token);
        emit tokenSet(_token);
    }

    /// @notice allows the owner to set the vesting start time
    /// @param _startTime start time of the vesting period
    function setStartTime(uint256 _startTime) external onlyOwner {
        startTime = _startTime;
        emit startTimeSet(_startTime);
    }

    /// @notice allows the owner to set the length of the vesting period
    /// @param _vestingPeriod length of the vesting period
    function setVestingPeriod(uint256 _vestingPeriod) external onlyOwner {
        vestingPeriod = _vestingPeriod;
        emit vestingPeriodSet(_vestingPeriod);
    }

    /// @notice allows the owner to set the dividends of the TVS holders
    function setUpTheDividends() external onlyOwner {
        _setAmounts();
        _setDividends();
    }

    /// @notice allows the owner to set amounts crucial for the dividend distribution
    function setAmounts() public onlyOwner {
        _setAmounts();
    }

    /// @notice allows the owner to set the dividends for the TVS holders
    function setDividends() external onlyOwner {
        _setDividends();
    }

    /// @notice USD value in 1e18 of all the unclaimed tokens of all the TVS
    function getTotalUnclaimedAmounts() public returns (uint256 _totalUnclaimedAmounts) {
        uint256 len = nft.getTotalMinted();
        for (uint i; i < len;) {
            (, bool isOwned) = safeOwnerOf(i);
            if (isOwned) _totalUnclaimedAmounts += getUnclaimedAmounts(i);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice USD value in 1e18 of all the unclaimed tokens of a TVS
    /// @param nftId NFT Id
    function getUnclaimedAmounts(uint256 nftId) public returns (uint256 amount) {
        if (address(token) == address(vesting.allocationOf(nftId).token)) return 0;
        uint256[] memory amounts = vesting.allocationOf(nftId).amounts;
        uint256[] memory claimedSeconds = vesting.allocationOf(nftId).claimedSeconds;
        uint256[] memory vestingPeriods = vesting.allocationOf(nftId).vestingPeriods;
        bool[] memory claimedFlows = vesting.allocationOf(nftId).claimedFlows;
        uint256 len = vesting.allocationOf(nftId).amounts.length;
        for (uint i; i < len;) {
            if (claimedFlows[i]) continue;
            if (claimedSeconds[i] == 0) {
                amount += amounts[i];
                continue;
            }
            uint256 claimedAmount = claimedSeconds[i] * amounts[i] / vestingPeriods[i];
            uint256 unclaimedAmount = amounts[i] - claimedAmount;
            amount += unclaimedAmount;
            unchecked {
                ++i;
            }
        }
        unclaimedAmountsIn[nftId] = amount;
    }

    /// @notice Get the ownership of a token in a way that it doesn't revert if the NFT was burnt
    /// @param nftId NFT Id
    function safeOwnerOf(uint256 nftId) public view returns (address owner, bool exists) {
        try nft.extOwnerOf(nftId) returns (address _owner) {
            // token exists, return owner and true
            return (_owner, true);
        } catch {
            // call reverted => token does not exist (burned or never minted)
            return (address(0), false);
        }
    }

    /// @notice Allows owner to withdraw stuck tokens
    /// @param tokenAddress Address of the token to withdraw (usdc or usdt)
    /// @param amount Amount of tokens to withdraw
    function withdrawStuckTokens(address tokenAddress, uint256 amount) external onlyOwner {
        require(amount > 0, Zero_Value());
        require(tokenAddress != address(0), Zero_Address());

        IERC20 tokenStuck = IERC20(tokenAddress);
        tokenStuck.safeTransfer(msg.sender, amount);
    }

    /// @notice Allows a TVS holder to claim his dividends
    function claimDividends() external {
        address user = msg.sender;
        uint256 totalAmount = dividendsOf[user].amount;
        uint256 claimedSeconds = dividendsOf[user].claimedSeconds;
        uint256 secondsPassed;
        if (block.timestamp >= vestingPeriod + startTime) {
            secondsPassed = vestingPeriod;
            dividendsOf[user].amount = 0;
            dividendsOf[user].claimedSeconds = 0;
        } else {
            secondsPassed = block.timestamp - startTime;
            dividendsOf[user].claimedSeconds += (secondsPassed - claimedSeconds);
        }
        uint256 claimableSeconds = secondsPassed - claimedSeconds;
        uint256 claimableAmount = totalAmount * claimableSeconds / vestingPeriod;
        stablecoin.safeTransfer(user, claimableAmount);
        emit dividendsClaimed(user, claimableAmount);
    }

    /// @notice Internal logic that allows the owner to set crucial amounts for dividends calculations
    function _setAmounts() internal {
        stablecoinAmountToDistribute = stablecoin.balanceOf(address(this));
        totalUnclaimedAmounts = getTotalUnclaimedAmounts();
        emit amountsSet(stablecoinAmountToDistribute, totalUnclaimedAmounts);
    }

    /// @notice Internal logic that allows the owner to set the dividends for each TVS holder
    function _setDividends() internal {
        uint256 len = nft.getTotalMinted();
        for (uint i; i < len;) {
            (address owner, bool isOwned) = safeOwnerOf(i);
            if (isOwned) dividendsOf[owner].amount += (unclaimedAmountsIn[i] * stablecoinAmountToDistribute / totalUnclaimedAmounts);
            unchecked {
                ++i;
            }
        }
        emit dividendsSet();
    }
}