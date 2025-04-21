// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/console2.sol";
import {Setup, ERC20, IStrategyInterface} from "./utils/Setup.sol";
import {IAuction} from "../interfaces/IAuction.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract OperationTest is Setup {
    function setUp() public virtual override {
        super.setUp();
    }

    function test_setupStrategyOK() public {
        console2.log("address of strategy", address(strategy));
        assertTrue(address(0) != address(strategy));
        assertEq(strategy.asset(), address(asset));
        assertEq(strategy.management(), management);
        assertEq(strategy.performanceFeeRecipient(), performanceFeeRecipient);
        assertEq(strategy.keeper(), keeper);
        assertTrue(strategyFactory.isDeployedStrategy(address(strategy)));
        assertEq(strategy.REUL(), tokenAddrs["rEUL"]);
        assertEq(strategy.EUL(), tokenAddrs["EUL"]);
    }

    function test_operation(uint256 _amount) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        // Earn Interest
        skip(1 days);

        // Report profit
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        // Check return Values
        assertGe(profit, 0, "!profit");
        assertEq(loss, 0, "!loss");

        skip(strategy.profitMaxUnlockTime());

        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertGe(
            asset.balanceOf(user),
            balanceBefore + _amount,
            "!final balance"
        );
    }

    function test_profitableReport(
        uint256 _amount,
        uint256 _airdropAmount
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        _airdropAmount = bound(
            _airdropAmount,
            0.1e6,
            _amount / 100 // no more than 1%
        );

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        // Earn Interest and rewards
        skip(1 days);
        airdrop(ERC20(strategy.asset()), address(strategy), _airdropAmount);

        // Report profit
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        // Check return Values
        assertGt(profit, 0, "!profit");
        assertEq(loss, 0, "!loss");

        skip(strategy.profitMaxUnlockTime());

        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertGe(
            asset.balanceOf(user),
            balanceBefore + _amount,
            "!final balance"
        );
    }

    function test_profitableReportBaseThenAirdrop(
        uint256 _amount,
        uint256 _airdropAmount
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        _airdropAmount = bound(
            _airdropAmount,
            0.1e6,
            _amount / 100 // no more than 1%
        );

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        // Earn Interest
        skip(1 days);

        // Report profit
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        // Check return Values
        assertGt(profit, 0, "!profit");
        assertEq(loss, 0, "!loss");

        skip(strategy.profitMaxUnlockTime());

        airdrop(ERC20(strategy.asset()), address(strategy), _airdropAmount);

        // Report profit
        vm.prank(keeper);
        (profit, loss) = strategy.report();

        // Check return Values
        assertGt(profit, 0, "!profit");
        assertEq(loss, 0, "!loss");

        skip(strategy.profitMaxUnlockTime());

        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertGe(
            asset.balanceOf(user),
            balanceBefore + _amount,
            "!final balance"
        );
    }

    function test_profitableReportAirdropThenBase(
        uint256 _amount,
        uint256 _airdropAmount
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        _airdropAmount = bound(
            _airdropAmount,
            0.1e6,
            _amount / 100 // no more than 1%
        );

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        airdrop(ERC20(strategy.asset()), address(strategy), _airdropAmount);

        // Report profit
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        // Check return Values
        assertGt(profit, 0, "!profit");
        assertEq(loss, 0, "!loss");

        skip(strategy.profitMaxUnlockTime());

        // Report profit
        vm.prank(keeper);
        (profit, loss) = strategy.report();

        // Check return Values
        assertGt(profit, 0, "!profit");
        assertEq(loss, 0, "!loss");

        skip(strategy.profitMaxUnlockTime());

        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertGe(
            asset.balanceOf(user),
            balanceBefore + _amount,
            "!final balance"
        );
    }

    function test_profitableReportAirdropThenBase_DudesVersion(
        uint256 _amount,
        uint256 _airdropAmount
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        _airdropAmount = bound(
            _airdropAmount,
            minFuzzAmount / 10,
            _amount / 10 // no more than 10%
        );

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        skip(strategy.profitMaxUnlockTime());
        airdrop(ERC20(strategy.asset()), address(strategy), _airdropAmount);

        // Report profit
        vm.prank(keeper);
        (uint256 profitWithAirdrop, uint256 loss) = strategy.report();

        // Check return Values
        assertGt(profitWithAirdrop, 0, "!profit");
        assertEq(loss, 0, "!loss");

        skip(strategy.profitMaxUnlockTime());

        uint256 profit;
        // Report profit
        vm.prank(keeper);
        (profit, loss) = strategy.report();

        // Check return Values
        assertGt(profit, 0, "!profit");
        assertEq(loss, 0, "!loss");
        assertGt(profitWithAirdrop, profit, "!airdropProfit");

        skip(strategy.profitMaxUnlockTime());

        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertGe(
            asset.balanceOf(user),
            balanceBefore + _amount,
            "!final balance"
        );
    }

    function test_profitableReportOnlyBase(uint256 _amount) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        skip(1 days);

        // Report profit
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        // Check return Values
        assertGt(profit, 0, "!profit");
        assertEq(loss, 0, "!loss");

        skip(strategy.profitMaxUnlockTime());

        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertGe(
            asset.balanceOf(user),
            balanceBefore + _amount,
            "!final balance"
        );
    }

    function test_profitableReportOnlyAirdrop(
        uint256 _amount,
        uint256 _airdropAmount
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        _airdropAmount = bound(
            _airdropAmount,
            0.1e6,
            _amount / 100 // no more than 1%
        );

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        airdrop(ERC20(strategy.asset()), address(strategy), _airdropAmount);

        // Report profit
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        // Check return Values
        assertGt(profit, 0, "!profit");
        assertEq(loss, 0, "!loss");

        skip(strategy.profitMaxUnlockTime());

        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertGe(
            asset.balanceOf(user),
            balanceBefore + _amount,
            "!final balance"
        );
    }

    function test_airdroppedREULUnwrapped(
        uint256 _amount,
        uint256 _airdropAmount
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        _airdropAmount = bound(
            _airdropAmount,
            1e6,
            Math.min(
                ERC20(strategy.EUL()).balanceOf(strategy.REUL()),
                _amount / 10
            )
        );

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        airdropREUL(address(strategy), _airdropAmount);

        vm.prank(management);
        strategy.setDoHealthCheck(false);

        // Report profit
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        // Check return Values
        assertEq(profit, 0, "!profit");
        assertApproxEqAbs(loss, 0, 0.001e6, "!loss");

        assertGt(ERC20(strategy.EUL()).balanceOf(address(strategy)), 0, "!eul");

        skip(strategy.profitMaxUnlockTime());

        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertApproxEqAbs(
            asset.balanceOf(user),
            balanceBefore + _amount,
            1,
            "!final balance"
        );
    }

    function test_setters(
        address _auctionToken,
        uint256 _minAmountToAuction,
        bool _useAuctions
    ) public {
        vm.expectRevert("!management");
        strategy.setMinAmountToAuction(_auctionToken, _minAmountToAuction);
        vm.prank(management);
        strategy.setMinAmountToAuction(_auctionToken, _minAmountToAuction);
        assertEq(
            _minAmountToAuction,
            strategy.minAmountToAuction(_auctionToken)
        );

        vm.expectRevert("!management");
        strategy.setUseAuctions(_useAuctions);
        vm.prank(management);
        strategy.setUseAuctions(_useAuctions);
        assertEq(_useAuctions, strategy.useAuctions());
    }

    function test_tendTrigger(uint256 _amount) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        (bool trigger, ) = strategy.tendTrigger();
        assertTrue(!trigger);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        (trigger, ) = strategy.tendTrigger();
        assertTrue(!trigger);

        // Skip some time
        skip(1 days);

        (trigger, ) = strategy.tendTrigger();
        assertTrue(!trigger);

        vm.prank(keeper);
        strategy.report();

        (trigger, ) = strategy.tendTrigger();
        assertTrue(!trigger);

        // Unlock Profits
        skip(strategy.profitMaxUnlockTime());

        (trigger, ) = strategy.tendTrigger();
        assertTrue(!trigger);

        vm.prank(user);
        strategy.redeem(_amount, user, user);

        (trigger, ) = strategy.tendTrigger();
        assertTrue(!trigger);
    }

    function test_strategyFactoryUnique() public {
        address vault = strategy.vault();
        vm.expectRevert("exists");
        strategyFactory.newStrategy(vault, "");
    }

    function test_auction_wS(
        uint256 _amount,
        uint256 _wsRewardAmount,
        bool _newAuction
    ) public {
        address wS = tokenAddrs["wS"];
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        _wsRewardAmount = bound(_wsRewardAmount, 1, _amount / 20);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        console2.log("Airdropping %s", wS);
        console2.log("Airdrop amount %e", _wsRewardAmount);

        airdrop(ERC20(wS), address(strategy), _wsRewardAmount);

        vm.startPrank(management);
        IAuction _auction;
        if (_newAuction) {
            _auction = IAuction(_createAuction(strategy));
            strategy.setAuction(address(_auction));
            assertEq(address(_auction), strategy.auction(), "!auction");
        } else {
            _auction = IAuction(strategy.auction());
        }
        strategy.setUseAuctions(true);
        _auction.enable(wS);
        vm.stopPrank();

        skip(10 minutes);

        // Report profit
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        // Check return Values
        assertGe(profit, 0, "!profit");
        assertEq(loss, 0, "!loss");
        assertGe(ERC20(wS).balanceOf(address(strategy)), _wsRewardAmount, "wS");

        skip(strategy.profitMaxUnlockTime());

        vm.expectRevert();
        strategy.kickAuction(wS);

        vm.prank(keeper);
        uint256 kicked = strategy.kickAuction(wS);

        assertGe(kicked, _wsRewardAmount, "!kicked");
        assertEq(ERC20(wS).balanceOf(address(strategy)), 0, "!swap");
        assertEq(asset.balanceOf(address(strategy)), 0, "!asset");
        assertTrue(_auction.isActive(wS), "!active");
    }
}
