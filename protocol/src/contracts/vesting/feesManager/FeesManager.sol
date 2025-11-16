// SPDX-License-Identifier: MIT
pragma solidity =0.8.29;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

abstract contract FeesManager is OwnableUpgradeable {

    /// @notice Fee that a user pays when placing a bid
    uint256 public bidFee;

    /// @notice Fee that a user pays when updating a bid
    uint256 public updateBidFee;

    /// @notice Fee percentage in basis point that a user pays when splitting a TVS
    uint256 public splitFeeRate;

    /// @notice Fee percentage in basis point that a user pays when merging TVSs
    uint256 public mergeFeeRate;

    /// @notice BasisPoint
    uint256 constant public BASIS_POINT = 10_000;

    /// @notice Emitted when the owner updates the bidFee
    /// @param oldBidFee old bidFee
    /// @param newBidFee new bidFee
    event bidFeeUpdated(uint256 oldBidFee, uint256 newBidFee);

    /// @notice Emitted when the owner updates the updateBidFee
    /// @param oldUpdateBidFee old updateBidFee
    /// @param newUpdateBidFee new updateBidFee
    event updateBidFeeUpdated(uint256 oldUpdateBidFee, uint256 newUpdateBidFee);

    /// @notice Emitted when the owner updates the splitFee
    /// @param oldSplitFee old splitFee
    /// @param newSplitFee new splitFee
    event splitFeeRateUpdated(uint256 oldSplitFee, uint256 newSplitFee);

    /// @notice Emitted when the owner updates the mergeFee
    /// @param oldMergeFee old mergeFee
    /// @param newMergeFee new mergeFee
    event mergeFeeRateUpdated(uint256 oldMergeFee, uint256 newMergeFee);

    function __FeesManager_init() internal onlyInitializing {
    }

    /// @notice Sets multiple fee parameters in a single transaction.
    /// @dev Calls internal setters for bid, bid update, split, and merge fees.
    /// @param _bidFee The new bid fee value to set.
    /// @param _bidUpdateFee The new bid update fee value to set.
    /// @param _splitFeeRate The new split fee value to set.
    /// @param _mergeFeeRate The new merge fee value to set.
    function setFees(
        uint256 _bidFee,
        uint256 _bidUpdateFee,
        uint256 _splitFeeRate,
        uint256 _mergeFeeRate
    ) public onlyOwner {
        _setBidFee(_bidFee);
        _setUpdateBidFee(_bidUpdateFee);
        _setSplitFeeRate(_splitFeeRate);
        _setMergeFeeRate(_mergeFeeRate);
    }

    /*
     * @notice Updates the bid fee.
     * @param bidFee The new bid fee value.
     * @dev Restricted to contract owner.
     *
     * Emits a {bidFeeUpdated} event.
     */
    function setBidFee(uint256 _bidFee) public onlyOwner {
        _setBidFee(_bidFee);
    }

    /**
     * @notice Internal function to update the bid fee.
     * @param newBidFee The new bid fee value.
     *
     * Emits a {bidFeeUpdated} event.
     *
     * Requirements:
     * - `newBidFee` must satisfy internal minimum and maximum constraints.
     */
    function _setBidFee(uint256 newBidFee) internal {
        // Example placeholder limits
        require(newBidFee < 100001, "Bid fee too high");

        uint256 oldBidFee = bidFee;
        bidFee = newBidFee;

        emit bidFeeUpdated(oldBidFee, newBidFee);
    }

    /**
     * @notice Updates the bid update fee.
     * @param _updateBidFee The new bid update fee value.
     *
     * Emits an {updateBidFeeUpdated} event.
     */
    function setUpdateBidFee(uint256 _updateBidFee) public onlyOwner {
        _setUpdateBidFee(_updateBidFee);
    }

    /**
     * @notice Internal function to update the bid update fee.
     * @param newUpdateBidFee The new bid update fee value.
     *
     * Emits an {updateBidFeeUpdated} event.
     */
    function _setUpdateBidFee(uint256 newUpdateBidFee) internal {
        require(newUpdateBidFee < 100001, "Bid update fee too high");

        uint256 oldUpdateBidFee = updateBidFee;
        updateBidFee = newUpdateBidFee;

        emit updateBidFeeUpdated(oldUpdateBidFee, newUpdateBidFee);
    }

    /**
     * @notice Updates the split fee.
     * @param _splitFee The new split fee value.
     *
     * Emits a {splitFeeRateUpdated} event.
     */
    function setSplitFeeRate(uint256 _splitFee) public onlyOwner {
        _setSplitFeeRate(_splitFee);
    }

    /**
     * @notice Internal function to update the split fee.
     * @param newSplitFeeRate The new split fee value.
     *
     * Emits a {splitFeeRateUpdated} event.
     */
    function _setSplitFeeRate(uint256 newSplitFeeRate) internal {
        require(newSplitFeeRate < 201, "Split fee too high");

        uint256 oldSplitFeeRate = splitFeeRate;
        splitFeeRate = newSplitFeeRate;

        emit splitFeeRateUpdated(oldSplitFeeRate, newSplitFeeRate);
    }

    /**
     * @notice Updates the merge fee.
     * @param _mergeFeeRate The new merge fee value.
     *
     * Emits a {mergeFeeRateUpdated} event.
     */
    function setMergeFeeRate(uint256 _mergeFeeRate) public onlyOwner {
        _setMergeFeeRate(_mergeFeeRate);
    }

    /**
     * @notice Internal function to update the merge fee.
     * @param newMergeFeeRate The new merge fee value.
     *
     * Emits a {mergeFeeRateUpdated} event.
     */
    function _setMergeFeeRate(uint256 newMergeFeeRate) internal {
        require(newMergeFeeRate < 201, "Merge fee too high");

        uint256 oldMergeFeeRate = mergeFeeRate;
        mergeFeeRate = newMergeFeeRate;

        emit mergeFeeRateUpdated(oldMergeFeeRate, newMergeFeeRate);
    }

    function calculateFeeAndNewAmountForOneTVS(uint256 feeRate, uint256[] memory amounts, uint256 length) public pure returns (uint256 feeAmount, uint256[] memory newAmounts) {
        for (uint256 i; i < length;) {
            feeAmount += calculateFeeAmount(feeRate, amounts[i]);
            newAmounts[i] = amounts[i] - feeAmount;
        }
    }

    function calculateFeeAmount(uint256 feeRate, uint256 amount) public pure returns(uint256 feeAmount) {
        feeAmount = amount * feeRate / BASIS_POINT;
    }

    uint256[50] private __gap;
}