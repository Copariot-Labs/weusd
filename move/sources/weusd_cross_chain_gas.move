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
    const E_CONTRACT_PAUSED: u64 = 1031; // Contract is paused

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
        cross_mint_role_contract: address,
        paused: bool  // Emergency pause state
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
    
    // Check if contract is paused (internal function for public user functions only)
    fun ensure_not_paused() acquires GlobalManage {
        let global_manage = borrow_global<GlobalManage>(@picwe);
        assert!(!global_manage.paused, E_CONTRACT_PAUSED);
    }
    
    // Pause the contract (only contract owner) - affects only public user functions
    // @param sender: Must be contract owner
    public entry fun pause(sender: &signer) acquires GlobalManage {
        assert!(signer::address_of(sender) == @picwe, error::permission_denied(ENOT_OWNER));
        let global_manage = borrow_global_mut<GlobalManage>(@picwe);
        assert!(!global_manage.paused, error::invalid_argument(E_INVALID_ARGS)); // Already paused
        global_manage.paused = true;
    }
    
    // Unpause the contract (only contract owner)
    // @param sender: Must be contract owner
    public entry fun unpause(sender: &signer) acquires GlobalManage {
        assert!(signer::address_of(sender) == @picwe, error::permission_denied(ENOT_OWNER));
        let global_manage = borrow_global_mut<GlobalManage>(@picwe);
        assert!(global_manage.paused, error::invalid_argument(E_INVALID_ARGS)); // Not paused
        global_manage.paused = false;
    }
    
    // View function to check if contract is paused
    #[view]
    public fun is_paused(): bool acquires GlobalManage {
        let global_manage = borrow_global<GlobalManage>(@picwe);
        global_manage.paused
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
                cross_mint_role_contract: INITIAL_CROSS_CHAIN_MINT_ROLE,
                paused: false
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

    // Set fee recipient address with zero address check
    // @param caller: Must be contract owner
    // @param feeRecipient: New fee recipient address (cannot be zero)
    public entry fun setFeeRecipient(
        caller: &signer, feeRecipient: address
    ) acquires GlobalManage {
        assert!(
            signer::address_of(caller) == @picwe, error::permission_denied(ENOT_OWNER)
        );
        // Check for zero address
        assert!(feeRecipient != @0x0, error::invalid_argument(E_InvalidTargetUserAddress));
        let fee_recipient = &mut borrow_global_mut<GlobalManage>(@picwe).feeRecipient;
        *fee_recipient = feeRecipient;
    }

    // Set cross-chain minter role with zero address check
    // @param caller: Must be contract owner
    // @param account: New minter role address (cannot be zero)
    public entry fun set_cross_chain_minter_role(
        caller: &signer, account: address
    ) acquires GlobalManage {
        assert!(
            signer::address_of(caller) == @picwe,
            error::permission_denied(E_ONLY_OWNER_CAN_SET_ROLE)
        );
        // Check for zero address
        assert!(account != @0x0, error::invalid_argument(E_InvalidTargetUserAddress));
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
        
        // Only swap if the element to delete is not the last element
        if (idx < len - 1) {
            let last_id = *vector::borrow(vec, len - 1);
            let slot = vector::borrow_mut(vec, idx);
            *slot = last_id;
            // Update the index mapping for the moved element
            smart_table::remove(&mut gm.requestIdToSourceActiveIndex, last_id);
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
        
        // Only swap if the element to delete is not the last element
        if (idx < len - 1) {
            let last_id = *vector::borrow(vec, len - 1);
            let slot = vector::borrow_mut(vec, idx);
            *slot = last_id;
            // Update the index mapping for the moved element
            smart_table::remove(&mut gm.requestIdToTargetActiveIndex, last_id);
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
        ensure_not_paused();
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
}
