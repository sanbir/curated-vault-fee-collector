// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { Checkpoints } from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";
import { IUltraVaultOracle, PriceUpdate } from "uyv2/interfaces/IUltraVaultOracle.sol";
import { IPriceSourceV1 } from "uyv2/legacy/v1/interfaces/IPriceSourceV1.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @title UltraVaultOracle
/// @notice Append-only share-price oracle. Stores each update verbatim and reports the
///         live price as a pure function of time, so identical bytecode prices the same
///         on every chain.
contract UltraVaultOracle is Ownable2Step, IUltraVaultOracle {
    using Checkpoints for Checkpoints.Trace208;

    ///////////////
    // Constants //
    ///////////////

    address public immutable vault;
    address public immutable asset;

    uint256 public constant MIN_VESTING_DURATION = 24 hours;
    uint256 public constant MAX_VESTING_DURATION = 7 days;
    uint8 internal constant PRICE_FEED_DECIMALS = 18;

    /////////////
    // Storage //
    /////////////

    /// @dev Append-only, sorted by `startTimestamp`. Seeded in the constructor, never empty.
    PriceUpdate[] internal _updates;

    /// @dev `startTimestamp => 1-based index into _updates`, for binary-search lookups
    ///      by `historicalSharePrice` / `sharePriceAt`. `currentSharePrice` doesn't use it.
    Checkpoints.Trace208 internal _index;

    /////////////////
    // Constructor //
    /////////////////

    constructor(address _owner, address _vault, uint256 _initialPrice) Ownable(_owner) {
        require(_vault != address(0), ZeroAddress());
        vault = _vault;

        address _asset = IERC4626(vault).asset();
        require(_asset != address(0), ZeroAddress());
        asset = _asset;
        uint8 assetDecimals = IERC20Metadata(_asset).decimals();
        uint8 vaultDecimals = IERC20Metadata(vault).decimals();
        require(assetDecimals == vaultDecimals, DecimalsMismatch());

        _seedInitialPrice(_initialPrice);
    }

    //////////////
    // View Fns //
    //////////////

    /// @notice Current share price in terms of the base asset.
    /// @dev Scans backward from the tail: one step normally, two when a future-dated
    ///      update is queued. Cheap for the hot path called on every vault op.
    function currentSharePrice() public view returns (uint256) {
        return _interpolate(_updates[_findActive(block.timestamp)], block.timestamp);
    }

    /// @inheritdoc IUltraVaultOracle
    /// @dev Binary search over the checkpoint index; for off-chain/occasional lookups.
    function sharePriceAt(uint256 timestamp) public view returns (uint256) {
        uint208 indexPlusOne = _index.upperLookupRecent(uint48(timestamp));
        require(indexPlusOne != 0, NoPriceData());
        return _interpolate(_updates[uint256(indexPlusOne) - 1], timestamp);
    }

    /// @notice Share price at `timestamp`.
    function historicalSharePrice(uint256 timestamp) external view returns (uint256) {
        return sharePriceAt(timestamp);
    }

    /// @inheritdoc IPriceSourceV1
    /// @dev V1 compat shim: only the (vault, asset) pair is supported. Equal decimals
    ///      (enforced in the ctor) collapse the V1 formula to `inAmount * price / 1e18`.
    function getQuote(
        uint256 inAmount,
        address base,
        address quote
    ) external view returns (uint256) {
        require(base == vault, VaultMismatch());
        require(quote == asset, AssetMismatch());
        return inAmount * currentSharePrice() / 1e18;
    }

    /// @inheritdoc IUltraVaultOracle
    function lastUpdate() external view returns (PriceUpdate memory) {
        return _updates[_updates.length - 1];
    }

    /// @inheritdoc IUltraVaultOracle
    function updatesCount() external view returns (uint256) {
        return _updates.length;
    }

    /////////////////////
    // Write Functions //
    /////////////////////

    /// @inheritdoc IUltraVaultOracle
    function applyPriceUpdate(
        uint256 startPrice,
        uint256 targetPrice,
        uint256 vestingDuration,
        uint256 startTimestamp
    ) external onlyOwner {
        require(startPrice != 0 && startPrice <= type(uint88).max, Overflow());
        require(targetPrice != 0 && targetPrice <= type(uint88).max, Overflow());
        require(startTimestamp <= type(uint40).max, Overflow());

        // Monotonic: keeps the array sorted for the read-side searches.
        require(
            startTimestamp >= uint256(_updates[_updates.length - 1].startTimestamp),
            NonMonotonicTimestamp()
        );

        if (vestingDuration != 0) {
            require(
                vestingDuration >= MIN_VESTING_DURATION && vestingDuration <= MAX_VESTING_DURATION,
                InvalidVestingDuration()
            );
            // Up-only; drawdowns must be instant.
            require(targetPrice > startPrice, DrawdownVestingNotAllowed());
        }

        _push(startPrice, targetPrice, vestingDuration, startTimestamp);
    }

    //////////////
    // Internal //
    //////////////

    function _seedInitialPrice(uint256 initialPrice) internal {
        require(initialPrice != 0 && initialPrice <= type(uint88).max, Overflow());
        require(block.timestamp <= type(uint40).max, Overflow());
        _push(initialPrice, initialPrice, 0, block.timestamp);
    }

    /// @dev Append to `_updates` and mirror the position into the checkpoint index
    ///      (1-based so `0` stays the "no data" sentinel). Then emit.
    function _push(
        uint256 startPrice,
        uint256 targetPrice,
        uint256 vestingDuration,
        uint256 startTimestamp
    ) internal {
        _updates.push(PriceUpdate({
            startPrice: uint88(startPrice),
            targetPrice: uint88(targetPrice),
            vestingDuration: uint40(vestingDuration),
            startTimestamp: uint40(startTimestamp)
        }));
        _index.push(uint48(startTimestamp), uint208(_updates.length));
        emit PriceUpdated(startPrice, targetPrice, vestingDuration, startTimestamp);
    }

    /// @dev Index of the update governing `atTime` (latest `startTimestamp <= atTime`),
    ///      scanning from the tail. Reverts `NoPriceData` before the seed.
    function _findActive(uint256 atTime) internal view returns (uint256) {
        uint256 i = _updates.length;
        while (i != 0) {
            unchecked { --i; }
            if (uint256(_updates[i].startTimestamp) <= atTime) {
                return i;
            }
        }
        revert NoPriceData();
    }

    function _interpolate(PriceUpdate memory u, uint256 atTime) internal pure returns (uint256) {
        if (u.vestingDuration == 0) {
            return uint256(u.targetPrice);
        }
        if (atTime <= uint256(u.startTimestamp)) {
            return uint256(u.startPrice);
        }
        uint256 endsAt = uint256(u.startTimestamp) + uint256(u.vestingDuration);
        if (atTime >= endsAt) {
            return uint256(u.targetPrice);
        }
        uint256 diff = uint256(u.targetPrice) - uint256(u.startPrice);
        uint256 elapsed = atTime - uint256(u.startTimestamp);
        return uint256(u.startPrice) + (diff * elapsed) / uint256(u.vestingDuration);
    }
}
