// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/console.sol";
import "forge-std/Script.sol";

import {EulerVaultAprOracle} from "../periphery/StrategyAprOracle.sol";
import {EulerCompounderStrategy} from "../Strategy.sol";

import {Strings} from "./lib/Strings.sol";

/// @title UpdateAprOracle Script
/// @notice This script manages Merkl campaign data for Euler vaults by fetching new campaigns and cleaning up expired ones
/// @dev Uses Foundry's FFI for API requests and optimizes gas usage through multicalls
contract UpdateAprOracle is Script {
    /// @notice Array of Euler Compounder strategies to manage campaign data for
    /// @dev Hardcoded strategy addresses for which to fetch and update campaign data
    EulerCompounderStrategy[2] private strategies = [
        EulerCompounderStrategy(0xa08CEb657D9A8035A44A1b44b8d4C42eC31Dd4D4),
        EulerCompounderStrategy(0xaf48f006e75AF050c4136F5a32B69e3FE1C4140f)
    ];

    /// @notice Reference to the APR Oracle contract that stores campaign data
    /// @dev Contract that manages Merkl campaign information for Euler vaults
    EulerVaultAprOracle private aprOracle =
        EulerVaultAprOracle(0x7726666964c7e419Fc1659970E6b4466D0296fB3);

    /// @notice List of vault addresses that had expired campaigns removed
    address[] private reepCampaigns;
    /// @notice List of vault addresses for new campaign additions
    address[] private campaignTargets;
    /// @notice List of new Merkl campaigns to be added
    EulerVaultAprOracle.MerklCampaign[] private merklCampaigns;

    /// @notice Structure to hold Merkl campaign data
    /// @param amount The reward amount for the campaign
    /// @param endTime The timestamp when the campaign ends
    /// @param startTime The timestamp when the campaign starts
    struct Campaign {
        uint256 amount;
        uint256 endTime;
        uint256 startTime;
    }

    /// @notice Accumulated multicall data for batch processing campaign updates
    /// @dev Contains encoded function calls for reepStaleCampaigns and addCampaigns
    bytes[] internal _multicallData;

    /// @notice Main script execution function
    /// @dev For each strategy:
    ///      1. Removes expired campaigns
    ///      2. Fetches active campaigns from Merkl API
    ///      3. Adds new campaigns to the oracle
    ///      4. Batches operations into multicalls for gas optimization
    function run() external {
        if (!_baseFeeOkay()) return;

        string[] memory inputs;
        string memory output;
        address eulerVault;

        if (!_baseFeeOkay()) return;

        vm.startPrank(aprOracle.governance());

        for (uint256 i; i < strategies.length; ++i) {
            eulerVault = address(strategies[i].vault());

            uint256 lengthBefore = aprOracle.merklCampaigns(eulerVault).length;
            address[] memory _reepVault = new address[](1);
            _reepVault[0] = eulerVault;
            aprOracle.reepStaleCampaigns(_reepVault);
            if (lengthBefore > aprOracle.merklCampaigns(eulerVault).length)
                reepCampaigns.push(eulerVault);

            // Prepare curl command to fetch campaign data from Merkl API
            inputs = new string[](3);
            inputs[0] = "curl";
            inputs[1] = "-s"; // silent mode
            inputs[2] = string.concat(
                "https://api.merkl.xyz/v4/campaigns?tokenSymbol=rEUL&mainParameter=",
                Strings.toChecksumHexString(eulerVault),
                "&endTimestamp=",
                Strings.toString(block.timestamp)
            );
            output = string(vm.ffi(inputs)); // Execute HTTP request

            // Prepare jq command to parse and transform JSON response
            inputs = new string[](7);
            inputs[0] = "jq"; // JSON processor
            inputs[1] = "-r"; // raw output
            inputs[2] = "-n"; // null input
            inputs[3] = "--argjson"; // pass JSON as argument
            inputs[4] = "data";
            inputs[5] = output;
            inputs[
                6
            ] = "$data|map({amount:.amount|tonumber,endTime:.endTimestamp|tonumber,startTime:.startTimestamp|tonumber})"; // Transform JSON to match Campaign struct

            output = string(vm.ffi(inputs));
            bytes memory data = vm.parseJson(output);
            Campaign[] memory campaigns = abi.decode(data, (Campaign[]));

            for (uint256 j; j < campaigns.length; ++j) {
                lengthBefore = aprOracle.merklCampaigns(eulerVault).length;
                address[] memory _target = new address[](1);
                EulerVaultAprOracle.MerklCampaign[]
                    memory _merklCampaign = new EulerVaultAprOracle.MerklCampaign[](
                        1
                    );
                _target[0] = eulerVault;
                _merklCampaign[0] = EulerVaultAprOracle.MerklCampaign({
                    startTime: uint64(campaigns[j].startTime),
                    endTime: uint64(campaigns[j].endTime),
                    amount: uint128(campaigns[j].amount)
                });
                aprOracle.addCampaigns(_target, _merklCampaign);

                if (lengthBefore == aprOracle.merklCampaigns(eulerVault).length)
                    continue;

                campaignTargets.push(eulerVault);
                merklCampaigns.push(_merklCampaign[0]);
            }
        }

        vm.stopPrank();

        if (reepCampaigns.length != 0)
            _multicallData.push(
                abi.encodeCall(aprOracle.reepStaleCampaigns, (reepCampaigns))
            );
        if (campaignTargets.length != 0)
            _multicallData.push(
                abi.encodeCall(
                    aprOracle.addCampaigns,
                    (campaignTargets, merklCampaigns)
                )
            );

        vm.startBroadcast(aprOracle.governance());
        if (_multicallData.length == 1) {
            (bool success, ) = address(aprOracle).call(_multicallData[0]);
            require(success, "call failed!");
        } else if (_multicallData.length != 0) {
            aprOracle.multicall(_multicallData);
        }
        vm.stopBroadcast();
    }

    /// @notice Checks if the current network base fee is below the configured limit
    /// @dev Reads BASE_FEE_LIMIT from environment (defaults to 12 gwei)
    /// @return bool True if base fee is acceptable, false otherwise
    function _baseFeeOkay() private returns (bool) {
        uint256 basefeeLimit = vm.envOr("BASE_FEE_LIMIT", uint256(12)) * 1e9;
        if (block.basefee >= basefeeLimit) {
            console.log(
                "Base fee too high: %d > %d gwei",
                block.basefee / 1e9,
                basefeeLimit / 1e9
            );
            return false;
        }

        return true;
    }
}
