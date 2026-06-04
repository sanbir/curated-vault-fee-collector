// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { FixedPointMathLib } from "src/utils/FixedPointMathLib.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { IUltraVaultOracle, Price } from "src/interfaces/IUltraVaultOracle.sol";
import { IOwnable } from "src/interfaces/IOwnable.sol";
import { IERC20Supply } from "src/interfaces/IERC20Supply.sol";
import { IPausable } from "src/interfaces/IPausable.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @notice Price update struct
struct PriceUpdate {
    // The vault to update the price for
    address vault;
    // The asset to update the price for (the asset the vault is denominated in)
    address asset;
    // The share value in assets
    uint256 shareValueInAssets;
}

/// @notice Safety limits for price updates
struct Limit {
    // Maximum allowed price jump from one update to the next (1e18 = 100%)
    uint256 jump;
    // Maximum allowed drawdown from the highwaterMark (1e18 = 100%)
    uint256 drawdown;
}

/// @title VaultPriceManager
/// @notice Contract managing vault price updates with limits
/// @dev Has built in safety mechanisms to pause vault upon sudden moves
contract VaultPriceManager is Ownable2Step {
    using FixedPointMathLib for uint256;

    ////////////
    // Events //
    ////////////

    event VaultAdded(address indexed vault);
    event OracleUpdated(address indexed oldOracle, address indexed newOracle);
    event LimitsUpdated(address indexed vault, Limit oldLimit, Limit newLimit);
    event AdminUpdated(address indexed vault, address indexed admin, bool isAdmin);

    ////////////
    // Errors //
    ////////////

    error ZeroOracleAddress();
    error CannotAddNonEmptyVault();
    error InputLengthMismatch();
    error NotAdminOrOwner();
    error InvalidLimit();

    ///////////////
    // Constants //
    ///////////////

    uint256 internal constant SCALE = 1e18;
    uint256 public constant MAX_JUMP_LIMIT = SCALE;
    uint256 public constant MAX_DRAWDOWN_LIMIT = SCALE;

    /////////////
    // Storage //
    /////////////

    IUltraVaultOracle public oracle;
    mapping(address => uint256) public highwaterMarks; // vault => highwaterMark
    mapping(address => Limit) public limits; // vault => Limit
    mapping(address => mapping(address => bool)) public isAdmin; // vault => admin => isAdmin

    /////////////////
    // Constructor //
    /////////////////

    /// @notice Initialize controller with oracle and owner
    /// @param _oracle Oracle contract address
    /// @param _owner Owner address
    constructor(address _oracle, address _owner) Ownable(_owner) {
        require(_oracle != address(0), ZeroOracleAddress());
        oracle = IUltraVaultOracle(_oracle);
    }

    //////////////////
    // Oracle Logic //
    //////////////////

    /// @notice Add vault to controller
    /// @param vault Vault address to add
    /// @dev Initializes price to 1e18 (1:1)
    /// @dev Must be called before vault receives deposits
    function addVault(address vault) external onlyOwner {
        // Ensure vault is empty
        require(IERC20Supply(vault).totalSupply() == 0, CannotAddNonEmptyVault());

        uint256 initialPrice = SCALE;
        highwaterMarks[vault] = initialPrice;
        oracle.setPrice(vault, address(IERC4626(vault).asset()), initialPrice);

        emit VaultAdded(vault);
    }

    /// @notice Update vault price and highwaterMark
    /// @param priceUpdate Price update data
    /// @dev Pauses vault on large price jumps or drawdowns
    function updatePriceInstantly(PriceUpdate calldata priceUpdate) external {
        _updatePriceInstantly(priceUpdate);
    }

    /// @notice Update prices for multiple vaults
    /// @param priceUpdates Array of price updates
    function updatePricesInstantly(PriceUpdate[] calldata priceUpdates) external {
        for (uint256 i; i < priceUpdates.length; i++) {
            _updatePriceInstantly(priceUpdates[i]);
        }
    }

    /// @notice Internal price update function
    function _updatePriceInstantly(
        PriceUpdate calldata priceUpdate
    ) internal onlyAdminOrOwner(priceUpdate.vault) {
        _checkSuddenMovements(priceUpdate);

        oracle.setPrice(
            priceUpdate.vault,
            priceUpdate.asset,
            priceUpdate.shareValueInAssets
        );
    }

    /// @notice Update vault price gradually over multiple blocks
    /// @param priceUpdate Price update data
    /// @param duration Vesting duration
    /// @dev Pauses vault on large price jumps
    function updatePriceWithVesting(
        PriceUpdate calldata priceUpdate,
        uint256 duration
    ) external {
        _updatePriceWithVesting(priceUpdate, duration);
    }

    /// @notice Update prices for multiple vaults gradually
    /// @param priceUpdates Array of price updates
    /// @param durations Array of vesting durations
    function updatePricesWithVesting(
        PriceUpdate[] calldata priceUpdates,
        uint256[] calldata durations
    ) external {
        require(priceUpdates.length == durations.length, InputLengthMismatch());

        for (uint256 i; i < priceUpdates.length; i++) {
            _updatePriceWithVesting(
                priceUpdates[i],
                durations[i]
            );
        }
    }

    /// @notice Internal gradual price update function
    function _updatePriceWithVesting(
        PriceUpdate calldata priceUpdate,
        uint256 duration
    ) internal onlyAdminOrOwner(priceUpdate.vault) {
        _checkSuddenMovements(priceUpdate);
        oracle.scheduleLinearPriceUpdate(
            priceUpdate.vault,
            priceUpdate.asset,
            priceUpdate.shareValueInAssets,
            duration
        );
    }

    /// @notice Check price update for sudden price swings and update highwatermark
    function _checkSuddenMovements(
        PriceUpdate calldata priceUpdate
    ) internal {
        uint256 lastPrice = oracle.getCurrentPrice(
            priceUpdate.vault,
            priceUpdate.asset
        );
        uint256 highwaterMark = highwaterMarks[priceUpdate.vault];
        Limit memory limit = limits[priceUpdate.vault];
        if (
            // Sudden drop
            priceUpdate.shareValueInAssets <
            lastPrice.mulDivDown(SCALE - limit.jump, SCALE) ||
            // Sudden increase
            priceUpdate.shareValueInAssets >
            lastPrice.mulDivDown(SCALE + limit.jump, SCALE) ||
            // Drawdown check
            priceUpdate.shareValueInAssets <
            highwaterMark.mulDivDown(SCALE - limit.drawdown, SCALE)
        ) {
            IPausable vault = IPausable(priceUpdate.vault);
            if (!vault.paused()) {
                vault.pause();
            }
        } else if (priceUpdate.shareValueInAssets > highwaterMark) {
            highwaterMarks[priceUpdate.vault] = priceUpdate.shareValueInAssets;
        }
    }

    ///////////////////
    // Oracle Update //
    ///////////////////

    /// @notice Set oracle address
    /// @param _newOracle new oracle address
    function setOracle(
        address _newOracle
    ) external onlyOwner {
        if (address(oracle) != _newOracle) {
            emit OracleUpdated(address(oracle), _newOracle);
            oracle = IUltraVaultOracle(_newOracle);
        }
    }

    //////////////////////
    // Admin Role Logic //
    //////////////////////

    /// @notice Set vault admin
    /// @param _vault Vault address
    /// @param _admin Admin address
    /// @param _isAdmin Whether to add or remove admin
    function setAdmin(
        address _vault,
        address _admin,
        bool _isAdmin
    ) external onlyOwner {
        if (isAdmin[_vault][_admin] != _isAdmin) {
            emit AdminUpdated(_vault, _admin, _isAdmin);
            isAdmin[_vault][_admin] = _isAdmin;
        }
    }

    /// @notice Modifier for admin/owner access
    /// @param _vault Vault to check access for
    modifier onlyAdminOrOwner(address _vault) {
        require(msg.sender == owner() || isAdmin[_vault][msg.sender], NotAdminOrOwner());
        _;
    }

    ///////////////////
    // Limits Update //
    ///////////////////

    /// @notice Set vault price limits
    /// @param _vault Vault address
    /// @param _limit Price limits to set
    function setLimits(address _vault, Limit memory _limit) external onlyOwner {
        _setLimits(_vault, _limit);
    }

    /// @notice Set price limits for multiple vaults
    /// @param _vaults Array of vault addresses
    /// @param _limits Array of price limits
    function setLimits(
        address[] memory _vaults,
        Limit[] memory _limits
    ) external onlyOwner {
        require(_vaults.length == _limits.length, InputLengthMismatch());
        for (uint256 i; i < _vaults.length; i++) {
            _setLimits(_vaults[i], _limits[i]);
        }
    }

    function _setLimits(address _vault, Limit memory _limit) internal {
        require(_limit.jump <= MAX_JUMP_LIMIT && _limit.drawdown <= MAX_DRAWDOWN_LIMIT, InvalidLimit());

        Limit memory oldLimit = limits[_vault];
        if (
            _limit.jump != oldLimit.jump || 
            _limit.drawdown != oldLimit.drawdown
        ) {
            emit LimitsUpdated(_vault, oldLimit, _limit);
            limits[_vault] = _limit;
        }
    }

    ///////////
    // Utils //
    ///////////

    /// @notice Claim oracle ownership
    function claimOracleOwnership() external onlyOwner {
        IOwnable(address(oracle)).acceptOwnership();
    }
}
