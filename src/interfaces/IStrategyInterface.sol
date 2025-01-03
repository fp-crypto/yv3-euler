// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {IBase4626Compounder} from "@periphery/Bases/4626Compounder/IBase4626Compounder.sol";
import {IUniswapV3Swapper} from "@periphery/swappers/interfaces/IUniswapV3Swapper.sol";

interface IStrategyInterface is IBase4626Compounder, IUniswapV3Swapper {
    /// @notice The Euler reward token contract
    function REUL() external view returns (address);
    /// @notice The EUL token contract
    function EUL() external view returns (address);
    /// @notice The Wrapped Ether contract address
    function WETH() external view returns (address);

    function MERKL_DISTRIBUTOR() external view returns (address);

    /// @notice Sets the minimum amount of EUL required to trigger a swap
    /// @dev Can only be called by management
    /// @param _minEulToSwap Minimum amount of EUL tokens (in wei) needed to execute a swap
    function setMinEulToSwap(uint256 _minEulToSwap) external;

    /// @notice Sets the Uniswap V3 fee tier for EUL to WETH swaps
    /// @dev Can only be called by management
    /// @param _eulToWethSwapFee The fee tier to use (in hundredths of a bip)
    function setEulToWethSwapFee(uint24 _eulToWethSwapFee) external;

    /// @notice Sets the Uniswap V3 fee tier for WETH to asset swaps
    /// @dev Can only be called by management
    /// @param _wethToAssetSwapFee The fee tier to use (in hundredths of a bip)
    function setWethToAssetSwapFee(uint24 _wethToAssetSwapFee) external;
}
