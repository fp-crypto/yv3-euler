pragma solidity ^0.8.18;

import "forge-std/console2.sol";
import {Setup} from "./utils/Setup.sol";

import {EulerVaultAprOracle as StrategyAprOracle} from "../periphery/StrategyAprOracle.sol";

contract OracleTest is Setup {
    StrategyAprOracle public oracle;

    function setUp() public override {
        super.setUp();
        oracle = new StrategyAprOracle(management);
    }

    function checkOracle(address _strategy, uint256 _delta) public {
        uint256 currentApr = oracle.aprAfterDebtChange(_strategy, 0);

        // Should be greater than 0 but likely less than 100%
        assertGt(currentApr, 0, "ZERO");
        assertLt(currentApr, 1e18, "+100%");

        uint256 negativeDebtChangeApr = oracle.aprAfterDebtChange(
            _strategy,
            -int256(_delta)
        );

        // The apr should go up if deposits go down
        assertLt(currentApr, negativeDebtChangeApr, "negative change");

        uint256 positiveDebtChangeApr = oracle.aprAfterDebtChange(
            _strategy,
            int256(_delta)
        );

        assertGt(currentApr, positiveDebtChangeApr, "positive change");

        address[] memory _targets = new address[](2);
        _targets[0] = strategy.vault();
        _targets[1] = strategy.vault();

        StrategyAprOracle.MerklCampaign[]
            memory _campaigns = new StrategyAprOracle.MerklCampaign[](2);
        _campaigns[0] = StrategyAprOracle.MerklCampaign({
            startTime: uint64(block.timestamp - 15 days),
            endTime: uint64(block.timestamp + 15 days),
            amount: 3332920000000000000000
        });
        _campaigns[1] = StrategyAprOracle.MerklCampaign({
            startTime: uint64(block.timestamp - 1 days),
            endTime: uint64(block.timestamp + 29 days),
            amount: 7500040000000000000000
        });

        vm.expectRevert("!governance");
        vm.prank(user);
        oracle.addCampaigns(_targets, _campaigns);

        vm.prank(management);
        oracle.addCampaigns(_targets, _campaigns);

        assertEq(oracle.merklCampaigns(strategy.vault()).length, 2);

        uint256 withRewardsApr = oracle.aprAfterDebtChange(_strategy, 0);
        assertGt(withRewardsApr, currentApr, "withRewardsApr");

        uint256 withRewardsAprNegativeChange = oracle.aprAfterDebtChange(
            _strategy,
            -int256(_delta)
        );
        assertLt(
            withRewardsApr,
            withRewardsAprNegativeChange,
            "withRewardsAprNegativeChange"
        );

        uint256 withRewardsAprPositiveChange = oracle.aprAfterDebtChange(
            _strategy,
            int256(_delta)
        );
        assertGt(
            withRewardsApr,
            withRewardsAprPositiveChange,
            "withRewardsAprPositiveChange"
        );

        vm.expectRevert("!governance");
        vm.prank(user);
        oracle.reepStaleCampaigns(_targets);

        vm.prank(management);
        oracle.reepStaleCampaigns(_targets);

        assertEq(oracle.merklCampaigns(strategy.vault()).length, 2);

        vm.warp(block.timestamp + 30 days);

        vm.prank(management);
        oracle.reepStaleCampaigns(_targets);

        assertEq(oracle.merklCampaigns(strategy.vault()).length, 0);
    }

    function test_oracle(uint256 _amount, uint16 _percentChange) public {
        _amount = bound(_amount, minFuzzAmount * 100, maxFuzzAmount);
        _percentChange = uint16(
            bound(uint256(_percentChange), 10, MAX_BPS - 1)
        );
        uint256 _delta = (_amount * _percentChange) / MAX_BPS;

        mintAndDepositIntoStrategy(strategy, user, _amount);
        checkOracle(address(strategy), _delta);
    }
}
