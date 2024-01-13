// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

// What are our invariants?
// 1. The total supply of MSC should be less than the total value of colleteral
// 2. Getter view functions should never revert <- evergreen invariant




import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {MSCEngine} from "../../../src/MSCEngine.sol";
import {MyStableCoin} from "../../../src/MyStableCoin.sol";
import {HelperConfig} from "../../../script/HelperConfig.s.sol";
import {DeployMSC} from "../../../script/DeployMSC.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import {StopOnRevertHandler} from "./StopOnRevertHandler.t.sol";
import {console} from "forge-std/console.sol";

contract StopOnRevertInvariants is StdInvariant, Test {
    MSCEngine public msce;
    MyStableCoin public msc;
    HelperConfig public helperConfig;

    address public ethUsdPriceFeed;
    address public btcUsdPriceFeed;
    address public weth;
    address public wbtc;

    uint256 amountCollateral = 10 ether;
    uint256 amountToMint = 100 ether;

    uint256 public constant STARTING_USER_BALANCE = 10 ether;
    address public constant USER = address(1);
    uint256 public constant MIN_HEALTH_FACTOR = 1e18;
    uint256 public constant LIQUIDATION_THRESHOLD = 50;

    // Liquidation
    address public liquidator = makeAddr("liquidator");
    uint256 public collateralToCover = 20 ether;

    StopOnRevertHandler public handler;

    function setUp() external {
        DeployMSC deployer = new DeployMSC();
        (msc, msce, helperConfig) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc,) = helperConfig.activeNetworkConfig();
       handler = new StopOnRevertHandler(msce, msc);
        targetContract(address(handler));
        //targetContract(address(ethUsdPriceFeed)); Why can't we just do this?
    }

    function invariant_protocolMustHaveMoreValueThatTotalSupplyDollars() public view {
        // get the value of all the collateral in the protocol
        // compare it to all debt (msc)
        uint256 totalSupply = msc.totalSupply();
        uint256 wethDeposted = ERC20Mock(weth).balanceOf(address(msce));
        uint256 wbtcDeposited = ERC20Mock(wbtc).balanceOf(address(msce));

        uint256 wethValue = msce.getUsdValue(weth, wethDeposted);
        uint256 wbtcValue = msce.getUsdValue(wbtc, wbtcDeposited);

        console.log("wethValue: %s", wethValue);
        console.log("wbtcValue: %s", wbtcValue);
        console.log("total supply: ", totalSupply);
        console.log("times mint is called: ", handler.timesMintIsCalled());

        assert(wethValue + wbtcValue >= totalSupply);
    }

    function invariant_gettersCantRevert() public view {
        msce.getAdditionalFeedPrecision();
        msce.getCollateralTokens();
        msce.getLiquidationBonus();
        msce.getLiquidationBonus();
        msce.getLiquidationThreshold();
        msce.getMinHealthFactor();
        msce.getPrecision();
        msce.getMsc();
        // msce.getTokenAmountFromUsd();
        // msce.getCollateralTokenPriceFeed();
        // msce.getCollateralBalanceOfUser();
        // getAccountCollateralValue();
    }
}