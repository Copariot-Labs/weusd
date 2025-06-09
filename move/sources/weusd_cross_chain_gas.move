module picwe::weusd_cross_chain_gas {
    use std::signer;
    use std::vector;
    use std::error;
    use aptos_std::smart_table;
    use aptos_framework::account;
    use aptos_framework::event;
    use aptos_framework::primary_fungible_store;
    use picwe::weusd;
    use picwe::weusd_mint_redeem;
    use std::string::{Self, String};

    const WEUSD_SALT: u256 = 2;
    const Block_chainid: u256 = 7777777;
    const BASIS_POINTS_DENOMINATOR: u64 = 10000;
    const DEFAULT_FEE_RATE_BASIS_POINTS: u64 = 100;
    const DEFAULT_CHAIN_GAS_FEE: u64 = 100000;

    const INITIAL_FEE_RECIPIENT: address = @weusd_fee_address;
    const INITIAL_CROSS_CHAIN_MINT_ROLE: address = @crosschain_mint_role;


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
    const E_UNSUPPORTED_CHAIN: u64 = 1030; // Unsupported target chain

    struct RequestData has store, copy, drop {
        requestId: u256,
        localUser: address,
        outerUser: String,
        amount: u64,
        isburn: bool,
        targetChainId: u256
    }

    struct GlobalManage has key {
        requestCount: u256,
        gasfee: u64,
        feeRateBasisPoints: u64,
        chainGasFees: smart_table::SmartTable<u256, u64>,
        feeRecipient: address,
        activeSourceRequests: vector<u256>,
        activeTargetRequests: vector<u256>,
        requests: smart_table::SmartTable<u256, RequestData>,
        requestIdToSourceActiveIndex: smart_table::SmartTable<u256, u256>,
        requestIdToTargetActiveIndex: smart_table::SmartTable<u256, u256>,
        supportedChains: smart_table::SmartTable<u256, bool>,
        cross_mint_role_contract: address
    }

    struct EventHandles has key {
        cross_chain_burn_events: event::EventHandle<CrossChainBurn>,
        cross_chain_mint_events: event::EventHandle<CrossChainMint>,
        source_request_archived_deleted_events: event::EventHandle<SourceRequestArchivedAndDeleted>,
        target_request_archived_deleted_events: event::EventHandle<TargetRequestArchivedAndDeleted>
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

    #[event]
    struct SourceRequestArchivedAndDeleted has drop, store {
        requestId: u256
    }

    #[event]
    struct TargetRequestArchivedAndDeleted has drop, store {
        requestId: u256
    }

    #[view]
    public fun getRequestById(requestId: u256): RequestData acquires GlobalManage {
        let requests = &borrow_global<GlobalManage>(@picwe).requests;
        *smart_table::borrow(requests, requestId)
    }

    #[view]
    public fun batchGetRequestById(requestIds: vector<u256>): vector<RequestData> acquires GlobalManage {
        let len = vector::length(&requestIds);
        let results = vector::empty<RequestData>();
        let i = 0;
        
        while (i < len) {
            let requestId = *vector::borrow(&requestIds, i);
            vector::push_back(&mut results, getRequestById(requestId));
            i = i + 1;
        };
        
        results
    }

    #[view]
    public fun requestExists(requestId: u256): bool acquires GlobalManage {
        let requests = &borrow_global<GlobalManage>(@picwe).requests;
        if (smart_table::contains(requests, requestId)) {
            let request = smart_table::borrow(requests, requestId);
            request.requestId != 0
        } else {
            false
        }
    }

    #[view]
    public fun batchRequestExists(requestIds: vector<u256>): vector<bool> acquires GlobalManage {
        let len = vector::length(&requestIds);
        let results = vector::empty<bool>();
        let i = 0;
        
        while (i < len) {
            let requestId = *vector::borrow(&requestIds, i);
            vector::push_back(&mut results, requestExists(requestId));
            i = i + 1;
        };
        results
    }

    #[view]
    fun getGasfee(): u64 acquires GlobalManage {
        let gasfee = borrow_global<GlobalManage>(@picwe).gasfee;
        gasfee
    }

    #[view]
    fun getChainGasfee(targetChainId: u256): u64 acquires GlobalManage {
        let global_manage = borrow_global<GlobalManage>(@picwe);
        
        if (smart_table::contains(&global_manage.chainGasFees, targetChainId)) {
            *smart_table::borrow(&global_manage.chainGasFees, targetChainId)
        } else if (global_manage.gasfee > 0) {
            global_manage.gasfee
        } else {
            DEFAULT_CHAIN_GAS_FEE
        }
    }

    #[view]
    fun getFeeRateBasisPoints(): u64 acquires GlobalManage {
        let fee_rate = borrow_global<GlobalManage>(@picwe).feeRateBasisPoints;
        fee_rate
    }

    #[view]
    fun calculateFee(amount: u64): u64 acquires GlobalManage {
        let fee_rate = getFeeRateBasisPoints();
        (amount * fee_rate) / BASIS_POINTS_DENOMINATOR
    }

    /// @dev Gets the total number of cross-chain requests
    #[view]
    public fun getRequestCount(): u256 acquires GlobalManage {
        let gm = borrow_global<GlobalManage>(@picwe);
        gm.requestCount
    }

    #[view]
    public fun getUserSourceRequests(
        user: address,
        page: u64,
        page_size: u64
    ): (vector<u256>, u64) acquires GlobalManage {
        assert!((page == 0 && page_size == 0) || (page > 0 && page_size > 0), E_INVALID_PAGINATION);

        let global_manage = borrow_global<GlobalManage>(@picwe);
        let active_requests = &global_manage.activeSourceRequests;
        let requests = &global_manage.requests;
        
        let total_requests = 0;
        let i = 0;
        let len = vector::length(active_requests);
        while (i < len) {
            let request_id = *vector::borrow(active_requests, i);
            let request = smart_table::borrow(requests, request_id);
            if (request.localUser == user) {
                total_requests = total_requests + 1;
            };
            i = i + 1;
        };

        let start_index = 0;
        let end_index = total_requests;

        if (page > 0 && page_size > 0) {
            start_index = if (total_requests >= (page * page_size)) {
                total_requests - (page * page_size)
            } else {
                0
            };
            end_index = start_index + page_size;
            if (end_index > total_requests) {
                end_index = total_requests;
            };
        };

        let user_requests = vector::empty<u256>();
        let count = 0;

        i = len;
        while (i > 0 && count < (end_index - start_index)) {
            let request_id = *vector::borrow(active_requests, i - 1);
            let request = smart_table::borrow(requests, request_id);
            if (request.localUser == user) {
                if ((total_requests - count) > start_index) {
                    vector::push_back(&mut user_requests, request_id);
                    count = count + 1;
                } else {
                    break
                };
            };
            i = i - 1;
        };

        (user_requests, total_requests)
    }

    #[view]
    public fun getUserTargetRequests(
        user: address,
        page: u64,
        page_size: u64
    ): (vector<u256>, u64) acquires GlobalManage {
        assert!((page == 0 && page_size == 0) || (page > 0 && page_size > 0), E_INVALID_PAGINATION);

        let global_manage = borrow_global<GlobalManage>(@picwe);
        let active_requests = &global_manage.activeTargetRequests;
        let requests = &global_manage.requests;
        
        let total_requests = 0;
        let i = 0;
        let len = vector::length(active_requests);
        while (i < len) {
            let request_id = *vector::borrow(active_requests, i);
            let request = smart_table::borrow(requests, request_id);
            if (request.localUser == user) {
                total_requests = total_requests + 1;
            };
            i = i + 1;
        };

        let start_index = 0;
        let end_index = total_requests;

        if (page > 0 && page_size > 0) {
            start_index = if (total_requests >= (page * page_size)) {
                total_requests - (page * page_size)
            } else {
                0
            };
            end_index = start_index + page_size;
            if (end_index > total_requests) {
                end_index = total_requests;
            };
        };

        let user_requests = vector::empty<u256>();
        let count = 0;

        i = len;
        while (i > 0 && count < (end_index - start_index)) {
            let request_id = *vector::borrow(active_requests, i - 1);
            let request = smart_table::borrow(requests, request_id);
            if (request.localUser == user) {
                if ((total_requests - count) > start_index) {
                    vector::push_back(&mut user_requests, request_id);
                    count = count + 1;
                } else {
                    break
                };
            };
            i = i - 1;
        };

        (user_requests, total_requests)
    }

    #[view]
    public fun getRequestByCount(count: u256): RequestData acquires GlobalManage {
        let global_manage = borrow_global<GlobalManage>(@picwe);
        assert!(count > 0 && count <= global_manage.requestCount, E_INVALID_REQUEST_ID);
        
        let source_chain_id = Block_chainid;
        let request_id = (source_chain_id << 128) | (WEUSD_SALT << 64) | count;
        assert!(requestExists(request_id), E_REQUEST_NOT_FOUND);
        
        getRequestById(request_id)
    }

    #[view]
    public fun getRequestsFromCount(
        start_count: u256,
        page: u64,
        page_size: u64
    ): (vector<RequestData>, u256) acquires GlobalManage {
        let global_manage = borrow_global<GlobalManage>(@picwe);
        assert!(start_count > 0, E_INVALID_REQUEST_ID);
        assert!(start_count <= global_manage.requestCount, E_INVALID_REQUEST_ID);
        assert!((page == 0 && page_size == 0) || (page > 0 && page_size > 0), E_INVALID_PAGINATION);

        let total_records = global_manage.requestCount - start_count + 1;
        let start_index = 0;
        let end_index = (total_records as u64);

        if (page > 0 && page_size > 0) {
            start_index = (page - 1) * page_size;
            if (start_index >= (total_records as u64)) {
                return (vector::empty(), total_records)
            };
            end_index = if (start_index + page_size < (total_records as u64)) {
                start_index + page_size
            } else {
                (total_records as u64)
            };
        };

        let request_data_array = vector::empty<RequestData>();
        let i = 0;
        while (i < (end_index - start_index)) {
            let current_count = start_count + ((start_index + i) as u256);
            let source_chain_id = Block_chainid;
            let request_id = (source_chain_id << 128) | (WEUSD_SALT << 64) | current_count;
            assert!(requestExists(request_id), E_REQUEST_NOT_FOUND);
            vector::push_back(&mut request_data_array, getRequestById(request_id));
            i = i + 1;
        };

        (request_data_array, total_records)
    }
    
    fun init_module(contract: &signer) acquires GlobalManage {
        move_to(
            contract,
            GlobalManage {
                requestCount: 0,
                gasfee: DEFAULT_CHAIN_GAS_FEE,
                feeRateBasisPoints: DEFAULT_FEE_RATE_BASIS_POINTS,
                chainGasFees: smart_table::new<u256, u64>(),
                feeRecipient: INITIAL_FEE_RECIPIENT,
                activeSourceRequests: vector::empty(),
                activeTargetRequests: vector::empty(),
                requests: smart_table::new<u256, RequestData>(),
                requestIdToSourceActiveIndex: smart_table::new<u256, u256>(),
                requestIdToTargetActiveIndex: smart_table::new<u256, u256>(),
                supportedChains: smart_table::new<u256, bool>(),
                cross_mint_role_contract: INITIAL_CROSS_CHAIN_MINT_ROLE
            }
        );
        move_to(
            contract,
            EventHandles {
                cross_chain_burn_events: account::new_event_handle<CrossChainBurn>(contract),
                cross_chain_mint_events: account::new_event_handle<CrossChainMint>(contract),
                source_request_archived_deleted_events: account::new_event_handle<SourceRequestArchivedAndDeleted>(contract),
                target_request_archived_deleted_events: account::new_event_handle<TargetRequestArchivedAndDeleted>(contract)
            }
        );
        let supported_chains = &mut borrow_global_mut<GlobalManage>(@picwe).supportedChains;
        smart_table::add(supported_chains, 56, true);
        smart_table::add(supported_chains, 1, true);
        smart_table::add(supported_chains, 42161, true);
        smart_table::add(supported_chains, 8453, true);
        let chain_gas_fees = &mut borrow_global_mut<GlobalManage>(@picwe).chainGasFees;
        smart_table::add(chain_gas_fees, 1, 1000000);
    }

    public entry fun set_cross_chain_minter_role(
        caller: &signer, account: address
    ) acquires GlobalManage {
        assert!(
            signer::address_of(caller) == @picwe,
            error::permission_denied(E_ONLY_OWNER_CAN_SET_ROLE)
        );
        let cross_mint_role_contract =
            &mut borrow_global_mut<GlobalManage>(@picwe).cross_mint_role_contract;
        *cross_mint_role_contract = account;
    }

    public entry fun setGasfee(caller: &signer, gasfee: u64) acquires GlobalManage {
        assert!(
            signer::address_of(caller) == @setter, error::permission_denied(ENOT_OWNER)
        );
        let gas_fee_mut = &mut borrow_global_mut<GlobalManage>(@picwe).gasfee;
        *gas_fee_mut = gasfee;
    }

    public entry fun setFeeRateBasisPoints(caller: &signer, fee_rate: u64) acquires GlobalManage {
        assert!(
            signer::address_of(caller) == @setter, error::permission_denied(ENOT_OWNER)
        );
        let fee_rate_mut = &mut borrow_global_mut<GlobalManage>(@picwe).feeRateBasisPoints;
        *fee_rate_mut = fee_rate;
    }

    public entry fun setChainGasfee(caller: &signer, targetChainId: u256, gasfee: u64) acquires GlobalManage {
        assert!(
            signer::address_of(caller) == @setter, error::permission_denied(ENOT_OWNER)
        );
        let chain_gas_fees = &mut borrow_global_mut<GlobalManage>(@picwe).chainGasFees;
        
        if (smart_table::contains(chain_gas_fees, targetChainId)) {
            let chain_gasfee = smart_table::borrow_mut(chain_gas_fees, targetChainId);
            *chain_gasfee = gasfee;
        } else {
            smart_table::add(chain_gas_fees, targetChainId, gasfee);
        }
    }

    public entry fun removeChainGasfee(caller: &signer, targetChainId: u256) acquires GlobalManage {
        assert!(
            signer::address_of(caller) == @setter, error::permission_denied(ENOT_OWNER)
        );
        let chain_gas_fees = &mut borrow_global_mut<GlobalManage>(@picwe).chainGasFees;
        
        if (smart_table::contains(chain_gas_fees, targetChainId)) {
            smart_table::remove(chain_gas_fees, targetChainId);
        }
    }

    public entry fun setFeeRecipient(
        caller: &signer, feeRecipient: address
    ) acquires GlobalManage {
        assert!(
            signer::address_of(caller) == @picwe, error::permission_denied(ENOT_OWNER)
        );
        let fee_recipient = &mut borrow_global_mut<GlobalManage>(@picwe).feeRecipient;
        *fee_recipient = feeRecipient;
    }

    public entry fun addSupportedChain(
        caller: &signer,
        targetChainId: u256
    ) acquires GlobalManage {
        assert!(
            signer::address_of(caller) == @picwe,
            error::permission_denied(E_ONLY_OWNER_CAN_SET_ROLE)
        );
        let supported_chains = &mut borrow_global_mut<GlobalManage>(@picwe).supportedChains;
        if (!smart_table::contains(supported_chains, targetChainId)) {
            smart_table::add(supported_chains, targetChainId, true);
        }
    }

    public entry fun removeSupportedChain(
        caller: &signer,
        targetChainId: u256
    ) acquires GlobalManage {
        assert!(
            signer::address_of(caller) == @picwe,
            error::permission_denied(E_ONLY_OWNER_CAN_SET_ROLE)
        );
        let supported_chains = &mut borrow_global_mut<GlobalManage>(@picwe).supportedChains;
        if (smart_table::contains(supported_chains, targetChainId)) {
            smart_table::remove(supported_chains, targetChainId);
        }
    }

    /// Archive and completely delete source request
    public entry fun archive_and_delete_source_request(
        caller: &signer,
        requestId: u256
    ) acquires GlobalManage, EventHandles {
        assert!(signer::address_of(caller) == @picwe, error::permission_denied(ENOT_OWNER));
        let gm = borrow_global_mut<GlobalManage>(@picwe);
        assert!(smart_table::contains(&gm.requestIdToSourceActiveIndex, requestId), E_INVALID_REQUEST_ID);
        let idx = (*smart_table::borrow(&gm.requestIdToSourceActiveIndex, requestId) as u64);
        let vec = &mut gm.activeSourceRequests;
        let len = vector::length(vec);
        assert!(idx < len, E_INVALID_REQUEST_ID);
        if (idx < len - 1) {
            let last_id = *vector::borrow(vec, len - 1);
            let slot = vector::borrow_mut(vec, idx);
            *slot = last_id;
            smart_table::add(&mut gm.requestIdToSourceActiveIndex, last_id, (idx as u256));
        };
        vector::pop_back(vec);
        smart_table::remove(&mut gm.requestIdToSourceActiveIndex, requestId);
        smart_table::remove(&mut gm.requests, requestId);
        event::emit_event(
            &mut borrow_global_mut<EventHandles>(@picwe).source_request_archived_deleted_events,
            SourceRequestArchivedAndDeleted { requestId }
        );
    }

    /// Archive and completely delete target request
    public entry fun archive_and_delete_target_request(
        caller: &signer,
        requestId: u256
    ) acquires GlobalManage, EventHandles {
        assert!(signer::address_of(caller) == @picwe, error::permission_denied(ENOT_OWNER));
        let gm = borrow_global_mut<GlobalManage>(@picwe);
        assert!(smart_table::contains(&gm.requestIdToTargetActiveIndex, requestId), E_INVALID_REQUEST_ID);
        let idx = (*smart_table::borrow(&gm.requestIdToTargetActiveIndex, requestId) as u64);
        let vec = &mut gm.activeTargetRequests;
        let len = vector::length(vec);
        assert!(idx < len, E_INVALID_REQUEST_ID);
        if (idx < len - 1) {
            let last_id = *vector::borrow(vec, len - 1);
            let slot = vector::borrow_mut(vec, idx);
            *slot = last_id;
            smart_table::add(&mut gm.requestIdToTargetActiveIndex, last_id, (idx as u256));
        };
        vector::pop_back(vec);
        smart_table::remove(&mut gm.requestIdToTargetActiveIndex, requestId);
        smart_table::remove(&mut gm.requests, requestId);
        event::emit_event(
            &mut borrow_global_mut<EventHandles>(@picwe).target_request_archived_deleted_events,
            TargetRequestArchivedAndDeleted { requestId }
        );
    }

    /// Batch archive and completely delete source requests
    public entry fun batch_archive_and_delete_source_requests(
        caller: &signer,
        requestIds: vector<u256>
    ) acquires GlobalManage, EventHandles {
        let len = vector::length(&requestIds);
        let i = 0;
        while (i < len) {
            let rid = *vector::borrow(&requestIds, i);
            if (smart_table::contains(&borrow_global<GlobalManage>(@picwe).requestIdToSourceActiveIndex, rid)) {
                archive_and_delete_source_request(caller, rid);
            };
            i = i + 1;
        }
    }

    /// Batch archive and completely delete target requests
    public entry fun batch_archive_and_delete_target_requests(
        caller: &signer,
        requestIds: vector<u256>
    ) acquires GlobalManage, EventHandles {
        let len = vector::length(&requestIds);
        let i = 0;
        while (i < len) {
            let rid = *vector::borrow(&requestIds, i);
            if (smart_table::contains(&borrow_global<GlobalManage>(@picwe).requestIdToTargetActiveIndex, rid)) {
                archive_and_delete_target_request(caller, rid);
            };
            i = i + 1;
        }
    }

    public entry fun burnWeUSDCrossChain(
        caller: &signer,
        targetChainId: u256,
        amount: u64,
        outerUser: String
    ) acquires GlobalManage, EventHandles {
        assert!(
            targetChainId != Block_chainid,
            E_DIFF
        );
        assert!(
            smart_table::contains(&borrow_global<GlobalManage>(@picwe).supportedChains, targetChainId),
            E_UNSUPPORTED_CHAIN
        );
        let gasfee = getChainGasfee(targetChainId);
        
        let percentage_fee = calculateFee(amount);
        let total_fee = gasfee + percentage_fee;
        
        assert!(amount > total_fee, E_NotEnoughAmout);
        assert!(string::length(&outerUser) > 0, E_InvalidTargetUserAddress);

        let global_manage = borrow_global_mut<GlobalManage>(@picwe);
        let requestCount_mut = &mut global_manage.requestCount;
        let feeRecipient = global_manage.feeRecipient;

        *requestCount_mut = *requestCount_mut + 1;
        let msgsender = signer::address_of(caller);
        let sourceChainId = Block_chainid;
        let requestId = (sourceChainId << 128) | (WEUSD_SALT << 64) | *requestCount_mut;
        assert!(requestExists(requestId) == false, E_RequestIdAlreadyExists);
        let burnAmount = amount - total_fee;

        let metadata = weusd::get_metadata();
        primary_fungible_store::transfer(caller, metadata, feeRecipient, total_fee);
        
        weusd::burn(msgsender, burnAmount);
        
        weusd_mint_redeem::reserve_stablecoin_for_cross_chain(burnAmount);
        
        createRequest(requestId, msgsender, outerUser, burnAmount, true, targetChainId);

        event::emit_event(
            &mut borrow_global_mut<EventHandles>(@picwe).cross_chain_burn_events,
            CrossChainBurn {
                requestId,
                localUser: msgsender,
                outerUser,
                sourceChainId,
                targetChainId,
                amount: burnAmount
            }
        );
    }

    public entry fun mintWeUSDCrossChain(
        caller: &signer,
        requestId: u256,
        sourceChainId: u256,
        amount: u64,
        localUser: address,
        outerUser: String
    ) acquires GlobalManage, EventHandles {
        let cross_mint_role_contract =
            &borrow_global<GlobalManage>(@picwe).cross_mint_role_contract;
        assert!(
            signer::address_of(caller) == *cross_mint_role_contract,
            error::permission_denied(E_NOTACL)
        );
        assert!(localUser != @0x0, E_InvalidTargetUserAddress);
        assert!(string::length(&outerUser) > 0, E_InvalidTargetUserAddress);
        assert!(requestExists(requestId) == false, E_RequestIdAlreadyExists);
        
        weusd::mint(localUser, amount);
        
        weusd_mint_redeem::return_stablecoin_from_cross_chain(amount);
        
        createRequest(requestId, localUser, outerUser, amount, false, Block_chainid);

        event::emit_event(
            &mut borrow_global_mut<EventHandles>(@picwe).cross_chain_mint_events,
            CrossChainMint {
                requestId,
                localUser,
                outerUser,
                sourceChainId,
                targetChainId: Block_chainid,
                amount
            }
        );
    }

    public entry fun batchMintWeUSDCrossChain(
        caller: &signer,
        requestIds: vector<u256>,
        sourceChainIds: vector<u256>,
        amounts: vector<u64>,
        localUsers: vector<address>,
        outerUsers: vector<String>
    ) acquires GlobalManage, EventHandles {
        let len = vector::length(&requestIds);
        assert!(len == vector::length(&sourceChainIds), E_INVALID_ARGS);
        assert!(len == vector::length(&amounts), E_INVALID_ARGS);
        assert!(len == vector::length(&localUsers), E_INVALID_ARGS);
        assert!(len == vector::length(&outerUsers), E_INVALID_ARGS);
        
        let i = 0;
        while (i < len) {
            let requestId = *vector::borrow(&requestIds, i);
            let sourceChainId = *vector::borrow(&sourceChainIds, i);
            let amount = *vector::borrow(&amounts, i);
            let localUser = *vector::borrow(&localUsers, i);
            let outerUser = *vector::borrow(&outerUsers, i);
            mintWeUSDCrossChain(caller, requestId, sourceChainId, amount, localUser, outerUser);
            i = i + 1;
        };
    }

    fun createRequest(
        requestId: u256,
        localUser: address,
        outerUser: String,
        amount: u64,
        isburn: bool,
        targetChainId: u256
    ) acquires GlobalManage {
        let newRequest = RequestData { 
            requestId, 
            localUser, 
            outerUser, 
            amount, 
            isburn,
            targetChainId
        };

        let requests = &mut borrow_global_mut<GlobalManage>(@picwe).requests;
        smart_table::add(requests, requestId, newRequest);

        if (isburn) {
            let activeSourceRequests =
                &mut borrow_global_mut<GlobalManage>(@picwe).activeSourceRequests;
            vector::push_back(activeSourceRequests, requestId);
            let vlen = vector::length(activeSourceRequests) - 1;
            let requestIdToSourceActiveIndex =
                &mut borrow_global_mut<GlobalManage>(@picwe).requestIdToSourceActiveIndex;
            smart_table::add(requestIdToSourceActiveIndex, requestId, (vlen as u256))
        } else {
            let activeTargetRequests =
                &mut borrow_global_mut<GlobalManage>(@picwe).activeTargetRequests;
            vector::push_back(activeTargetRequests, requestId);
            let vlen = vector::length(activeTargetRequests) - 1;
            let requestIdToTargetActiveIndex =
                &mut borrow_global_mut<GlobalManage>(@picwe).requestIdToTargetActiveIndex;
            smart_table::add(requestIdToTargetActiveIndex, requestId, (vlen as u256))
        };
    }

    #[view]
    public fun is_initialized(): bool {
        exists<GlobalManage>(@picwe)
    }

    public entry fun initialize(admin: &signer) acquires GlobalManage {
        assert!(signer::address_of(admin) == @picwe, error::permission_denied(ENOT_OWNER));
        assert!(!exists<GlobalManage>(@picwe), error::already_exists(1));
        
        init_module(admin);
    }

    // =================== Test Functions ===================
    #[test_only]
    use std::signer::address_of;
    #[test_only]
    use picwe::faucet;
    #[test_only]
    public fun create_test_accounts(
        deployer: &signer, 
        user_1: &signer, 
        user_2: &signer
    ) {
        account::create_account_for_test(address_of(user_1));
        account::create_account_for_test(address_of(user_2));
        account::create_account_for_test(address_of(deployer));
        account::create_account_for_test(@weusd_fee_address);
        account::create_account_for_test(@crosschain_mint_role);
        account::create_account_for_test(@picwe);
    }

    #[test_only]
    public fun test_init_only(creator: &signer) acquires GlobalManage {
        init_module(creator);
        weusd::test_init_only(creator);
        weusd_mint_redeem::test_init_only(creator);
        faucet::test_init_only(creator);
        let resource_signer = weusd_mint_redeem::get_resource_signer();
        let stablecoin_metadata = faucet::get_usdt_metadata();
        faucet::claim_usdt(&resource_signer);
    }

    // Test setting and getting chain gas fees
    #[test(sender = @picwe, user1 = @0x123, user2 = @0x1234)]
    public fun test_chain_gas_fee(
        sender: &signer,
        user1: &signer,
        user2: &signer
    ) acquires GlobalManage {
        // Initialize the test environment
        create_test_accounts(sender, user1, user2);
        
        // Initialize the module
        test_init_only(sender);

        // Set and test the gas fee for a specific chain
        let target_chain_id: u256 = 421614; // Arbitrum Sepolia
        let gas_fee: u64 = 5000;
        
        // Set the chain gas fee
        setChainGasfee(sender, target_chain_id, gas_fee);
        
        // Get and verify the chain gas fee
        let retrieved_gas_fee = getChainGasfee(target_chain_id);
        assert!(retrieved_gas_fee == gas_fee, 1001);
        
        // Test deleting the chain gas fee
        removeChainGasfee(sender, target_chain_id);
        
        // Verify that the default value is returned after deletion
        let default_gas_fee = getChainGasfee(target_chain_id);
        assert!(default_gas_fee == DEFAULT_CHAIN_GAS_FEE, 1002);
    }

    // Test setting and getting the global default gas fee
    #[test(sender = @picwe, user1 = @0x123)]
    public fun test_default_gas_fee(
        sender: &signer,
        user1: &signer
    ) acquires GlobalManage {
        // Initialize the test environment
        create_test_accounts(sender, user1, user1);
        
        // Initialize the module
        test_init_only(sender);

        // Test the default gas fee
        let default_fee = getGasfee();
        assert!(default_fee == DEFAULT_CHAIN_GAS_FEE, 1003);
        
        // Set a new global default gas fee
        let new_fee: u64 = 2000;
        setGasfee(sender, new_fee);
        
        // Verify the global default gas fee
        let current_fee = getGasfee();
        assert!(current_fee == new_fee, 1004);
        
        // Test that getting the fee for an unset chain ID will return the global default value
        let non_existent_chain_id: u256 = 999999;
        let retrieved_fee = getChainGasfee(non_existent_chain_id);
        assert!(retrieved_fee == new_fee, 1005);
    }

    // Test setting and getting the fee rate basis points
    #[test(sender = @picwe, user1 = @0x123)]
    public fun test_fee_rate_basis_points(
        sender: &signer,
        user1: &signer
    ) acquires GlobalManage {
        // Initialize the test environment
        create_test_accounts(sender, user1, user1);
        
        // Initialize the module
        test_init_only(sender);

        // Test the default fee rate basis points
        let default_fee_rate = getFeeRateBasisPoints();
        assert!(default_fee_rate == DEFAULT_FEE_RATE_BASIS_POINTS, 1006);
        
        // Set a new fee rate basis points
        let new_fee_rate: u64 = 50; // 0.5%
        setFeeRateBasisPoints(sender, new_fee_rate);
        
        // Verify the fee rate basis points
        let current_fee_rate = getFeeRateBasisPoints();
        assert!(current_fee_rate == new_fee_rate, 1007);
        
        // Test fee calculation
        let amount: u64 = 10000000; // 10 WeUSD (assuming 6 decimal places)
        let expected_fee = (amount * new_fee_rate) / BASIS_POINTS_DENOMINATOR; // Should be 50000 (0.05 WeUSD)
        let calculated_fee = calculateFee(amount);
        assert!(calculated_fee == expected_fee, 1008);
    }

    // Test the getChainGasfee function edge cases
    #[test(sender = @picwe)]
    public fun test_chain_gas_fee_edge_cases(
        sender: &signer
    ) acquires GlobalManage {
        // Initialize the test environment
        create_test_accounts(sender, sender, sender);
        
        // Initialize the module
        test_init_only(sender);

        // Define the chain ID for testing
        let chain_id: u256 = 421614; // Arbitrum Sepolia
        
        // The initial situation should return the default value (DEFAULT_CHAIN_GAS_FEE)
        let initial_gas_fee = getChainGasfee(chain_id);
        assert!(initial_gas_fee == DEFAULT_CHAIN_GAS_FEE, 2001);
        
        // Test case 1: Set the global gas fee to a non-zero value
        setGasfee(sender, 3000);
        let global_gas_fee = getGasfee();
        assert!(global_gas_fee == 3000, 2002);
        
        // An unset chain ID should return the global value
        let unset_chain_gas_fee = getChainGasfee(chain_id);
        assert!(unset_chain_gas_fee == 3000, 2003);
        
        // Test case 2: Set the gas fee for a specific chain
        setChainGasfee(sender, chain_id, 5000);
        let specific_chain_gas_fee = getChainGasfee(chain_id);
        assert!(specific_chain_gas_fee == 5000, 2004);
        
        // Test case 3: Set the global gas fee to 0
        setGasfee(sender, 0);
        let zero_global_gas_fee = getGasfee();
        assert!(zero_global_gas_fee == 0, 2005);
        
        // The gas fee for a specific chain should remain unchanged
        let unchanged_chain_gas_fee = getChainGasfee(chain_id);
        assert!(unchanged_chain_gas_fee == 5000, 2006);
        
        // Test case 4: Remove the gas fee setting for a specific chain
        removeChainGasfee(sender, chain_id);
        
        // The global fee is 0, an unset chain ID should return the default value
        let default_chain_gas_fee = getChainGasfee(chain_id);
        assert!(default_chain_gas_fee == DEFAULT_CHAIN_GAS_FEE, 2007);
        
        // Test case 5: Extreme values
        let max_chain_id: u256 = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
        let very_large_fee: u64 = 0xFFFFFFFFFFFFFFFF;
        
        // Set the maximum value
        setChainGasfee(sender, max_chain_id, very_large_fee);
        let large_fee = getChainGasfee(max_chain_id);
        assert!(large_fee == very_large_fee, 2008);
        
        // Test case 6: Value is 1
        setChainGasfee(sender, 1, 1);
        let minimal_fee = getChainGasfee(1);
        assert!(minimal_fee == 1, 2009);
    }

    // Test setting the cross-chain minter role
    #[test(sender = @picwe, user1 = @0x123)]
    public fun test_set_cross_chain_minter_role(
        sender: &signer,
        user1: &signer
    ) acquires GlobalManage {
        // Initialize the test environment
        create_test_accounts(sender, user1, user1);
        
        // Initialize the module
        test_init_only(sender);

        // The initial role should be INITIAL_CROSS_CHAIN_MINT_ROLE
        let global_manage = borrow_global<GlobalManage>(@picwe);
        assert!(global_manage.cross_mint_role_contract == @crosschain_mint_role, 1014);
        
        // Set a new role
        let new_role = address_of(user1);
        set_cross_chain_minter_role(sender, new_role);
        
        // Verify the new role
        let global_manage = borrow_global<GlobalManage>(@picwe);
        assert!(global_manage.cross_mint_role_contract == new_role, 1015);
    }

    // Test a non-authorized user setting the cross-chain minter role (expected to fail)
    #[expected_failure(abort_code = 328704)]
    #[test(sender = @picwe, user1 = @0x123)]
    public fun test_unauthorized_set_cross_chain_minter_role(
        sender: &signer,
        user1: &signer
    ) acquires GlobalManage {
        // Initialize the test environment
        create_test_accounts(sender, user1, user1);
        
        // Initialize the module
        test_init_only(sender);

        // Non-authorized user tries to set the role (should fail)
        set_cross_chain_minter_role(user1, address_of(user1));
    }

    // Test the basic simulation of key functions
    #[test(sender = @picwe, user1 = @0x123, mint_role = @crosschain_mint_role)]
    public fun test_mock_basic_functions(
        sender: &signer,
        user1: &signer,
        mint_role: &signer
    ) acquires GlobalManage {
        // Initialize the test environment
        create_test_accounts(sender, user1, mint_role);
        
        // Initialize the related modules (more initialization may be needed for actual testing)
        test_init_only(sender);
        
        // Simulate test data
        let target_chain_id: u256 = 421614;
        let amount: u64 = 10000000; // 10 WeUSD
        
        // Set the test gas fee
        setChainGasfee(sender, target_chain_id, 100000); // 0.1 WeUSD
        
        // Set the fee rate
        setFeeRateBasisPoints(sender, 30); // 0.3%
        
        // Calculate and verify the gas fee retrieval
        let gas_fee = getChainGasfee(target_chain_id);
        assert!(gas_fee == 100000, 1016);
        
        // Calculate and verify the percentage-based fee calculation
        let percentage_fee = calculateFee(amount);
        assert!(percentage_fee == 30000, 1017); // 0.3% of 10 WeUSD = 0.03 WeUSD = 30000
        
        // Verify the total fee calculation
        let total_fee = gas_fee + percentage_fee;
        assert!(total_fee == 130000, 1018); // 0.1 + 0.03 = 0.13 WeUSD = 130000
        
        // Verify the logic of getting the request ID (create a temporary request)
        let request_count = borrow_global<GlobalManage>(@picwe).requestCount;
        assert!(request_count == 0, 1019);
    }

    // Test getting user requests
    #[test(sender = @picwe, user1 = @0x123, user2 = @0x1234)]
    public fun test_get_user_requests(
        sender: &signer,
        user1: &signer,
        user2: &signer
    ) acquires GlobalManage {
        // Initialize the test environment
        create_test_accounts(sender, user1, user2);
        
        // Initialize the module
        test_init_only(sender);
        
        // Simulate creating request data
        let user1_addr = address_of(user1);
        let user2_addr = address_of(user2);
        let outer_user = string::utf8(b"0x7ab8Fa18A57E54af232eFe45E25e0d38f4070a5a");
        
        // Create a burn request for user1
        createRequest(1, user1_addr, outer_user, 1000000, true, 0);
        
        // Create a burn request for user2
        createRequest(2, user2_addr, outer_user, 2000000, true, 0);
        
        // Create a mint request for user1
        createRequest(3, user1_addr, outer_user, 3000000, false, 0);
        
        // Test getting user1's source requests
        let (user1_source_requests, user1_source_count) = getUserSourceRequests(user1_addr, 0, 0);
        assert!(user1_source_count == 1, 1020);
        assert!(vector::length(&user1_source_requests) == 1, 1021);
        assert!(*vector::borrow(&user1_source_requests, 0) == 1, 1022);
        
        // Test getting user2's source requests
        let (user2_source_requests, user2_source_count) = getUserSourceRequests(user2_addr, 0, 0);
        assert!(user2_source_count == 1, 1023);
        assert!(vector::length(&user2_source_requests) == 1, 1024);
        assert!(*vector::borrow(&user2_source_requests, 0) == 2, 1025);
        
        // Test getting user1's target requests
        let (user1_target_requests, user1_target_count) = getUserTargetRequests(user1_addr, 0, 0);
        assert!(user1_target_count == 1, 1026);
        assert!(vector::length(&user1_target_requests) == 1, 1027);
        assert!(*vector::borrow(&user1_target_requests, 0) == 3, 1028);
        
        // Test request existence
        assert!(requestExists(1), 1029);
        assert!(requestExists(2), 1030);
        assert!(requestExists(3), 1031);
        assert!(!requestExists(4), 1032);
        
        // Test batch checking request existence
        let request_ids = vector::empty<u256>();
        vector::push_back(&mut request_ids, 1);
        vector::push_back(&mut request_ids, 2);
        vector::push_back(&mut request_ids, 4);
        
        let exists_results = batchRequestExists(request_ids);
        assert!(vector::length(&exists_results) == 3, 1033);
        assert!(*vector::borrow(&exists_results, 0), 1034);
        assert!(*vector::borrow(&exists_results, 1), 1035);
        assert!(!*vector::borrow(&exists_results, 2), 1036);
        
        // Test getting request details
        let request_1 = getRequestById(1);
        assert!(request_1.requestId == 1, 1037);
        assert!(request_1.localUser == user1_addr, 1038);
        assert!(request_1.amount == 1000000, 1039);
        assert!(request_1.isburn, 1040);
        
        // Test batch getting request details
        let batch_request_ids = vector::empty<u256>();
        vector::push_back(&mut batch_request_ids, 1);
        vector::push_back(&mut batch_request_ids, 3);
        
        let batch_requests = batchGetRequestById(batch_request_ids);
        assert!(vector::length(&batch_requests) == 2, 1041);
        
        let batch_request_1 = *vector::borrow(&batch_requests, 0);
        assert!(batch_request_1.requestId == 1, 1042);
        
        let batch_request_2 = *vector::borrow(&batch_requests, 1);
        assert!(batch_request_2.requestId == 3, 1043);
        assert!(batch_request_2.amount == 3000000, 1044);
        assert!(!batch_request_2.isburn, 1045);
    }

    // Test the correctness of the getChainGasfee function
    #[test(sender = @picwe)]
    public fun test_get_chain_gas_fee(
        sender: &signer
    ) acquires GlobalManage {
        // Initialize the test environment
        create_test_accounts(sender, sender, sender);
        
        // Initialize the module
        test_init_only(sender);

        // Define the chain IDs for testing
        let chain_id_1: u256 = 111111;
        let chain_id_2: u256 = 222222;
        let chain_id_3: u256 = 333333;
        
        // Set the gas fees for different chains
        let fee_1: u64 = 1000;
        let fee_2: u64 = 2000;
        let global_fee: u64 = 5000;
        
        // Set the fees
        setChainGasfee(sender, chain_id_1, fee_1);
        setChainGasfee(sender, chain_id_2, fee_2);
        setGasfee(sender, global_fee);
        
        // Verify the correctness of global_fee
        let retrieved_global_fee = getGasfee();
        assert!(retrieved_global_fee == global_fee, 1200);
        
        // Test getting the fees for set chains
        assert!(getChainGasfee(chain_id_1) == fee_1, 1009);
        assert!(getChainGasfee(chain_id_2) == fee_2, 1010);
        
        // Test getting the fees for unset chains (should return the global default value)
        assert!(getChainGasfee(chain_id_3) == global_fee, 1011);
        
        // Test the behavior after removing the chain fee
        removeChainGasfee(sender, chain_id_1);
        assert!(getChainGasfee(chain_id_1) == global_fee, 1012);
        
        // Test the behavior when the global fee is 0
        setGasfee(sender, 0);
        let zero_global_fee = getGasfee();
        assert!(zero_global_fee == 0, 1201);
        
        // After removing the set fee for a chain, it should return the default value
        removeChainGasfee(sender, chain_id_2);
        assert!(getChainGasfee(chain_id_2) == DEFAULT_CHAIN_GAS_FEE, 1013);
        
        // Test getting the fees for unset chains, should return the default value
        assert!(getChainGasfee(chain_id_3) == DEFAULT_CHAIN_GAS_FEE, 1014);
    }

    // Test the burnWeUSDCrossChain function
    #[test(sender = @picwe, user1 = @0x123, fee_recipient = @weusd_fee_address)]
    public fun test_burn_weusd_cross_chain(
        sender: &signer,
        user1: &signer,
        fee_recipient: &signer
    ) acquires GlobalManage, EventHandles {
        // Initialize the test environment
        create_test_accounts(sender, user1, fee_recipient);
        
        // Initialize the module
        test_init_only(sender);

        // Claim USDT for the user
        faucet::claim_usdt(user1);

        // Mint some WeUSD to user1 for testing
        let mint_amount: u64 = 50000000; // 50 WeUSD
        weusd_mint_redeem::mintWeUSD(user1, mint_amount);

        // Set the target chain ID and amount
        let target_chain_id: u256 = 421614; // Arbitrum Sepolia
        let amount: u64 = 10000000; // 10 WeUSD
        let outer_user = string::utf8(b"0x7ab8Fa18A57E54af232eFe45E25e0d38f4070a5a");
        let gas_fee = getChainGasfee(target_chain_id);    
        // // Set the chain's gas fee
        // let gas_fee: u64 = 100000; // 0.1 WeUSD
        // setChainGasfee(sender, target_chain_id, gas_fee);
        
        // // Set the fee rate
        // setFeeRateBasisPoints(sender, 30); // 0.3%
        
        // Calculate fees before executing the burn function
        let percentage_fee = calculateFee(amount);
        assert!(percentage_fee == 30000, 1025); // 0.3% of 10 WeUSD = 0.03 WeUSD = 30000
        
        let total_fee = gas_fee + percentage_fee;
        assert!(total_fee == 130000, 1026); // 0.1 + 0.03 = 0.13 WeUSD = 130000
        
        // Get the current request count
        let request_count_before = borrow_global<GlobalManage>(@picwe).requestCount;
        
        // Execute the burnWeUSDCrossChain function
        burnWeUSDCrossChain(user1, target_chain_id, amount, outer_user);
        
        // Verify the request count increases
        let request_count_after = borrow_global<GlobalManage>(@picwe).requestCount;
        assert!(request_count_after == request_count_before + 1, 1020);
        
        // Verify the active source request list updates
        let active_source_requests = &borrow_global<GlobalManage>(@picwe).activeSourceRequests;
        assert!(vector::length(active_source_requests) == 1, 1021);
        
        // Verify the request data is stored correctly
        let request_id = *vector::borrow(active_source_requests, 0);
        let requests = &borrow_global<GlobalManage>(@picwe).requests;
        let request_data = smart_table::borrow(requests, request_id);
        
        assert!(request_data.localUser == address_of(user1), 1022);
        assert!(request_data.outerUser == outer_user, 1023);
        assert!(request_data.isburn == true, 1024);
        
        // Verify the actual stored amount is correct (amount after fee deduction)
        assert!(request_data.amount == amount - total_fee, 1027);
    }

    // Test the mintWeUSDCrossChain function
    #[test(sender = @picwe, user1 = @0x123, mint_role = @crosschain_mint_role)]
    public fun test_mint_weusd_cross_chain(
        sender: &signer,
        user1: &signer,
        mint_role: &signer
    ) acquires GlobalManage, EventHandles {
        // Initialize the test environment
        create_test_accounts(sender, user1, mint_role);
        
        // Initialize the module
        test_init_only(sender);

        // Set the test data
        let request_id: u256 = 12345;
        let source_chain_id: u256 = 421614; // Arbitrum Sepolia
        let amount: u64 = 10000000; // 10 WeUSD
        let local_user = address_of(user1);
        let outer_user = string::utf8(b"0x7ab8Fa18A57E54af232eFe45E25e0d38f4070a5a");
        
        // Execute the mintWeUSDCrossChain function
        mintWeUSDCrossChain(mint_role, request_id, source_chain_id, amount, local_user, outer_user);
        
        // Verify the active target request list updates
        let active_target_requests = &borrow_global<GlobalManage>(@picwe).activeTargetRequests;
        assert!(vector::length(active_target_requests) == 1, 1031);
        
        // Verify all requests are stored correctly
        let stored_request_id = *vector::borrow(active_target_requests, 0);
        assert!(stored_request_id == request_id, 1032);
        
        let requests = &borrow_global<GlobalManage>(@picwe).requests;
        let request_data = smart_table::borrow(requests, request_id);
        
        assert!(request_data.localUser == local_user, 1033);
        assert!(request_data.outerUser == outer_user, 1034);
        assert!(request_data.amount == amount, 1035);
        assert!(request_data.isburn == false, 1036);
    }

    // Test a non-authorized user trying to mint WeUSD (expected to fail)
    #[expected_failure(abort_code = 328705)]
    #[test(sender = @picwe, user1 = @0x123)]
    public fun test_unauthorized_mint_weusd_cross_chain(
        sender: &signer,
        user1: &signer
    ) acquires GlobalManage, EventHandles {
        // Initialize the test environment
        create_test_accounts(sender, user1, user1);
        
        // Initialize the module
        test_init_only(sender);

        // Set the test data
        let request_id: u256 = 12345;
        let source_chain_id: u256 = 421614;
        let amount: u64 = 10000000;
        let local_user = address_of(user1);
        let outer_user = string::utf8(b"0x7ab8Fa18A57E54af232eFe45E25e0d38f4070a5a");
        
        // Non-authorized user tries to mint (should fail)
        mintWeUSDCrossChain(user1, request_id, source_chain_id, amount, local_user, outer_user);
    }

    // Test the batchMintWeUSDCrossChain function
    #[test(sender = @picwe, user1 = @0x123, mint_role = @crosschain_mint_role)]
    public fun test_batch_mint_weusd_cross_chain(
        sender: &signer,
        user1: &signer,
        mint_role: &signer
    ) acquires GlobalManage, EventHandles {
        // Initialize the test environment
        create_test_accounts(sender, user1, mint_role);
        
        // Initialize the module
        test_init_only(sender);

        // Prepare the batch mint data
        let request_ids = vector<u256>[12345, 12346, 12347];
        let source_chain_ids = vector<u256>[421614, 421614, 421614];
        let amounts = vector<u64>[1000000, 2000000, 3000000];
        let local_users = vector<address>[address_of(user1), address_of(user1), address_of(user1)];
        let outer_user = string::utf8(b"0x7ab8Fa18A57E54af232eFe45E25e0d38f4070a5a");
        let outer_users = vector<String>[outer_user, outer_user, outer_user];
        
        // Execute the batch mint
        batchMintWeUSDCrossChain(mint_role, request_ids, source_chain_ids, amounts, local_users, outer_users);
        
        // Verify the active target request list updates
        let active_target_requests = &borrow_global<GlobalManage>(@picwe).activeTargetRequests;
        assert!(vector::length(active_target_requests) == 3, 1041);
        
        // Verify all requests are stored correctly
        let requests = &borrow_global<GlobalManage>(@picwe).requests;
        
        let i = 0;
        while (i < 3) {
            let request_id = *vector::borrow(&request_ids, i);
            let amount = *vector::borrow(&amounts, i);
            
            let request_data = smart_table::borrow(requests, request_id);
            assert!(request_data.amount == amount, 1042);
            assert!(request_data.isburn == false, 1043);
            
            i = i + 1;
        };
    }
}
