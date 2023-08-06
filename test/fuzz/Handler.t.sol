// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Test, console2, console} from "forge-std/Test.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";

contract Handler is Test {
    DecentralizedStableCoin dsc;
    DSCEngine dSCEngine;
    HelperConfig helperConfig;

    ERC20Mock weth;
    ERC20Mock wbtc;

    address[] public usersWithCollateralDeposited;

    uint256 MAX_DEPOSIT_SIZE = type(uint96).max;

    constructor(DSCEngine _dSCEngine, DecentralizedStableCoin _dsc) {
        dSCEngine = _dSCEngine;
        dsc = _dsc;

        address[] memory collateralTokens = dSCEngine.getCollateralTokens();

        weth = ERC20Mock(collateralTokens[0]);
        wbtc = ERC20Mock(collateralTokens[1]);
    }

    function depositCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        amountCollateral = bound(amountCollateral, 1, MAX_DEPOSIT_SIZE);

        vm.startPrank(msg.sender);

        collateral.mint(msg.sender, amountCollateral);
        collateral.approve(address(dSCEngine), amountCollateral);

        dSCEngine.depositCollateral(address(collateral), amountCollateral);

        vm.stopPrank();

        usersWithCollateralDeposited.push(msg.sender);
    }

    function mintDsc(uint256 amountDsc, uint256 addressSeed) public {
        if (usersWithCollateralDeposited.length == 0) {
            return;
        }
        address sender = usersWithCollateralDeposited[addressSeed % usersWithCollateralDeposited.length];
        (uint256 totalDSCMinted, uint256 collateralValueInUsd) = dSCEngine.getAccountInformation(sender);

        console2.log("maxDscToMint ", totalDSCMinted, collateralValueInUsd);

        int256 maxDscToMint = int256(collateralValueInUsd / 2) - int256(totalDSCMinted);

        if (maxDscToMint < 0) {
            return;
        }

        amountDsc = bound(amountDsc, 0, uint256(maxDscToMint));

        if (amountDsc == 0) {
            return;
        }

        vm.startPrank(sender);

        dSCEngine.mintDsc(amountDsc);
        vm.stopPrank();
    }

    function redeemCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);

        uint256 maxCollateralToReddem = dSCEngine.getTotalCollateralValueOfUser(address(collateral), msg.sender);
        console2.log("maxCollateralToReddem ", maxCollateralToReddem);

        amountCollateral = bound(amountCollateral, 0, maxCollateralToReddem);

        if (amountCollateral == 0) {
            return;
        }
        dSCEngine.redeemCollateral(address(collateral), amountCollateral);
    }

    // Helper Functions
    function _getCollateralFromSeed(uint256 _collateralSeed) private view returns (ERC20Mock) {
        if (_collateralSeed % 2 == 0) {
            return weth;
        }
        return wbtc;
    }
}
