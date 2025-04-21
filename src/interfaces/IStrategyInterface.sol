// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {IBase4626Compounder} from "@periphery/Bases/4626Compounder/IBase4626Compounder.sol";

interface IStrategyInterface is IBase4626Compounder {
    /// @notice The Euler reward token contract
    function REUL() external view returns (address);
    /// @notice The EUL token contract
    function EUL() external view returns (address);
    /// @notice The Wrapped Native token address
    function WRAPPED_NATIVE() external view returns (address);

    function MERKL_DISTRIBUTOR() external view returns (address);

    /// @notice Flag indicating whether to use auctions for token swaps
    function useAuctions() external view returns (bool);

    /// @notice Address of the auction contract
    function auction() external view returns (address);

    /// @notice Minimum amount of a token required to start an auction
    function minAmountToAuction(address _token) external view returns (uint256);

    /// @notice Sets whether to use auctions for token swaps
    /// @param _useAuctions New value for useAuctions flag
    function setUseAuctions(bool _useAuctions) external;

    /// @notice Sets the auction contract address
    /// @param _auction Address of the auction contract
    function setAuction(address _auction) external;

    /// @notice Sets the minimum amount of a token required to trigger an auction
    /// @param _token Address of the token
    /// @param _minAmountToAuction Minimum amount of tokens needed to start an auction
    function setMinAmountToAuction(address _token, uint256 _minAmountToAuction) external;

    /// @notice Initiates an auction for a given token
    /// @param _from The token to be sold in the auction
    /// @return The available amount for bidding on in the auction
    function kickAuction(address _from) external returns (uint256);

    /// @notice Claims rewards for a given set of users
    /// @param users Recipients of tokens
    /// @param tokens ERC20 tokens being claimed
    /// @param amounts Amounts of tokens to be sent to corresponding users
    /// @param proofs Merkle proofs verifying the claims
    function claim(
        address[] calldata users,
        address[] calldata tokens,
        uint256[] calldata amounts,
        bytes32[][] calldata proofs
    ) external;
}
