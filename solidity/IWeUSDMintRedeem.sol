// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/**
 * @title IWeUSDMintRedeem
 * @dev Interface for the WeUSDMintRedeem contract
 */
interface IWeUSDMintRedeem {
    /**
     * @dev Handle cross-chain USDT reserves
     * @param amount Amount to reserve for cross-chain
     */
    function reserveStablecoinForCrossChain(uint256 amount) external;
    
    /**
     * @dev Handle cross-chain USDT return
     * @param amount Amount to return from cross-chain
     */
    function returnStablecoinFromCrossChain(uint256 amount) external;
    
    /**
     * @dev Get cross-chain reserves
     * @return Total cross-chain reserves
     */
    function getCrossChainReserves() external view returns (uint256);
    
    /**
     * @dev Get cross-chain deficit
     * @return Total cross-chain deficit
     */
    function getCrossChainDeficit() external view returns (uint256);
    
    /**
     * @dev Get total reserves
     * @return Total stablecoin reserves
     */
    function getTotalReserves() external view returns (uint256);
}
