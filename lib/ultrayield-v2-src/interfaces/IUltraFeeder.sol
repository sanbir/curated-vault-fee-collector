// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0;

import { IBaseVault, IBaseVaultErrors, IBaseVaultEvents } from "uyv2/interfaces/IBaseVault.sol";
import { IUltraVault } from "uyv2/interfaces/IUltraVault.sol";

interface IUltraFeederErrors {
    error ZeroMainVaultAddress();
    error AssetAddressesMismatch();
    error AssetNumberMismatch();
    error ShareNumberMismatch();
}

interface IUltraFeeder is IBaseVault, IUltraFeederErrors {
    /// @notice Get the main vault address
    function mainVault() external view returns (IUltraVault);
}
