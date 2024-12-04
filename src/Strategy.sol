// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {Base4626Compounder, ERC20, IStrategy, SafeERC20} from "@periphery/Bases/4626Compounder/Base4626Compounder.sol";
import {UniswapV3Swapper} from "@periphery/swappers/UniswapV3Swapper.sol";
import {IRewardToken} from "@euler-interfaces/IRewardToken.sol";

/// @title Euler Compounder Strategy
/// @notice A strategy for compounding Euler rewards into the underlying asset
/// @dev Inherits Base4626Compounder for vault functionality and UniswapV3Swapper for DEX interactions
contract EulerCompounderStrategy is Base4626Compounder, UniswapV3Swapper {
    using SafeERC20 for ERC20;

    /// @notice The Euler reward token contract
    IRewardToken public constant REUL =
        IRewardToken(0xf3e621395fc714B90dA337AA9108771597b4E696);
    /// @notice The EUL token contract
    ERC20 public constant EUL =
        ERC20(0xd9Fcd98c322942075A5C3860693e9f4f03AAE07b);
    /// @notice The Wrapped Ether contract address
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    /// @notice Minimum amount of EUL required to execute a swap (default: 1 EUL)
    uint96 public minEulToSwap = 1e18;

    /// @notice Initializes the Euler compounder strategy
    /// @param _vault Address of the underlying vault
    /// @param _name Name of the strategy token
    /// @param _assetSwapUniFee Uniswap V3 fee tier for asset swaps
    constructor(
        address _vault,
        string memory _name,
        uint24 _assetSwapUniFee
    ) Base4626Compounder(IStrategy(_vault).asset(), _name, _vault) {
        _setUniFees(address(EUL), WETH, 10000);
        if (address(asset) != WETH) {
            _setUniFees(WETH, address(asset), _assetSwapUniFee);
        }
    }

    /// @notice Claims REUL rewards and swaps them for the underlying asset
    /// @dev Overrides the base function to handle Euler-specific reward claiming and swapping
    function _claimAndSellRewards() internal override {
        uint256 _reulBalance = REUL.balanceOf(address(this));
        if (_reulBalance != 0) {
            REUL.withdrawToByLockTimestamps(
                address(this),
                REUL.getLockedAmountsLockTimestamps(address(this)),
                true
            );
        }

        uint256 _eulBalance = EUL.balanceOf(address(this));
        if (_eulBalance >= uint256(minEulToSwap)) {
            _swapFrom(address(EUL), address(asset), _eulBalance, 0);
        }
    }

    /// @notice Sets the minimum amount of EUL required to trigger a swap
    /// @dev Can only be called by management
    /// @param _minEulToSwap Minimum amount of EUL tokens (in wei) needed to execute a swap
    function setMinEulToSwap(uint96 _minEulToSwap) external onlyManagement {
        minEulToSwap = _minEulToSwap;
    }

    /// @notice Sets the Uniswap V3 fee tier for EUL to WETH swaps
    /// @dev Can only be called by management
    /// @param _eulToWethSwapFee The fee tier to use (in hundredths of a bip)
    function setEulToWethSwapFee(
        uint24 _eulToWethSwapFee
    ) external onlyManagement {
        _setUniFees(address(EUL), WETH, _eulToWethSwapFee);
    }

    /// @notice Sets the Uniswap V3 fee tier for WETH to asset swaps
    /// @dev Can only be called by management
    /// @param _wethToAssetSwapFee The fee tier to use (in hundredths of a bip)
    function setWethToAssetSwapFee(
        uint24 _wethToAssetSwapFee
    ) external onlyManagement {
        _setUniFees(WETH, address(asset), _wethToAssetSwapFee);
    }
}
