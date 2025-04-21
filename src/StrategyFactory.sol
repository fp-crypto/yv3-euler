// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import {EulerCompounderStrategy as Strategy, ERC20} from "./Strategy.sol";
import {IStrategyInterface} from "./interfaces/IStrategyInterface.sol";
import {IAuctionFactory} from "./interfaces/IAuctionFactory.sol";

/// @title Strategy Factory for Euler Compounder Strategies
/// @notice Factory contract for deploying and managing Euler compounder strategies
/// @dev Handles deployment and configuration of strategies with proper access control
contract StrategyFactory {
    /// @notice Emitted when a new strategy is deployed
    /// @param strategy Address of the newly deployed strategy
    /// @param asset Address of the underlying asset for the strategy
    event NewStrategy(address indexed strategy, address indexed asset);

    /// @notice Address with emergency shutdown powers for all strategies
    address public immutable emergencyAdmin;

    /// @notice The Wrapped Native token address for the current chain
    address public immutable WRAPPED_NATIVE;

    /// @notice The REUL token address (can be address(0) if not using REUL)
    address public immutable REUL;

    address public constant AUCTION_FACTORY =
        0xCfA510188884F199fcC6e750764FAAbE6e56ec40;

    /// @notice Address with management rights over strategies
    address public management;

    /// @notice Address that receives performance fees from strategies
    address public performanceFeeRecipient;

    /// @notice Address that can trigger harvests and tends on strategies
    address public keeper;

    /// @notice Maps base vaults to their corresponding strategies
    /// @dev Tracks deployments to prevent duplicate strategies for the same vault
    mapping(address => address) public deployments;

    /// @notice Initializes the factory with the core protocol roles
    /// @param _management Address that will have management rights over strategies
    /// @param _performanceFeeRecipient Address that will receive performance fees
    /// @param _keeper Address that will be able to tend/harvest strategies
    /// @param _emergencyAdmin Address that will have emergency powers
    /// @param _wrappedNative Address of the wrapped native token for the chain
    /// @param _reul Address of the REUL token (can be address(0) if not using REUL)
    constructor(
        address _management,
        address _performanceFeeRecipient,
        address _keeper,
        address _emergencyAdmin,
        address _wrappedNative,
        address _reul
    ) {
        management = _management;
        performanceFeeRecipient = _performanceFeeRecipient;
        keeper = _keeper;
        emergencyAdmin = _emergencyAdmin;
        WRAPPED_NATIVE = _wrappedNative;
        REUL = _reul;
    }

    /// @notice Deploy a new Strategy
    /// @dev Creates a new Strategy instance and sets up all the required roles
    /// @param _baseVault The underlying 4646 vault for the strategy to use
    /// @param _name The name for the strategy token
    /// @return address The address of the newly deployed strategy
    function newStrategy(
        address _baseVault,
        string calldata _name
    ) external virtual returns (address) {
        // Ensure no strategy exists for this vault already
        require(deployments[_baseVault] == address(0), "exists");

        // Deploy new strategy with appropriate parameters
        IStrategyInterface _newStrategy = IStrategyInterface(
            address(new Strategy(_baseVault, _name, WRAPPED_NATIVE, REUL))
        );

        address _management = management;
        address _asset = _newStrategy.asset();
        address _auction = IAuctionFactory(AUCTION_FACTORY).createNewAuction(
            _asset,
            address(_newStrategy),
            management
        );

        // Configure strategy roles
        _newStrategy.setPerformanceFeeRecipient(performanceFeeRecipient);
        _newStrategy.setKeeper(keeper);
        _newStrategy.setPendingManagement(_management);
        _newStrategy.setEmergencyAdmin(emergencyAdmin);
        _newStrategy.setAuction(_auction);

        // Record deployment and emit event
        address _strategyAddress = address(_newStrategy);
        deployments[_baseVault] = _strategyAddress;
        emit NewStrategy(_strategyAddress, _asset);

        return _strategyAddress;
    }

    /// @notice Updates the core protocol roles
    /// @dev Can only be called by current management
    /// @param _management New management address
    /// @param _performanceFeeRecipient New fee recipient address
    /// @param _keeper New keeper address
    function setAddresses(
        address _management,
        address _performanceFeeRecipient,
        address _keeper
    ) external {
        require(msg.sender == management, "!management");
        management = _management;
        performanceFeeRecipient = _performanceFeeRecipient;
        keeper = _keeper;
    }

    /// @notice Checks if a strategy was deployed by this factory
    /// @dev Verifies if the strategy address matches the recorded deployment for its vault
    /// @param _strategy Address of the strategy to check
    /// @return bool True if the strategy was deployed by this factory, false otherwise
    function isDeployedStrategy(
        address _strategy
    ) external view returns (bool) {
        address _vault = IStrategyInterface(_strategy).vault();
        return deployments[_vault] == _strategy;
    }
}
