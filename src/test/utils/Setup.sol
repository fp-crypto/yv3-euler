// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import "forge-std/console2.sol";
import {Test} from "forge-std/Test.sol";

import {ERC20, IStrategy} from "../../Strategy.sol";
import {StrategyFactory} from "../../StrategyFactory.sol";
import {IStrategyInterface} from "../../interfaces/IStrategyInterface.sol";
import {IAuctionFactory} from "../../interfaces/IAuctionFactory.sol";

// Inherit the events so they can be checked if desired.
import {IEvents} from "@tokenized-strategy/interfaces/IEvents.sol";

interface IFactory {
    function governance() external view returns (address);

    function set_protocol_fee_bps(uint16) external;

    function set_protocol_fee_recipient(address) external;
}

contract Setup is Test, IEvents {
    // Contract instances that we will use repeatedly.
    ERC20 public asset;
    IStrategy public vault;
    IStrategyInterface public strategy;

    StrategyFactory public strategyFactory;

    mapping(string => address) public tokenAddrs;

    // Addresses for different roles we will use repeatedly.
    address public user = address(10);
    address public keeper = address(4);
    address public management = address(1);
    address public performanceFeeRecipient = address(3);
    address public emergencyAdmin = address(5);

    // Address of the real deployed Factory
    address public factory;

    // Integer variables that will be used repeatedly.
    uint256 public decimals;
    uint256 public constant MAX_BPS = 10_000;

    uint256 public maxFuzzAmount = 10_000_000e6;
    uint256 public minFuzzAmount = 100e6;

    // Default profit max unlock time is set for 10 days
    uint256 public profitMaxUnlockTime = 10 days;

    function setUp() public virtual {
        _setTokenAddrs();

        // Set asset
        asset = ERC20(tokenAddrs["USDC.e"]);
        vault = IStrategyInterface(address(tokenAddrs["eUSDC.e"]));

        // Set decimals
        decimals = asset.decimals();

        strategyFactory = new StrategyFactory(
            management,
            performanceFeeRecipient,
            keeper,
            emergencyAdmin,
            tokenAddrs["rEUL"]
        );

        // Deploy strategy and set variables
        strategy = IStrategyInterface(setUpStrategy());

        factory = strategy.FACTORY();

        // label all the used addresses for traces
        vm.label(keeper, "keeper");
        vm.label(factory, "factory");
        vm.label(address(asset), "asset");
        vm.label(management, "management");
        vm.label(address(strategy), "strategy");
        vm.label(performanceFeeRecipient, "performanceFeeRecipient");
        vm.label(strategy.EUL(), "EUL");
        vm.label(strategy.REUL(), "REUL");
    }

    function setUpStrategy() public returns (address) {
        // we save the strategy as a IStrategyInterface to give it the needed interface
        IStrategyInterface _strategy = IStrategyInterface(
            address(
                strategyFactory.newStrategy(
                    address(vault),
                    "Tokenized Strategy"
                )
            )
        );

        vm.prank(management);
        _strategy.acceptManagement();

        return address(_strategy);
    }

    function depositIntoStrategy(
        IStrategyInterface _strategy,
        address _user,
        uint256 _amount
    ) public {
        vm.prank(_user);
        asset.approve(address(_strategy), _amount);

        vm.prank(_user);
        _strategy.deposit(_amount, _user);
    }

    function mintAndDepositIntoStrategy(
        IStrategyInterface _strategy,
        address _user,
        uint256 _amount
    ) public {
        airdrop(asset, _user, _amount);
        depositIntoStrategy(_strategy, _user, _amount);
    }

    // For checking the amounts in the strategy
    function checkStrategyTotals(
        IStrategyInterface _strategy,
        uint256 _totalAssets,
        uint256 _totalDebt,
        uint256 _totalIdle
    ) public {
        uint256 _assets = _strategy.totalAssets();
        uint256 _balance = ERC20(_strategy.asset()).balanceOf(
            address(_strategy)
        );
        uint256 _idle = _balance > _assets ? _assets : _balance;
        uint256 _debt = _assets - _idle;
        assertEq(_assets, _totalAssets, "!totalAssets");
        assertEq(_debt, _totalDebt, "!totalDebt");
        assertEq(_idle, _totalIdle, "!totalIdle");
        assertEq(_totalAssets, _totalDebt + _totalIdle, "!Added");
    }

    function airdrop(ERC20 _asset, address _to, uint256 _amount) public {
        uint256 balanceBefore = _asset.balanceOf(_to);
        deal(address(_asset), _to, balanceBefore + _amount);
    }

    function airdropREUL(address _to, uint256 _amount) public {
        ERC20 reul = ERC20(strategy.REUL());
        vm.prank(strategy.MERKL_DISTRIBUTOR());
        reul.transfer(_to, _amount);
    }

    function maxREUL() public view returns (uint256) {
        return ERC20(strategy.REUL()).balanceOf(strategy.MERKL_DISTRIBUTOR());
    }

    function setFees(uint16 _protocolFee, uint16 _performanceFee) public {
        address gov = IFactory(factory).governance();

        // Need to make sure there is a protocol fee recipient to set the fee.
        vm.prank(gov);
        IFactory(factory).set_protocol_fee_recipient(gov);

        vm.prank(gov);
        IFactory(factory).set_protocol_fee_bps(_protocolFee);

        vm.prank(management);
        strategy.setPerformanceFee(_performanceFee);
    }

    function _createAuction(
        IStrategyInterface _strategy
    ) internal returns (address) {
        return
            IAuctionFactory(0xCfA510188884F199fcC6e750764FAAbE6e56ec40)
                .createNewAuction(
                    _strategy.asset(),
                    address(_strategy),
                    management
                );
    }

    function _setTokenAddrs() internal {
        tokenAddrs["rEUL"] = 0x09E6cab47B7199b9d3839A2C40654f246d518a80;
        tokenAddrs["EUL"] = 0x8e15C8D399e86d4FD7B427D42f06c60cDD9397e7;
        tokenAddrs["wS"] = 0x039e2fB66102314Ce7b64Ce5Ce3E5183bc94aD38;
        tokenAddrs["USDC.e"] = 0x29219dd400f2Bf60E5a23d13Be72B486D4038894;
        tokenAddrs["eUSDC.e"] = 0x196F3C7443E940911EE2Bb88e019Fd71400349D9;
    }
}
