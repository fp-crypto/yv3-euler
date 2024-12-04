// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {Base4626Compounder, ERC20, IStrategy, SafeERC20} from "@periphery/Bases/4626Compounder/Base4626Compounder.sol";
import {UniswapV3Swapper} from "@periphery/swappers/UniswapV3Swapper.sol";
import {IRewardToken} from "@euler-interfaces/IRewardToken.sol";

contract EulerCompounderStrategy is Base4626Compounder, UniswapV3Swapper {
    using SafeERC20 for ERC20;

    IRewardToken public constant REUL =
        IRewardToken(0xf3e621395fc714B90dA337AA9108771597b4E696);
    ERC20 public constant EUL =
        ERC20(0xd9Fcd98c322942075A5C3860693e9f4f03AAE07b);
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    uint96 public minEulToSwap = 1e18;

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

    function setMinEulToSwap(uint96 _minEulToSwap) external onlyManagement {
        minEulToSwap = _minEulToSwap;
    }

    function setEulToWethSwapFee(
        uint24 _eulToWethSwapFee
    ) external onlyManagement {
        _setUniFees(address(EUL), WETH, _eulToWethSwapFee);
    }

    function setWethToAssetSwapFee(
        uint24 _wethToAssetSwapFee
    ) external onlyManagement {
        _setUniFees(WETH, address(asset), _wethToAssetSwapFee);
    }
}
