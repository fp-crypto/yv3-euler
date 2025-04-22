// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {Base4626Compounder, ERC20, IStrategy, SafeERC20} from "@periphery/Bases/4626Compounder/Base4626Compounder.sol";
import {IAuction} from "./interfaces/IAuction.sol";
import {IRewardToken} from "@euler-interfaces/IRewardToken.sol";
import {IMerklDistributor} from "./interfaces/IMerklDistributor.sol";

/// @title Euler Compounder Strategy
/// @notice A strategy for compounding Euler rewards into the underlying asset
/// @dev Inherits Base4626Compounder for vault functionality and automated reward compounding
contract EulerCompounderStrategy is Base4626Compounder {
    using SafeERC20 for ERC20;

    /// @notice The Euler reward token contract (REUL)
    IRewardToken public immutable REUL;

    /// @notice The EUL token contract (underlying of REUL)
    ERC20 public immutable EUL;

    /// @notice The Merkl Distributor contract for claiming rewards
    /// @dev Hardcoded address of the official Merkl distributor
    IMerklDistributor public constant MERKL_DISTRIBUTOR =
        IMerklDistributor(0x3Ef3D8bA38EBe18DB133cEc108f4D14CE00Dd9Ae);

    /// @notice Flag to enable using auctions for token swaps
    /// @dev When true, uses auction-based swapping mechanism instead of Uniswap
    bool public useAuctions;

    /// @notice Address of the auction contract used for token swaps
    /// @dev Used when useAuctions is true
    address public auction;

    /// @notice Minimum token amount required to start an auction, per token
    /// @dev Maps token address to minimum amount threshold
    mapping(address => uint256) public minAmountToAuction;

    /// @notice Initializes the Euler compounder strategy
    /// @param _vault Address of the underlying vault
    /// @param _name Name of the strategy token
    /// @param _reul Address of the REUL token contract
    constructor(
        address _vault,
        string memory _name,
        address _reul
    ) Base4626Compounder(IStrategy(_vault).asset(), _name, _vault) {
        require(_reul != address(0), "!rEUL");
        REUL = IRewardToken(_reul);
        EUL = ERC20(IRewardToken(_reul).underlying());
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
    }

    /// @notice Sets the minimum amount of a token required to trigger an auction
    /// @param _token Address of the token
    /// @param _minAmountToAuction Minimum amount of tokens needed to start an auction
    /// @dev Can only be called by management
    function setMinAmountToAuction(
        address _token,
        uint256 _minAmountToAuction
    ) external onlyManagement {
        minAmountToAuction[_token] = _minAmountToAuction;
    }

    /// @notice Sets whether to use auctions for token swaps
    /// @param _useAuctions New value for useAuctions flag
    /// @dev Can only be called by management
    function setUseAuctions(bool _useAuctions) external onlyManagement {
        useAuctions = _useAuctions;
    }

    /// @notice Sets the auction contract address
    /// @param _auction Address of the auction contract
    /// @dev Can only be called by management
    /// @dev Verifies the auction contract is compatible with this strategy by:
    ///      1. Checking that auction's want matches the strategy's asset
    ///      2. Ensuring the auction contract's receiver is this strategy
    function setAuction(address _auction) external onlyManagement {
        if (_auction != address(0)) {
            require(IAuction(_auction).want() == address(asset), "!want");
            require(
                IAuction(_auction).receiver() == address(this),
                "!receiver"
            );
        }
        auction = _auction;
    }

    /// @notice Initiates an auction for a given token
    /// @dev Can only be called by keepers when auctions are enabled
    /// @param _from The token to be sold in the auction
    /// @return The available amount for bidding on in the auction
    function kickAuction(
        address _from
    ) external virtual onlyKeepers returns (uint256) {
        address _auction = auction;
        require(useAuctions && _auction != address(0), "!auction");
        return _kickAuction(_auction, _from);
    }

    /// @notice Internal function to initiate an auction for reward tokens
    /// @dev Transfers tokens to the auction contract and starts the auction process.
    ///      Security features:
    ///      1. Prevents auctioning the strategy's underlying asset or vault tokens
    ///      2. Transfers all available balance of the token to the auction contract
    ///      3. Relies on the auction contract to properly handle the kicked auction
    ///      4. The auction contract has already been validated in setAuction()
    /// @param _auction The contract running the auction
    /// @param _from The token to be sold in the auction (e.g., EUL or WETH)
    /// @return The available amount for bidding on in the auction
    function _kickAuction(
        address _auction,
        address _from
    ) internal virtual returns (uint256) {
        require(_from != address(asset) && _from != address(vault), "!kick");
        uint256 _balance = ERC20(_from).balanceOf(address(this));
        require(_balance >= minAmountToAuction[_from], "!min");
        ERC20(_from).safeTransfer(_auction, _balance);
        return IAuction(_auction).kick(_from);
    }

    /// @notice Claims rewards for a given set of users (forwards to merkl distributor)
    /// @dev Anyone may call this function for anyone else, funds go to destination regardless, it's just a question of
    ///      who provides the proof and pays the gas: `msg.sender` is used only for addresses that require a trusted operator
    /// @param users Recipients of tokens
    /// @param tokens ERC20 tokens being claimed
    /// @param amounts Amounts of tokens that will be sent to the corresponding users
    /// @param proofs Array of Merkle proofs verifying the claims
    function claim(
        address[] calldata users,
        address[] calldata tokens,
        uint256[] calldata amounts,
        bytes32[][] calldata proofs
    ) external {
        MERKL_DISTRIBUTOR.claim(users, tokens, amounts, proofs);
    }
}
