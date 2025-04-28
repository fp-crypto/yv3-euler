// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/console2.sol";
import {Setup, ERC20, IStrategyInterface} from "./utils/Setup.sol";
import {IAuction} from "../interfaces/IAuction.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {EulerCompounderStrategy} from "../Strategy.sol";

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
        uint256 _airdropAmount,
        uint256 _minAmountToAuction
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
        console2.log("_airdropAmount: %e", _airdropAmount);
        console2.log("_minAmountToAuction: %e", _minAmountToAuction);

        if (_minAmountToAuction != 0) {
            vm.startPrank(management);
            strategy.setUseAuctions(true);
            strategy.setMinAmountToAuction(strategy.EUL(), _minAmountToAuction);
            IAuction(strategy.auction()).enable(strategy.EUL());
            vm.stopPrank();
        }

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
        assertApproxEqAbs(loss, 0, _amount / 10_000, "!loss"); // 10bp diff

        if (
            _minAmountToAuction != 0 &&
            _airdropAmount / 5 >= _minAmountToAuction
        ) {
            assertTrue(
                IAuction(strategy.auction()).isActive(strategy.EUL()),
                "!active"
            );
            assertGt(
                ERC20(strategy.EUL()).balanceOf(strategy.auction()),
                (_airdropAmount / 5) - 5,
                "!eul"
            );
        } else if (_airdropAmount / 5 < _minAmountToAuction) {
            assertEq(
                ERC20(strategy.REUL()).balanceOf(address(strategy)),
                _airdropAmount,
                "!reul"
            );
        } else {
            assertGt(
                ERC20(strategy.EUL()).balanceOf(address(strategy)),
                (_airdropAmount / 5) - 5,
                "!eul"
            );
        }

        skip(strategy.profitMaxUnlockTime());

        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertApproxEqAbs(
            asset.balanceOf(user),
            balanceBefore + _amount,
            _amount / 10_000,
            "!final balance"
        );
    }

    function test_setters(
        address _auctionToken,
        uint256 _minAmountToAuction,
        bool _useAuctions,
        address _depositor
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

        vm.expectRevert("!management");
        strategy.setDepositor(_depositor);
        vm.prank(management);
        strategy.setDepositor(_depositor);
        assertEq(_depositor, strategy.depositor());
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

    function test_setAuction_validationFails() public {
        address mockAuction = address(0x123);

        // Create a mock auction contract that has incorrect want
        vm.mockCall(
            mockAuction,
            abi.encodeWithSelector(IAuction.want.selector),
            abi.encode(address(0xBEEF)) // Different from strategy.asset()
        );

        vm.mockCall(
            mockAuction,
            abi.encodeWithSelector(IAuction.receiver.selector),
            abi.encode(address(strategy))
        );

        // Test failure when want doesn't match asset
        vm.prank(management);
        vm.expectRevert("!want");
        strategy.setAuction(mockAuction);

        // Mock correct want but incorrect receiver
        vm.mockCall(
            mockAuction,
            abi.encodeWithSelector(IAuction.want.selector),
            abi.encode(address(asset))
        );

        vm.mockCall(
            mockAuction,
            abi.encodeWithSelector(IAuction.receiver.selector),
            abi.encode(address(0xBEEF)) // Different from strategy address
        );

        // Test failure when receiver doesn't match strategy
        vm.prank(management);
        vm.expectRevert("!receiver");
        strategy.setAuction(mockAuction);
    }

    function test_kickAuction_errors() public {
        // Test when auctions are disabled
        vm.prank(management);
        strategy.setUseAuctions(false);

        vm.prank(keeper);
        vm.expectRevert(bytes("!kick"));
        strategy.kickAuction(address(0xBEEF));

        // Test when auction address is zero
        vm.startPrank(management);
        strategy.setUseAuctions(true);
        strategy.setAuction(address(0)); // Set to zero address
        vm.stopPrank();

        vm.prank(keeper);
        vm.expectRevert(bytes("!kick"));
        strategy.kickAuction(address(0xBEEF));
    }

    function test_kickAuction_invalidToken() public {
        // Setup auction first
        address validAuction = _createAuction(strategy);

        vm.startPrank(management);
        strategy.setAuction(validAuction);
        strategy.setUseAuctions(true);
        vm.stopPrank();

        // Test kicking with asset as token (should fail)
        vm.prank(keeper);
        vm.expectRevert(bytes("!kick"));
        strategy.kickAuction(address(asset));

        // Test kicking with vault as token (should fail)
        vm.prank(keeper);
        vm.expectRevert(bytes("!kick"));
        strategy.kickAuction(address(vault));
    }

    function test_kickAuction_belowMinAmount(
        uint256 minAmount,
        uint256 belowMinAmount
    ) public {
        vm.assume(minAmount != 0);
        address mockToken = address(0xBEEF);
        belowMinAmount = bound(belowMinAmount, 0, minAmount - 1);

        // Setup auction
        address validAuction = _createAuction(strategy);
        // Setup token with balance
        vm.mockCall(
            mockToken,
            abi.encodeWithSelector(ERC20.balanceOf.selector, address(strategy)),
            abi.encode(belowMinAmount)
        );
        vm.mockCall(
            mockToken,
            abi.encodeWithSelector(
                ERC20.balanceOf.selector,
                address(validAuction)
            ),
            abi.encode(0)
        );

        vm.startPrank(management);
        strategy.setAuction(validAuction);
        strategy.setUseAuctions(true);
        strategy.setMinAmountToAuction(mockToken, minAmount);
        vm.stopPrank();

        // Test kicking with below min amount (should fail)
        vm.prank(keeper);
        vm.expectRevert(bytes("!kick"));
        strategy.kickAuction(mockToken);
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

    function test_tryKickAuction_fails() public {
        address mockToken = address(0xBEEF);
        address mockAuction = address(0x123);

        // Setup token balance
        vm.mockCall(
            mockToken,
            abi.encodeWithSelector(ERC20.balanceOf.selector, address(strategy)),
            abi.encode(100e18)
        );

        vm.mockCall(
            mockToken,
            abi.encodeWithSelector(ERC20.balanceOf.selector, mockAuction),
            abi.encode(0)
        );

        // Mock safe transfer to succeed
        vm.mockCall(
            mockToken,
            abi.encodeWithSelector(
                ERC20.transfer.selector,
                mockAuction,
                100e18
            ),
            abi.encode(true)
        );

        vm.mockCall(
            mockAuction,
            abi.encodeWithSelector(IAuction.want.selector),
            abi.encode(strategy.asset())
        );

        vm.mockCall(
            mockAuction,
            abi.encodeWithSelector(IAuction.receiver.selector),
            abi.encode(address(strategy))
        );

        vm.mockCall(
            mockAuction,
            abi.encodeWithSelector(IAuction.isActive.selector, asset),
            abi.encode(false)
        );

        vm.mockCall(
            mockAuction,
            abi.encodeWithSelector(IAuction.available.selector, asset),
            abi.encode(false)
        );

        // Mock auction.kick to revert
        vm.mockCallRevert(
            mockAuction,
            abi.encodeWithSelector(IAuction.kick.selector, mockToken),
            abi.encodeWithSignature("Error(string)", "kick failed")
        );

        vm.startPrank(management);
        strategy.setUseAuctions(true);
        strategy.setAuction(mockAuction);
        strategy.setMinAmountToAuction(mockToken, 1); // Set minimum to 1 wei
        vm.stopPrank();

        // Call kickAuction, which should fail
        vm.prank(keeper);
        vm.expectRevert();
        strategy.kickAuction(mockToken);
    }

    function test_constructor_zeroReulAddress() public {
        // Try to deploy with zero address for REUL, should revert
        vm.expectRevert(bytes("!rEUL"));
        new EulerCompounderStrategy(
            address(vault),
            "Test Strategy",
            address(0) // Zero address for REUL
        );
    }

    function test_depositor(uint256 _amount) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        address _depositor = address(0xDE905175);
        vm.label(_depositor, "depositor");

        vm.prank(management);
        strategy.setDepositor(_depositor);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, _depositor, _amount);
        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        // Earn Interest
        skip(1 days);

        vm.prank(_depositor);
        strategy.redeem(_amount, _depositor, _depositor);
        assertGe(asset.balanceOf(_depositor), _amount, "!final balance");

        airdrop(asset, user, _amount);
        vm.prank(user);
        asset.approve(address(strategy), _amount);

        vm.expectRevert();
        vm.prank(user);
        strategy.deposit(_amount, user);

        vm.prank(management);
        strategy.setDepositor(address(0));

        vm.prank(user);
        strategy.deposit(_amount, user);
    }
}
