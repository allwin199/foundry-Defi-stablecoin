// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Test, console2} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

contract DSCEngineTest is Test {
    /*/////////////////////////////////////////////////////////////////////////////
                                STATE VARIABLES
    /////////////////////////////////////////////////////////////////////////////*/
    DecentralizedStableCoin dsc;
    DSCEngine dSCEngine;
    HelperConfig helperConfig;

    address weth;
    address wbtc;
    address wethUsdPriceFeedAddress;
    address wbtcUsdPriceFeedAddress;

    address public USER = makeAddr("user");

    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;

    uint256 public constant STARTING_USER_BALANCE = 1000e18;
    uint256 public constant STARTING_ERC20_BALANCE = 10e18;
    uint256 public constant AMOUNT_COLLATERAL = 10e18;
    uint256 public constant AMOUNT_DSC_To_Mint = 1e18;

    /*/////////////////////////////////////////////////////////////////////////////
                                    EVENTS
    /////////////////////////////////////////////////////////////////////////////*/
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event DSCMinted(address user, uint256 amount);

    function setUp() public {
        DeployDSC deployer = new DeployDSC();
        (dsc, dSCEngine, helperConfig) = deployer.run();
        (weth, wbtc, wethUsdPriceFeedAddress, wbtcUsdPriceFeedAddress,) = helperConfig.activeNetworkConfig();
        vm.deal(USER, STARTING_USER_BALANCE);
        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
        ERC20Mock(wbtc).mint(USER, STARTING_ERC20_BALANCE);
    }

    /*/////////////////////////////////////////////////////////////////////////////
                                CONSTRUCTOR TESTS
    /////////////////////////////////////////////////////////////////////////////*/
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function test_RevertsIf_TokenLength_DosentMatch_PriceFeeds() public {
        tokenAddresses.push(weth);
        tokenAddresses.push(wbtc);
        priceFeedAddresses.push(wethUsdPriceFeedAddress);

        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesAndPriceFeedAddresses_MustBeSameLength.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    /*/////////////////////////////////////////////////////////////////////////////
                                PRICEFEED TESTS
    /////////////////////////////////////////////////////////////////////////////*/

    function test_GetUsdValue_ForETH() public {
        uint256 ethAmount = 15e18;

        uint256 expectedUsd = 30000e18;
        uint256 actualUsd = dSCEngine.getUsdValue(weth, ethAmount);

        assertEq(expectedUsd, actualUsd, "getUsdValue");
    }

    function test_GetTokenAmountFromUsd() public {
        uint256 usdAmountInWei = 100e18;

        uint256 expectedWeth = 0.05e18;
        uint256 actualWeth = dSCEngine.getTokenAmountFromUsd(weth, usdAmountInWei);

        assertEq(expectedWeth, actualWeth, "getTokenFromUsd");
    }

    /*/////////////////////////////////////////////////////////////////////////////
                            DEPOSIT COLLATERAL TESTS
    /////////////////////////////////////////////////////////////////////////////*/

    function test_RevertsIf_CollateralDeposited_WithZeroAmount() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dSCEngine), AMOUNT_COLLATERAL);
        vm.expectRevert(DSCEngine.DSCEngine__Amount_MustBeMoreThanZero.selector);
        dSCEngine.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function test_RevertsIf_CollateralDeposited_WithWrongToken() public {
        ERC20Mock ranToken = new ERC20Mock();
        vm.startPrank(USER);

        vm.expectRevert(DSCEngine.DSCEngine__TokenNotAllowed.selector);
        dSCEngine.depositCollateral(address(ranToken), AMOUNT_COLLATERAL);

        vm.stopPrank();
    }

    modifier despositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dSCEngine), AMOUNT_COLLATERAL);
        dSCEngine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    function test_UserCanDepositCollateral_AndGetAccountInfo() public despositedCollateral {
        (uint256 totalDSCMinted, uint256 collateralValueInUsd) = dSCEngine.getAccountInformation(USER);

        uint256 expectedCollateralDepositedInUsd = dSCEngine.getUsdValue(weth, AMOUNT_COLLATERAL);
        uint256 expectedTotalDscMinted = 0;
        uint256 expectedDepositedAmount = dSCEngine.getTokenAmountFromUsd(weth, collateralValueInUsd);

        assertEq(collateralValueInUsd, expectedCollateralDepositedInUsd, "depositCollateral");
        assertEq(totalDSCMinted, expectedTotalDscMinted, "depositCollateral");
        assertEq(expectedDepositedAmount, AMOUNT_COLLATERAL);
    }

    function test_UserCanDepositCollateral_EmitsEvent() public {
        // Arrange
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dSCEngine), AMOUNT_COLLATERAL);

        // Act / Assert

        vm.expectEmit({emitter: address(dSCEngine)});
        emit CollateralDeposited(USER, weth, AMOUNT_COLLATERAL);
        dSCEngine.depositCollateral(weth, AMOUNT_COLLATERAL);

        vm.stopPrank();
    }

    function test_UserCanDepositCollateral_UpdatedDS() public despositedCollateral {
        // Assert
        uint256 expectedValue = dSCEngine.getTotalCollateralValueOfUser(USER, weth);
        assertEq(AMOUNT_COLLATERAL, expectedValue);
    }

    /*/////////////////////////////////////////////////////////////////////////////
                                    MINTDSC TESTS
    /////////////////////////////////////////////////////////////////////////////*/
    function test_RevertsIf_Minting_WithZeroAmount() public despositedCollateral {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__Amount_MustBeMoreThanZero.selector);
        dSCEngine.mintDsc(0);
        vm.stopPrank();
    }

    modifier MintedDSC() {
        vm.startPrank(USER);
        dSCEngine.mintDsc(AMOUNT_DSC_To_Mint);
        vm.stopPrank();
        _;
    }

    function test_MintDSC_UpdatesDS() public despositedCollateral MintedDSC {
        uint256 expectedDSCMinted = dSCEngine.getDscMintedByUser(USER);

        assertEq(expectedDSCMinted, AMOUNT_DSC_To_Mint);
    }

    function test_MintDSC_EmitsEvent() public despositedCollateral {
        vm.startPrank(USER);

        vm.expectEmit({emitter: address(dSCEngine)});
        emit DSCMinted(USER, AMOUNT_DSC_To_Mint);
        dSCEngine.mintDsc(AMOUNT_DSC_To_Mint);

        vm.stopPrank();
    }
}
