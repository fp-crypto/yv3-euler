// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {AprOracleBase} from "@periphery/AprOracle/AprOracleBase.sol";
import {IEVault} from "@euler-interfaces/IEVault.sol";
import {IVaultLens} from "@euler-interfaces/IVaultLens.sol";
import {IStrategyInterface as IEulerCompounderStrategy} from "../interfaces/IStrategyInterface.sol";
import {UniswapV3SwapSimulator, ISwapRouter} from "../libraries/UniswapV3SwapSimulator.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Multicall} from "@openzeppelin/contracts/utils/Multicall.sol";

contract EulerVaultAprOracle is AprOracleBase, Multicall {
    using EnumerableSet for EnumerableSet.Bytes32Set;

    IVaultLens public constant VAULT_LENS =
        IVaultLens(0xE4044D26C879f58Acc97f27db04c1686fa9ED29E);
    address public constant UNISWAP_V3_ROUTER =
        0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address public constant EUL = 0xd9Fcd98c322942075A5C3860693e9f4f03AAE07b;
    /// @notice The Wrapped Ether contract address
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    struct MerklCampaign {
        uint64 startTime;
        uint64 endTime;
        uint128 amount;
    }

    mapping(address => EnumerableSet.Bytes32Set) private _merklCampaigns;

    constructor() AprOracleBase("Euler Vault Apr Oracle", msg.sender) {}

    /**
     * @notice Will return the expected APR of a Euler Vault post a supply change.
     * @param _strategy The euler compounder strategy to get the apr for.
     * @param _delta The difference in supply.
     * @return _apr The expected apr for the vault represented as 1e18.
     */
    function aprAfterDebtChange(
        address _strategy,
        int256 _delta
    ) external view override returns (uint256 _apr) {
        IEulerCompounderStrategy _eulerStrategy = IEulerCompounderStrategy(
            _strategy
        );
        IEVault _eVault = IEVault(_eulerStrategy.vault());

        uint256[] memory _cash = new uint256[](1);
        _cash[0] = _eVault.cash();
        require(int256(_cash[0]) >= -_delta, "delta too big"); // dev: _delta too big
        _cash[0] = uint256(int256(_cash[0]) + _delta);

        uint256[] memory _borrows = new uint256[](1);
        _borrows[0] = _eVault.totalBorrows();

        IVaultLens.VaultInterestRateModelInfo memory _info = VAULT_LENS
            .getVaultInterestRateModelInfo(address(_eVault), _cash, _borrows);

        _apr = _info.interestRateInfo[0].supplyAPY / 1e9;

        uint256 _eulPerWeek = (reulPerSecond(address(_eVault)) * 7 days) / 5; // rEUL vests 20% immediately, thus divide by 5
        if (_eulPerWeek == 0) return _apr;

        uint256 _eVaultShare = (_eVault.balanceOf(address(_eulerStrategy)) *
            1e18) / (_eVault.totalSupply());

        address _asset = _eulerStrategy.asset();

        _apr +=
            ((eulInAsset(
                (_eulPerWeek * _eVaultShare) / 1e18,
                _asset,
                _eulerStrategy.uniFees(EUL, WETH),
                _asset == WETH ? 0 : _eulerStrategy.uniFees(WETH, _asset)
            ) * 52) * 1e18) /
            _eulerStrategy.totalAssets();
    }

    function merklCampaigns(
        address _eVault
    ) public view returns (MerklCampaign[] memory _campaigns) {
        EnumerableSet.Bytes32Set storage _values = _merklCampaigns[_eVault];
        _campaigns = new MerklCampaign[](_values.length());

        for (uint256 i; i < _campaigns.length; ++i) {
            _campaigns[i] = campaignFromBytes32(_values.at(i));
        }
    }

    function reulPerSecond(
        address _eVault
    ) public view returns (uint256 _reulPerSecond) {
        EnumerableSet.Bytes32Set storage _campaigns = _merklCampaigns[_eVault];
        MerklCampaign memory _campaign;
        for (uint256 i; i < _campaigns.length(); ++i) {
            _campaign = campaignFromBytes32(_campaigns.at(i));
            if (
                _campaign.startTime > block.timestamp ||
                _campaign.endTime <= block.timestamp
            ) continue;

            _reulPerSecond +=
                uint256(_campaign.amount) /
                uint256(_campaign.endTime - _campaign.startTime);
        }
    }

    function addCampaigns(
        address[] calldata _targets,
        MerklCampaign[] calldata _campaigns
    ) external onlyGovernance {
        require(_targets.length == _campaigns.length);

        for (uint256 i; i < _targets.length; ++i) {
            MerklCampaign memory _campaign = _campaigns[i];
            require(_campaign.startTime < _campaign.endTime);

            _merklCampaigns[_targets[i]].add(campaignToBytes32(_campaign));
        }
    }

    function reepStaleCampaigns(
        address[] calldata _targets
    ) external onlyGovernance {
        bytes32[] memory _values;
        MerklCampaign memory _campaign;
        for (uint256 i; i < _targets.length; ++i) {
            _values = _merklCampaigns[_targets[i]].values();
            for (uint256 j; j < _values.length; ++j) {
                bytes32 value = _values[j];
                _campaign = campaignFromBytes32(value);
                if (block.timestamp > _campaign.endTime) {
                    _merklCampaigns[_targets[i]].remove(value);
                }
            }
        }
    }

    function eulInAsset(
        uint256 _eulAmount,
        address _asset,
        uint24 _eulWethFee,
        uint24 _wethAssetFee
    ) private view returns (uint256 _assetAmount) {
        if (_eulAmount == 0) {
            return 0;
        }

        uint256 _wethAmount = UniswapV3SwapSimulator.simulateExactInputSingle(
            ISwapRouter(UNISWAP_V3_ROUTER),
            ISwapRouter.ExactInputSingleParams({
                tokenIn: EUL,
                tokenOut: WETH,
                fee: _eulWethFee,
                recipient: address(0),
                deadline: block.timestamp,
                amountIn: _eulAmount,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );

        if (_wethAssetFee == 0) return _wethAmount;

        _assetAmount = UniswapV3SwapSimulator.simulateExactInputSingle(
            ISwapRouter(UNISWAP_V3_ROUTER),
            ISwapRouter.ExactInputSingleParams({
                tokenIn: WETH,
                tokenOut: _asset,
                fee: _wethAssetFee,
                recipient: address(0),
                deadline: block.timestamp,
                amountIn: _wethAmount,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );
    }

    /// @notice Convert MerklCampaign struct to bytes32
    /// @param campaign The MerklCampaign struct to convert
    /// @return result Packed bytes32 representation of the campaign
    function campaignToBytes32(
        MerklCampaign memory campaign
    ) internal pure returns (bytes32 result) {
        // Packed conversion: startTime (64 bits) | endTime (64 bits) | amount (128 bits)
        assembly {
            result := or(
                or(
                    shl(192, mload(campaign)), // startTime at most significant bits
                    shl(128, mload(add(campaign, 0x20))) // endTime next
                ),
                mload(add(campaign, 0x40)) // amount at least significant bits
            )
        }
    }

    /// @notice Convert bytes32 back to MerklCampaign struct
    /// @param packed The bytes32 to convert back to a struct
    /// @return campaign Unpacked MerklCampaign struct
    function campaignFromBytes32(
        bytes32 packed
    ) internal pure returns (MerklCampaign memory campaign) {
        campaign = MerklCampaign({
            startTime: uint64(bytes8(packed << 0)),
            endTime: uint64(bytes8(packed << 64)),
            amount: uint128(uint256(packed))
        });
    }
}
