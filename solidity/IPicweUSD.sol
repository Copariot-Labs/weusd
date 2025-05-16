// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title IPicweUSD
 * @dev Interface for the PicweUSD token with additional mint and burn functions
 */
interface IPicweUSD is IERC20 {
    function mint(address to, uint256 amount) external;
    function burn(uint256 amount) external;
    function burnFrom(address from, uint256 amount) external;
    function decimals() external view returns (uint8);
}
