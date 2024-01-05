// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import {DeployMSC} from "../../script/DeployMSC.s.sol";
import {MSCEngine} from "../../src/MSCEngine.sol";
import {MyStableCoin} from "../../src/MyStableCoin.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";
// import {MockMoreDebtMSC} from "../mocks/MockMoreDebtMSC.sol";
// import {MockFailedMintMSC} from "../mocks/MockFailedMintMSC.sol";
// import {MockFailedTransferFrom} from "../mocks/MockFailedTransferFrom.sol";
// import {MockFailedTransfer} from "../mocks/MockFailedTransfer.sol";
import {Test, console} from "forge-std/Test.sol";
import {StdCheats} from "forge-std/StdCheats.sol";

contract MSCEngineTest is StdCheats, Test {
    event CollateralRedeemed(address indexed redeemFrom, address indexed redeemTo, address token, uint256 amount); // if redeemFrom != redeemedTo, then it was liquidated

    MSCEngine public msce;
    MyStableCoin public msc;
    HelperConfig public helperConfig;

    address public ethUsdPriceFeed;
    address public btcUsdPriceFeed;
    address public weth;
    address public wbtc;
    uint256 public deployerKey;

    uint256 amountCollateral = 10 ether;
    uint256 amountToMint = 100 ether;
    address public user = address(1);

    uint256 public constant STARTING_USER_BALANCE = 10 ether;
    uint256 public constant MIN_HEALTH_FACTOR = 1e18;
    uint256 public constant LIQUIDATION_THRESHOLD = 50;

    // Liquidation
    address public liquidator = makeAddr("liquidator");
    uint256 public collateralToCover = 20 ether;

    function setUp() external {
        DeployMSC deployer = new DeployMSC();
        (msc, msce, helperConfig) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc, deployerKey) = helperConfig.activeNetworkConfig();
        if (block.chainid == 31337) {
            vm.deal(user, STARTING_USER_BALANCE);
        }
        // Should we put our integration tests here?
        // else {
        //     user = vm.addr(deployerKey);
        //     ERC20Mock mockErc = new ERC20Mock("MOCK", "MOCK", user, 100e18);
        //     MockV3Aggregator aggregatorMock = new MockV3Aggregator(
        //         helperConfig.DECIMALS(),
        //         helperConfig.ETH_USD_PRICE()
        //     );
        //     vm.etch(weth, address(mockErc).code);
        //     vm.etch(wbtc, address(mockErc).code);
        //     vm.etch(ethUsdPriceFeed, address(aggregatorMock).code);
        //     vm.etch(btcUsdPriceFeed, address(aggregatorMock).code);
        // }
        ERC20Mock(weth).mint(user, STARTING_USER_BALANCE);
        ERC20Mock(wbtc).mint(user, STARTING_USER_BALANCE);
    }

    ///////////////////////
    // Constructor Tests //
    ///////////////////////
    address[] public tokenAddresses;
    address[] public feedAddresses;

    function testRevertsIfTokenLengthDoesntMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        feedAddresses.push(ethUsdPriceFeed);
        feedAddresses.push(btcUsdPriceFeed);

        vm.expectRevert(MSCEngine.MSCEngine__TokenAddressesAndPriceFeedAddressesAmountsDontMatch.selector);
        new MSCEngine(tokenAddresses, feedAddresses, address(msc));
    }

    //////////////////
    // Price Tests //
    //////////////////

    function testGetTokenAmountFromUsd() public {
        // If we want $100 of WETH @ $2000/WETH, that would be 0.05 WETH
        uint256 expectedWeth = 0.05 ether;
        uint256 amountWeth = msce.getTokenAmountFromUsd(weth, 100 ether);
        assertEq(amountWeth, expectedWeth);
    }

    function testGetUsdValue() public {
        uint256 ethAmount = 15e18;
        // 15e18 ETH * $2000/ETH = $30,000e18
        uint256 expectedUsd = 30000e18;
        uint256 usdValue = msce.getUsdValue(weth, ethAmount);
        assertEq(usdValue, expectedUsd);
    }

    ///////////////////////////////////////
    // depositCollateral Tests //
    ///////////////////////////////////////

    // this test needs it's own setup
    function testRevertsIfTransferFromFails() public {
        // Arrange - Setup
        address owner = msg.sender;
        vm.prank(owner);
        MockFailedTransferFrom mockMsc = new MockFailedTransferFrom();
        tokenAddresses = [address(mockMsc)];
        feedAddresses = [ethUsdPriceFeed];
        vm.prank(owner);
        MSCEngine mockMsce = new MSCEngine(
            tokenAddresses,
            feedAddresses,
            address(mockMsc)
        );
        mockMsc.mint(user, amountCollateral);

        vm.prank(owner);
        mockMsc.transferOwnership(address(mockMsce));
        // Arrange - User
        vm.startPrank(user);
        ERC20Mock(address(mockMsc)).approve(address(mockMsce), amountCollateral);
        // Act / Assert
        vm.expectRevert(MSCEngine.MSCEngine__TransferFailed.selector);
        mockMsce.depositCollateral(address(mockMsc), amountCollateral);
        vm.stopPrank();
    }

    function testRevertsIfCollateralZero() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(msce), amountCollateral);

        vm.expectRevert(MSCEngine.MSCEngine__NeedsMoreThanZero.selector);
        msce.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock randToken = new ERC20Mock("RAN", "RAN", user, 100e18);
        vm.startPrank(user);
        vm.expectRevert(abi.encodeWithSelector(MSCEngine.MSCEngine__TokenNotAllowed.selector, address(randToken)));
        msce.depositCollateral(address(randToken), amountCollateral);
        vm.stopPrank();
    }

    modifier depositedCollateral() {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(msce), amountCollateral);
        msce.depositCollateral(weth, amountCollateral);
        vm.stopPrank();
        _;
    }

    function testCanDepositCollateralWithoutMinting() public depositedCollateral {
        uint256 userBalance = msc.balanceOf(user);
        assertEq(userBalance, 0);
    }

    function testCanDepositedCollateralAndGetAccountInfo() public depositedCollateral {
        (uint256 totalMscMinted, uint256 collateralValueInUsd) = msce.getAccountInformation(user);
        uint256 expectedDepositedAmount = msce.getTokenAmountFromUsd(weth, collateralValueInUsd);
        assertEq(totalMscMinted, 0);
        assertEq(expectedDepositedAmount, amountCollateral);
    }

    ///////////////////////////////////////
    // depositCollateralAndMintMsc Tests //
    ///////////////////////////////////////

    function testRevertsIfMintedMscBreaksHealthFactor() public {
        (, int256 price,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();
        amountToMint = (amountCollateral * (uint256(price) * msce.getAdditionalFeedPrecision())) / msce.getPrecision();
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(msce), amountCollateral);

        uint256 expectedHealthFactor =
            msce.calculateHealthFactor(amountToMint, msce.getUsdValue(weth, amountCollateral));
        vm.expectRevert(abi.encodeWithSelector(MSCEngine.MSCEngine__BreaksHealthFactor.selector, expectedHealthFactor));
        msce.depositCollateralAndMintMsc(weth, amountCollateral, amountToMint);
        vm.stopPrank();
    }

    modifier depositedCollateralAndMintedMsc() {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(msce), amountCollateral);
        msce.depositCollateralAndMintMsc(weth, amountCollateral, amountToMint);
        vm.stopPrank();
        _;
    }

    function testCanMintWithDepositedCollateral() public depositedCollateralAndMintedMsc {
        uint256 userBalance = msc.balanceOf(user);
        assertEq(userBalance, amountToMint);
    }

    ///////////////////////////////////
    // mintMsc Tests //
    ///////////////////////////////////
    // This test needs it's own custom setup
    function testRevertsIfMintFails() public {
        // Arrange - Setup
        MockFailedMintMSC mockMsc = new MockFailedMintMSC();
        tokenAddresses = [weth];
        feedAddresses = [ethUsdPriceFeed];
        address owner = msg.sender;
        vm.prank(owner);
        MSCEngine mockMsce = new MSCEngine(
            tokenAddresses,
            feedAddresses,
            address(mockMsc)
        );
        mockMsc.transferOwnership(address(mockMsce));
        // Arrange - User
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(mockMsce), amountCollateral);

        vm.expectRevert(MSCEngine.MSCEngine__MintFailed.selector);
        mockMsce.depositCollateralAndMintMsc(weth, amountCollateral, amountToMint);
        vm.stopPrank();
    }

    function testRevertsIfMintAmountIsZero() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(msce), amountCollateral);
        msce.depositCollateralAndMintMsc(weth, amountCollateral, amountToMint);
        vm.expectRevert(MSCEngine.MSCEngine__NeedsMoreThanZero.selector);
        msce.mintMsc(0);
        vm.stopPrank();
    }

    function testRevertsIfMintAmountBreaksHealthFactor() public depositedCollateral{
        // 0xe580cc6100000000000000000000000000000000000000000000000006f05b59d3b20000
        // 0xe580cc6100000000000000000000000000000000000000000000003635c9adc5dea00000
        (, int256 price,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();
        amountToMint = (amountCollateral * (uint256(price) * msce.getAdditionalFeedPrecision())) / msce.getPrecision();

        vm.startPrank(user);
        uint256 expectedHealthFactor =
            msce.calculateHealthFactor(amountToMint, msce.getUsdValue(weth, amountCollateral));
        vm.expectRevert(abi.encodeWithSelector(MSCEngine.MSCEngine__BreaksHealthFactor.selector, expectedHealthFactor));
        msce.mintMsc(amountToMint);
        vm.stopPrank();
    }

    function testCanMintMsc() public depositedCollateral {
        vm.prank(user);
        msce.mintMsc(amountToMint);

        uint256 userBalance = msc.balanceOf(user);
        assertEq(userBalance, amountToMint);
    }

    ///////////////////////////////////
    // burnMsc Tests //
    ///////////////////////////////////

    function testRevertsIfBurnAmountIsZero() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(msce), amountCollateral);
        msce.depositCollateralAndMintMsc(weth, amountCollateral, amountToMint);
        vm.expectRevert(MSCEngine.MSCEngine__NeedsMoreThanZero.selector);
        msce.burnMsc(0);
        vm.stopPrank();
    }

    function testCantBurnMoreThanUserHas() public {
        vm.prank(user);
        vm.expectRevert();
        msce.burnMsc(1);
    }

    function testCanBurnMsc() public depositedCollateralAndMintedMsc {
        vm.startPrank(user);
        msc.approve(address(msce), amountToMint);
        msce.burnMsc(amountToMint);
        vm.stopPrank();

        uint256 userBalance = msc.balanceOf(user);
        assertEq(userBalance, 0);
    }

    ///////////////////////////////////
    // redeemCollateral Tests //
    //////////////////////////////////

    // this test needs it's own setup
    function testRevertsIfTransferFails() public {
        // Arrange - Setup
        address owner = msg.sender;
        vm.prank(owner);
        MockFailedTransfer mockMsc = new MockFailedTransfer();
        tokenAddresses = [address(mockMsc)];
        feedAddresses = [ethUsdPriceFeed];
        vm.prank(owner);
        MSCEngine mockMsce = new MSCEngine(
            tokenAddresses,
            feedAddresses,
            address(mockMsc)
        );
        mockMsc.mint(user, amountCollateral);

        vm.prank(owner);
        mockMsc.transferOwnership(address(mockMsce));
        // Arrange - User
        vm.startPrank(user);
        ERC20Mock(address(mockMsc)).approve(address(mockMsce), amountCollateral);
        // Act / Assert
        mockMsce.depositCollateral(address(mockMsc), amountCollateral);
        vm.expectRevert(MSCEngine.MSCEngine__TransferFailed.selector);
        mockMsce.redeemCollateral(address(mockMsc), amountCollateral);
        vm.stopPrank();
    }

    function testRevertsIfRedeemAmountIsZero() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(msce), amountCollateral);
        msce.depositCollateralAndMintMsc(weth, amountCollateral, amountToMint);
        vm.expectRevert(MSCEngine.MSCEngine__NeedsMoreThanZero.selector);
        msce.redeemCollateral(weth, 0);
        vm.stopPrank();
    }

    function testCanRedeemCollateral() public depositedCollateral {
        vm.startPrank(user);
        msce.redeemCollateral(weth, amountCollateral);
        uint256 userBalance = ERC20Mock(weth).balanceOf(user);
        assertEq(userBalance, amountCollateral);
        vm.stopPrank();
    }

    function testEmitCollateralRedeemedWithCorrectArgs() public depositedCollateral {
        vm.expectEmit(true, true, true, true, address(msce));
        emit CollateralRedeemed(user, user, weth, amountCollateral);
        vm.startPrank(user);
        msce.redeemCollateral(weth, amountCollateral);
        vm.stopPrank();
    }
    ///////////////////////////////////
    // redeemCollateralForMsc Tests //
    //////////////////////////////////

    function testMustRedeemMoreThanZero() public depositedCollateralAndMintedMsc {
        vm.startPrank(user);
        msc.approve(address(msce), amountToMint);
        vm.expectRevert(MSCEngine.MSCEngine__NeedsMoreThanZero.selector);
        msce.redeemCollateralForMsc(weth, 0, amountToMint);
        vm.stopPrank();
    }

    function testCanRedeemDepositedCollateral() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(msce), amountCollateral);
        msce.depositCollateralAndMintMsc(weth, amountCollateral, amountToMint);
        msc.approve(address(msce), amountToMint);
        msce.redeemCollateralForMsc(weth, amountCollateral, amountToMint);
        vm.stopPrank();

        uint256 userBalance = msc.balanceOf(user);
        assertEq(userBalance, 0);
    }

    ////////////////////////
    // healthFactor Tests //
    ////////////////////////

    function testProperlyReportsHealthFactor() public depositedCollateralAndMintedMsc {
        uint256 expectedHealthFactor = 100 ether;
        uint256 healthFactor = msce.getHealthFactor(user);
        // $100 minted with $20,000 collateral at 50% liquidation threshold
        // means that we must have $200 collatareral at all times.
        // 20,000 * 0.5 = 10,000
        // 10,000 / 100 = 100 health factor
        assertEq(healthFactor, expectedHealthFactor);
    }

    function testHealthFactorCanGoBelowOne() public depositedCollateralAndMintedMsc {
        int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18
        // Rememeber, we need $200 at all times if we have $100 of debt

        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);

        uint256 userHealthFactor = msce.getHealthFactor(user);
        // 180*50 (LIQUIDATION_THRESHOLD) / 100 (LIQUIDATION_PRECISION) / 100 (PRECISION) = 90 / 100 (totalMscMinted) = 0.9
        assert(userHealthFactor == 0.9 ether);
    }

    ///////////////////////
    // Liquidation Tests //
    ///////////////////////

    // This test needs it's own setup
    function testMustImproveHealthFactorOnLiquidation() public {
        // Arrange - Setup
        MockMoreDebtMSC mockMsc = new MockMoreDebtMSC(ethUsdPriceFeed);
        tokenAddresses = [weth];
        feedAddresses = [ethUsdPriceFeed];
        address owner = msg.sender;
        vm.prank(owner);
        MSCEngine mockMsce = new MSCEngine(
            tokenAddresses,
            feedAddresses,
            address(mockMsc)
        );
        mockMsc.transferOwnership(address(mockMsce));
        // Arrange - User
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(mockMsce), amountCollateral);
        mockMsce.depositCollateralAndMintMsc(weth, amountCollateral, amountToMint);
        vm.stopPrank();

        // Arrange - Liquidator
        collateralToCover = 1 ether;
        ERC20Mock(weth).mint(liquidator, collateralToCover);

        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(mockMsce), collateralToCover);
        uint256 debtToCover = 10 ether;
        mockMsce.depositCollateralAndMintMsc(weth, collateralToCover, amountToMint);
        mockMsc.approve(address(mockMsce), debtToCover);
        // Act
        int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);
        // Act/Assert
        vm.expectRevert(MSCEngine.MSCEngine__HealthFactorNotImproved.selector);
        mockMsce.liquidate(weth, user, debtToCover);
        vm.stopPrank();
    }

    function testCantLiquidateGoodHealthFactor() public depositedCollateralAndMintedMsc {
        ERC20Mock(weth).mint(liquidator, collateralToCover);

        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(msce), collateralToCover);
        msce.depositCollateralAndMintMsc(weth, collateralToCover, amountToMint);
        msc.approve(address(msce), amountToMint);

        vm.expectRevert(MSCEngine.MSCEngine__HealthFactorOk.selector);
        msce.liquidate(weth, user, amountToMint);
        vm.stopPrank();
    }

    modifier liquidated() {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(msce), amountCollateral);
        msce.depositCollateralAndMintMsc(weth, amountCollateral, amountToMint);
        vm.stopPrank();
        int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18

        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);
        uint256 userHealthFactor = msce.getHealthFactor(user);

        ERC20Mock(weth).mint(liquidator, collateralToCover);

        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(msce), collateralToCover);
        msce.depositCollateralAndMintMsc(weth, collateralToCover, amountToMint);
        msc.approve(address(msce), amountToMint);
        msce.liquidate(weth, user, amountToMint); // We are covering their whole debt
        vm.stopPrank();
        _;
    }

    function testLiquidationPayoutIsCorrect() public liquidated {
        uint256 liquidatorWethBalance = ERC20Mock(weth).balanceOf(liquidator);
        uint256 expectedWeth = msce.getTokenAmountFromUsd(weth, amountToMint)
            + (msce.getTokenAmountFromUsd(weth, amountToMint) / msce.getLiquidationBonus());
        uint256 hardCodedExpected = 6111111111111111110;
        assertEq(liquidatorWethBalance, hardCodedExpected);
        assertEq(liquidatorWethBalance, expectedWeth);
    }

    function testUserStillHasSomeEthAfterLiquidation() public liquidated {
        // Get how much WETH the user lost
        uint256 amountLiquidated = msce.getTokenAmountFromUsd(weth, amountToMint)
            + (msce.getTokenAmountFromUsd(weth, amountToMint) / msce.getLiquidationBonus());

        uint256 usdAmountLiquidated = msce.getUsdValue(weth, amountLiquidated);
        uint256 expectedUserCollateralValueInUsd = msce.getUsdValue(weth, amountCollateral) - (usdAmountLiquidated);

        (, uint256 userCollateralValueInUsd) = msce.getAccountInformation(user);
        uint256 hardCodedExpectedValue = 70000000000000000020;
        assertEq(userCollateralValueInUsd, expectedUserCollateralValueInUsd);
        assertEq(userCollateralValueInUsd, hardCodedExpectedValue);
    }

    function testLiquidatorTakesOnUsersDebt() public liquidated {
        (uint256 liquidatorMscMinted,) = msce.getAccountInformation(liquidator);
        assertEq(liquidatorMscMinted, amountToMint);
    }

    function testUserHasNoMoreDebt() public liquidated {
        (uint256 userMscMinted,) = msce.getAccountInformation(user);
        assertEq(userMscMinted, 0);
    }

    ///////////////////////////////////
    // View & Pure Function Tests //
    //////////////////////////////////
    function testGetCollateralTokenPriceFeed() public {
        address priceFeed = msce.getCollateralTokenPriceFeed(weth);
        assertEq(priceFeed, ethUsdPriceFeed);
    }

    function testGetCollateralTokens() public {
        address[] memory collateralTokens = msce.getCollateralTokens();
        assertEq(collateralTokens[0], weth);
    }

    function testGetMinHealthFactor() public {
        uint256 minHealthFactor = msce.getMinHealthFactor();
        assertEq(minHealthFactor, MIN_HEALTH_FACTOR);
    }

    function testGetLiquidationThreshold() public {
        uint256 liquidationThreshold = msce.getLiquidationThreshold();
        assertEq(liquidationThreshold, LIQUIDATION_THRESHOLD);
    }

    function testGetAccountCollateralValueFromInformation() public depositedCollateral {
        (, uint256 collateralValue) = msce.getAccountInformation(user);
        uint256 expectedCollateralValue = msce.getUsdValue(weth, amountCollateral);
        assertEq(collateralValue, expectedCollateralValue);
    }

    function testGetCollateralBalanceOfUser() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(msce), amountCollateral);
        msce.depositCollateral(weth, amountCollateral);
        vm.stopPrank();
        uint256 collateralBalance = msce.getCollateralBalanceOfUser(user, weth);
        assertEq(collateralBalance, amountCollateral);
    }

    function testGetAccountCollateralValue() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(msce), amountCollateral);
        msce.depositCollateral(weth, amountCollateral);
        vm.stopPrank();
        uint256 collateralValue = msce.getAccountCollateralValue(user);
        uint256 expectedCollateralValue = msce.getUsdValue(weth, amountCollateral);
        assertEq(collateralValue, expectedCollateralValue);
    }

    function testGetMsc() public {
        address mscAddress = msce.getMsc();
        assertEq(mscAddress, address(msc));
    }

    function testLiquidationPrecision() public {
        uint256 expectedLiquidationPrecision = 100;
        uint256 actualLiquidationPrecision = msce.getLiquidationPrecision();
        assertEq(actualLiquidationPrecision, expectedLiquidationPrecision);
    }

    // How do we adjust our invariant tests for this?
    // function testInvariantBreaks() public depositedCollateralAndMintedMsc {
    //     MockV3Aggregator(ethUsdPriceFeed).updateAnswer(0);

    //     uint256 totalSupply = msc.totalSupply();
    //     uint256 wethDeposted = ERC20Mock(weth).balanceOf(address(msce));
    //     uint256 wbtcDeposited = ERC20Mock(wbtc).balanceOf(address(msce));

    //     uint256 wethValue = msce.getUsdValue(weth, wethDeposted);
    //     uint256 wbtcValue = msce.getUsdValue(wbtc, wbtcDeposited);

    //     console.log("wethValue: %s", wethValue);
    //     console.log("wbtcValue: %s", wbtcValue);
    //     console.log("totalSupply: %s", totalSupply);

    //     assert(wethValue + wbtcValue >= totalSupply);
    // }
}