// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import {EulerCompounderStrategy as Strategy, ERC20} from "./Strategy.sol";
import {IStrategyInterface} from "./interfaces/IStrategyInterface.sol";

contract StrategyFactory {
    event NewStrategy(address indexed strategy, address indexed asset);

    address public immutable emergencyAdmin;

    address public management;
    address public performanceFeeRecipient;
    address public keeper;

    /// @notice Track the deployments. base vault => strategy
    mapping(address => address) public deployments;

    /// @notice Initializes the factory with the core protocol roles
    /// @param _management Address that will have management rights over strategies
    /// @param _performanceFeeRecipient Address that will receive performance fees
    /// @param _keeper Address that will be able to tend/harvest strategies
    /// @param _emergencyAdmin Address that will have emergency powers
    constructor(
        address _management,
        address _performanceFeeRecipient,
        address _keeper,
        address _emergencyAdmin
    ) {
        management = _management;
        performanceFeeRecipient = _performanceFeeRecipient;
        keeper = _keeper;
        emergencyAdmin = _emergencyAdmin;
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
        // tokenized strategies available setters.
        IStrategyInterface _newStrategy = IStrategyInterface(
            address(new Strategy(_baseVault, _name, 0))
        );

        _newStrategy.setPerformanceFeeRecipient(performanceFeeRecipient);

        _newStrategy.setKeeper(keeper);

        _newStrategy.setPendingManagement(management);

        _newStrategy.setEmergencyAdmin(emergencyAdmin);

        emit NewStrategy(address(_newStrategy), _newStrategy.asset());

        deployments[_baseVault] = address(_newStrategy);
        return address(_newStrategy);
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
    /// @dev Verifies if the strategy address matches the recorded deployment for its asset
    /// @param _strategy Address of the strategy to check
    /// @return bool True if the strategy was deployed by this factory, false otherwise
    function isDeployedStrategy(
        address _strategy
    ) external view returns (bool) {
        address _asset = IStrategyInterface(_strategy).asset();
        return deployments[_asset] == _strategy;
    }
}
