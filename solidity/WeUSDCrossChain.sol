// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "./IPicweUSD.sol";
import "./IWeUSDMintRedeem.sol";

/**
 * @notice Struct to store cross-chain request data
 * @param requestId Unique identifier for the request
 * @param localUser Address of the user on the local chain
 * @param outerUser Address or identifier of the user on the remote chain
 * @param amount Amount of WeUSD tokens involved in the request
 * @param isburn Whether this is a burn request (true) or mint request (false)
 * @param targetChainId Chain ID of the target chain for this request
 */
struct RequestData {
    uint256 requestId;
    address localUser;
    string outerUser;
    uint256 amount;
    bool isburn;
    uint256 targetChainId;
}

/**
 * @title WeUSDCrossChain
 * @author WeUSD Protocol Team
 * @notice Contract for managing cross-chain transfers of WeUSD tokens
 * @dev This contract handles burning WeUSD on source chains and minting on target chains,
 *      with integrated fee collection, gas fee management, and request tracking.
 *      Uses role-based access control for administrative functions and cross-chain operations.
 */
contract WeUSDCrossChain is AccessControl {
    /// @notice Role identifier for admin operations
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    /// @notice Role identifier for cross-chain minting operations
    bytes32 public constant CROSS_CHAIN_MINTER_ROLE = keccak256("CROSS_CHAIN_MINTER_ROLE");
    
    /// @notice WeUSD token contract (immutable after deployment)
    IPicweUSD public immutable weUSD;
    /// @notice WeUSD mint/redeem contract for reserve management
    IWeUSDMintRedeem public mintRedeem;
    /// @notice Counter for generating unique request IDs
    uint256 public requestCount;
    
    /// @notice WeUSD token decimal places (immutable)
    uint8 public constant WEUSD_DECIMALS = 6;
    /// @notice Salt value for request ID generation (immutable)
    uint256 public constant WEUSD_SALT = 2;
    /// @notice Denominator for basis points calculations (immutable)
    uint256 public constant BASIS_POINTS_DENOMINATOR = 10000;
    /// @notice Maximum fee rate allowed (20% in basis points)
    uint256 public constant MAX_FEE_RATE = 2000;
    /// @notice Minimum fee rate allowed (0.01% in basis points)
    uint256 public constant MIN_FEE_RATE = 1;
    
    /// @notice Current fee rate in basis points (1% = 100 basis points)
    uint256 private feeRateBasisPoints = 100;
    /// @notice Default gas fee for cross-chain operations
    uint256 public gasfee = 1*10**(6-1);
    /// @notice Address that receives transaction fees
    address public feeRecipient;

    /// @notice Array of active source chain request IDs
    uint256[] public activeSourceRequests;
    /// @notice Array of active target chain request IDs
    uint256[] public activeTargetRequests;

    /// @notice Mapping of chain ID to specific gas fee for that chain
    mapping(uint256 => uint256) public chainGasFees;
    /// @notice Mapping of request ID to request data
    mapping(uint256 => RequestData) private requests;
    /// @notice Mapping of request ID to its index in activeSourceRequests array
    mapping(uint256 => uint256) public requestIdToSourceActiveIndex;
    /// @notice Mapping of request ID to its index in activeTargetRequests array
    mapping(uint256 => uint256) public requestIdToTargetActiveIndex;
    /// @notice Mapping of chain ID to whether it's supported for cross-chain operations
    mapping(uint256 => bool) public supportedChains;

    /// @notice Emitted when WeUSD is burned for cross-chain transfer
    /// @param requestId Unique identifier for the burn request
    /// @param localUser Address of the user who initiated the burn
    /// @param outerUser Target user address on the destination chain
    /// @param sourceChainId Chain ID where the burn occurred
    /// @param targetChainId Chain ID where tokens will be minted
    /// @param amount Amount of WeUSD burned (after fees)
    event CrossChainBurn(uint256 indexed requestId, address indexed localUser, string outerUser, uint256 sourceChainId, uint256 targetChainId, uint256 amount);
    
    /// @notice Emitted when WeUSD is minted on target chain
    /// @param requestId Unique identifier for the mint request
    /// @param localUser Address of the user who received the minted tokens
    /// @param outerUser Source user address on the origin chain
    /// @param sourceChainId Chain ID where the burn occurred
    /// @param targetChainId Chain ID where tokens were minted
    /// @param amount Amount of WeUSD minted
    event CrossChainMint(uint256 indexed requestId, address indexed localUser, string outerUser, uint256 sourceChainId, uint256 targetChainId, uint256 amount);
    
    /// @notice Emitted when mint/redeem contract is updated
    /// @param mintRedeemContract Address of the new mint/redeem contract
    event MintRedeemContractSet(address indexed mintRedeemContract);
    
    /// @notice Emitted when gas fee for a specific chain is set
    /// @param targetChainId Chain ID for which the gas fee was set
    /// @param gasfee New gas fee amount
    event ChainGasFeeSet(uint256 indexed targetChainId, uint256 gasfee);
    
    /// @notice Emitted when gas fee for a specific chain is removed
    /// @param targetChainId Chain ID for which the gas fee was removed
    event ChainGasFeeRemoved(uint256 indexed targetChainId);
    
    /// @notice Emitted when fee rate is updated
    /// @param feeRateBasisPoints New fee rate in basis points
    event FeeRateSet(uint256 feeRateBasisPoints);
    
    /// @notice Emitted when fee recipient is updated
    /// @param newFeeRecipient New address to receive fees
    event FeeRecipientSet(address newFeeRecipient);
    
    /// @notice Emitted when a chain is added to supported chains
    /// @param targetChainId Chain ID that was added
    event SupportedChainAdded(uint256 indexed targetChainId);
    
    /// @notice Emitted when a chain is removed from supported chains
    /// @param targetChainId Chain ID that was removed
    event SupportedChainRemoved(uint256 indexed targetChainId);
    
    /// @notice Emitted when a source request is archived and deleted
    /// @param requestId Request ID that was archived
    event SourceRequestArchivedAndDeleted(uint256 indexed requestId);
    
    /// @notice Emitted when a target request is archived and deleted
    /// @param requestId Request ID that was archived
    event TargetRequestArchivedAndDeleted(uint256 indexed requestId);

    /**
     * @notice Constructor to initialize the WeUSDCrossChain contract
     * @dev Sets up initial roles and validates all input addresses
     * @param _weUSD Address of the WeUSD token contract
     * @param _crossChainMinter Address to be granted cross-chain minter role
     * @param _feeRecipient Address to receive transaction fees
     */
    constructor(address _weUSD, address _crossChainMinter, address _feeRecipient) {
        // L-4 Fix: Add zero address checks
        require(_weUSD != address(0), "WeUSD address cannot be zero");
        require(_crossChainMinter != address(0), "Cross-chain minter cannot be zero");
        require(_feeRecipient != address(0), "Fee recipient cannot be zero");

        // Initialize immutable variables
        weUSD = IPicweUSD(_weUSD);
        
        // Initialize state variables
        feeRecipient = _feeRecipient;
        
        // Set up role-based access control
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(CROSS_CHAIN_MINTER_ROLE, _crossChainMinter);
    }

    /**
     * @notice Set the mint/redeem contract address for reserve management
     * @dev Only admin can call this function. This contract manages stablecoin reserves.
     * @param _mintRedeem Address of the WeUSDMintRedeem contract
     */
    function setMintRedeemContract(address _mintRedeem) external onlyRole(ADMIN_ROLE) {
        require(_mintRedeem != address(0), "Mint redeem contract cannot be zero");
        mintRedeem = IWeUSDMintRedeem(_mintRedeem);
        emit MintRedeemContractSet(_mintRedeem);
    }

    /**
     * @notice Set the default gas fee for cross-chain operations
     * @dev Only admin can call this function. This fee is charged for all cross-chain transfers.
     * @param _gasfee New default gas fee amount in WeUSD units
     */
    function setGasfee(uint256 _gasfee) external onlyRole(ADMIN_ROLE) {
        gasfee = _gasfee;
    }

    /**
     * @notice Set the percentage fee rate for cross-chain operations
     * @dev Only admin can call this function. Fee is calculated as percentage of transfer amount.
     * @param _feeRateBasisPoints New fee rate in basis points (100 = 1%)
     */
    function setFeeRateBasisPoints(uint256 _feeRateBasisPoints) external onlyRole(ADMIN_ROLE) {
        require(_feeRateBasisPoints >= MIN_FEE_RATE && _feeRateBasisPoints <= MAX_FEE_RATE, "Invalid fee rate");
        feeRateBasisPoints = _feeRateBasisPoints;
        emit FeeRateSet(_feeRateBasisPoints);
    }

    /**
     * @notice Get the current percentage fee rate
     * @return Current fee rate in basis points
     */
    function getFeeRateBasisPoints() public view returns (uint256) {
        return feeRateBasisPoints;
    }

    /**
     * @notice Set gas fee for a specific target chain
     * @dev Only admin can call this function. Overrides default gas fee for specific chains.
     * @param targetChainId Chain ID for which to set the gas fee
     * @param _gasfee Gas fee amount for the specified chain
     */
    function setChainGasfee(uint256 targetChainId, uint256 _gasfee) external onlyRole(ADMIN_ROLE) {
        chainGasFees[targetChainId] = _gasfee;
        emit ChainGasFeeSet(targetChainId, _gasfee);
    }

    /**
     * @notice Remove gas fee setting for a specific target chain
     * @dev Only admin can call this function. Chain will use default gas fee after removal.
     * @param targetChainId Chain ID for which to remove the custom gas fee
     */
    function removeChainGasfee(uint256 targetChainId) external onlyRole(ADMIN_ROLE) {
        delete chainGasFees[targetChainId];
        emit ChainGasFeeRemoved(targetChainId);
    }

    /**
     * @notice Get gas fee for a specific target chain
     * @dev Returns chain-specific gas fee if set, otherwise returns default gas fee
     * @param targetChainId Chain ID to query gas fee for
     * @return Gas fee amount for the specified chain
     */
    function getChainGasfee(uint256 targetChainId) public view returns (uint256) {
        uint256 chainGasFee = chainGasFees[targetChainId];
        return chainGasFee > 0 ? chainGasFee : gasfee;
    }

    /**
     * @notice Calculate percentage fee for a given amount
     * @dev Uses current fee rate to calculate fee in basis points
     * @param amount Amount to calculate fee for
     * @return Calculated fee amount
     */
    function calculateFee(uint256 amount) public view returns (uint256) {
        return (amount * feeRateBasisPoints) / BASIS_POINTS_DENOMINATOR;
    }

    /**
     * @notice Set the fee recipient address
     * @dev Only admin can call this function. All cross-chain fees are sent to this address.
     * @param _feeRecipient New address to receive fees
     */
    function setFeeRecipient(address _feeRecipient) external onlyRole(ADMIN_ROLE) {
        require(_feeRecipient != address(0), "Fee recipient cannot be zero");
        feeRecipient = _feeRecipient;
        emit FeeRecipientSet(_feeRecipient);
    }

    /**
     * @notice Burn WeUSD tokens for cross-chain transfer
     * @dev Burns tokens on source chain and reserves stablecoin for cross-chain operations.
     *      Charges gas fee and percentage fee, then burns remaining amount.
     * @param targetChainId Chain ID where WeUSD will be minted
     * @param amount Total amount including fees to be processed
     * @param outerUser Target user identifier on destination chain
     */
    function burnWeUSDCrossChain(uint256 targetChainId, uint256 amount, string memory outerUser) external {
        require(targetChainId != block.chainid, "Target chain must be different from source chain");
        require(supportedChains[targetChainId], "Unsupported target chain");
        require(bytes(outerUser).length > 0, "Invalid outer user address");
        
        // Calculate fees
        uint256 currentGasFee = getChainGasfee(targetChainId);
        uint256 percentageFee = calculateFee(amount);
        uint256 totalFee = currentGasFee + percentageFee;
        
        require(amount > totalFee, "Amount must be greater than total fees");
        
        // Generate unique request ID
        uint256 sourceChainId = block.chainid;
        uint256 requestId = (sourceChainId << 128) | (WEUSD_SALT << 64) | (++requestCount);
        require(!requestExists(requestId), "Request ID already exists");
        
        // Calculate burn amount after fees
        uint256 burnAmount = amount - totalFee;
        
        // Transfer fee to fee recipient
        require(weUSD.transferFrom(msg.sender, feeRecipient, totalFee), "Fee transfer failed");
        
        // Burn WeUSD tokens and reserve stablecoin
        weUSD.burnFrom(msg.sender, burnAmount);
        mintRedeem.reserveStablecoinForCrossChain(burnAmount);
        
        // Create request record and emit event
        _createRequest(requestId, msg.sender, outerUser, burnAmount, true, targetChainId);
        emit CrossChainBurn(requestId, msg.sender, outerUser, sourceChainId, targetChainId, burnAmount);
    }

    /**
     * @notice Mint WeUSD tokens on target chain for cross-chain transfer
     * @dev Only cross-chain minter can call this. Mints tokens and returns stablecoin to reserves.
     * @param requestId Unique request ID to prevent duplicate processing
     * @param sourceChainId Chain ID where the burn occurred
     * @param amount Amount of WeUSD to mint
     * @param localUser Address to receive the minted WeUSD
     * @param outerUser Source user identifier from origin chain
     */
    function mintWeUSDCrossChain(
        uint256 requestId, 
        uint256 sourceChainId, 
        uint256 amount, 
        address localUser,
        string memory outerUser
    ) external onlyRole(CROSS_CHAIN_MINTER_ROLE) {
        require(sourceChainId != block.chainid, "Source chain must be different from target chain");
        require(amount > 0, "Amount must be greater than 0");
        require(localUser != address(0), "Invalid local user address");
        require(!requestExists(requestId), "Request ID already exists");
        
        // Mint WeUSD tokens and return stablecoin to reserves
        weUSD.mint(localUser, amount);
        mintRedeem.returnStablecoinFromCrossChain(amount);
        
        // Create request record and emit event
        _createRequest(requestId, localUser, outerUser, amount, false, block.chainid);
        emit CrossChainMint(requestId, localUser, outerUser, sourceChainId, block.chainid, amount);
    }

    /**
     * @notice Batch mint WeUSD tokens for multiple cross-chain transfers
     * @dev Only cross-chain minter can call this. Processes multiple mint requests atomically.
     * @param requestIds Array of unique request IDs
     * @param sourceChainIds Array of source chain IDs
     * @param amounts Array of amounts to mint
     * @param localUsers Array of addresses to receive minted WeUSD
     * @param outerUsers Array of source user identifiers
     */
    function batchMintWeUSDCrossChain(
        uint256[] calldata requestIds, 
        uint256[] calldata sourceChainIds, 
        uint256[] calldata amounts, 
        address[] calldata localUsers,
        string[] calldata outerUsers
    ) external onlyRole(CROSS_CHAIN_MINTER_ROLE) {
        require(
            requestIds.length == sourceChainIds.length && 
            requestIds.length == amounts.length && 
            requestIds.length == localUsers.length &&
            requestIds.length == outerUsers.length, 
            "Input arrays must have the same length"
        );

        // Validate all inputs first to ensure atomicity
        for (uint256 i = 0; i < requestIds.length; i++) {
            require(sourceChainIds[i] != block.chainid, "Source chain must be different from target chain");
            require(amounts[i] > 0, "Amount must be greater than 0");
            require(localUsers[i] != address(0), "Invalid local user address");
            require(!requestExists(requestIds[i]), "Request ID already exists");
        }

        // Execute all operations after validation
        for (uint256 i = 0; i < requestIds.length; i++) {
            // Mint WeUSD tokens and return stablecoin to reserves
            weUSD.mint(localUsers[i], amounts[i]);           
            mintRedeem.returnStablecoinFromCrossChain(amounts[i]);           
            
            // Create request record and emit event
            _createRequest(requestIds[i], localUsers[i], outerUsers[i], amounts[i], false, block.chainid);
            emit CrossChainMint(requestIds[i], localUsers[i], outerUsers[i], sourceChainIds[i], block.chainid, amounts[i]);
        }
    }

    /**
     * @notice Get total number of cross-chain requests processed
     * @return Current request count
     */
    function getRequestCount() public view returns (uint256) {
        return requestCount;
    }    
    
    /**
     * @notice Get request data by request ID
     * @dev Returns empty struct if request doesn't exist
     * @param _requestId Unique identifier of the request
     * @return RequestData struct containing request details
     */
    function getRequestById(uint256 _requestId) public view returns (RequestData memory) {
        return requests[_requestId];
    }

    /**
     * @notice Check if a request exists
     * @param _requestId Unique identifier of the request
     * @return True if request exists, false otherwise
     */
    function requestExists(uint256 _requestId) public view returns (bool) {
        return requests[_requestId].requestId != 0;
    }
    
    /**
     * @notice Check if multiple requests exist
     * @param _requestIds Array of request IDs to check
     * @return Array of boolean values indicating existence of each request
     */
    function batchRequestExists(uint256[] calldata _requestIds) public view returns (bool[] memory) {
        uint256 len = _requestIds.length;
        bool[] memory results = new bool[](len);
        for (uint256 i = 0; i < len; i++) {
            results[i] = requestExists(_requestIds[i]);
        }
        return results;
    }

    /**
     * @notice Get request data by count number
     * @dev Reconstructs request ID from count and retrieves data
     * @param count Count number of the request (1-based)
     * @return RequestData struct containing request details
     */
    function getRequestByCount(uint256 count) public view returns (RequestData memory) {
        require(count > 0 && count <= requestCount, "Invalid count");
        
        uint256 sourceChainId = block.chainid;
        uint256 requestId = (sourceChainId << 128) | (WEUSD_SALT << 64) | (count);
        require(requestExists(requestId), "Request does not exist");
        
        return getRequestById(requestId);
    }

    /**
     * @notice Get multiple requests starting from a specific count with pagination
     * @param startCount Starting count number (1-based)
     * @param page Page number (1-based, 0 means no pagination)
     * @param pageSize Number of items per page (0 means no pagination)
     * @return Array of RequestData and total number of available records
     */
    function getRequestsFromCount(
        uint256 startCount,
        uint256 page,
        uint256 pageSize
    ) public view returns (RequestData[] memory, uint256) {
        require(startCount > 0, "Start count must be greater than 0");
        require(startCount <= requestCount, "Start count exceeds request count");
        require((page == 0 && pageSize == 0) || (page > 0 && pageSize > 0), "Invalid page or page size");

        uint256 totalRecords = requestCount - startCount + 1;
        uint256 startIndex = 0;
        uint256 endIndex = totalRecords;

        // Apply pagination if specified
        if (page > 0 && pageSize > 0) {
            startIndex = (page - 1) * pageSize;
            if (startIndex >= totalRecords) {
                RequestData[] memory emptyArray = new RequestData[](0);
                return (emptyArray, totalRecords);
            }
            endIndex = Math.min(startIndex + pageSize, totalRecords);
        }

        // Build result array
        RequestData[] memory requestDataArray = new RequestData[](endIndex - startIndex);
        for (uint256 i = 0; i < (endIndex - startIndex); i++) {
            uint256 currentCount = startCount + (startIndex + i);
            uint256 sourceChainId = block.chainid;
            uint256 requestId = (sourceChainId << 128) | (WEUSD_SALT << 64) | currentCount;
            require(requestExists(requestId), "Request does not exist");
            requestDataArray[i] = getRequestById(requestId);
        }

        return (requestDataArray, totalRecords);
    }

    /**
     * @notice Get source chain requests for a specific user with pagination
     * @param _user User address to query
     * @param _page Page number (1-based, 0 means no pagination)
     * @param _pageSize Number of items per page (0 means no pagination)
     * @return Array of source request IDs and total count for the user
     */
    function getUserSourceRequests(address _user, uint256 _page, uint256 _pageSize) public view returns (uint256[] memory, uint256) {
        require((_page == 0 && _pageSize == 0) || (_page > 0 && _pageSize > 0), "Invalid page or page size");

        // Count total requests for user
        uint256 totalRequests = 0;
        for (uint256 i = 0; i < activeSourceRequests.length; i++) {
            if (requests[activeSourceRequests[i]].localUser == _user) {
                totalRequests++;
            }
        }

        // Calculate pagination bounds
        uint256 startIndex = 0;
        uint256 endIndex = totalRequests;

        if (_page > 0 && _pageSize > 0) {
            startIndex = totalRequests - (_page * _pageSize);
            if (startIndex > totalRequests) startIndex = 0;
            endIndex = startIndex + _pageSize;
            if (endIndex > totalRequests) endIndex = totalRequests;
        }

        // Build result array (newest first)
        uint256[] memory userSourceRequests = new uint256[](endIndex - startIndex);
        uint256 count = 0;

        for (uint256 i = activeSourceRequests.length; i > 0 && count < userSourceRequests.length; i--) {
            uint256 requestId = activeSourceRequests[i-1];
            if (requests[requestId].localUser == _user) {
                if (totalRequests - count > startIndex) {
                    userSourceRequests[count] = requestId;
                    count++;
                } else {
                    break;
                }
            }
        }

        return (userSourceRequests, totalRequests);
    }

    /**
     * @notice Get target chain requests for a specific user with pagination
     * @param _user User address to query
     * @param _page Page number (1-based, 0 means no pagination)
     * @param _pageSize Number of items per page (0 means no pagination)
     * @return Array of target request IDs and total count for the user
     */
    function getUserTargetRequests(address _user, uint256 _page, uint256 _pageSize) public view returns (uint256[] memory, uint256) {
        require((_page == 0 && _pageSize == 0) || (_page > 0 && _pageSize > 0), "Invalid page or page size");

        // Count total requests for user
        uint256 totalRequests = 0;
        for (uint256 i = 0; i < activeTargetRequests.length; i++) {
            if (requests[activeTargetRequests[i]].localUser == _user) {
                totalRequests++;
            }
        }

        // Calculate pagination bounds
        uint256 startIndex = 0;
        uint256 endIndex = totalRequests;

        if (_page > 0 && _pageSize > 0) {
            startIndex = totalRequests - (_page * _pageSize);
            if (startIndex > totalRequests) startIndex = 0;
            endIndex = startIndex + _pageSize;
            if (endIndex > totalRequests) endIndex = totalRequests;
        }

        // Build result array (newest first)
        uint256[] memory userTargetRequests = new uint256[](endIndex - startIndex);
        uint256 count = 0;

        for (uint256 i = activeTargetRequests.length; i > 0 && count < userTargetRequests.length; i--) {
            uint256 requestId = activeTargetRequests[i-1];
            if (requests[requestId].localUser == _user) {
                if (totalRequests - count > startIndex) {
                    userTargetRequests[count] = requestId;
                    count++;
                } else {
                    break;
                }
            }
        }

        return (userTargetRequests, totalRequests);
    }

    /**
     * @notice Add a chain to the list of supported chains
     * @dev Only admin can call this function
     * @param targetChainId Chain ID to add to supported chains
     */
    function addSupportedChain(uint256 targetChainId) external onlyRole(ADMIN_ROLE) {
        supportedChains[targetChainId] = true;
        emit SupportedChainAdded(targetChainId);
    }

    /**
     * @notice Remove a chain from the list of supported chains
     * @dev Only admin can call this function
     * @param targetChainId Chain ID to remove from supported chains
     */
    function removeSupportedChain(uint256 targetChainId) external onlyRole(ADMIN_ROLE) {
        supportedChains[targetChainId] = false;
        emit SupportedChainRemoved(targetChainId);
    }

    /**
     * @notice Archive and delete a source request
     * @dev Only admin can call this function. Permanently removes request data.
     * @param requestId Request ID to archive and delete
     */
    function archiveAndDeleteSourceRequest(uint256 requestId) public onlyRole(ADMIN_ROLE) {
        uint256 idx = requestIdToSourceActiveIndex[requestId];
        require(activeSourceRequests.length > idx && activeSourceRequests[idx] == requestId, "Invalid requestId");
        
        // Swap with last element and pop (gas efficient removal)
        uint256 lastIndex = activeSourceRequests.length - 1;
        if (idx != lastIndex) {
            uint256 lastId = activeSourceRequests[lastIndex];
            activeSourceRequests[idx] = lastId;
            requestIdToSourceActiveIndex[lastId] = idx;
        }
        
        // Remove from arrays and mappings
        activeSourceRequests.pop();
        delete requestIdToSourceActiveIndex[requestId];
        delete requests[requestId];
        
        emit SourceRequestArchivedAndDeleted(requestId);
    }

    /**
     * @notice Archive and delete a target request
     * @dev Only admin can call this function. Permanently removes request data.
     * @param requestId Request ID to archive and delete
     */
    function archiveAndDeleteTargetRequest(uint256 requestId) public onlyRole(ADMIN_ROLE) {
        uint256 idx = requestIdToTargetActiveIndex[requestId];
        require(activeTargetRequests.length > idx && activeTargetRequests[idx] == requestId, "Invalid requestId");
        
        // Swap with last element and pop (gas efficient removal)
        uint256 lastIndex = activeTargetRequests.length - 1;
        if (idx != lastIndex) {
            uint256 lastId = activeTargetRequests[lastIndex];
            activeTargetRequests[idx] = lastId;
            requestIdToTargetActiveIndex[lastId] = idx;
        }
        
        // Remove from arrays and mappings
        activeTargetRequests.pop();
        delete requestIdToTargetActiveIndex[requestId];
        delete requests[requestId];
        
        emit TargetRequestArchivedAndDeleted(requestId);
    }

    /**
     * @notice Batch archive and delete multiple source requests
     * @dev Only admin can call this function. Processes multiple requests efficiently.
     * @param requestIds Array of request IDs to archive and delete
     */
    function batchArchiveAndDeleteSourceRequests(uint256[] calldata requestIds) external onlyRole(ADMIN_ROLE) {
        for (uint256 i = 0; i < requestIds.length; i++) {
            uint256 requestId = requestIds[i];
            // Check if request exists and is valid before attempting deletion
            if (requestIdToSourceActiveIndex[requestId] < activeSourceRequests.length && 
                activeSourceRequests[requestIdToSourceActiveIndex[requestId]] == requestId) {
                archiveAndDeleteSourceRequest(requestId);
            }
        }
    }

    /**
     * @notice Batch archive and delete multiple target requests
     * @dev Only admin can call this function. Processes multiple requests efficiently.
     * @param requestIds Array of request IDs to archive and delete
     */
    function batchArchiveAndDeleteTargetRequests(uint256[] calldata requestIds) external onlyRole(ADMIN_ROLE) {
        for (uint256 i = 0; i < requestIds.length; i++) {
            uint256 requestId = requestIds[i];
            // Check if request exists and is valid before attempting deletion
            if (requestIdToTargetActiveIndex[requestId] < activeTargetRequests.length && 
                activeTargetRequests[requestIdToTargetActiveIndex[requestId]] == requestId) {
                archiveAndDeleteTargetRequest(requestId);
            }
        }
    }

    /**
     * @notice Internal function to create and store request data
     * @dev Creates request record and adds to appropriate tracking arrays
     * @param _requestId Unique identifier for the request
     * @param _localUser Address of the local user
     * @param _outerUser Identifier of the remote user
     * @param _amount Amount involved in the request
     * @param _isburn Whether this is a burn (true) or mint (false) request
     * @param _targetChainId Target chain ID for the request
     */
    function _createRequest(
        uint256 _requestId, 
        address _localUser, 
        string memory _outerUser, 
        uint256 _amount, 
        bool _isburn, 
        uint256 _targetChainId
    ) internal {
        // Create request data structure
        RequestData memory newRequest = RequestData({
            requestId: _requestId,
            localUser: _localUser,
            outerUser: _outerUser,
            amount: _amount,
            isburn: _isburn,
            targetChainId: _targetChainId
        });
        
        // Store request data
        requests[_requestId] = newRequest;
        
        // Add to appropriate tracking array and index mapping
        if(_isburn){
            activeSourceRequests.push(_requestId);
            requestIdToSourceActiveIndex[_requestId] = activeSourceRequests.length - 1;
        } else {
            activeTargetRequests.push(_requestId);
            requestIdToTargetActiveIndex[_requestId] = activeTargetRequests.length - 1;
        }
    }
}