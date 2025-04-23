// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {AprOracleBase} from "@periphery/AprOracle/AprOracleBase.sol";
import {IEVault} from "@euler-interfaces/IEVault.sol";
import {IVaultLens} from "@euler-interfaces/IVaultLens.sol";
import {IRewardToken} from "@euler-interfaces/IRewardToken.sol";
import {IStrategyInterface} from "../interfaces/IStrategyInterface.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {EnumerableMap} from "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";
import {Multicall} from "@openzeppelin/contracts/utils/Multicall.sol";

// Interface for Chainlink price feeds
interface AggregatorV3Interface {
    function decimals() external view returns (uint8);
    function description() external view returns (string memory);
    function version() external view returns (uint256);
    function getRoundData(uint80 _roundId) external view returns (
        uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound
    );
    function latestRoundData() external view returns (
        uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound
    );
}

/**
 * @title StrategyAprOracle
 * @notice Oracle contract for calculating APR for Euler Compounder Strategies across multiple chains
 * @dev Uses Chainlink price feeds for USD-denominated APR calculations, supporting various reward tokens
 */
contract EulerCompounderStrategyAprOracle is AprOracleBase, Multicall {
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableMap for EnumerableMap.AddressToBytes32Map;

    /// @notice The Euler Protocol's VaultLens contract for querying vault information
    IVaultLens private immutable VAULT_LENS;
    
    /// @notice Address of the rEUL (Euler Reward) token
    address public immutable REUL_TOKEN;
    
    /// @notice Address of the EUL (Euler) token
    address public immutable EUL_TOKEN;

    /// @notice Token information structure
    struct TokenInfo {
        address priceFeed;      // Chainlink price feed address (or zero if using manual price)
        uint256 manualPrice;    // Manual price in USD (1e18 basis) - used if priceFeed is zero
        uint8 decimals;         // Token decimals
    }

    /// @notice Campaign information structure (packed for storage efficiency)
    struct RewardCampaign {
        uint64 startTime;       // Campaign start timestamp
        uint64 endTime;         // Campaign end timestamp
        uint128 amount;         // Total reward amount
    }

    /// @notice Token information mapping
    mapping(address => TokenInfo) public tokenInfo;

    /// @notice Vault => (RewardToken => CampaignData) mapping
    /// @dev Using EnumerableMap allows iteration over all reward tokens for a vault
    mapping(address => EnumerableMap.AddressToBytes32Map) private _rewardCampaigns;
    
    /// @notice Tracking vaults for easier iteration
    EnumerableSet.AddressSet private _trackedVaults;

    constructor(
        address _vaultLens,
        address _reulToken,
        address _governance
    ) AprOracleBase("Euler Strategy Apr Oracle", _governance) {
        VAULT_LENS = IVaultLens(_vaultLens);
        REUL_TOKEN = _reulToken;
        EUL_TOKEN = IRewardToken(_reulToken).underlying();
    }

    /**
     * @notice Will return the expected APR of a strategy post a supply change
     * @param _strategy The Euler compounder strategy to get the apr for
     * @param _delta The difference in supply
     * @return _apr The expected apr for the vault represented as 1e18
     */
    function aprAfterDebtChange(
        address _strategy,
        int256 _delta
    ) external view override returns (uint256 _apr) {
        IStrategyInterface strategy = IStrategyInterface(_strategy);
        address eVault = strategy.vault();
        address asset = strategy.asset();

        // Base vault APR
        _apr = eVaultApr(eVault, _delta);
        
        // Add rewards APR
        uint256 rewardUsdApr = rewardUsdApr(eVault, _delta);
        
        // Convert USD APR to asset APR if we have price info for the asset
        if (rewardUsdApr > 0) {
            uint256 assetPriceUsd = getTokenUsdPrice(asset);
            if (assetPriceUsd > 0) {
                _apr += (rewardUsdApr * 1e18) / assetPriceUsd;
            }
        }
    }

    /**
     * @notice Calculate the base APR for an Euler Vault
     * @param _eVault The euler vault address
     * @param _delta The difference in supply
     * @return _apr The base APR for the vault represented as 1e18
     */
    function eVaultApr(
        address _eVault,
        int256 _delta
    ) public view virtual returns (uint256 _apr) {
        uint256[] memory _cash = new uint256[](1);
        _cash[0] = IEVault(_eVault).cash();
        require(int256(_cash[0]) >= -_delta, "delta too big");
        _cash[0] = uint256(int256(_cash[0]) + _delta);

        uint256[] memory _borrows = new uint256[](1);
        _borrows[0] = IEVault(_eVault).totalBorrows();

        IVaultLens.VaultInterestRateModelInfo memory _info = VAULT_LENS
            .getVaultInterestRateModelInfo(_eVault, _cash, _borrows);

        _apr = _info.interestRateInfo[0].supplyAPY / 1e9;
    }

    /**
     * @notice Calculate the USD-denominated reward APR from all active campaigns
     * @param _eVault The euler vault address
     * @param _delta The difference in supply
     * @return _usdApr The reward APR in USD terms (1e18 basis)
     */
    function rewardUsdApr(
        address _eVault,
        int256 _delta
    ) public view returns (uint256 _usdApr) {
        EnumerableMap.AddressToBytes32Map storage campaigns = _rewardCampaigns[_eVault];
        if (campaigns.length() == 0) return 0;

        // Get vault's asset and the USD value of total assets
        address asset = IEVault(_eVault).asset();
        uint256 assetPriceUsd = getTokenUsdPrice(asset);
        if (assetPriceUsd == 0) return 0; // No price data available
        
        uint256 totalAssetsUsd = uint256(int256(IEVault(_eVault).totalAssets()) + _delta) * assetPriceUsd / 1e18;
        if (totalAssetsUsd == 0) return 0;

        // Iterate over all reward tokens for this vault
        for (uint256 i = 0; i < campaigns.length(); i++) {
            (address rewardToken, bytes32 campaignData) = campaigns.at(i);
            RewardCampaign memory campaign = decodeRewardCampaign(campaignData);
            
            // Skip expired or future campaigns
            if (campaign.endTime <= block.timestamp || campaign.startTime > block.timestamp) {
                continue;
            }

            // Get USD value of rewards per second
            uint256 rewardTokenPriceUsd = getTokenUsdPrice(rewardToken);
            if (rewardTokenPriceUsd == 0) continue; // Skip if no price data
            
            // Calculate USD reward rate
            uint256 campaignDuration = campaign.endTime - campaign.startTime;
            uint256 rewardPerSecond = uint256(campaign.amount) / campaignDuration;
            
            // Adjust for token decimals
            uint8 rewardDecimals = tokenInfo[rewardToken].decimals;
            if (rewardDecimals != 18) {
                rewardPerSecond = rewardPerSecond * 10**(18 - rewardDecimals);
            }
            
            uint256 rewardUsdPerSecond = (rewardPerSecond * rewardTokenPriceUsd) / 1e18;

            // Add annualized rate to total USD APR
            _usdApr += (rewardUsdPerSecond * 365 days * 1e18) / totalAssetsUsd;
        }
    }

    /**
     * @notice Get the USD price of a token using configured price feed
     * @param _token Address of the token
     * @return price USD price in 1e18 format
     */
    function getTokenUsdPrice(address _token) public view returns (uint256 price) {
        // Special case: rEUL to EUL conversion at 5:1 ratio
        if (_token == REUL_TOKEN) {
            // Get EUL price and apply 5:1 conversion
            uint256 eulPrice = getTokenUsdPrice(EUL_TOKEN);
            return eulPrice / 5; // 5 rEUL = 1 EUL
        }
        
        TokenInfo memory info = tokenInfo[_token];
        
        // Check for manual price first
        if (info.manualPrice > 0) {
            return info.manualPrice;
        }
        
        // Check for Chainlink feed
        address feed = info.priceFeed;
        if (feed == address(0)) {
            return 0; // No price available
        }
        
        // Get latest price from Chainlink
        try AggregatorV3Interface(feed).latestRoundData() returns (
            uint80 /* roundID */,
            int256 answer,
            uint256 /* startedAt */,
            uint256 /* updatedAt */,
            uint80 /* answeredInRound */
        ) {
            if (answer <= 0) {
                return 0; // Invalid price
            }
            
            // Convert to 1e18 format based on feed decimals
            uint8 feedDecimals;
            try AggregatorV3Interface(feed).decimals() returns (uint8 decimals) {
                feedDecimals = decimals;
            } catch {
                // Default to 8 if we can't determine (common for Chainlink)
                feedDecimals = 8;
            }
            
            if (feedDecimals < 18) {
                price = uint256(answer) * 10**(18 - feedDecimals);
            } else if (feedDecimals > 18) {
                price = uint256(answer) / 10**(feedDecimals - 18);
            } else {
                price = uint256(answer);
            }
        } catch {
            return 0; // Error accessing price feed
        }
        
        return price;
    }

    /**
     * @notice Set token information including price feeds and decimals
     * @param _tokens Array of token addresses
     * @param _priceFeeds Array of Chainlink price feed addresses (or address(0) for manual pricing)
     * @param _manualPrices Array of USD prices (1e18 format) - used when price feed is address(0)
     * @param _decimals Array of token decimals
     */
    function setTokenInfo(
        address[] calldata _tokens,
        address[] calldata _priceFeeds,
        uint256[] calldata _manualPrices,
        uint8[] calldata _decimals
    ) external onlyGovernance {
        require(
            _tokens.length == _priceFeeds.length &&
            _tokens.length == _manualPrices.length &&
            _tokens.length == _decimals.length,
            "length mismatch"
        );

        for (uint256 i = 0; i < _tokens.length; i++) {
            tokenInfo[_tokens[i]] = TokenInfo({
                priceFeed: _priceFeeds[i],
                manualPrice: _manualPrices[i],
                decimals: _decimals[i]
            });
        }
    }

    /**
     * @notice Add new reward campaigns for vaults
     * @param _vaults Array of vault addresses
     * @param _rewardTokens Array of reward token addresses
     * @param _startTimes Array of campaign start timestamps
     * @param _endTimes Array of campaign end timestamps
     * @param _amounts Array of reward amounts
     */
    function addRewardCampaigns(
        address[] calldata _vaults,
        address[] calldata _rewardTokens,
        uint64[] calldata _startTimes,
        uint64[] calldata _endTimes,
        uint128[] calldata _amounts
    ) external onlyGovernance {
        uint256 length = _vaults.length;
        require(
            length == _rewardTokens.length && 
            length == _startTimes.length && 
            length == _endTimes.length && 
            length == _amounts.length,
            "length mismatch"
        );

        for (uint256 i = 0; i < length; i++) {
            require(_startTimes[i] < _endTimes[i], "invalid timing");
            require(_amounts[i] > 0, "zero amount");

            RewardCampaign memory campaign = RewardCampaign({
                startTime: _startTimes[i],
                endTime: _endTimes[i],
                amount: _amounts[i]
            });

            // Add vault to tracked vaults if not already
            if (!_trackedVaults.contains(_vaults[i])) {
                _trackedVaults.add(_vaults[i]);
            }

            // Set or update campaign for this vault/token pair
            _rewardCampaigns[_vaults[i]].set(
                _rewardTokens[i],
                encodeRewardCampaign(campaign)
            );
        }
    }

    /**
     * @notice Remove expired or stale campaigns from vaults
     * @param _vaults Array of vault addresses to clean up
     */
    function reepStaleCampaigns(
        address[] calldata _vaults
    ) external onlyGovernance {
        for (uint256 i = 0; i < _vaults.length; i++) {
            address vault = _vaults[i];
            EnumerableMap.AddressToBytes32Map storage campaigns = _rewardCampaigns[vault];
            
            // Use a separate array to track items to remove to avoid modifying while iterating
            address[] memory tokensToRemove = new address[](campaigns.length());
            uint256 removeCount = 0;
            
            for (uint256 j = 0; j < campaigns.length(); j++) {
                (address token, bytes32 campaignData) = campaigns.at(j);
                RewardCampaign memory campaign = decodeRewardCampaign(campaignData);
                
                if (block.timestamp > campaign.endTime) {
                    tokensToRemove[removeCount++] = token;
                }
            }
            
            // Now remove the expired campaigns
            for (uint256 j = 0; j < removeCount; j++) {
                campaigns.remove(tokensToRemove[j]);
            }
            
            // Remove vault from tracked vaults if it has no active campaigns
            if (campaigns.length() == 0 && _trackedVaults.contains(vault)) {
                _trackedVaults.remove(vault);
            }
        }
    }

    /**
     * @notice Get the list of tracked vaults
     * @return vaults Array of vault addresses that have active campaigns
     */
    function getTrackedVaults() external view returns (address[] memory vaults) {
        uint256 count = _trackedVaults.length();
        vaults = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            vaults[i] = _trackedVaults.at(i);
        }
    }

    /**
     * @notice Get all reward tokens for a vault
     * @param _vault The vault address
     * @return tokens Array of reward token addresses
     */
    function getVaultRewardTokens(address _vault) external view returns (address[] memory tokens) {
        EnumerableMap.AddressToBytes32Map storage campaigns = _rewardCampaigns[_vault];
        uint256 count = campaigns.length();
        
        tokens = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            (address token, ) = campaigns.at(i);
            tokens[i] = token;
        }
    }

    /**
     * @notice Get campaign details for a specific vault and token
     * @param _vault The vault address
     * @param _rewardToken The reward token address
     * @return campaign The campaign details
     */
    function getRewardCampaign(
        address _vault,
        address _rewardToken
    ) external view returns (RewardCampaign memory campaign) {
        bytes32 data;
        bool exists;
        (exists, data) = _rewardCampaigns[_vault].tryGet(_rewardToken);
        
        require(exists, "campaign not found");
        return decodeRewardCampaign(data);
    }

    /**
     * @notice Encode RewardCampaign struct into bytes32
     * @param _campaign RewardCampaign struct to encode
     * @return encoded The encoded bytes32
     */
    function encodeRewardCampaign(
        RewardCampaign memory _campaign
    ) internal pure returns (bytes32 encoded) {
        // Pack data into a single bytes32:
        // - startTime: 64 bits (top bits)
        // - endTime: 64 bits
        // - amount: 128 bits (bottom bits)
        return bytes32(
            (uint256(_campaign.startTime) << 192) |
            (uint256(_campaign.endTime) << 128) |
            uint256(_campaign.amount)
        );
    }

    /**
     * @notice Decode bytes32 into RewardCampaign struct
     * @param _encoded Encoded campaign data
     * @return campaign Decoded RewardCampaign struct
     */
    function decodeRewardCampaign(
        bytes32 _encoded
    ) internal pure returns (RewardCampaign memory campaign) {
        uint256 data = uint256(_encoded);
        
        campaign.startTime = uint64(data >> 192);
        campaign.endTime = uint64(data >> 128);
        campaign.amount = uint128(data);
        
        return campaign;
    }
}
