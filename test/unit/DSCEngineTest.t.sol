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
    DecentralizedStableCoin dsc;
    DSCEngine dSCEngine;
    HelperConfig helperConfig;

    address weth;
    address wbtc;
    address wethUsdPriceFeedAddress;
    address wbtcUsdPriceFeedAddress;

    address public USER = makeAddr("user");

    uint256 private constant PRECISION = 1e10;

    uint256 public constant STARTING_USER_BALANCE = 1000e18;
    uint256 public constant STARTING_ERC20_BALANCE = 10e18;
    uint256 public constant AMOUNT_COLLATERAL = 10e18;

    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);

    function setUp() public {
        DeployDSC deployer = new DeployDSC();
        (dsc, dSCEngine, helperConfig) = deployer.run();
        (weth, wbtc, wethUsdPriceFeedAddress, wbtcUsdPriceFeedAddress,) = helperConfig.activeNetworkConfig();
        vm.deal(USER, STARTING_USER_BALANCE);
        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
        ERC20Mock(wbtc).mint(USER, STARTING_ERC20_BALANCE);
    }

    /*/////////////////////////////////////////////////////////////////////////////
                                PRICEFEED TESTS
    /////////////////////////////////////////////////////////////////////////////*/

    function test_getUsdValue_ForETH() public {
        uint256 ethAmount = 15e18;
        AggregatorV3Interface priceFeed = AggregatorV3Interface(wethUsdPriceFeedAddress);
        (, int256 price,,,) = priceFeed.latestRoundData();
        uint256 expectedUsd = (ethAmount * (uint256(price) * PRECISION)) / 1e18;
        uint256 actualUsd = dSCEngine.getUsdValue(weth, ethAmount);
        assertEq(actualUsd, expectedUsd);
    }

    function test_getUsdValue_ForBTC() public {
        uint256 amount = 15e18;
        AggregatorV3Interface priceFeed = AggregatorV3Interface(wbtcUsdPriceFeedAddress);
        (, int256 price,,,) = priceFeed.latestRoundData();
        uint256 expectedUsd = (amount * (uint256(price) * PRECISION)) / 1e18;
        uint256 actualUsd = dSCEngine.getUsdValue(wbtc, amount);

        assertEq(actualUsd, expectedUsd);
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
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dSCEngine), AMOUNT_COLLATERAL);
        vm.expectRevert(DSCEngine.DSCEngine__TokenNotAllowed.selector);
        dSCEngine.depositCollateral(address(0), 1e18);
        vm.stopPrank();
    }

    function test_userCanDepositCollateralETH_EmitsEvent() public {
        // Arrange
        vm.startPrank(USER);
        uint256 depositAmount = 1e9;

        // Act / Assert
        ERC20Mock(weth).approve(address(dSCEngine), AMOUNT_COLLATERAL);
        vm.expectEmit({emitter: address(dSCEngine)});
        emit CollateralDeposited(USER, weth, depositAmount);
        dSCEngine.depositCollateral(weth, depositAmount);
        vm.stopPrank();
    }

    function test_userCanDepositCollateralBTC_EmitsEvent() public {
        // Arrange
        vm.startPrank(USER);
        uint256 depositAmount = 1e9;

        // Act / Assert
        ERC20Mock(wbtc).approve(address(dSCEngine), AMOUNT_COLLATERAL);
        vm.expectEmit({emitter: address(dSCEngine)});
        emit CollateralDeposited(USER, wbtc, depositAmount);
        dSCEngine.depositCollateral(wbtc, depositAmount);
        vm.stopPrank();
    }

    function test_userCanDepositCollateralETH_UpdatedDS() public {
        // Arrange
        vm.startPrank(USER);
        uint256 depositAmount = 1e9;

        // Act
        ERC20Mock(weth).approve(address(dSCEngine), AMOUNT_COLLATERAL);
        dSCEngine.depositCollateral(weth, depositAmount);

        // Assert
        uint256 expectedValue = dSCEngine.getTotalCollateralValueOfUser(USER, weth);
        assertEq(depositAmount, expectedValue);
        vm.stopPrank();
    }

    function test_userCanDepositCollateralBTC_UpdatedDS() public {
        // Arrange
        vm.startPrank(USER);
        uint256 depositAmount = 1e9;

        // Act
        ERC20Mock(wbtc).approve(address(dSCEngine), AMOUNT_COLLATERAL);
        dSCEngine.depositCollateral(wbtc, depositAmount);

        // Assert
        uint256 expectedValue = dSCEngine.getTotalCollateralValueOfUser(USER, wbtc);
        assertEq(depositAmount, expectedValue);
        vm.stopPrank();
    }

    /*/////////////////////////////////////////////////////////////////////////////
                                    MINT DSC TESTS
    /////////////////////////////////////////////////////////////////////////////*/
    function test_RevertsIf_Minting_WithZeroAmount() public {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__Amount_MustBeMoreThanZero.selector);
        dSCEngine.mintDsc(0);
        vm.stopPrank();
    }
}
