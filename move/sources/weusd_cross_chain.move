module picwe::weusd_cross_chain {
    use std::vector;
    use aptos_std::smart_table;
    use aptos_framework::account;
    use aptos_framework::event;
    use std::string::String;

    const WEUSD_SALT: u256 = 2;
    const Block_chainid: u256 = 7777777;

    const INITIAL_FEE_RECIPIENT: address = @weusd_fee_address;
    const INITIAL_CROSS_CHAIN_MINT_ROLE: address = @crosschain_mint_role;

    // Deprecated error code
    const E_DEPRECATED_MODULE: u64 = 2000; // Deprecated module error

    //error code
    const ENOT_OWNER: u64 = 1000;
    const E_DIFF: u64 = 1020; //"Target chain must be different from source chain"
    const E_NotEnoughAmout: u64 = 1021; //Amount must be greater than gasfee
    const E_InvalidTargetUserAddress: u64 = 1022; //Invalid target user address
    const E_RequestIdAlreadyExists: u64 = 1023; //Request ID already exists
    const E_ONLY_OWNER_CAN_SET_ROLE: u64 = 1024;
    const E_NOTACL: u64 = 1025;
    const E_INVALID_PAGINATION: u64 = 1026;
    const E_INVALID_REQUEST_ID: u64 = 1027;
    const E_REQUEST_NOT_FOUND: u64 = 1028;
    const E_INVALID_ARGS: u64 = 1029;

    struct RequestData has store, copy, drop {
        requestId: u256,
        localUser: address,
        outerUser: String,
        amount: u64,
        isburn: bool
    }

    struct GlobalManage has key {
        requestCount: u256,
        gasfee: u64,
        feeRecipient: address,
        activeSourceRequests: vector<u256>,
        activeTargetRequests: vector<u256>,
        requests: smart_table::SmartTable<u256, RequestData>,
        requestIdToSourceActiveIndex: smart_table::SmartTable<u256, u256>,
        requestIdToTargetActiveIndex: smart_table::SmartTable<u256, u256>,
        cross_mint_role_contract: address
    }

    struct EventHandles has key {
        cross_chain_burn_events: event::EventHandle<CrossChainBurn>,
        cross_chain_mint_events: event::EventHandle<CrossChainMint>
    }

    #[event]
    struct CrossChainBurn has drop, store {
        requestId: u256,
        localUser: address,
        outerUser: String,
        sourceChainId: u256,
        targetChainId: u256,
        amount: u64
    }

    #[event]
    struct CrossChainMint has drop, store {
        requestId: u256,
        localUser: address,
        outerUser: String,
        sourceChainId: u256,
        targetChainId: u256,
        amount: u64
    }

    #[view]
    public fun getRequestById(_requestId: u256): RequestData  {
        // Deprecated module, return error
        abort E_DEPRECATED_MODULE
    }

    #[view]
    public fun batchGetRequestById(_requestIds: vector<u256>): vector<RequestData>  {
        // Deprecated module, return error
        abort E_DEPRECATED_MODULE
    }

    #[view]
    public fun requestExists(_requestId: u256): bool  {
        // Deprecated module, return error
        abort E_DEPRECATED_MODULE
    }

    #[view]
    public fun batchRequestExists(_requestIds: vector<u256>): vector<bool>  {
        // Deprecated module, return error
        abort E_DEPRECATED_MODULE
    }

    #[view]
    fun getGasfee(): u64  {
        // Deprecated module, return error
        abort E_DEPRECATED_MODULE
    }

    #[view]
    public fun getUserSourceRequests(
        _user: address,
        _page: u64,
        _page_size: u64
    ): (vector<u256>, u64)  {
        // Deprecated module, return error
        abort E_DEPRECATED_MODULE
    }

    #[view]
    public fun getUserTargetRequests(
        _user: address,
        _page: u64,
        _page_size: u64
    ): (vector<u256>, u64)  {
        // Deprecated module, return error
        abort E_DEPRECATED_MODULE
    }

    #[view]
    public fun getRequestByCount(_count: u256): RequestData  {
        // Deprecated module, return error
        abort E_DEPRECATED_MODULE
    }

    #[view]
    public fun getRequestsFromCount(
        _start_count: u256,
        _page: u64,
        _page_size: u64
    ): (vector<RequestData>, u256)  {
        // Deprecated module, return error
        abort E_DEPRECATED_MODULE
    }
    
    fun init_module(_contract: &signer) {
        // Structure remains the same, but logic is deprecated
        move_to(
            _contract,
            GlobalManage {
                requestCount: 0,
                gasfee: 0,
                feeRecipient: INITIAL_FEE_RECIPIENT,
                activeSourceRequests: vector::empty(),
                activeTargetRequests: vector::empty(),
                requests: smart_table::new<u256, RequestData>(),
                requestIdToSourceActiveIndex: smart_table::new<u256, u256>(),
                requestIdToTargetActiveIndex: smart_table::new<u256, u256>(),
                cross_mint_role_contract: INITIAL_CROSS_CHAIN_MINT_ROLE
            }
        );
        move_to(
            _contract,
            EventHandles {
                cross_chain_burn_events: account::new_event_handle<CrossChainBurn>(_contract),
                cross_chain_mint_events: account::new_event_handle<CrossChainMint>(_contract)
            }
        );
    }

    public entry fun set_cross_chain_minter_role(
        _caller: &signer, _account: address
    )  {
        // Deprecated module, return error
        abort E_DEPRECATED_MODULE
    }

    public entry fun setGasfee(_caller: &signer, _gasfee: u64)  {
        // Deprecated module, return error
        abort E_DEPRECATED_MODULE
    }

    public entry fun setFeeRecipient(
        _caller: &signer, _feeRecipient: address
    )  {
        // Deprecated module, return error
        abort E_DEPRECATED_MODULE
    }

    public entry fun burnWeUSDCrossChain(
        _caller: &signer,
        _targetChainId: u256,
        _amount: u64,
        _outerUser: String
    ) {
        // Deprecated module, return error
        abort E_DEPRECATED_MODULE
    }

    public entry fun mintWeUSDCrossChain(
        _caller: &signer,
        _requestId: u256,
        _sourceChainId: u256,
        _amount: u64,
        _localUser: address,
        _outerUser: String
    ){
        // Deprecated module, return error
        abort E_DEPRECATED_MODULE
    }

    public entry fun batchMintWeUSDCrossChain(
        _caller: &signer,
        _requestIds: vector<u256>,
        _sourceChainIds: vector<u256>,
        _amounts: vector<u64>,
        _localUsers: vector<address>,
        _outerUsers: vector<String>
    )  {
        // Deprecated module, return error
        abort E_DEPRECATED_MODULE
    }

    fun createRequest(
        _requestId: u256,
        _localUser: address,
        _outerUser: String,
        _amount: u64,
        _isburn: bool
    )  {
        // Deprecated module, return error
        abort E_DEPRECATED_MODULE
    }
}
