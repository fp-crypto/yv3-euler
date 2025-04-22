// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/console2.sol";
import {Setup, ERC20, IStrategyInterface} from "./utils/Setup.sol";
import {IMerklDistributor} from "../interfaces/IMerklDistributor.sol";

// Mock implementation of the Merkl Distributor
contract MockMerklDistributor is IMerklDistributor {
    // Track claims for testing
    uint256 public claimCount;
    mapping(address => mapping(address => uint256)) public claimedAmounts;

    event ClaimCalled(
        address[] users,
        address[] tokens,
        uint256[] amounts,
        bytes32[][] proofs
    );

    function claim(
        address[] calldata users,
        address[] calldata tokens,
        uint256[] calldata amounts,
        bytes32[][] calldata proofs
    ) external override {
        // Log the call
        claimCount++;
        emit ClaimCalled(users, tokens, amounts, proofs);

        // Track claims and transfer tokens
        for (
            uint256 i = 0;
            i < users.length && i < tokens.length && i < amounts.length;
            i++
        ) {
            claimedAmounts[users[i]][tokens[i]] += amounts[i];

            // Transfer tokens from this contract to the user if we have balance
            uint256 balance = ERC20(tokens[i]).balanceOf(address(this));
            if (balance >= amounts[i]) {
                ERC20(tokens[i]).transfer(users[i], amounts[i]);
            }
        }
    }
}

contract MerklClaimTest is Setup {
    // The original Merkl Distributor address from the contract
    address constant ORIGINAL_MERKL =
        0x3Ef3D8bA38EBe18DB133cEc108f4D14CE00Dd9Ae;

    // Our mock contract
    MockMerklDistributor public mockMerklImpl;

    function setUp() public override {
        // Call the original setup to get all the tokens and contracts initialized
        super.setUp();

        // Deploy our mock Merkl distributor
        mockMerklImpl = new MockMerklDistributor();

        // Etch our mock's code at the original contract address
        vm.etch(ORIGINAL_MERKL, address(mockMerklImpl).code);

        // Set up storage slots if needed
        // Note: this is a fresh instance at the ORIGINAL_MERKL address
        MockMerklDistributor mockMerkl = MockMerklDistributor(ORIGINAL_MERKL);

        // Airdrop tokens to the mock distributor for testing claims
        address wrappedToken = tokenAddrs["wS"];
        airdrop(ERC20(wrappedToken), ORIGINAL_MERKL, 100e18);

        // Make sure the mock has tokens
        assertGt(
            ERC20(wrappedToken).balanceOf(ORIGINAL_MERKL),
            0,
            "Mock should have tokens"
        );
    }

    function test_merklClaimForwarding() public {
        // Reset the claim count for this test
        MockMerklDistributor mockMerkl = MockMerklDistributor(ORIGINAL_MERKL);

        // Force reset the claim count using vm.store
        // This ensures each test starts with a clean state
        vm.store(ORIGINAL_MERKL, bytes32(uint256(0)), bytes32(uint256(0)));

        address recipient = address(0xBEEF);
        address tokenAddr = tokenAddrs["wS"];
        uint256 claimAmount = 10e18;

        // Prepare claim parameters
        address[] memory users = new address[](1);
        users[0] = recipient;

        address[] memory tokens = new address[](1);
        tokens[0] = tokenAddr;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = claimAmount;

        bytes32[][] memory proofs = new bytes32[][](1);
        proofs[0] = new bytes32[](0); // Empty proof for testing

        // Check initial balances
        uint256 initialBalance = ERC20(tokenAddr).balanceOf(recipient);

        // Call claim via the strategy
        strategy.claim(users, tokens, amounts, proofs);

        // Assert that the call was forwarded
        assertEq(mockMerkl.claimCount(), 1, "Claim count should be 1");

        // Assert that the tokens were transferred
        assertEq(
            ERC20(tokenAddr).balanceOf(recipient),
            initialBalance + claimAmount,
            "Recipient should have received tokens"
        );
    }

    function test_merklClaimWithMultipleRecipients() public {
        // Reset the claim count for this test
        MockMerklDistributor mockMerkl = MockMerklDistributor(ORIGINAL_MERKL);

        // Force reset the claim count using vm.store
        // This ensures each test starts with a clean state
        vm.store(ORIGINAL_MERKL, bytes32(uint256(0)), bytes32(uint256(0)));

        address recipient1 = address(0xBEEF);
        address recipient2 = address(0xCAFE);
        address tokenAddr = tokenAddrs["wS"];
        uint256 claimAmount1 = 10e18;
        uint256 claimAmount2 = 5e18;

        // Prepare claim parameters
        address[] memory users = new address[](2);
        users[0] = recipient1;
        users[1] = recipient2;

        address[] memory tokens = new address[](2);
        tokens[0] = tokenAddr;
        tokens[1] = tokenAddr;

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = claimAmount1;
        amounts[1] = claimAmount2;

        bytes32[][] memory proofs = new bytes32[][](2);
        proofs[0] = new bytes32[](0);
        proofs[1] = new bytes32[](0);

        // Check initial balances
        uint256 initialBalance1 = ERC20(tokenAddr).balanceOf(recipient1);
        uint256 initialBalance2 = ERC20(tokenAddr).balanceOf(recipient2);

        // Call claim via the strategy
        strategy.claim(users, tokens, amounts, proofs);

        // Verify claim count
        assertEq(mockMerkl.claimCount(), 1, "Claim count should be 1");

        // Assert that the tokens were transferred to both recipients
        assertEq(
            ERC20(tokenAddr).balanceOf(recipient1),
            initialBalance1 + claimAmount1,
            "Recipient 1 should have received tokens"
        );

        assertEq(
            ERC20(tokenAddr).balanceOf(recipient2),
            initialBalance2 + claimAmount2,
            "Recipient 2 should have received tokens"
        );
    }
}
