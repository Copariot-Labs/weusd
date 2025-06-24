// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./IPicweUSD.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/**
 * @title WeUSDMintRedeem
 * @author WeUSD Protocol Team
 * @notice Contract for minting and redeeming WeUSD tokens with cross-chain support
 * @dev This contract manages the minting and redemption of WeUSD tokens backed by stablecoins,
 *      with integrated cross-chain reserve management and fee collection mechanisms.
 *      Uses role-based access control for administrative functions and reentrancy protection
 *      for all state-changing operations involving external calls.
 */
contract WeUSDMintRedeem is AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    /// @notice Role identifier for admin operations
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    /// @notice Role identifier for balancer operations
    bytes32 public constant BALANCER_ROLE = keccak256("BALANCER_ROLE");
    /// @notice Role identifier for cross-chain operations
    bytes32 public constant CROSS_CHAIN_ROLE = keccak256("CROSS_CHAIN_ROLE");
    /// @notice Role identifier for withdrawal operations
    bytes32 public constant WITHDRAW_ROLE = keccak256("WITHDRAW_ROLE");
    
    /// @notice WeUSD token decimal places (immutable after deployment)
    uint8 public constant WEUSD_DECIMALS = 6;
    /// @notice Maximum fee ratio allowed (20% in basis points)
    uint256 public constant MAX_FEE_RATIO = 2000;
    /// @notice Minimum fee ratio allowed (0.1% in basis points)
    uint256 public constant MIN_FEE_RATIO = 10;
    /// @notice Maximum minimum amount (1000 WeUSD)
    uint256 public constant MAX_MIN_AMOUNT = 1000000000;
    /// @notice Minimum minimum amount (0.001 WeUSD)
    uint256 public constant MIN_MIN_AMOUNT = 1000;
    
    /// @notice WeUSD token contract (immutable after deployment)
    IPicweUSD public immutable weUSD;
    /// @notice Stablecoin token contract used for backing
    IERC20 public stablecoin;
    /// @notice Decimal places of the stablecoin
    uint8 public stablecoinDecimals;
    /// @notice Cross-chain contract address for cross-chain operations
    address public crossChainContract;
    
    /// @notice Address that receives transaction fees
    address public feeRecipient;
    /// @notice Fee ratio in basis points (100 = 1%)
    uint256 public feeRatio = 100;
    /// @notice Minimum amount for mint/redeem operations (in WeUSD units)
    uint256 public minAmount = 10000;
    
    /// @notice Total stablecoin reserves held by the contract
    uint256 public stablecoinReserves;
    /// @notice Total fees accumulated from redemption operations
    uint256 public accumulatedFees;
    /// @notice Stablecoin reserves allocated for cross-chain operations
    uint256 public crossChainReserves;
    /// @notice Outstanding deficit from cross-chain operations
    uint256 public crossChainDeficit;
    
    /// @notice Emitted when WeUSD tokens are minted
    /// @param user Address of the user who minted tokens
    /// @param costStablecoinAmount Amount of stablecoin used for minting
    /// @param weUSDAmount Amount of WeUSD tokens minted
    /// @param fee Fee charged for the operation (always 0 for minting)
    event MintedWeUSD(address indexed user, uint256 costStablecoinAmount, uint256 weUSDAmount, uint256 fee);
    
    /// @notice Emitted when WeUSD tokens are redeemed
    /// @param user Address of the user who redeemed tokens
    /// @param receivedStablecoinAmount Amount of stablecoin received after fees
    /// @param weUSDAmount Amount of WeUSD tokens redeemed
    /// @param fee Fee charged for the operation
    event BurnedWeUSD(address indexed user, uint256 receivedStablecoinAmount, uint256 weUSDAmount, uint256 fee);
    
    /// @notice Emitted when fee ratio is updated
    /// @param newFeeRatio New fee ratio in basis points
    event FeeRatioSet(uint256 newFeeRatio);
    
    /// @notice Emitted when minimum amount is updated
    /// @param newMinAmount New minimum amount for operations
    event MinAmountSet(uint256 newMinAmount);
    
    /// @notice Emitted when fee recipient is updated
    /// @param newFeeRecipient New address to receive fees
    event FeeRecipientSet(address newFeeRecipient);
    
    /// @notice Emitted when cross-chain reserves are withdrawn
    /// @param sender Address that initiated the withdrawal
    /// @param amount Amount withdrawn
    /// @param recipient Address that received the funds
    event CrossChainReservesWithdrawn(address indexed sender, uint256 amount, address recipient);
    
    /// @notice Emitted when cross-chain contract address is set
    /// @param crossChainContract Address of the cross-chain contract
    event CrossChainContractSet(address indexed crossChainContract);
    
    /// @notice Emitted when stablecoin is reserved for cross-chain operations
    /// @param amount Amount reserved (in WeUSD units)
    event StablecoinReserved(uint256 amount);
    
    /// @notice Emitted when stablecoin is returned from cross-chain operations
    /// @param amount Amount returned (in WeUSD units)
    /// @param deficit Any deficit incurred during the operation
    event StablecoinReturned(uint256 amount, uint256 deficit);
    
    /// @notice Emitted when stablecoin contract is updated
    /// @param newStablecoin Address of the new stablecoin contract
    /// @param decimals Decimal places of the new stablecoin
    event StablecoinSet(address indexed newStablecoin, uint8 decimals);
    
    /// @notice Thrown when fee calculation results in insufficient amount
    error InsufficientFee();
    /// @notice Thrown when contract has insufficient reserves for operation
    error InsufficientReserves();
    /// @notice Thrown when operation amount is below minimum threshold
    error InsufficientAmount();
    /// @notice Thrown when calculated amount is zero
    error ZeroAmount();
    /// @notice Thrown when caller lacks required authorization
    error Unauthorized();
    /// @notice Thrown when zero address is provided where not allowed
    error ZeroAddress();

    /**
     * @notice Constructor to initialize the WeUSDMintRedeem contract
     * @dev Sets up initial roles and validates all input addresses
     * @param _weUSD Address of the WeUSD token contract
     * @param _stablecoin Address of the stablecoin token contract
     * @param _feeRecipient Address to receive transaction fees
     * @param _balancer Address to be granted balancer role
     */
    constructor(
        address _weUSD,
        address _stablecoin,
        address _feeRecipient,
        address _balancer
    ) {
        // L-4 Fix: Add zero address checks
        require(_weUSD != address(0), "WeUSD address cannot be zero");
        require(_stablecoin != address(0), "Stablecoin address cannot be zero");
        require(_feeRecipient != address(0), "Fee recipient cannot be zero");
        require(_balancer != address(0), "Balancer address cannot be zero");

        // Initialize immutable variables
        weUSD = IPicweUSD(_weUSD);
        
        // Initialize state variables
        stablecoin = IERC20(_stablecoin);
        stablecoinDecimals = IERC20Metadata(_stablecoin).decimals();
        feeRecipient = _feeRecipient;
        
        // Set up role-based access control
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(BALANCER_ROLE, _balancer);
        _grantRole(WITHDRAW_ROLE, msg.sender);
        _grantRole(WITHDRAW_ROLE, _balancer);

        // Configure role hierarchy
        _setRoleAdmin(WITHDRAW_ROLE, ADMIN_ROLE);
    }
    
    /**
     * @notice Pause the contract (only admin can pause)
     * @dev Pauses only public user functions (mint/redeem), admin functions remain available
     */
    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }
    
    /**
     * @notice Unpause the contract (only admin can unpause)
     * @dev Unpauses all public user functions
     */
    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }
    
    /**
     * @notice Set the cross-chain contract address and grant it the cross-chain role
     * @dev Only admin can call this function. Grants CROSS_CHAIN_ROLE to the new contract
     *      and revokes the role from the previous contract if it exists.
     * @param _crossChainContract Address of the WeUSDCrossChain contract
     */
    function setCrossChainContract(address _crossChainContract) external onlyRole(ADMIN_ROLE) {
        require(_crossChainContract != address(0), "Cross-chain contract cannot be zero");
        
        // WUS1-2 Fix: Revoke role from old cross-chain contract if it exists
        if (crossChainContract != address(0)) {
            _revokeRole(CROSS_CHAIN_ROLE, crossChainContract);
        }
        
        crossChainContract = _crossChainContract;
        _grantRole(CROSS_CHAIN_ROLE, _crossChainContract);
        emit CrossChainContractSet(_crossChainContract);
    }
    
    /**
     * @notice Convert WeUSD amount to stablecoin amount with rounding down
     * @dev Used for redemption calculations to ensure users don't receive more than they should
     * @param weUSDAmount Amount in WeUSD decimals
     * @return Amount in stablecoin decimals (rounded down)
     */
    function _toStablecoinAmountDown(uint256 weUSDAmount) internal view returns (uint256) {
        if (stablecoinDecimals == WEUSD_DECIMALS) {
            return weUSDAmount;
        } else if (stablecoinDecimals > WEUSD_DECIMALS) {
            // Scale up: multiply by 10^(difference)
            return weUSDAmount * (10 ** (stablecoinDecimals - WEUSD_DECIMALS));
        } else {
            // Scale down: divide by 10^(difference), truncating remainder
            uint256 divisor = 10 ** (WEUSD_DECIMALS - stablecoinDecimals);
            return weUSDAmount / divisor;
        }
    }

    /**
     * @notice Convert WeUSD amount to stablecoin amount with rounding up for minting
     * @dev Used for minting calculations to ensure protocol collects sufficient stablecoin.
     *      Rounds up when there's a remainder to maintain 1:1 backing ratio.
     * @param weUSDAmount Amount in WeUSD decimals
     * @return Amount in stablecoin decimals (rounded up if remainder exists)
     */
    function _toStablecoinAmountUp(uint256 weUSDAmount) internal view returns (uint256) {
        if (stablecoinDecimals == WEUSD_DECIMALS) {
            return weUSDAmount;
        } else if (stablecoinDecimals > WEUSD_DECIMALS) {
            // Scale up: multiply by 10^(difference)
            return weUSDAmount * (10 ** (stablecoinDecimals - WEUSD_DECIMALS));
        } else {
            // Scale down: divide by 10^(difference), round up if remainder
            uint256 divisor = 10 ** (WEUSD_DECIMALS - stablecoinDecimals);
            uint256 quotient = weUSDAmount / divisor;
            // Round up: add 1 if there's a remainder
            if (weUSDAmount % divisor > 0) {
                quotient += 1;
            }
            return quotient;
        }
    }
    
    /**
     * @notice Mint WeUSD tokens by depositing stablecoin
     * @dev Transfers stablecoin from user and mints equivalent WeUSD tokens.
     *      Uses rounding up conversion to ensure sufficient collateral.
     * @param weUSDAmount Amount of WeUSD tokens to mint
     */
    function mintWeUSD(uint256 weUSDAmount) external nonReentrant whenNotPaused {
        require(weUSDAmount >= minAmount, "Amount too small");
        
        // Calculate required stablecoin amount (rounded up)
        uint256 scMintAmount = _toStablecoinAmountUp(weUSDAmount);
        
        // Validate user has sufficient balance and allowance
        require(stablecoin.balanceOf(msg.sender) >= scMintAmount, "Insufficient balance");
        require(stablecoin.allowance(msg.sender, address(this)) >= scMintAmount, "Insufficient allowance");
        
        // Transfer stablecoin from user to contract
        stablecoin.safeTransferFrom(msg.sender, address(this), scMintAmount);
        
        // Update reserves and mint WeUSD tokens
        stablecoinReserves += scMintAmount;
        weUSD.mint(msg.sender, weUSDAmount);
        
        emit MintedWeUSD(msg.sender, scMintAmount, weUSDAmount, 0);
    }
    
    /**
     * @notice Redeem WeUSD tokens for stablecoin
     * @dev Burns WeUSD tokens and transfers stablecoin to user after deducting fees.
     *      Uses rounding down conversion and applies redemption fee.
     * @param weUSDAmount Amount of WeUSD tokens to redeem
     */
    function redeemWeUSD(uint256 weUSDAmount) external nonReentrant whenNotPaused {
        require(weUSDAmount >= minAmount, "Amount too small");
        
        // Calculate stablecoin amount to redeem (rounded down)
        uint256 scRedeemAmount = _toStablecoinAmountDown(weUSDAmount);
        require(stablecoinReserves >= scRedeemAmount, "Insufficient reserves");
        
        // Calculate fee and net amount
        uint256 feeSC = (scRedeemAmount * feeRatio) / 10000;
        uint256 actualSC = scRedeemAmount - feeSC;
        require(actualSC > 0, "Zero amount after fee");
        
        // Update state before external calls (CEI pattern)
        stablecoinReserves -= scRedeemAmount;
        accumulatedFees += feeSC;
        
        // Burn WeUSD tokens and transfer stablecoin
        weUSD.burnFrom(msg.sender, weUSDAmount);
        stablecoin.safeTransfer(msg.sender, actualSC);
        
        // Transfer fee to recipient if non-zero
        if (feeSC > 0) {
            stablecoin.safeTransfer(feeRecipient, feeSC);
        }
        
        emit BurnedWeUSD(msg.sender, actualSC, weUSDAmount, feeSC);
    }
    
    /**
     * @notice Set the fee ratio for redemption operations
     * @dev Only admin can call this function. Fee is applied only to redemptions.
     * @param newFeeRatio New fee ratio in basis points (100 = 1%)
     */
    function setFeeRatio(uint256 newFeeRatio) external onlyRole(ADMIN_ROLE) {
        require(newFeeRatio >= MIN_FEE_RATIO && newFeeRatio <= MAX_FEE_RATIO, "Invalid fee ratio");
        feeRatio = newFeeRatio;
        emit FeeRatioSet(newFeeRatio);
    }
    
    /**
     * @notice Set the minimum amount for mint/redeem operations
     * @dev Only admin can call this function. Prevents dust attacks and maintains efficiency.
     * @param newMinAmount New minimum amount in WeUSD units
     */
    function setMinAmount(uint256 newMinAmount) external onlyRole(ADMIN_ROLE) {
        // L-4 Fix: Add reasonable validation range
        require(newMinAmount >= MIN_MIN_AMOUNT && newMinAmount <= MAX_MIN_AMOUNT, "Invalid min amount");
        minAmount = newMinAmount;
        emit MinAmountSet(newMinAmount);
    }
    
    /**
     * @notice Set the fee recipient address
     * @dev Only admin can call this function. All redemption fees are sent to this address.
     * @param newFeeRecipient New address to receive fees
     */
    function setFeeRecipient(address newFeeRecipient) external onlyRole(ADMIN_ROLE) {
        require(newFeeRecipient != address(0), "Fee recipient cannot be zero");
        feeRecipient = newFeeRecipient;
        emit FeeRecipientSet(newFeeRecipient);
    }
    
    /**
     * @notice Reserve stablecoin for cross-chain operations
     * @dev Only cross-chain contract can call this. Implements atomic state updates
     *      and handles deficit repayment logic. Converts WeUSD amounts to stablecoin.
     * @param amount Amount to reserve in WeUSD units
     */
    function reserveStablecoinForCrossChain(uint256 amount) external onlyRole(CROSS_CHAIN_ROLE){
        // Convert WeUSD amount to stablecoin amount
        uint256 scAmount = _toStablecoinAmountDown(amount);
        
        // Calculate all values before any state changes (CEI pattern)
        uint256 toReserve = scAmount;
        uint256 deficitRepayment = 0;
        
        // Calculate deficit repayment if applicable
        if (crossChainDeficit > 0) {
            deficitRepayment = toReserve <= crossChainDeficit ? toReserve : crossChainDeficit;
            toReserve = scAmount - deficitRepayment;
        }
        
        // Perform all checks before state updates
        require(stablecoinReserves >= toReserve, "Insufficient reserves");
        
        // Atomic state updates - all or nothing
        if (deficitRepayment > 0) {
            crossChainDeficit -= deficitRepayment;
        }
        
        if (toReserve > 0) {
            stablecoinReserves -= toReserve;
            crossChainReserves += toReserve;
        }
        
        emit StablecoinReserved(amount);
    }
    
    /**
     * @notice Return stablecoin from cross-chain operations
     * @dev Only cross-chain contract can call this. Handles cases where returned
     *      amount exceeds available reserves by tracking deficit.
     * @param amount Amount to return in WeUSD units
     */
    function returnStablecoinFromCrossChain(uint256 amount) external onlyRole(CROSS_CHAIN_ROLE){
        // Convert WeUSD amount to stablecoin amount
        uint256 scAmount = _toStablecoinAmountDown(amount);
        
        // Calculate all values before any state changes (CEI pattern)
        uint256 deficit = 0;
        uint256 reservesToReturn = 0;
        uint256 deficitToAdd = 0;
        
        if (crossChainReserves >= scAmount) {
            // We have enough reserves to return
            reservesToReturn = scAmount;
        } else {
            // Not enough reserves, calculate deficit
            reservesToReturn = crossChainReserves;
            deficitToAdd = scAmount - crossChainReserves;
            deficit = deficitToAdd;
        }
        
        // Atomic state updates - all or nothing
        if (reservesToReturn > 0) {
            crossChainReserves -= reservesToReturn;
            stablecoinReserves += reservesToReturn;
        }
        
        if (deficitToAdd > 0) {
            crossChainDeficit += deficitToAdd;
        }
        
        emit StablecoinReturned(amount, deficit);
    }
    
    /**
     * @notice Withdraw cross-chain reserves to specified recipient
     * @dev Only withdraw role can call this. Transfers actual stablecoin tokens.
     * @param amount Amount to withdraw in stablecoin units
     * @param recipient Address to receive the withdrawn funds
     */
    function withdrawCrossChainReserves(uint256 amount, address recipient) external onlyRole(WITHDRAW_ROLE){
        require(recipient != address(0), "Recipient cannot be zero");
        require(crossChainReserves >= amount, "Insufficient reserves");
        
        // Transfer tokens and update state
        stablecoin.safeTransfer(recipient, amount);
        crossChainReserves -= amount;
        
        emit CrossChainReservesWithdrawn(msg.sender, amount, recipient);
    }
    
    /**
     * @notice Withdraw cross-chain reserves to the caller (balancer)
     * @dev Only balancer role can call this. Convenience function for balancer operations.
     * @param amount Amount to withdraw in stablecoin units
     */
    function withdrawCrossChainReservesToBalancer(uint256 amount) external onlyRole(BALANCER_ROLE){
        require(crossChainReserves >= amount, "Insufficient reserves");
        
        // Transfer tokens and update state
        stablecoin.safeTransfer(msg.sender, amount);
        crossChainReserves -= amount;
        
        emit CrossChainReservesWithdrawn(msg.sender, amount, msg.sender);
    }
    
    /**
     * @notice Get total accumulated fees from redemption operations
     * @return Total accumulated fees in stablecoin units
     */
    function getAccumulatedFees() external view returns (uint256) {
        return accumulatedFees;
    }
    
    /**
     * @notice Get total stablecoin reserves available for operations
     * @return Total stablecoin reserves in stablecoin units
     */
    function getTotalReserves() external view returns (uint256) {
        return stablecoinReserves;
    }
    
    /**
     * @notice Get current mint state configuration
     * @return feeRecipient Current fee recipient address
     * @return feeRatio Current fee ratio in basis points
     * @return minAmount Current minimum amount for operations
     */
    function getMintStateFields() external view returns (address, uint256, uint256) {
        return (feeRecipient, feeRatio, minAmount);
    }
    
    /**
     * @notice Get total cross-chain reserves
     * @return Total cross-chain reserves in stablecoin units
     */
    function getCrossChainReserves() external view returns (uint256) {
        return crossChainReserves;
    }
    
    /**
     * @notice Get current cross-chain deficit
     * @return Total cross-chain deficit in stablecoin units
     */
    function getCrossChainDeficit() external view returns (uint256) {
        return crossChainDeficit;
    }
    
    /**
     * @notice Set a new stablecoin contract and update its decimals
     * @dev Only admin can call this. Updates both contract reference and cached decimals.
     * @param _stablecoin Address of the new stablecoin token contract
     */
    function setStablecoin(address _stablecoin) external onlyRole(ADMIN_ROLE) {
        require(_stablecoin != address(0), "Stablecoin address cannot be zero");
        stablecoin = IERC20(_stablecoin);
        stablecoinDecimals = IERC20Metadata(_stablecoin).decimals();
        emit StablecoinSet(_stablecoin, stablecoinDecimals);
    }
}
