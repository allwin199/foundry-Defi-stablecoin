// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

contract OpenInvariantsTest is StdInvariant, Test {
    DecentralizedStableCoin dsc;
    DSCEngine dSCEngine;
    HelperConfig helperConfig;

    address weth;
    address wbtc;

    address public USER = makeAddr("user");

    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;

    uint256 public constant STARTING_USER_BALANCE = 1000e18;
    uint256 public constant STARTING_ERC20_BALANCE = 10e18;
    uint256 public constant AMOUNT_COLLATERAL = 10e18;
    uint256 public constant AMOUNT_DSC_To_Mint = 1e18;

    function setUp() external {
        DeployDSC deployer = new DeployDSC();
        (dsc, dSCEngine, helperConfig) = deployer.run();
        (weth, wbtc,,,) = helperConfig.activeNetworkConfig();

        targetContract(address(dSCEngine));
    }

    function invariant_protocolMustHaveMoreValueThanTotalSupply() public view {
        uint256 totalSupply = dsc.totalSupply();
        uint256 totalWethDeposited = IERC20(weth).balanceOf(address(dSCEngine));
        uint256 totalBtcDeposited = IERC20(wbtc).balanceOf(address(dSCEngine));

        uint256 wethUsdValue = dSCEngine.getUsdValue(weth, totalWethDeposited);
        uint256 wbtcUsdValue = dSCEngine.getUsdValue(wbtc, totalBtcDeposited);

        assert(wethUsdValue + wbtcUsdValue >= totalSupply);
    }
}
