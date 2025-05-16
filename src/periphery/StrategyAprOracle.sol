// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {AprOracleBase} from "@periphery/AprOracle/AprOracleBase.sol";
import {IEVault} from "@euler-interfaces/IEVault.sol";
import {IVaultLens} from "@euler-interfaces/IVaultLens.sol";
import {IRewardToken} from "@euler-interfaces/IRewardToken.sol";
import {IStrategyInterface} from "../interfaces/IStrategyInterface.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Multicall} from "@openzeppelin/contracts/utils/Multicall.sol";
import {IPyth, PythStructs} from "../interfaces/IPythOracle.sol";

// Interface for Chainlink price feeds
interface AggregatorV3Interface {
    function decimals() external view returns (uint8);
    function description() external view returns (string memory);
    function version() external view returns (uint256);
    function getRoundData(
        uint80 _roundId
    )
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
}

/**
 * @title StrategyAprOracle
 * @notice Oracle contract for calculating APR for Euler Compounder Strategies across multiple chains
 * @dev Uses Chainlink and Pyth Network price feeds for USD-denominated APR calculations, supporting various reward tokens
 */
contract StrategyAprOracle is AprOracleBase, Multicall {
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.Bytes32Set;

    /// @notice The Euler Protocol's VaultLens contract for querying vault information
    IVaultLens private immutable VAULT_LENS;

    /// @notice Address of the rEUL (Euler Reward) token
    address public immutable REUL_TOKEN;

    /// @notice Address of the EUL (Euler) token
    address public immutable EUL_TOKEN;

    /// @notice Pyth Oracle contract for alternative price feeds
    IPyth public immutable PYTH_ORACLE;

    /// @notice Token information structure
    struct TokenInfo {
        address priceFeed; // Chainlink price feed address (or zero if using manual price)
        bytes32 pythPriceFeedId; // Pyth price feed ID (or bytes32(0) if not using Pyth)
        uint256 manualPrice; // Manual price in USD (1e18 basis) - used if priceFeed is zero
        uint8 decimals; // Token decimals
    }

    /// @notice Campaign information structure (packed for storage efficiency)
    struct RewardCampaign {
        uint64 startTime; // Campaign start timestamp
        uint64 endTime; // Campaign end timestamp
        uint128 amount; // Total reward amount
    }

    /// @notice Token information mapping
    mapping(address => TokenInfo) public tokenInfo;

    /// @notice Vault => (RewardToken => CampaignData[]) mapping
    /// @dev Supports multiple campaigns per reward token per vault
    mapping(address => mapping(address => EnumerableSet.Bytes32Set))
        private _rewardCampaigns;

    /// @notice Tracking vaults for easier iteration
    EnumerableSet.AddressSet private _trackedVaults;

    /// @notice Tracking reward tokens for easier iteration (per vault)
    mapping(address => EnumerableSet.AddressSet) private _trackedTokens;

    constructor(
        address _vaultLens,
        address _reulToken,
        address _pythOracle,
        address _governance
    ) AprOracleBase("Euler Strategy Apr Oracle", _governance) {
        VAULT_LENS = IVaultLens(_vaultLens);
        REUL_TOKEN = _reulToken;
        EUL_TOKEN = IRewardToken(_reulToken).underlying();
        PYTH_ORACLE = IPyth(_pythOracle);
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
        // Base vault APR
        _apr = eVaultApr(eVault, _delta);
        // Add rewards APR (for the whole vault)
        _apr += rewardUsdApr(eVault, _delta);
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
        if (!_trackedVaults.contains(_eVault)) return 0;

        // Get vault's asset and the USD value of total assets
        address asset = IEVault(_eVault).asset();
        uint256 assetPriceUsd = getTokenUsdPrice(asset);
        if (assetPriceUsd == 0) return 0; // No price data available

        uint256 totalAssetsUsd = (uint256(
            int256(IEVault(_eVault).totalAssets()) + _delta
        ) * assetPriceUsd) / 1e18;
        if (totalAssetsUsd == 0) return 0;

        // Iterate over all reward tokens for this vault
        EnumerableSet.AddressSet storage tokenSet = _trackedTokens[_eVault];
        for (uint256 i = 0; i < tokenSet.length(); i++) {
            address rewardToken = tokenSet.at(i);
            _usdApr += _calculateTokenRewardApr(
                _eVault,
                rewardToken,
                totalAssetsUsd
            );
        }
    }

    /**
     * @notice Helper function to calculate reward APR for a specific token
     * @param _eVault The vault address
     * @param _rewardToken The reward token address
     * @param _totalAssetsUsd Total assets value in USD
     * @return tokenApr The APR contribution from this token's rewards
     */
    function _calculateTokenRewardApr(
        address _eVault,
        address _rewardToken,
        uint256 _totalAssetsUsd
    ) internal view returns (uint256 tokenApr) {
        uint256 rewardTokenPriceUsd = getTokenUsdPrice(_rewardToken);
        if (rewardTokenPriceUsd == 0) return 0; // Skip if no price data

        uint256 currentTime = block.timestamp;

        // Process all campaigns for this token
        EnumerableSet.Bytes32Set storage campaigns = _rewardCampaigns[_eVault][
            _rewardToken
        ];
        for (uint256 j = 0; j < campaigns.length(); j++) {
            bytes32 campaignData = campaigns.at(j);
            tokenApr += _calculateCampaignApr(
                campaignData,
                _rewardToken,
                rewardTokenPriceUsd,
                currentTime,
                _totalAssetsUsd
            );
        }
    }

    /**
     * @notice Helper function to calculate APR for a specific campaign
     * @param _campaignData Encoded campaign data
     * @param _rewardToken The reward token address
     * @param _rewardTokenPriceUsd USD price of the reward token
     * @param _currentTime Current timestamp
     * @param _totalAssetsUsd Total assets value in USD
     * @return campaignApr The APR contribution from this campaign
     */
    function _calculateCampaignApr(
        bytes32 _campaignData,
        address _rewardToken,
        uint256 _rewardTokenPriceUsd,
        uint256 _currentTime,
        uint256 _totalAssetsUsd
    ) internal view returns (uint256 campaignApr) {
        RewardCampaign memory campaign = decodeRewardCampaign(_campaignData);

        // Skip expired or future campaigns
        if (
            campaign.endTime <= _currentTime ||
            campaign.startTime > _currentTime
        ) {
            return 0;
        }

        // Calculate USD reward rate
        uint256 campaignDuration = campaign.endTime - campaign.startTime;
        uint256 rewardPerSecond = uint256(campaign.amount) / campaignDuration;
        uint256 rewardUsdPerSecond = (rewardPerSecond * _rewardTokenPriceUsd) /
            (
                _rewardToken != REUL_TOKEN
                    ? (10 ** tokenInfo[_rewardToken].decimals)
                    : 1e18
            );

        // Calculate annualized rate for this campaign
        return (rewardUsdPerSecond * 365 days * 1e18) / _totalAssetsUsd;
    }

    /**
     * @notice Get the USD price of a token using configured price feed
     * @param _token Address of the token
     * @return price USD price in 1e18 format
     */
    function getTokenUsdPrice(
        address _token
    ) public view returns (uint256 price) {
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

        // Try Chainlink feed first
        if (info.priceFeed != address(0)) {
            price = _getChainlinkPrice(info.priceFeed);
            if (price > 0) return price;
        }

        // If Chainlink fails or isn't available, try Pyth
        if (info.pythPriceFeedId != bytes32(0)) {
            price = _getPythPrice(info.pythPriceFeedId);
            if (price > 0) return price;
        }

        return 0; // No price available from any source
    }

    /**
     * @notice Get price from Chainlink price feed
     * @param _feed Address of the price feed
     * @return price USD price in 1e18 format
     */
    function _getChainlinkPrice(
        address _feed
    ) internal view returns (uint256 price) {
        // Get latest price from Chainlink
        try AggregatorV3Interface(_feed).latestRoundData() returns (
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
            uint8 feedDecimals = _getChainlinkDecimals(_feed);

            if (feedDecimals < 18) {
                price = uint256(answer) * 10 ** (18 - feedDecimals);
            } else if (feedDecimals > 18) {
                price = uint256(answer) / 10 ** (feedDecimals - 18);
            } else {
                price = uint256(answer);
            }
        } catch {
            return 0; // Error accessing price feed
        }

        return price;
    }

    /**
     * @notice Get price from Pyth Network price feed
     * @param _priceId Pyth price feed ID
     * @return price USD price in 1e18 format
     */
    function _getPythPrice(
        bytes32 _priceId
    ) internal view returns (uint256 price) {
        if (_priceId == bytes32(0)) return 0;

        try PYTH_ORACLE.getPriceUnsafe(_priceId) returns (
            PythStructs.Price memory pythPrice
        ) {
            // Check for valid price
            if (pythPrice.price <= 0 || pythPrice.publishTime == 0) {
                return 0; // Invalid price
            }

            // Convert Pyth price to 1e18 format
            // Pyth prices use expo to indicate decimal place, typically negative
            int32 expo = pythPrice.expo;
            uint256 rawPrice;

            // Handle negative prices (shouldn't happen for most assets, but just in case)
            if (pythPrice.price < 0) {
                return 0; // Negative prices not supported for APR calculations
            } else {
                rawPrice = uint256(uint64(pythPrice.price));
            }

            // Adjust to 1e18 format based on exponent
            // If expo is -8, price has 8 decimal places, so multiply by 10^(18-8)
            if (expo < 0) {
                uint32 adjExpo = uint32(-expo);
                if (adjExpo < 18) {
                    price = rawPrice * 10 ** (18 - adjExpo);
                } else if (adjExpo > 18) {
                    price = rawPrice / 10 ** (adjExpo - 18);
                } else {
                    price = rawPrice;
                }
            } else {
                // Positive exponent (unusual but possible)
                price = rawPrice * 10 ** (18 + uint32(expo));
            }

            return price;
        } catch {
            return 0; // Error accessing Pyth price feed
        }
    }

    /**
     * @notice Get decimals from Chainlink price feed
     * @param _feed Address of the price feed
     * @return decimals The number of decimals the feed uses
     */
    function _getChainlinkDecimals(
        address _feed
    ) internal view returns (uint8 decimals) {
        try AggregatorV3Interface(_feed).decimals() returns (uint8 _decimals) {
            return _decimals;
        } catch {
            // Default to 8 if we can't determine (common for Chainlink)
            return 8;
        }
    }

    /**
     * @notice Set token information including price feeds and decimals
     * @param _tokens Array of token addresses
     * @param _tokenInfoArr Array of TokenInfo
     */
    function setTokenInfo(
        address[] calldata _tokens,
        TokenInfo[] calldata _tokenInfoArr
    ) external onlyGovernance {
        require(_tokens.length == _tokenInfoArr.length, "length mismatch");

        for (uint256 i = 0; i < _tokens.length; i++) {
            tokenInfo[_tokens[i]] = _tokenInfoArr[i];
        }
    }

    /**
     * @notice Add new reward campaigns for vaults
     * @param _vaults Array of vault addresses
     * @param _rewardTokens Array of reward token addresses
     * @param _rewardCampaignsArr Array of campaigns
     */
    function addRewardCampaigns(
        address[] calldata _vaults,
        address[] calldata _rewardTokens,
        RewardCampaign[] calldata _rewardCampaignsArr
    ) external onlyGovernance {
        uint256 length = _vaults.length;
        require(
            length == _rewardTokens.length &&
                length == _rewardCampaignsArr.length,
            "length mismatch"
        );

        for (uint256 i = 0; i < length; i++) {
            address vault = _vaults[i];
            address token = _rewardTokens[i];
            RewardCampaign memory campaign = _rewardCampaignsArr[i];

            require(campaign.startTime < campaign.endTime, "invalid timing");
            require(campaign.amount > 0, "zero amount");

            // Add vault and token to tracking sets
            _trackedVaults.add(vault);
            _trackedTokens[vault].add(token);

            // Add campaign to the set
            bytes32 encodedCampaign = encodeRewardCampaign(campaign);
            _rewardCampaigns[vault][token].add(encodedCampaign);
        }
    }

    /**
     * @notice Remove specific campaigns from vaults
     * @param _vaults Array of vault addresses
     * @param _rewardTokens Array of reward token addresses
     * @param _rewardCampaignsArr Array of campaigns to remove
     */
    function removeRewardCampaigns(
        address[] calldata _vaults,
        address[] calldata _rewardTokens,
        RewardCampaign[] calldata _rewardCampaignsArr
    ) external onlyGovernance {
        uint256 length = _vaults.length;
        require(
            length == _rewardTokens.length &&
                length == _rewardCampaignsArr.length,
            "length mismatch"
        );

        for (uint256 i = 0; i < length; i++) {
            address vault = _vaults[i];
            address token = _rewardTokens[i];
            RewardCampaign memory campaign = _rewardCampaignsArr[i];

            // Remove campaign from the set
            bytes32 encodedCampaign = encodeRewardCampaign(campaign);
            _rewardCampaigns[vault][token].remove(encodedCampaign);

            // Clean up if no campaigns left for this token
            if (_rewardCampaigns[vault][token].length() == 0) {
                _trackedTokens[vault].remove(token);

                // Clean up if no tokens left for this vault
                if (_trackedTokens[vault].length() == 0) {
                    _trackedVaults.remove(vault);
                }
            }
        }
    }

    /**
     * @notice Remove expired or stale campaigns from vaults
     * @param _vaults Array of vault addresses to clean up
     */
    function reepStaleCampaigns(
        address[] calldata _vaults
    ) external onlyGovernance {
        uint256 currentTime = block.timestamp;

        for (uint256 i = 0; i < _vaults.length; i++) {
            address vault = _vaults[i];
            if (!_trackedVaults.contains(vault)) continue;

            EnumerableSet.AddressSet storage tokenSet = _trackedTokens[vault];
            address[] memory tokensToCheck = new address[](tokenSet.length());

            // Copy to memory to avoid state modifications during iteration
            for (uint256 j = 0; j < tokenSet.length(); j++) {
                tokensToCheck[j] = tokenSet.at(j);
            }

            // Now process each token
            for (uint256 j = 0; j < tokensToCheck.length; j++) {
                address token = tokensToCheck[j];
                _cleanCampaignsForToken(vault, token, currentTime);
            }
        }
    }

    /**
     * @notice Helper to clean campaigns for a specific vault and token
     * @param vault The vault address
     * @param token The reward token address
     * @param currentTime Current timestamp
     */
    function _cleanCampaignsForToken(
        address vault,
        address token,
        uint256 currentTime
    ) internal {
        EnumerableSet.Bytes32Set storage campaigns = _rewardCampaigns[vault][
            token
        ];
        uint256 length = campaigns.length();

        // Create a memory array to store campaigns that need to be removed
        bytes32[] memory expiredCampaigns = new bytes32[](length);
        uint256 expiredCount = 0;

        // Identify expired campaigns
        for (uint256 i = 0; i < length; i++) {
            bytes32 campaignData = campaigns.at(i);
            // Extract end time from the bytes32 data (bits 128-191)
            uint64 endTime = uint64(uint256(campaignData) >> 128);

            if (currentTime > endTime) {
                expiredCampaigns[expiredCount] = campaignData;
                expiredCount++;
            }
        }

        // Remove expired campaigns
        _removeExpiredCampaigns(vault, token, expiredCampaigns, expiredCount);
    }

    /**
     * @notice Remove expired campaigns and clean up tracking if needed
     * @param vault The vault address
     * @param token The reward token address
     * @param expiredCampaigns Array of expired campaign data
     * @param count Number of expired campaigns
     */
    function _removeExpiredCampaigns(
        address vault,
        address token,
        bytes32[] memory expiredCampaigns,
        uint256 count
    ) internal {
        EnumerableSet.Bytes32Set storage campaigns = _rewardCampaigns[vault][
            token
        ];

        // Remove each expired campaign
        for (uint256 i = 0; i < count; i++) {
            campaigns.remove(expiredCampaigns[i]);
        }

        // Clean up token tracking if no campaigns left
        if (campaigns.length() == 0) {
            _trackedTokens[vault].remove(token);

            // Clean up vault tracking if no tokens left
            if (_trackedTokens[vault].length() == 0) {
                _trackedVaults.remove(vault);
            }
        }
    }

    /**
     * @notice Get the list of tracked vaults
     * @return vaults Array of vault addresses that have active campaigns
     */
    function getTrackedVaults() external view returns (address[] memory) {
        return _trackedVaults.values();
    }

    /**
     * @notice Get all reward tokens for a vault
     * @param _vault The vault address
     * @return tokens Array of reward token addresses
     */
    function getVaultRewardTokens(
        address _vault
    ) external view returns (address[] memory) {
        return _trackedTokens[_vault].values();
    }

    /**
     * @notice Get all campaigns for a specific vault and token
     * @param _vault The vault address
     * @param _rewardToken The reward token address
     * @return Array of reward campaigns
     */
    function getRewardCampaigns(
        address _vault,
        address _rewardToken
    ) external view returns (RewardCampaign[] memory) {
        EnumerableSet.Bytes32Set storage campaignSet = _rewardCampaigns[_vault][
            _rewardToken
        ];
        uint256 length = campaignSet.length();
        RewardCampaign[] memory campaigns = new RewardCampaign[](length);

        for (uint256 i = 0; i < length; i++) {
            bytes32 campaignData = campaignSet.at(i);
            campaigns[i] = decodeRewardCampaign(campaignData);
        }

        return campaigns;
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
        return
            bytes32(
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
