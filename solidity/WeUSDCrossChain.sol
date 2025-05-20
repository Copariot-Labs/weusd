// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "./IPicweUSD.sol";
import "./IWeUSDMintRedeem.sol";

struct RequestData {
    uint256 requestId;
    address localUser;
    string outerUser;
    uint256 amount;
    bool isburn;
    uint256 targetChainId;
}

contract WeUSDCrossChain is AccessControl {
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant CROSS_CHAIN_MINTER_ROLE = keccak256("CROSS_CHAIN_MINTER_ROLE");
    IPicweUSD public weUSD;
    IWeUSDMintRedeem public mintRedeem;
    uint256 public requestCount;
    uint8 public constant WEUSD_DECIMALS = 6;
    uint256 public constant WEUSD_SALT = 2;
    uint256 public constant BASIS_POINTS_DENOMINATOR = 10000;
    // 0.3%
    uint256 private feeRateBasisPoints = 30;
    uint256 public gasfee = 5*10**(6-1);
    address public feeRecipient;

    uint256[] public activeSourceRequests;
    uint256[] public activeTargetRequests;

    mapping(uint256 => uint256) public chainGasFees;
    mapping(uint256 => RequestData) private requests;
    mapping(uint256 => uint256) public requestIdToSourceActiveIndex;
    mapping(uint256 => uint256) public requestIdToTargetActiveIndex;

    event CrossChainBurn(uint256 indexed requestId, address indexed localUser, string outerUser, uint256 sourceChainId, uint256 targetChainId, uint256 amount);
    event CrossChainMint(uint256 indexed requestId, address indexed localUser, string outerUser, uint256 sourceChainId, uint256 targetChainId, uint256 amount);
    event MintRedeemContractSet(address indexed mintRedeemContract);
    event ChainGasFeeSet(uint256 indexed targetChainId, uint256 gasfee);
    event ChainGasFeeRemoved(uint256 indexed targetChainId);
    event FeeRateSet(uint256 feeRateBasisPoints);

    constructor(address _weUSD, address _crossChainMinter, address _feeRecipient) {
        weUSD = IPicweUSD(_weUSD);
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(CROSS_CHAIN_MINTER_ROLE, _crossChainMinter);
        feeRecipient = _feeRecipient;
    }

    /**
     * @dev Sets the mint redeem contract
     * @param _mintRedeem The address of the WeUSDMintRedeem contract
     */
    function setMintRedeemContract(address _mintRedeem) external onlyRole(ADMIN_ROLE) {
        mintRedeem = IWeUSDMintRedeem(_mintRedeem);
        emit MintRedeemContractSet(_mintRedeem);
    }

    /**
     * @dev Sets the gas fee (gasfee).
     * @param _gasfee The new gas fee amount.
     * 
     * @notice This function can only be called by users with the ADMIN_ROLE.
     * @notice A GasFeeSet event will be triggered after successful setting.
     */
    function setGasfee(uint256 _gasfee) external onlyRole(ADMIN_ROLE) {
        gasfee = _gasfee;
    }

    /**
     * @dev Sets the fee rate in basis points (e.g., 30 = 0.3%).
     * @param _feeRateBasisPoints The new fee rate in basis points.
     * 
     * @notice This function can only be called by users with the ADMIN_ROLE.
     * @notice A FeeRateSet event will be triggered after successful setting.
     */
    function setFeeRateBasisPoints(uint256 _feeRateBasisPoints) external onlyRole(ADMIN_ROLE) {
        feeRateBasisPoints = _feeRateBasisPoints;
        emit FeeRateSet(_feeRateBasisPoints);
    }

    /**
     * @dev Gets the current fee rate in basis points.
     * @return The current fee rate in basis points.
     */
    function getFeeRateBasisPoints() public view returns (uint256) {
        return feeRateBasisPoints;
    }

    /**
     * @dev Sets the gas fee for a specific target chain.
     * @param targetChainId The ID of the target chain.
     * @param _gasfee The new gas fee amount for the target chain.
     * 
     * @notice This function can only be called by users with the ADMIN_ROLE.
     * @notice A ChainGasFeeSet event will be triggered after successful setting.
     */
    function setChainGasfee(uint256 targetChainId, uint256 _gasfee) external onlyRole(ADMIN_ROLE) {
        chainGasFees[targetChainId] = _gasfee;
        emit ChainGasFeeSet(targetChainId, _gasfee);
    }

    /**
     * @dev Removes the gas fee setting for a specific target chain.
     * @param targetChainId The ID of the target chain.
     * 
     * @notice This function can only be called by users with the ADMIN_ROLE.
     * @notice After removal, the default gas fee will be used for this chain.
     * @notice A ChainGasFeeRemoved event will be triggered after successful removal.
     */
    function removeChainGasfee(uint256 targetChainId) external onlyRole(ADMIN_ROLE) {
        delete chainGasFees[targetChainId];
        emit ChainGasFeeRemoved(targetChainId);
    }

    /**
     * @dev Gets the gas fee for a specific target chain.
     * @param targetChainId The ID of the target chain.
     * @return The gas fee for the target chain, or the default gas fee if not set.
     */
    function getChainGasfee(uint256 targetChainId) public view returns (uint256) {
        uint256 chainGasFee = chainGasFees[targetChainId];
        return chainGasFee > 0 ? chainGasFee : gasfee;
    }

    /**
     * @dev Calculates the percentage fee for a given amount using the current fee rate
     * @param amount The amount to calculate the fee on
     * @return The calculated fee amount
     */
    function calculateFee(uint256 amount) public view returns (uint256) {
        return (amount * feeRateBasisPoints) / BASIS_POINTS_DENOMINATOR;
    }

    /**
     * @dev Sets the fee recipient (feeRecipient).
     * @param _feeRecipient The new fee recipient address.
     * 
     * @notice This function can only be called by users with the ADMIN_ROLE.
     * @notice A FeeRecipientSet event will be triggered after successful setting.
     */
    function setFeeRecipient(address _feeRecipient) external onlyRole(ADMIN_ROLE) {
        feeRecipient = _feeRecipient;
    }
    /**
     * @dev Burns weUSD tokens on the source chain for cross-chain transfer.
     * @param targetChainId The ID of the target chain where weUSD will be minted.
     * @param amount The total amount of weUSD to be burned (including gas fee and percentage fee).
     * @param outerUser The address or identifier of the user on the target chain to receive the minted weUSD.
     *
     * @notice This function can be called by any user.
     * @notice A portion of the amount is deducted as gas fee and percentage fee and transferred to the fee recipient.
     * @notice The remaining amount is burned from the sender's balance.
     * @notice A CrossChainBurn event is emitted after successful burning.
     */
    function burnWeUSDCrossChain(uint256 targetChainId, uint256 amount, string memory outerUser) external {
        require(targetChainId != block.chainid, "Target chain must be different from source chain");
        uint256 currentGasFee = getChainGasfee(targetChainId);
        uint256 percentageFee = calculateFee(amount);
        uint256 totalFee = currentGasFee + percentageFee;
        
        require(amount > totalFee, "Amount must be greater than total fees");
        require(bytes(outerUser).length > 0, "Invalid outer user address");
        uint256 sourceChainId = block.chainid;
        uint256 requestId = (sourceChainId << 128) | (WEUSD_SALT << 64) | (++requestCount);
        require(!requestExists(requestId), "Request ID already exists");
        uint256 burnAmount = amount - totalFee;
        weUSD.transferFrom(msg.sender, feeRecipient, totalFee);
        weUSD.burnFrom(msg.sender, burnAmount);
        mintRedeem.reserveStablecoinForCrossChain(burnAmount);
        _createRequest(requestId, msg.sender, outerUser, burnAmount, true, targetChainId);
        emit CrossChainBurn(requestId, msg.sender, outerUser, sourceChainId, targetChainId, burnAmount);
    }

    /**
     * @dev Mints weUSD tokens on the target chain for cross-chain transfer.
     * @param requestId Unique request ID to prevent duplicate processing
     * @param sourceChainId ID of the source chain
     * @param amount Amount of weUSD to be minted
     * @param localUser Address of the target user to receive the minted weUSD
     * @param outerUser Address of the source user to receive the minted weUSD
     *
     * @notice This function can only be called by addresses with the CROSS_CHAIN_MINTER_ROLE role
     * @notice The requestId must not have been used before
     * @notice The source chain must be different from the current chain
     * @notice The minting amount must be greater than 0
     * @notice The local user address cannot be the zero address
     * @notice A CrossChainMint event will be emitted after successful minting
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
        weUSD.mint(localUser, amount);
        mintRedeem.returnStablecoinFromCrossChain(amount);
        _createRequest(requestId, localUser, outerUser, amount, false, block.chainid);
        emit CrossChainMint(requestId, localUser, outerUser, sourceChainId, block.chainid, amount);
    }

    /**
    * @dev Batch mints weUSD tokens on the target chain for cross-chain transfer.
    * @param requestIds Array of unique request IDs to prevent duplicate processing
    * @param sourceChainIds Array of IDs of the source chains
    * @param amounts Array of amounts of weUSD to be minted
    * @param localUsers Array of addresses of the target users to receive the minted weUSD
    * @param outerUsers Array of addresses of the source users to receive the minted weUSD
    *
    * @notice This function can only be called by addresses with the CROSS_CHAIN_MINTER_ROLE role
    * @notice All input arrays must have the same length
    * @notice Each requestId must not have been used before
    * @notice Each source chain must be different from the current chain
    * @notice Each minting amount must be greater than 0
    * @notice Each local user address cannot be the zero address
    * @notice A CrossChainMint event will be emitted for each successful minting
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

        for (uint256 i = 0; i < requestIds.length; i++) {
            require(sourceChainIds[i] != block.chainid, "Source chain must be different from target chain");
            require(amounts[i] > 0, "Amount must be greater than 0");
            require(localUsers[i] != address(0), "Invalid local user address");
            require(!requestExists(requestIds[i]), "Request ID already exists");
            weUSD.mint(localUsers[i], amounts[i]);           
            mintRedeem.returnStablecoinFromCrossChain(amounts[i]);           
            _createRequest(requestIds[i], localUsers[i], outerUsers[i], amounts[i], false, block.chainid);
            emit CrossChainMint(requestIds[i], localUsers[i], outerUsers[i], sourceChainIds[i], block.chainid, amounts[i]);
        }
    }
    
    /**
     * @dev Retrieves the request data for a given request ID
     * @param _requestId The unique identifier of the request
     * @return RequestData struct containing the request details
     * 
     * @notice This function can be called by any address
     * @notice Returns a struct with default values if the request ID doesn't exist
     */
    function getRequestById(uint256 _requestId) public view returns (RequestData memory) {
        return requests[_requestId];
    }

    /**
     * @dev Checks if a request exists for a given request ID
     * @param _requestId The unique identifier of the request
     * @return bool indicating whether the request exists
     * 
     * @notice This function can be called by any address
     */
    function requestExists(uint256 _requestId) public view returns (bool) {
        return requests[_requestId].requestId != 0;
    }
    
    /**
     * @dev Checks if multiple requests exist for a given list of request IDs
     * @param _requestIds An array of unique identifiers of the requests
     * @return bool[] An array of booleans indicating whether each corresponding request exists
     * 
     * @notice This function can be called by any address
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
     * @dev Retrieves the request data for a given request count
     * @param count The count number of the request
     * @return RequestData struct containing the request details
     * 
     * @notice This function can be called by any address
     * @notice Reverts if the count is invalid or the request doesn't exist
     */
    function getRequestByCount(uint256 count) public view returns (RequestData memory) {
        require(count > 0 && count <= requestCount, "Invalid count");
        
        uint256 sourceChainId = block.chainid;
        uint256 requestId = (sourceChainId << 128) | (WEUSD_SALT << 64) | (count);
        require(requestExists(requestId), "Request does not exist");
        
        return getRequestById(requestId);
    }

    /**
     * @dev Retrieves multiple requests starting from a specific count
     * @param startCount The starting count number
     * @param page Page number (starting from 1)
     * @param pageSize Number of items per page
     * @return RequestData[] Array of request data for the specified range
     * @return uint256 Total number of records available from startCount
     * 
     * @notice This function can be called by any address
     * @notice If page or pageSize is 0, all requests from startCount will be returned
     * @notice Returns an empty array if no records are found in the specified range
     */
    function getRequestsFromCount(
        uint256 startCount,
        uint256 page,
        uint256 pageSize
    ) public view returns (RequestData[] memory, uint256) {
        require(startCount > 0, "Start count must be greater than 0");
        require(startCount <= requestCount, "Start count exceeds request count");
        require(page == 0 || pageSize == 0 || (page > 0 && pageSize > 0), "Invalid page or page size");

        uint256 totalRecords = requestCount - startCount + 1;
        uint256 startIndex = 0;
        uint256 endIndex = totalRecords;

        if (page > 0 && pageSize > 0) {
            startIndex = (page - 1) * pageSize;
            if (startIndex >= totalRecords) {
                RequestData[] memory emptyArray = new RequestData[](0);
                return (emptyArray, totalRecords);
            }
            endIndex = Math.min(startIndex + pageSize, totalRecords);
        }

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
     * @dev Get all source chain request IDs for a specific user
     * @param _user User address
     * @param _page Page number (starting from 1)
     * @param _pageSize Number of items per page
     * @return uint256[] Array containing source chain request IDs for the user's specified page
     * @return uint256 Total number of source chain requests for the user
     * 
     * @notice This function can be called by any address
     * @notice If the user has no source chain requests, an empty array will be returned
     * @notice If _page or _pageSize is 0, all requests will be returned
     */
    function getUserSourceRequests(address _user, uint256 _page, uint256 _pageSize) public view returns (uint256[] memory, uint256) {
        require(_page == 0 || _pageSize == 0 || (_page > 0 && _pageSize > 0), "Invalid page or page size");

        uint256 totalRequests = 0;
        for (uint256 i = 0; i < activeSourceRequests.length; i++) {
            if (requests[activeSourceRequests[i]].localUser == _user) {
                totalRequests++;
            }
        }

        uint256 startIndex = 0;
        uint256 endIndex = totalRequests;

        if (_page > 0 && _pageSize > 0) {
            startIndex = totalRequests - (_page * _pageSize);
            if (startIndex > totalRequests) startIndex = 0;
            endIndex = startIndex + _pageSize;
            if (endIndex > totalRequests) endIndex = totalRequests;
        }

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
     * @dev Get all target chain request IDs for a specific user
     * @param _user User address
     * @param _page Page number (starting from 1)
     * @param _pageSize Number of items per page
     * @return uint256[] Array containing target chain request IDs for the user's specified page
     * @return uint256 Total number of target chain requests for the user
     * 
     * @notice Any address can call this function
     * @notice If the user has no target chain requests, an empty array will be returned
     * @notice If _page or _pageSize is 0, all requests will be returned
     */
    function getUserTargetRequests(address _user, uint256 _page, uint256 _pageSize) public view returns (uint256[] memory, uint256) {
        require(_page == 0 || _pageSize == 0 || (_page > 0 && _pageSize > 0), "Invalid page or page size");

        uint256 totalRequests = 0;
        for (uint256 i = 0; i < activeTargetRequests.length; i++) {
            if (requests[activeTargetRequests[i]].localUser == _user) {
                totalRequests++;
            }
        }

        uint256 startIndex = 0;
        uint256 endIndex = totalRequests;

        if (_page > 0 && _pageSize > 0) {
            startIndex = totalRequests - (_page * _pageSize);
            if (startIndex > totalRequests) startIndex = 0;
            endIndex = startIndex + _pageSize;
            if (endIndex > totalRequests) endIndex = totalRequests;
        }

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

    // internal functions
    function _createRequest(uint256 _requestId, address _localUser, string memory _outerUser, uint256 _amount, bool _isburn, uint256 _targetChainId) internal {
        RequestData memory newRequest = RequestData({
            requestId: _requestId,
            localUser: _localUser,
            outerUser: _outerUser,
            amount: _amount,
            isburn: _isburn,
            targetChainId: _targetChainId
        });
        
        requests[_requestId] = newRequest;
        if(_isburn){
            activeSourceRequests.push(_requestId);
        }else{
            activeTargetRequests.push(_requestId);
        }
        if(_isburn){
            requestIdToSourceActiveIndex[_requestId] = activeSourceRequests.length - 1;
        }else{
            requestIdToTargetActiveIndex[_requestId] = activeTargetRequests.length - 1;
        }
    }
}