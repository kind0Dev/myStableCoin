// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Test} from "forge-std/Test.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";

import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";
import {MSCEngine, AggregatorV3Interface} from "../../../src/MSCEngine.sol";
import {MyStableCoin} from "../../../src/MyStableCoin.sol";
import {console} from "forge-std/console.sol";

contract StopOnRevertHandler is Test {
    using EnumerableSet for EnumerableSet.AddressSet;

    // Deployed contracts to interact with
    MSCEngine public mscEngine;
    MyStableCoin public msc;
    MockV3Aggregator public ethUsdPriceFeed;
    MockV3Aggregator public btcUsdPriceFeed;
    ERC20Mock public weth;
    ERC20Mock public wbtc;

    // Ghost Variables
    uint96 public constant MAX_DEPOSIT_SIZE = type(uint96).max;

    address[] public userWithCollateralDeposited;
    uint256 public timesMintIsCalled;

    constructor(MSCEngine _mscEngine, MyStableCoin _msc) {
        mscEngine = _mscEngine;
        msc = _msc;

        address[] memory collateralTokens = mscEngine.getCollateralTokens();
        weth = ERC20Mock(collateralTokens[0]);
        wbtc = ERC20Mock(collateralTokens[1]);

        ethUsdPriceFeed = MockV3Aggregator(mscEngine.getCollateralTokenPriceFeed(address(weth)));
        btcUsdPriceFeed = MockV3Aggregator(mscEngine.getCollateralTokenPriceFeed(address(wbtc)));
    }

    // FUNCTOINS TO INTERACT WITH

    ///////////////
    // MSCEngine //
    ///////////////
    function depositCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        // must be more than 0
        amountCollateral = bound(amountCollateral, 1, MAX_DEPOSIT_SIZE);
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);

        vm.startPrank(msg.sender);
        collateral.mint(msg.sender, amountCollateral);
        collateral.approve(address(mscEngine), amountCollateral);
        mscEngine.depositCollateral(address(collateral), amountCollateral);
        vm.stopPrank();

        userWithCollateralDeposited.push(msg.sender);
    }

    function mintMsc(uint256 amountCollateral, uint256 addressSeed) public {
        if(userWithCollateralDeposited.length == 0) {
            return;
        }
        address sender = userWithCollateralDeposited[addressSeed % userWithCollateralDeposited.length];
        (uint256 totalMscMinted, uint256 collateralValueInUsd) = mscEngine.getAccountInformation(sender);

        int256 maxMscToMint = (int256(collateralValueInUsd) / 2) - int256(totalMscMinted);
        if (maxMscToMint < 0){
            return;
        }

        amountCollateral = bound(amountCollateral, 0, uint256(maxMscToMint));
        if (amountCollateral == 0){
            return;
        }
        
        vm.startPrank(sender);
        mscEngine.mintMsc(amountCollateral);
        vm.stopPrank();
        timesMintIsCalled++;
    }

    function redeemCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        uint256 maxCollateral = mscEngine.getCollateralBalanceOfUser(msg.sender, address(collateral));

        amountCollateral = bound(amountCollateral, 0, maxCollateral);
        if (amountCollateral == 0) {
            return;
        }
        mscEngine.redeemCollateral(address(collateral), amountCollateral);
    }

    function burnMsc(uint256 amountMsc) public {
        // Must burn more than 0
        amountMsc = bound(amountMsc, 0, msc.balanceOf(msg.sender));
        if (amountMsc == 0) {
            return;
        }
        mscEngine.burnMsc(amountMsc);
    }

    // Only the MSCEngine can mint MSC!
    // function mintMsc(uint256 amountMsc) public {
    //     amountMsc = bound(amountMsc, 0, MAX_DEPOSIT_SIZE);
    //     vm.prank(msc.owner());
    //     msc.mint(msg.sender, amountMsc);
    // }

    function liquidate(uint256 collateralSeed, address userToBeLiquidated, uint256 debtToCover) public {
        uint256 minHealthFactor = mscEngine.getMinHealthFactor();
        uint256 userHealthFactor = mscEngine.getHealthFactor(userToBeLiquidated);
        if (userHealthFactor >= minHealthFactor) {
            return;
        }
        debtToCover = bound(debtToCover, 1, uint256(type(uint96).max));
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        mscEngine.liquidate(address(collateral), userToBeLiquidated, debtToCover);
    }

    /////////////////////////////
    //  MyStableCoin //
    /////////////////////////////
    function transferMsc(uint256 amountMsc, address to) public {
        if (to == address(0)) {
            to = address(1);
        }
        amountMsc = bound(amountMsc, 0, msc.balanceOf(msg.sender));
        vm.prank(msg.sender);
        msc.transfer(to, amountMsc);
    }

    /////////////////////////////
    // Aggregator //
    /////////////////////////////
    function updateCollateralPrice(uint96 newPrice, uint256 collateralSeed) public {
        int256 intNewPrice = int256(uint256(newPrice));
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        MockV3Aggregator priceFeed = MockV3Aggregator(mscEngine.getCollateralTokenPriceFeed(address(collateral)));

        priceFeed.updateAnswer(intNewPrice);
    }

    /// Helper Functions
    function _getCollateralFromSeed(uint256 collateralSeed) private view returns (ERC20Mock) {
        if (collateralSeed % 2 == 0) {
            return weth;
        } else {
            return wbtc;
        }
    }
}