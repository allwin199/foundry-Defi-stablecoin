// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.18;

import {ERC20Burnable, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title Decentralized Stable Coin
/// @author Prince Allwin
/// Collateral: Exogenous(ETH & BTC)
/// Minting: Algorathmic
/// Relative Stability: Pegged to USD
/// @notice This is the contract meant to governed by DSCEngine. This contract is just the ERC20 implementation of our stablecoin system
contract DecentralizedStableCoin is ERC20Burnable, Ownable {
    /*/////////////////////////////////////////////////////////////////////////////
                                CUSTOM ERRORS
    /////////////////////////////////////////////////////////////////////////////*/
    error DecentralizedStableCoin__BurnAmount_MustBeMoreThanZero();
    error DecentralizedStableCoin__BurnAmount_ExceedsBalance();
    error DecentralizedStableCoin__ZeroAddress();
    error DecentralizedStableCoin__MintAmount_MustBeMoreThanZero();

    /*/////////////////////////////////////////////////////////////////////////////
                                Functions
    /////////////////////////////////////////////////////////////////////////////*/
    constructor() ERC20("DecentralizedStableCoin", "DSC") {}

    /*/////////////////////////////////////////////////////////////////////////////
                            EXTERNAL & public FUNCTIONS
    /////////////////////////////////////////////////////////////////////////////*/

    /// @param amount totalAmount to be burn
    /// @dev make sure the amount is <= balance of the sender
    /// @dev if (amount <= 0) revert with custom error
    /// @dev if (balance < amount) revert with custom error
    /// @dev use the burn fn in super(parent) class to burn.
    function burn(uint256 amount) public override onlyOwner {
        uint256 balance = balanceOf(msg.sender);
        if (amount <= 0) {
            revert DecentralizedStableCoin__BurnAmount_MustBeMoreThanZero();
        }
        if (balance < amount) {
            revert DecentralizedStableCoin__BurnAmount_ExceedsBalance();
        }
        super.burn(amount);
    }

    /// @param to account of the user
    /// @param amount how much amount should be minted
    /// @dev _mint is from the ERC20 class.
    function mint(address to, uint256 amount) external onlyOwner returns (bool) {
        if (to == address(0)) {
            revert DecentralizedStableCoin__ZeroAddress();
        }
        if (amount <= 0) {
            revert DecentralizedStableCoin__MintAmount_MustBeMoreThanZero();
        }
        _mint(to, amount);
        return true;
    }
}
