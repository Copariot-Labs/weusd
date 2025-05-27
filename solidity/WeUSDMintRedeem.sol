// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "./IPicweUSD.sol";

/**
 * @title WeUSDMintRedeem
 * @dev Contract for minting and redeeming WeUSD tokens, with cross-chain support
 */
contract WeUSDMintRedeem is AccessControl {
    using SafeERC20 for IERC20;
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant BALANCER_ROLE = keccak256("BALANCER_ROLE");
    bytes32 public constant CROSS_CHAIN_ROLE = keccak256("CROSS_CHAIN_ROLE");
    bytes32 public constant WITHDRAW_ROLE = keccak256("WITHDRAW_ROLE");
    
    // Decimals
    uint8 public constant WEUSD_DECIMALS = 6;
    uint8 public constant STABLECOIN_DECIMALS = 6;
    
    // Contracts
    IPicweUSD public weUSD;
    IERC20 public stablecoin;
    address public crossChainContract;
    
    // Fee settings
    address public feeRecipient;
    uint256 public feeRatio = 100; // Fee rate in basis points (1% = 100)
    uint256 public minAmount = 10000; // Minimum amount for mint/redeem (0.01 tokens)
    
    // Reserve tracking
    uint256 public stablecoinReserves;
    uint256 public accumulatedFees;
    uint256 public crossChainReserves;
    uint256 public crossChainDeficit;
    
    // Events
    event MintedWeUSD(address indexed user, uint256 costStablecoinAmount, uint256 weUSDAmount, uint256 fee);
    event BurnedWeUSD(address indexed user, uint256 receivedStablecoinAmount, uint256 weUSDAmount, uint256 fee);
    event FeeRatioSet(uint256 newFeeRatio);
    event MinAmountSet(uint256 newMinAmount);
    event FeeRecipientSet(address newFeeRecipient);
    event CrossChainReservesWithdrawn(address indexed sender, uint256 amount, address recipient);
    event CrossChainContractSet(address indexed crossChainContract);
    event StablecoinReserved(uint256 amount);
    event StablecoinReturned(uint256 amount, uint256 deficit);
    
    // Error messages
    error InsufficientFee();
    error InsufficientReserves();
    error InsufficientAmount();
    error ZeroAmount();
    error Unauthorized();

    /**
     * @dev Constructor
     * @param _weUSD Address of the WeUSD token contract
     * @param _stablecoin Address of the stablecoin token contract
     * @param _feeRecipient Address to receive fees
     * @param _balancer Address of the balancer role
     */
    constructor(address _weUSD, address _stablecoin, address _feeRecipient, address _balancer) {
        weUSD = IPicweUSD(_weUSD);
        stablecoin = IERC20(_stablecoin);
        feeRecipient = _feeRecipient;
        
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(BALANCER_ROLE, _balancer);
        _grantRole(WITHDRAW_ROLE, msg.sender);
        _grantRole(WITHDRAW_ROLE, _balancer);

        _setRoleAdmin(WITHDRAW_ROLE, ADMIN_ROLE);
    }
    
    /**
     * @dev Set the cross-chain contract address
     * @param _crossChainContract Address of the WeUSDCrossChain contract
     */
    function setCrossChainContract(address _crossChainContract) external onlyRole(ADMIN_ROLE) {
        crossChainContract = _crossChainContract;
        _grantRole(CROSS_CHAIN_ROLE, _crossChainContract);
        emit CrossChainContractSet(_crossChainContract);
    }
    
    /**
     * @dev Mint WeUSD tokens
     * @param weUSDAmount Amount of WeUSD to mint
     */
    function mintWeUSD(uint256 weUSDAmount) external {
        require(stablecoin.balanceOf(msg.sender) >= weUSDAmount, "Insufficient balance");
        require(stablecoin.allowance(msg.sender, address(this)) >= weUSDAmount, "Insufficient allowance");
        stablecoin.safeTransferFrom(msg.sender, address(this), weUSDAmount);
        // Update reserves
        stablecoinReserves += weUSDAmount;
        // Mint WeUSD tokens
        weUSD.mint(msg.sender, weUSDAmount);        
        emit MintedWeUSD(msg.sender, weUSDAmount, weUSDAmount, 0);
    }
    
    /**
     * @dev Redeem WeUSD tokens
     * @param weUSDAmount Amount of WeUSD to redeem
     */
    function redeemWeUSD(uint256 weUSDAmount) external {
        require(weUSDAmount >= minAmount, "Amount too small");
        require(stablecoinReserves >= weUSDAmount, "Insufficient reserves");
        
        // Calculate fee
        uint256 fee = (weUSDAmount * feeRatio) / 10000;
        uint256 actualStablecoinAmount = weUSDAmount - fee;
        require(actualStablecoinAmount > 0, "Zero amount after fee");
        
        // Burn WeUSD tokens
        weUSD.burnFrom(msg.sender, weUSDAmount);
        
        // Transfer stablecoin to recipient
        stablecoin.safeTransfer(msg.sender, actualStablecoinAmount);
        // Transfer fee to fee recipient
        if (fee > 0) {
            stablecoin.safeTransfer(feeRecipient, fee);
        }
        
        // Update reserves
        stablecoinReserves -= weUSDAmount;
        accumulatedFees += fee;
        
        emit BurnedWeUSD(msg.sender, actualStablecoinAmount, weUSDAmount, fee);
    }
    
    /**
     * @dev Set fee ratio
     * @param newFeeRatio New fee ratio (in basis points)
     */
    function setFeeRatio(uint256 newFeeRatio) external onlyRole(ADMIN_ROLE) {
        require(newFeeRatio >= 10 && newFeeRatio <= 2000, "Invalid fee ratio");
        feeRatio = newFeeRatio;
        emit FeeRatioSet(newFeeRatio);
    }
    
    /**
     * @dev Set minimum mint/redeem amount
     * @param newMinAmount New minimum amount
     */
    function setMinAmount(uint256 newMinAmount) external onlyRole(ADMIN_ROLE) {
        minAmount = newMinAmount;
        emit MinAmountSet(newMinAmount);
    }
    
    /**
     * @dev Set fee recipient
     * @param newFeeRecipient New fee recipient address
     */
    function setFeeRecipient(address newFeeRecipient) external onlyRole(ADMIN_ROLE) {
        feeRecipient = newFeeRecipient;
        emit FeeRecipientSet(newFeeRecipient);
    }
    
    /**
     * @dev Handle cross-chain USDT reserves
     * @param amount Amount to reserve for cross-chain
     * @notice This function can only be called by the WeUSDCrossChain contract
     */
    function reserveStablecoinForCrossChain(uint256 amount) external onlyRole(CROSS_CHAIN_ROLE) {
        uint256 toReserve = amount;
        if (crossChainDeficit > 0) {
            uint256 repay = toReserve <= crossChainDeficit ? toReserve : crossChainDeficit;
            crossChainDeficit -= repay;
            toReserve -= repay;
        }
        require(stablecoinReserves >= toReserve, "Insufficient reserves");
        stablecoinReserves -= toReserve;
        if (toReserve > 0) {
            crossChainReserves += toReserve;
        }
        emit StablecoinReserved(amount);
    }
    
    /**
     * @dev Handle cross-chain USDT return
     * @param amount Amount to return from cross-chain
     * @notice This function can only be called by the WeUSDCrossChain contract
     */
    function returnStablecoinFromCrossChain(uint256 amount) external onlyRole(CROSS_CHAIN_ROLE) {
        uint256 deficit = 0;
        
        if (crossChainReserves >= amount) {
            // If we have enough reserves, return them to the pool
            crossChainReserves -= amount;
            stablecoinReserves += amount;
        } else {
            // If not enough reserves, record the deficit
            deficit = amount - crossChainReserves;
            stablecoinReserves += crossChainReserves;
            crossChainReserves = 0;
            crossChainDeficit += deficit;
        }
        
        emit StablecoinReturned(amount, deficit);
    }
    
    /**
     * @dev Withdraw cross-chain reserves
     * @param amount Amount to withdraw
     * @param recipient Address to receive the withdrawn amount
     */
    function withdrawCrossChainReserves(uint256 amount, address recipient) external onlyRole(WITHDRAW_ROLE) {
        require(crossChainReserves >= amount, "Insufficient reserves");
        stablecoin.safeTransfer(recipient, amount);
        
        crossChainReserves -= amount;
        emit CrossChainReservesWithdrawn(msg.sender, amount, recipient);
    }
    
    /**
     * @dev Withdraw cross-chain reserves to balancer address
     * @param amount Amount to withdraw
     */
    function withdrawCrossChainReservesToBalancer(uint256 amount) external onlyRole(BALANCER_ROLE) {
        require(crossChainReserves >= amount, "Insufficient reserves");
        stablecoin.safeTransfer(msg.sender, amount);
        
        crossChainReserves -= amount;
        emit CrossChainReservesWithdrawn(msg.sender, amount, msg.sender);
    }
    
    /**
     * @dev Get accumulated fees
     * @return Total accumulated fees
     */
    function getAccumulatedFees() external view returns (uint256) {
        return accumulatedFees;
    }
    
    /**
     * @dev Get total reserves
     * @return Total stablecoin reserves
     */
    function getTotalReserves() external view returns (uint256) {
        return stablecoinReserves;
    }
    
    /**
     * @dev Get mint state fields
     * @return Fee recipient, fee ratio, and minimum amount
     */
    function getMintStateFields() external view returns (address, uint256, uint256) {
        return (feeRecipient, feeRatio, minAmount);
    }
    
    /**
     * @dev Get cross-chain reserves
     * @return Total cross-chain reserves
     */
    function getCrossChainReserves() external view returns (uint256) {
        return crossChainReserves;
    }
    
    /**
     * @dev Get cross-chain deficit
     * @return Total cross-chain deficit
     */
    function getCrossChainDeficit() external view returns (uint256) {
        return crossChainDeficit;
    }
}
