// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

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
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // which means user should be 200% over-collateralized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10; // this means a 10% bonus

    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 collateralAmount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_dscMinted;
    address[] private s_collateralTokens;

    // Immutables
    DecentralizedStableCoin private immutable i_dsc;

    /*/////////////////////////////////////////////////////////////////////////////
                                    EVENTS
    /////////////////////////////////////////////////////////////////////////////*/
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(
        address indexed redeemedFrom, address indexed redeemedto, address indexed token, uint256 amount
    );
    event DSCBurned(address user, uint256 amount);
    event DSCMinted(address user, uint256 amount);

    /*/////////////////////////////////////////////////////////////////////////////
                                CUSTOM ERRORS
    /////////////////////////////////////////////////////////////////////////////*/
    error DSCEngine__Amount_MustBeMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAddresses_MustBeSameLength();
    error DSCEngine__TokenNotAllowed();
    error DSCEngine__Collateral_TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 healthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__RedeemCollateralAmount_IsMoreThanDeposited();
    error DSCEngine__RedeemCollateral_TransferFailed();
    error DSCEngine__AmountToBurn_MoreThanMinted();
    error DSCEngine__TransferFailed();
    error DSCEngine__HealthFactorOk();
    error DSCEngine__HealthFactorNotImproved();

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
            s_collateralTokens.push(tokenAddresses[index]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    /*/////////////////////////////////////////////////////////////////////////////
                                EXTERNAL FUNCTIONS
    /////////////////////////////////////////////////////////////////////////////*/

    /// @param tokenCollateralAddress  The address of the token to deposit as collateral, either wETH or wBTC
    /// @param amountCollateral amount of collateral to deposit
    /// @param amountDscToMint amount of DSC to be minted
    /// @notice this function will deposit your collateral and mint DSC in one transaction
    function depositCollateralAndMintDSC(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    )
        external
        moreThanZero(amountCollateral)
        moreThanZero(amountDscToMint)
        isTokenAllowed(tokenCollateralAddress)
        nonReentrant
    {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }

    /// @dev follows CHECKS, EFFECTS, INTERACTIONS (CEI)
    /// @dev we should let the user pick what collateral they want to deposit
    /// eg: wETH or wBTC
    /// @param tokenCollateralAddress The address of the token to deposit as collateral, this will be either wETH or wBTC
    /// @param amountCollateral amount of collateral to deposit
    /// @dev we should keep track of the users collateral balance based on the token
    /// @dev since we are updating the state, we have to emit an event.
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
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

    /// @dev follows CEI
    /// Inorder to redeem collateral
    // 1. Health factor of the user must be over 1 After collateral pulled
    /// @param tokenCollateralAddress The address of the token to redeem, this will be either wETH or wBTC
    /// @param amountToRedeem amount of collateral to redeem
    /// @param amountDSCToBurn amount of DSC to burn
    /// @notice This function burns DSC and redeems underlying collateral in one transaction
    function redeemCollateralForDSC(address tokenCollateralAddress, uint256 amountToRedeem, uint256 amountDSCToBurn)
        external
        moreThanZero(amountToRedeem)
        isTokenAllowed(tokenCollateralAddress)
        moreThanZero(amountDSCToBurn)
        nonReentrant
    {
        burnDSC(amountDSCToBurn);
        redeemCollateral(tokenCollateralAddress, amountToRedeem);
        // redeem collateral already checks health factor
    }

    /// @dev follows CEI
    /// Inorder to redeem collateral
    // 1. Health factor of the user must be over 1 After collateral pulled
    /// @param tokenCollateralAddress The address of the token to redeem, this will be either wETH or wBTC
    /// @param amountToRedeem amount of collateral to redeem
    /// @dev since we are updating the state, we have to emit an event.
    function redeemCollateral(address tokenCollateralAddress, uint256 amountToRedeem)
        public
        moreThanZero(amountToRedeem)
        isTokenAllowed(tokenCollateralAddress)
        nonReentrant
    {
        _redeemCollateral(tokenCollateralAddress, amountToRedeem, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /// @dev follows CHECKS, EFFECTS, INTERACTIONS (CEI)
    /// @param amountDscToMint the amount of DSC to be minted
    /// @notice user must have more collateral value than the minimum threshold
    /// @dev Before allowing a user to mint
    /// 1. Check if the collateral value > DSC amount
    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        s_dscMinted[msg.sender] = s_dscMinted[msg.sender] + amountDscToMint;
        emit DSCMinted(msg.sender, amountDscToMint);
        // if they minted too much, we should revert
        // If they want to mint $150 worth of DSC but they have only $100 worth of ETH
        // they shouldn't be allowed to mint.
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    /// @dev If the collateral value goes down, then the user will be undercollateralized.
    /// The user can burn some DSC and get their collateral value higher.
    function burnDSC(uint256 amountDSCToBurn) public moreThanZero(amountDSCToBurn) {
        _burnDsc(amountDSCToBurn, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender); // I don't think this will ever hit...
    }

    /// Let's say a user has $100 worth of ETH in collateral and minted $50 worth of DSC.
    /// Right now this user is over collaterialized. Which is good
    /// What if ETH price tanks, and now the value of the collateral is only $40 worth in ETH
    /// The user has minted $50 worth of DSC
    /// Now this user is under collateralized
    /// This user should get liqudated. They shouldn't be allowed to hold the position.
    /// This liquidation fn will be called by other users to remove people's position to save the protocol.

    /// Follows CEI
    /// @param collateral The erc20 collateral address to liquidate from the user
    /// @param user The user who has broken the health factor. Their healthfactor should be blow MIN_HEALTH_FACTOR
    /// @param debtToCover The amount of DSC you want to burn to improve the users health factor
    /// @notice you can partially liquidate a user
    /// @notice you will get a liquidation bonus for taking the users funds
    /// @notice This function working assumes the protocol will be roughly 200% overcollateralized in order for this to work.
    /// @notice A known bug would be if the protocol were 100% or less collateralized, then we wouldn't be able to incentivize the liquidators.
    /// For example, if the price of the collateral plummeted before anyone could be liquidated.
    function liquidate(address collateral, address user, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        isTokenAllowed(collateral)
        nonReentrant
    {
        /// @dev check the healthFactor of the user before liquidating
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOk();
        }

        // If the user is liquidatable
        // We want to burn their DSC "debt"
        // And take their collateral
        // If a user has $140 ETH and $100 DSC minted.
        // Healthfactor is < 1

        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);

        // If a user has $100 worth of DSC, then we have to find out how much is $100 worth of DSC in ETH
        // whatever that amount is, with that amount we have to give them 10% bonus

        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;

        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;
        _redeemCollateral(collateral, totalCollateralToRedeem, user, msg.sender);

        _burnDsc(debtToCover, user, msg.sender);

        uint256 endingUserHealthFactor = _healthFactor(user);
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }
        ///@dev If health factor is not improved, we should revert

        _revertIfHealthFactorIsBroken(msg.sender);
        // by liquidating someone, if the healthfactor is broken for the liquidator, then it should revert
    }

    /// @dev info related to liquidation and health factor
    /// Let's say a user has $100 worth of ETH in collateral and minted $50 worth of DSC.
    /// Right now this user is over collaterialized. Which is good.

    /// We should keep a threshold limit.
    /// Let's keep a threshold limit of 200%
    /// Which means if a user can hold $50 worth of DSC, they should have 150% collateral
    /// 200% of 50 is 100. The user should have 100$ worth of ETH to hold $50 worth of DSC.

    /// What if ETH price tanks, and now the value of the collateral is only $99 worth in ETH
    /// and the user is under the threshold limit
    /// seeing this user position, other users can call the liquidate fn and liquidate this user.

    /// The process of liquidation is, who ever is calling the liqudation fn
    /// They will pay back the users minted DSC, and they can take all their collateral.
    /// for eg, the person who called the liquidation fn, they will pay back $50 worth of DSC.
    /// and they will get all their collateral, in this case this person got $99 worth of ETH.
    /// this person will get incentivized for this. $99 worth of ETH (50+49)
    /// By paying $50 worth of DSC, they got extra $49 worth of ETH.
    /// This is the punishment for the user, for letting the collateral too low

    function getHealthFactor() public view {}

    /*/////////////////////////////////////////////////////////////////////////////
                        PRIVATE & INTERNAL VIEW FUNCTIONS
    /////////////////////////////////////////////////////////////////////////////*/

    /// @dev Low-level internal function, do not call unless the function calling is checking for health factors being broken
    function _burnDsc(uint256 amountDSCToBurn, address onBehalfOf, address /*dscFrom*/ ) private {
        if (amountDSCToBurn > s_dscMinted[onBehalfOf]) {
            revert DSCEngine__AmountToBurn_MoreThanMinted();
        }
        s_dscMinted[onBehalfOf] = s_dscMinted[onBehalfOf] - amountDSCToBurn;
        emit DSCBurned(onBehalfOf, amountDSCToBurn);
        bool success = i_dsc.transferFrom(onBehalfOf, address(this), amountDSCToBurn);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amountDSCToBurn);
    }

    function _redeemCollateral(address tokenCollateralAddress, uint256 amountToRedeem, address from, address to)
        private
    {
        if (amountToRedeem > s_collateralDeposited[from][tokenCollateralAddress]) {
            revert DSCEngine__RedeemCollateralAmount_IsMoreThanDeposited();
        }
        s_collateralDeposited[from][tokenCollateralAddress] =
            s_collateralDeposited[from][tokenCollateralAddress] -= amountToRedeem;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountToRedeem);

        bool success = IERC20(tokenCollateralAddress).transfer(to, amountToRedeem);
        if (!success) {
            revert DSCEngine__RedeemCollateral_TransferFailed();
        }
    }

    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDSCMinted, uint256 collateralValueInUsd)
    {
        totalDSCMinted = s_dscMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }

    /// @dev Returns how close to liquidation a user is
    /// If a user goes below 1, then they can be liquidated
    function _healthFactor(address user) private view returns (uint256) {
        // To determine the health factor
        // 1. Get total DSC minted by this user
        // 2. Total VALUE of the collateral deposited
        // 3. Make sure Collateral Value > DSC minted
        (uint256 totalDSCMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;

        return ((collateralAdjustedForThreshold * PRECISION) / totalDSCMinted);

        // if collateralValueInUsd = $1000 ETH and totalDSCMinted = $100 of DSC
        // LIQUIDATION_THRESHOLD = 50
        // (collateralValueInUsd * LIQUIDATION_THRESHOLD) = 1000 * 50 = 50000
        // collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION
        // collateralAdjustedForThreshold = (1000 * 50) / 100 = 500
        // return ((collateralAdjustedForThreshold * PRECISION) / totalDSCMinted);
        // collateralAdjustedForThreshold = 500
        // PRECISION = 1e18;
        // (collateralAdjustedForThreshold * PRECISION) = 500e18;
        // (collateralAdjustedForThreshold * PRECISION) / totalDSCMinted) = 500e18 / 100e18 = 5
        // this is > 1
        // If healthFactor < 1, user will get liquidated
    }

    // 1. Check health factor (do they have enough collateral)
    // 2. Revert If they don't have a good health factor
    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }

    /*/////////////////////////////////////////////////////////////////////////////
                        PUBLIC & EXTERNAL VIEW FUNCTIONS
    /////////////////////////////////////////////////////////////////////////////*/

    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();

        return (usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);

        // If usdAmountInWei = 10e18;
        // (usdAmountInWei * PRECISION) = 10e18 * 1e18 = 10e36;
        // (uint256(price) * ADDITIONAL_FEED_PRECISION) = $2000e8 * 1e10 = 2000e18
        // 10e18 / 2000e18 = 5000000000000000 = 0.005e18
    }

    /// If a user has wETH with a value of 2wEth
    /// then we need to get the USD value for that.
    function getAccountCollateralValue(address user) public view returns (uint256) {
        // To get the amountCollateralValue
        // loop through each collateral token, get the amount of collateral they deposited
        // map it to the price and get the USD value
        uint256 totalCollateralValueInUsd = 0;
        for (uint256 index = 0; index < s_collateralTokens.length; index++) {
            address token = s_collateralTokens[index];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd = totalCollateralValueInUsd + getUsdValue(token, amount);
        }
        return totalCollateralValueInUsd;
    }

    ///@dev we are getting the usdValue for wETH & wBTC
    /// @param token this token will describe whether it is wETH or wBTC or ...
    /// @param amount the amount the user already have in these tokens
    /// since we have the token address, we need to get the respective priceFeed address
    /// s_priceFeeds[] will hold all the addresses for priceFeeds, we can get the required pricFeed address
    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        uint256 valueInUsd = (amount * (uint256(price) * ADDITIONAL_FEED_PRECISION)) / PRECISION;
        return valueInUsd;
    }

    /*/////////////////////////////////////////////////////////////////////////////
                                    GETTER FUNCTIONS
    /////////////////////////////////////////////////////////////////////////////*/
    function getTotalCollateralValueOfUser(address user, address token) external view returns (uint256) {
        return s_collateralDeposited[user][token];
    }

    function getDscMintedByUser(address user) external view returns (uint256) {
        return s_dscMinted[user];
    }

    function getAccountInformation(address user)
        external
        view
        returns (uint256 totalDSCMinted, uint256 collateralValueInUsd)
    {
        (totalDSCMinted, collateralValueInUsd) = _getAccountInformation(user);
    }
}
