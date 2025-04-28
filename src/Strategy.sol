// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {Base4626Compounder, ERC20, IStrategy, SafeERC20} from "@periphery/Bases/4626Compounder/Base4626Compounder.sol";
import {IAuction} from "./interfaces/IAuction.sol";
import {IRewardToken} from "@euler-interfaces/IRewardToken.sol";
import {IMerklDistributor} from "./interfaces/IMerklDistributor.sol";
import {EnumerableMap} from "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";

/// @title Euler Compounder Strategy
/// @notice A strategy for compounding Euler rewards into the underlying asset
/// @dev Inherits Base4626Compounder for vault functionality and automated reward compounding
contract EulerCompounderStrategy is Base4626Compounder {
    using SafeERC20 for ERC20;
    using EnumerableMap for EnumerableMap.AddressToUintMap;

    /// @notice The Euler reward token contract (REUL)
    IRewardToken public immutable REUL;

    /// @notice The EUL token contract (underlying of REUL)
    ERC20 public immutable EUL;

    /// @notice The Merkl Distributor contract for claiming rewards
    /// @dev Hardcoded address of the official Merkl distributor
    IMerklDistributor public constant MERKL_DISTRIBUTOR =
        IMerklDistributor(0x3Ef3D8bA38EBe18DB133cEc108f4D14CE00Dd9Ae);

    /// @notice Flag to enable using auctions for token swaps
    /// @dev When true, uses auction-based swapping mechanism for reward tokens
    bool public useAuctions;

    /// @notice Address of the auction contract used for token swaps
    /// @dev Used when useAuctions is true
    /// @dev Must be properly validated with matching want/receiver addresses
    address public auction;

    /// @notice Address of authorized depositor
    /// @dev If this value is set, only the depositor can deposit
    /// @dev if this is set to address(0), anyone can deposit
    address public depositor;

    /// @notice Minimum token amount required to start an auction, per token
    /// @dev Maps token address to minimum amount threshold
    /// @dev Used to prevent dust auctions and control when auctions are triggered
    /// @dev Tokens are only auctioned if their balance exceeds this threshold
    EnumerableMap.AddressToUintMap private _minAmountToAuction;

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

    /// @notice Claims REUL rewards and attempts to kick auctions for registered tokens
    /// @dev Overrides the base function to handle Euler-specific reward claiming and auction initiation
    /// @dev First, withdraws any REUL tokens to convert them to underlying EUL tokens
    /// @dev If auctions are enabled, attempts to kick an auction for each registered token that meets the minimum threshold
    function _claimAndSellRewards() internal override {
        uint256 _reulBalance = REUL.balanceOf(address(this));
        if (_reulBalance != 0) {
            (, uint256 _minEulToAuction) = _minAmountToAuction.tryGet(
                address(EUL)
            );
            // don't claim if it's too little to auction
            if (
                _minEulToAuction == 0 ||
                ((_reulBalance / 5) + EUL.balanceOf(address(this))) >=
                _minEulToAuction
            ) {
                REUL.withdrawToByLockTimestamps(
                    address(this),
                    REUL.getLockedAmountsLockTimestamps(address(this)),
                    true
                );
            }
        }

        if (!useAuctions) return;
        address _auction = auction;
        if (_auction == address(0)) return;
        address _token;
        uint256 _length = _minAmountToAuction.length();
        for (uint256 _i; _i < _length; ++_i) {
            (_token, ) = _minAmountToAuction.at(_i);
            _tryKickAuction(_auction, _token);
        }
    }

    /// @inheritdoc Base4626Compounder
    function availableDepositLimit(
        address _owner
    ) public view override returns (uint256) {
        address _depositor = depositor;
        if (_depositor != address(0) && _depositor != _owner) return 0;
        return super.availableDepositLimit(_owner);
    }

    /// @notice Gets the minimum amount required to trigger an auction for a specific token
    /// @param _token Address of the token to check
    /// @return _amount The minimum amount threshold (returns 0 if token is not registered)
    function minAmountToAuction(
        address _token
    ) external view returns (uint256 _amount) {
        (, _amount) = _minAmountToAuction.tryGet(_token);
    }

    /// @notice Sets the minimum amount of a token required to trigger an auction
    /// @param _token Address of the token to configure the threshold for
    /// @param _tokenMinAmountToAuction Minimum amount of tokens needed to start an auction
    /// @dev Can only be called by management
    /// @dev This sets or updates a token in the mapping of tokens that can be auctioned
    /// @dev Setting a threshold registers the token for automatic auction attempts during harvest
    /// @dev The threshold prevents initiating auctions for small (dust) amounts
    function setMinAmountToAuction(
        address _token,
        uint256 _tokenMinAmountToAuction
    ) external onlyManagement {
        if (_tokenMinAmountToAuction == 0) {
            _minAmountToAuction.remove(_token);
        } else {
            _minAmountToAuction.set(_token, _tokenMinAmountToAuction);
        }
    }

    /// @notice Sets whether to use auctions for token swaps
    /// @param _useAuctions New value for useAuctions flag
    /// @dev Can only be called by management
    /// @dev When enabled, the strategy will attempt to kick auctions during harvest
    /// @dev When disabled, the strategy will not use auctions and rewards will accumulate
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

    /// @notice Sets the authorized depositor address
    /// @param _depositor Address allowed to deposit into the strategy
    /// @dev Can only be called by management
    /// @dev Setting to address(0) allows anyone to deposit
    /// @dev Setting to a specific address restricts deposits to only that address
    function setDepositor(address _depositor) external onlyManagement {
        depositor = _depositor;
    }

    /// @notice Initiates an auction for a given token
    /// @dev Can only be called by keepers when auctions are enabled
    /// @dev This function transfers tokens to the auction contract and kicks off a new auction
    /// @dev Will fail if:
    ///      1. Auctions are disabled or no auction contract is set
    ///      2. The token is the strategy's asset or vault
    ///      3. The token balance is below the configured minimum threshold
    ///      4. The auction fails to start for any reason
    /// @param _from The token to be sold in the auction
    /// @return The available amount for bidding on in the auction
    function kickAuction(
        address _from
    ) external virtual onlyKeepers returns (uint256) {
        (bool _success, uint256 _amount) = _tryKickAuction(auction, _from);
        require(_success, "!kick");
        return _amount;
    }

    /// @notice Internal function to initiate an auction for reward tokens
    /// @dev Transfers tokens to the auction contract and starts the auction process.
    ///      Security features:
    ///      1. Prevents auctioning the strategy's underlying asset or vault tokens
    ///      2. Transfers all available balance of the token to the auction contract
    ///      3. Relies on the auction contract to properly handle the kicked auction
    ///      4. The auction contract has already been validated in setAuction()
    ///      5. Implements minimum amount thresholds to prevent dust auctions
    ///      6. Uses try/catch to gracefully handle auction failures
    /// @param _auction The contract operating the auction
    /// @param _from The token to be sold in the auction (e.g., EUL or WETH)
    /// @return Success Boolean indicating whether the auction was successfully kicked
    /// @return Amount The amount of tokens put up for auction (0 if failed)
    function _tryKickAuction(
        address _auction,
        address _from
    ) internal virtual returns (bool, uint256) {
        if (!useAuctions || _auction == address(0)) return (false, 0); // auctions not enabled
        if (_from == address(asset) || _from == address(vault))
            return (false, 0); // don't kick asset or vault tokens
        if (
            IAuction(_auction).isActive(address(asset)) ||
            IAuction(_auction).available(address(asset)) != 0
        ) return (false, 0); // auction is active
        uint256 _balance = ERC20(_from).balanceOf(address(this)) +
            ERC20(_from).balanceOf(_auction);
        (, uint256 _tokenMinAmountToAuction) = _minAmountToAuction.tryGet(
            _from
        );
        if (_balance == 0 || _balance < _tokenMinAmountToAuction)
            return (false, 0); // no tokens to auction
        ERC20(_from).safeTransfer(_auction, _balance);
        uint256 _amountKicked = IAuction(_auction).kick(_from);
        return (_amountKicked != 0, _amountKicked);
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
