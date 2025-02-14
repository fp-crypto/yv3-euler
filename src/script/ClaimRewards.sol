// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/console.sol";
import "forge-std/Script.sol";

import {EulerVaultAprOracle} from "../periphery/StrategyAprOracle.sol";
import {EulerCompounderStrategy} from "../Strategy.sol";
import {StrategyFactory} from "../StrategyFactory.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Strings} from "./lib/Strings.sol";

/// @title ClaimRewards Script
/// @notice Script to claim Merkl rewards for Euler Compounder strategies
/// @dev Uses Foundry's FFI capabilities to fetch reward data from Merkl API and execute claims
contract ClaimRewards is Script {
    using Strings for string;

    /// @notice Array of Euler Compounder strategies to claim rewards for
    /// @dev Hardcoded strategy addresses that will receive their Merkl rewards
    EulerCompounderStrategy[2] private strategies = [
        EulerCompounderStrategy(0xa08CEb657D9A8035A44A1b44b8d4C42eC31Dd4D4),
        EulerCompounderStrategy(0xaf48f006e75AF050c4136F5a32B69e3FE1C4140f)
    ];

    /// @notice Structure to hold parsed Merkl reward claim data
    /// @param amounts Array of reward amounts as strings (to be parsed to uint256)
    /// @param proofs Merkle proofs required to verify and claim rewards
    /// @param tokens Array of reward token addresses
    /// @param users Array of recipient addresses for the rewards
    struct ClaimData {
        string[] amounts;
        bytes32[][] proofs;
        address[] tokens;
        address[] users;
    }

    /// @notice Main script execution function
    /// @dev For each strategy:
    ///      1. Fetches available rewards from Merkl API
    ///      2. Parses the JSON response to extract claim data
    ///      3. Converts string amounts to uint256
    ///      4. Executes the claim transaction if rewards are available
    function run() external {
        if (!_baseFeeOkay()) return;

        string[] memory inputs;
        string memory output;
        EulerCompounderStrategy strategy;
        address eulerVault;

        if (!_baseFeeOkay()) return;

        for (uint256 i; i < strategies.length; ++i) {
            strategy = strategies[i];
            eulerVault = address(strategy.vault());

            // Prepare curl command to fetch reward data from Merkl API
            inputs = new string[](3);
            inputs[0] = "curl";
            inputs[1] = "-s"; // silent mode
            inputs[2] = string.concat(
                "https://api.merkl.xyz/v4/users/",
                Strings.toChecksumHexString(address(strategy)),
                "/rewards?chainId=",
                Strings.toString(block.chainid)
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
            ] = "$data|.[].rewards|map({amounts: [.amount], proofs: [.proofs], tokens: [.token.address], users: [.recipient]})|reduce .[] as $item ({};. + $item)";

            output = string(vm.ffi(inputs));

            if (bytes(output).length == 0) continue;

            bytes memory data = vm.parseJson(output);
            ClaimData memory claimData = abi.decode(data, (ClaimData));

            if (claimData.amounts.length == 0) continue;

            uint256[] memory amounts = new uint256[](claimData.amounts.length);
            for (uint256 j; j < amounts.length; j++) {
                amounts[j] = claimData.amounts[j].parseUint();
            }

            vm.startBroadcast();
            strategy.claim(
                claimData.users,
                claimData.tokens,
                amounts,
                claimData.proofs
            );
            vm.stopBroadcast();
        }
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
