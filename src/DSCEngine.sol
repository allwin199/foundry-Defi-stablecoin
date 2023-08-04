// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";

/// @title DSCEngine
/// @author Prince Allwin
/// @notice The system is designed to be as minimal as possible, and have the tokens maintain a 1 token == $1 peg.
/// This stable coin has the properties:
/// 1. Exogeneous Collateral
/// 2. Dollar Pegged
/// 3. Algorathmically Stable
///
/// It is similar to DAI if DAI had no governance, no fees and was only backed by WETH and WBTC.
///
/// Our DSC system should be over collaterialized. At no point,
/// should the value of all collateral <= the $ backed value of all the DSC
///
/// @notice This contract is the core of the DSC System. It handles all the logic for mining and redeeming DSC, as well as depositing and withdrawing collateral.
/// @notice This contract is very loosely based on the MakerDAO DSS (DAI) system.

contract DSCEngine is ReentrancyGuard {
    /*/////////////////////////////////////////////////////////////////////////////
                                STATE VARIABLES
    /////////////////////////////////////////////////////////////////////////////*/
    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 collateralAmount)) private s_collateralDeposited;

    // Immutables
    DecentralizedStableCoin private immutable i_dsc;

    /*/////////////////////////////////////////////////////////////////////////////
                                    EVENTS
    /////////////////////////////////////////////////////////////////////////////*/
    event CollateralDeposited(address indexed user, address indexed tokenCollateralAddress, uint256 indexed amount);

    /*/////////////////////////////////////////////////////////////////////////////
                                CUSTOM ERRORS
    /////////////////////////////////////////////////////////////////////////////*/
    error DSCEngine__Amount_MustBeMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAddresses_MustBeSameLength();
    error DSCEngine__TokenNotAllowed();
    error DSCEngine__Collateral_TransferFailed();

    /*/////////////////////////////////////////////////////////////////////////////
                                MODIFIERS
    /////////////////////////////////////////////////////////////////////////////*/
    modifier moreThanZero(uint256 amount) {
        if (amount <= 0) {
            revert DSCEngine__Amount_MustBeMoreThanZero();
        }
        _;
    }

    modifier isTokenAllowed(address tokenCollateralAddress) {
        if (s_priceFeeds[tokenCollateralAddress] == address(0)) {
            revert DSCEngine__TokenNotAllowed();
        }
        _;
    }

    /*/////////////////////////////////////////////////////////////////////////////
                                    FUNCTIONS
    /////////////////////////////////////////////////////////////////////////////*/

    /// @param tokenAddresses 2 tokenAddresses will be provided (wETH & wBTC)
    /// @param priceFeedAddresses for thoes 2 tokenAddresses, we need to find the correspoing priceFeed.
    /// @param dscAddress Since DecentralizedStableCoin contains info about `burn` and `mint` we need that deployed contract here.
    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddresses_MustBeSameLength();
        }
        for (uint256 index = 0; index < tokenAddresses.length; index++) {
            s_priceFeeds[tokenAddresses[index]] = priceFeedAddresses[index];
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    /*/////////////////////////////////////////////////////////////////////////////
                                EXTERNAL FUNCTIONS
    /////////////////////////////////////////////////////////////////////////////*/

    function depositCollateralAndMintDSC() external {}

    /// @dev follows CHECKS, EFFECTS, INTERACTIONS (CEI)
    /// @dev we should let the user pick what collateral they want to deposit
    /// eg: wETH or wBTC
    /// @param tokenCollateralAddress The address of the token to seposit as collateral, this will be either wETH or wBTC
    /// @param amountCollateral amount of collateral to deposit
    /// @dev we should keep track of the users collateral balance based on the token
    /// @dev since we are updating the state, we have to emit an event.
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        external
        moreThanZero(amountCollateral)
        isTokenAllowed(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] =
            s_collateralDeposited[msg.sender][tokenCollateralAddress] + amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert DSCEngine__Collateral_TransferFailed();
        }
    }

    function redeemCollateralForDSC() external {}

    function redeemCollateral() external {}

    function mintDsc() external {}

    /// @dev If the collateral value goes down, then the user will be undercollateralized.
    /// The user can burn some DSC and get their collateral value higher.
    function burnDSC() external {}

    /// Let's say a user has $100 worth of ETH in collateral and minted $50 worth of DSC.
    /// Right now this user is over collaterialized. Which is good
    /// What if ETH price tanks, and now the value of the collateral is only $40 worth in ETH
    /// The user has minted $50 worth of DSC
    /// Now this user is under collateralized
    /// This user should get liqudated. They shouldn't be allowed to hold the position.
    /// This liquidation fn will be called by other users to remove people's position to save the protocol.
    function liquidate() external {}

    /// @dev info related to liquidation and health factor
    /// Let's say a user has $100 worth of ETH in collateral and minted $50 worth of DSC.
    /// Right now this user is over collaterialized. Which is good.

    /// We should keep a threshold limit.
    /// Let's keep a threshold limit of 150%
    /// Which means if a user can hold $50 worth of DSC, they should have 150% collateral
    /// 150% of 50 is 75. The user should have 75$ worth of ETH to hold $50 worth of DSC.

    /// What if ETH price tanks, and now the value of the collateral is only $74 worth in ETH
    /// and the user is under the threshold limit
    /// seeing this user position, other users can call the liquidate fn and liquidate this user.

    /// The process of liquidation is, who ever is calling the liqudation fn
    /// They will pay back the users minted DSC, and they can take all their collateral.
    /// for eg, the person who called the liquidation fn, they will pay back $50 worth of DSC.
    /// and they will get all their collateral, in this case this person got $74 worth of ETH.
    /// this person will get incentivized for this. $74 worth of ETH (50+24)
    /// By paying $50 worth of DSC, they got extra $24 worth of ETH.
    /// This is the punishment for the user, for letting the collateral too low

    /// The user has minted $50 worth of DSC
    /// Now this user is under collateralized

    function getHealthFactor() external view {}
}
