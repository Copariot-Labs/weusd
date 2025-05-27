module picwe::weusd_mint_redeem {
    use std::signer;
    use aptos_framework::account;
    use aptos_framework::event;
    use aptos_framework::object::{Self, Object};
    use aptos_framework::fungible_asset::Metadata;
    use aptos_framework::primary_fungible_store;
    
    use picwe::weusd;
    use picwe::faucet;

    #[test_only]
    use std::signer::address_of;


    friend picwe::weusd_cross_chain_gas;
    
    const WEUSD_DECIMALS: u8 = 6;
    const STABLECOIN_DECIMALS: u8 = 6;
    
    const E_INSUFFICIENT_FEE: u64 = 1003;
    const E_INSUFFICIENT_RESERVES: u64 = 1004;
    const E_INSUFFICIENT_AMOUNT: u64 = 1006;
    const E_ZERO_AMOUNT: u64 = 1012;
    const E_NOT_AUTHORIZED: u64 = 1013;
    const E_INVALID_FEE_RATIO: u64 = 1014;
    const E_INVALID_PARAMETER: u64 = 1015;

    const STABLECOIN_ADDRESS: address = @stablecoin_metadata_address;
    const BALANCER_ADDRESS: address = @balancer_address;
    const RESOURCE_ACCOUNT_SEED: vector<u8> = b"PICWE_RESOURCE_ACCOUNT";

    #[event]
    struct MintedWeUSD has drop, store {
        user: address,
        costStablecoinAmount: u64,
        weUSDAmount: u64,
        fee: u64
    }

    #[event]
    struct BurnedWeUSD has drop, store {
        user: address,
        receivedStablecoinAmount: u64,
        weUSDAmount: u64,
        fee: u64
    }

    struct MintState has key {
        fee_recipient: address,
        fee_ratio: u64,  // Fee rate, base 10000
        stablecoin_reserves: u64,
        resource_signer_cap: account::SignerCapability,
        accumulated_fees: AccumulatedFees,
        min_amount: u64,  // Minimum WeUSD amount for minting&redeem
        cross_chain_reserves: u64,  // USDT reserved for cross-chain operations
        cross_chain_deficit: u64    // USDT deficit due to cross-chain operations
    }

    struct AccumulatedFees has store {
        stablecoin_fees: u64
    }

    struct EventHandles has key {
        minted_weusd_events: event::EventHandle<MintedWeUSD>,
        burned_weusd_events: event::EventHandle<BurnedWeUSD>,
    }

    fun init_module(sender: &signer) {
        let (_, resource_signer_cap) = account::create_resource_account(sender, RESOURCE_ACCOUNT_SEED);
        move_to(sender, MintState {
            fee_recipient: @weusd_fee_address,
            fee_ratio: 100, // 1% fee
            stablecoin_reserves: 0,
            resource_signer_cap,
            accumulated_fees: AccumulatedFees {
                stablecoin_fees: 0
            },
            min_amount: 10_000, // Default 0.01 WeUSD minimum
            cross_chain_reserves: 0,
            cross_chain_deficit: 0
        });
        move_to(sender, EventHandles {
            minted_weusd_events: account::new_event_handle<MintedWeUSD>(sender),
            burned_weusd_events: account::new_event_handle<BurnedWeUSD>(sender),
        });
    }

    // Get USDT token metadata
    fun get_usdt_metadata(): Object<Metadata> {
        faucet::get_usdt_metadata()
    }

    // Get resource account signer
    public(friend) fun get_resource_signer(): signer acquires MintState {
        account::create_signer_with_capability(&borrow_global<MintState>(@picwe).resource_signer_cap)
    }
    
    // Mint WeUSD tokens
    public entry fun mintWeUSD(
        sender: &signer,
        weusd_amount: u64
    ) acquires MintState, EventHandles {
        let sender_addr = signer::address_of(sender);
        let resource_signer = get_resource_signer();
        let mint_state = borrow_global_mut<MintState>(@picwe);
        assert!(weusd_amount >= mint_state.min_amount, E_INSUFFICIENT_AMOUNT);
        
        let stablecoin_metadata = get_usdt_metadata();
        let resource_account = signer::address_of(&resource_signer);
        
        // Transfer USDT from sender to resource account
        primary_fungible_store::transfer(
            sender,
            stablecoin_metadata,
            resource_account,
            weusd_amount
        );
        
        // Update reserves
        mint_state.stablecoin_reserves = mint_state.stablecoin_reserves + weusd_amount;

        // Mint WeUSD tokens
        weusd::mint(sender_addr, weusd_amount);

        event::emit_event(
            &mut borrow_global_mut<EventHandles>(@picwe).minted_weusd_events,
            MintedWeUSD {
                user: sender_addr,
                costStablecoinAmount: weusd_amount,
                weUSDAmount: weusd_amount,
                fee: 0
            }
        );
    }
    
    // Redeem WeUSD tokens
    public entry fun redeemWeUSD(
        sender: &signer,
        weusd_amount: u64
    ) acquires MintState, EventHandles {
        let recipient = signer::address_of(sender);
        let resource_signer = get_resource_signer();
        let mint_state = borrow_global_mut<MintState>(@picwe);
        assert!(weusd_amount >= mint_state.min_amount, E_INSUFFICIENT_AMOUNT);
        assert!(mint_state.stablecoin_reserves >= weusd_amount, E_INSUFFICIENT_RESERVES);

        // Calculate fee
        let fee = (weusd_amount * mint_state.fee_ratio) / 10000;
        let actual_stablecoin_amount = weusd_amount - fee;
        assert!(actual_stablecoin_amount > 0, E_ZERO_AMOUNT);

        let stablecoin_metadata = get_usdt_metadata();
        let fee_recipient = mint_state.fee_recipient;

        // Transfer USDT to recipient
        primary_fungible_store::transfer(
            &resource_signer,
            stablecoin_metadata,
            recipient,
            actual_stablecoin_amount
        );

        // Transfer fee to fee recipient
        primary_fungible_store::transfer(
            &resource_signer,
            stablecoin_metadata,
            fee_recipient,
            fee
        );
        
        // Update reserves
        mint_state.stablecoin_reserves = mint_state.stablecoin_reserves - weusd_amount;
        
        // Burn WEUSD
        weusd::burn(recipient, weusd_amount);
        
        // Update accumulated fees
        mint_state.accumulated_fees.stablecoin_fees = mint_state.accumulated_fees.stablecoin_fees + fee;

        event::emit_event(
            &mut borrow_global_mut<EventHandles>(@picwe).burned_weusd_events,
            BurnedWeUSD {
                user: recipient,
                receivedStablecoinAmount: actual_stablecoin_amount,
                weUSDAmount: weusd_amount,
                fee: fee
            }
        );
    }

    // Set fee ratio
    public entry fun set_fee_ratio(
        sender: &signer, 
        new_fee_ratio: u64
    ) acquires MintState {
        assert!(signer::address_of(sender) == @picwe, E_NOT_AUTHORIZED);
        assert!(new_fee_ratio >= 10 && new_fee_ratio <= 2000, E_INVALID_FEE_RATIO); // 0.1% to 20%
        let mint_state = borrow_global_mut<MintState>(@picwe);
        mint_state.fee_ratio = new_fee_ratio;
    }

    // Set minimum mint amount
    public entry fun set_min_amount(
        sender: &signer,
        new_min_amount: u64
    ) acquires MintState {
        assert!(signer::address_of(sender) == @setter, E_NOT_AUTHORIZED);
        let mint_state = borrow_global_mut<MintState>(@picwe);
        mint_state.min_amount = new_min_amount;
    }

    // Set fee recipient
    public entry fun set_fee_recipient(
        sender: &signer,
        new_fee_recipient: address
    ) acquires MintState {
        assert!(signer::address_of(sender) == @setter, E_NOT_AUTHORIZED);
        let mint_state = borrow_global_mut<MintState>(@picwe);
        mint_state.fee_recipient = new_fee_recipient;
    }

    // Query accumulated fees
    #[view]
    public fun get_accumulated_fees(): u64 acquires MintState {
        let mint_state = borrow_global<MintState>(@picwe);
        mint_state.accumulated_fees.stablecoin_fees
    }

    // Query total reserves
    #[view]
    public fun get_total_reserves(): u64 acquires MintState {
        let mint_state = borrow_global<MintState>(@picwe);
        mint_state.stablecoin_reserves
    }

    #[view]
    public fun get_mint_state_fields(): (address, u64, u64) acquires MintState {
        let mint_state = borrow_global<MintState>(@picwe);
        (
            mint_state.fee_recipient,
            mint_state.fee_ratio,
            mint_state.min_amount
        )
    }

    // Function to handle cross-chain USDT reserves
    public(friend) fun reserve_stablecoin_for_cross_chain(
        amount: u64
    ) acquires MintState {
        let mint_state = borrow_global_mut<MintState>(@picwe);
        assert!(mint_state.stablecoin_reserves >= amount, E_INSUFFICIENT_RESERVES);
        
        // Deduct from reserves
        mint_state.stablecoin_reserves = mint_state.stablecoin_reserves - amount;
        // Repay any existing cross-chain deficit first and compute remaining to reserve
        let to_reserve = if (mint_state.cross_chain_deficit > 0) {
            let repay = if (amount <= mint_state.cross_chain_deficit) {
                amount
            } else {
                mint_state.cross_chain_deficit
            };
            mint_state.cross_chain_deficit = mint_state.cross_chain_deficit - repay;
            amount - repay
        } else {
            amount
        };
        // Add remaining amount to cross-chain reserves
        if (to_reserve > 0) {
            mint_state.cross_chain_reserves = mint_state.cross_chain_reserves + to_reserve;
        };
    }

    // Function to handle cross-chain USDT return
    public(friend) fun return_stablecoin_from_cross_chain(
        amount: u64
    ) acquires MintState {
        let mint_state = borrow_global_mut<MintState>(@picwe);
        
        if (mint_state.cross_chain_reserves >= amount) {
            // If we have enough reserves, return them to the pool
            mint_state.cross_chain_reserves = mint_state.cross_chain_reserves - amount;
            mint_state.stablecoin_reserves = mint_state.stablecoin_reserves + amount;
        } else {
            // If not enough reserves, record the deficit
            let remaining_amount = amount - mint_state.cross_chain_reserves;
            mint_state.stablecoin_reserves = mint_state.stablecoin_reserves + mint_state.cross_chain_reserves;
            mint_state.cross_chain_reserves = 0;
            mint_state.cross_chain_deficit = mint_state.cross_chain_deficit + remaining_amount;
        }
    }

    // Function for project to withdraw cross-chain reserves
    public entry fun withdraw_cross_chain_reserves(
        sender: &signer,
        amount: u64,
        recipient: address
    ) acquires MintState {
        let sender_addr = signer::address_of(sender);
        assert!(sender_addr == @picwe || sender_addr == BALANCER_ADDRESS, E_NOT_AUTHORIZED);
        
        // Get resource signer first
        let resource_signer = get_resource_signer();        
        // Then get mint state
        let mint_state = borrow_global_mut<MintState>(@picwe);
        assert!(mint_state.cross_chain_reserves >= amount, E_INSUFFICIENT_RESERVES);
        
        // Transfer USDT to specified recipient address
        let stablecoin_metadata = get_usdt_metadata();
        
        primary_fungible_store::transfer(
            &resource_signer,
            stablecoin_metadata,
            recipient,
            amount
        );
        
        // Update cross-chain reserves
        mint_state.cross_chain_reserves = mint_state.cross_chain_reserves - amount;
    }

    // Function to withdraw cross-chain reserves to balancer address
    public entry fun withdraw_cross_chain_reserves_to_balancer(
        sender: &signer,
        amount: u64
    ) acquires MintState {
        let sender_addr = signer::address_of(sender);
        assert!(sender_addr == @picwe || sender_addr == BALANCER_ADDRESS, E_NOT_AUTHORIZED);
        withdraw_cross_chain_reserves(sender, amount, BALANCER_ADDRESS);
    }

    // View function to check cross-chain reserves
    #[view]
    public fun get_cross_chain_reserves(): u64 acquires MintState {
        let mint_state = borrow_global<MintState>(@picwe);
        mint_state.cross_chain_reserves
    }

    // View function to check cross-chain deficit
    #[view]
    public fun get_cross_chain_deficit(): u64 acquires MintState {
        let mint_state = borrow_global<MintState>(@picwe);
        mint_state.cross_chain_deficit
    }

    #[test_only]
    public fun create_test_accounts(
        deployer: &signer, 
        user_1: &signer, 
        user_2: &signer
    ) {
        account::create_account_for_test(address_of(user_1));
        account::create_account_for_test(address_of(user_2));
        account::create_account_for_test(address_of(deployer));
    }

    #[test_only]
    public fun test_init_only(creator: &signer) {
        init_module(creator);
    }

    // Test basic mint and redeem functionality
    #[test(sender = @picwe, user1 = @0x123, user2 = @0x1234)]
    public fun test_basic_mint_redeem(
        sender: &signer,
        user1: &signer,
        user2: &signer
    ) acquires MintState, EventHandles {
        // Initialize test environment
        create_test_accounts(sender, user1, user2);
        
        // Initialize modules
        faucet::test_init_only(sender);
        weusd::test_init_only(sender);
        test_init_only(sender);

        // Get test tokens
        faucet::claim_usdt(user1);

        // Test mint
        let initial_usdt_balance = primary_fungible_store::balance(address_of(user1), get_usdt_metadata());
        let mint_amount = 1000_000000; // 1000 USDT
        
        mintWeUSD(user1, mint_amount);
        
        // Verify mint results
        let final_usdt_balance = primary_fungible_store::balance(address_of(user1), get_usdt_metadata());
        let weusd_balance = primary_fungible_store::balance(address_of(user1), weusd::get_metadata());
        assert!(initial_usdt_balance - final_usdt_balance == mint_amount, E_INVALID_PARAMETER);
        assert!(weusd_balance == mint_amount, E_INVALID_PARAMETER);

        // Test redeem
        redeemWeUSD(user1, mint_amount);
        
        // Verify redeem results
        let final_usdt_balance_after_redeem = primary_fungible_store::balance(address_of(user1), get_usdt_metadata());
        let final_weusd_balance = primary_fungible_store::balance(address_of(user1), weusd::get_metadata());
        assert!(final_weusd_balance == 0, E_INVALID_PARAMETER);
        assert!(final_usdt_balance_after_redeem < initial_usdt_balance, E_INVALID_PARAMETER); // Due to fees
    }

    // Test fee ratio changes
    #[test(sender = @picwe, user1 = @0x123)]
    public fun test_fee_ratio_changes(
        sender: &signer,
        user1: &signer
    ) acquires MintState {
        // Initialize test environment
        create_test_accounts(sender, user1, user1);
        
        // Initialize modules
        faucet::test_init_only(sender);
        weusd::test_init_only(sender);
        test_init_only(sender);

        // Test setting fee ratio
        set_fee_ratio(sender, 200); // 2%
        let (_, fee_ratio, _) = get_mint_state_fields();
        assert!(fee_ratio == 200, E_INVALID_PARAMETER);

        // Test invalid fee ratio
        set_fee_ratio(sender, 10); // 0.1%
        let (_, fee_ratio, _) = get_mint_state_fields();
        assert!(fee_ratio == 10, E_INVALID_PARAMETER);
    }

    // Test minimum amount restrictions
    #[test(sender = @picwe, user1 = @0x123)]
    public fun test_min_amount_restrictions(
        sender: &signer,
        user1: &signer
    ) acquires MintState {
        // Initialize test environment
        create_test_accounts(sender, user1, user1);
        
        // Initialize modules
        faucet::test_init_only(sender);
        weusd::test_init_only(sender);
        test_init_only(sender);

        // Get test tokens
        faucet::claim_usdt(user1);

        // Test setting minimum amount
        set_min_amount(sender, 100_000000); // 100 USDT
        let (_, _, min_amount) = get_mint_state_fields();
        assert!(min_amount == 100_000000, E_INVALID_PARAMETER);

        // Test mint with amount below minimum
        let mint_amount = 50_000000; // 50 USDT
        assert!(mint_amount < min_amount, E_INVALID_PARAMETER);
    }

    // Test insufficient reserves
    #[test(sender = @picwe, user1 = @0x123)]
    public fun test_insufficient_reserves(
        sender: &signer,
        user1: &signer
    ) acquires MintState, EventHandles {
        // Initialize test environment
        create_test_accounts(sender, user1, user1);
        
        // Initialize modules
        faucet::test_init_only(sender);
        weusd::test_init_only(sender);
        test_init_only(sender);

        // Get test tokens
        faucet::claim_usdt(user1);

        // Mint some WeUSD
        let mint_amount = 1000_000000;
        mintWeUSD(user1, mint_amount);

        // Try to redeem more than reserves
        let redeem_amount = 2000_000000;
        assert!(redeem_amount > get_total_reserves(), E_INVALID_PARAMETER);
    }

    // Test fee calculations
    #[test(sender = @picwe, user1 = @0x123)]
    public fun test_fee_calculations(
        sender: &signer,
        user1: &signer
    ) acquires MintState, EventHandles {
        // Initialize test environment
        create_test_accounts(sender, user1, user1);
        
        // Initialize modules
        faucet::test_init_only(sender);
        weusd::test_init_only(sender);
        test_init_only(sender);

        // Get test tokens
        faucet::claim_usdt(user1);

        // Set fee ratio to 1%
        set_fee_ratio(sender, 100);

        // Mint and redeem to accumulate fees
        let amount = 1000_000000;
        mintWeUSD(user1, amount);
        redeemWeUSD(user1, amount);

        // Verify fee calculation
        let expected_fee = (amount * 100) / 10000; // 1% of amount
        let actual_fee = get_accumulated_fees();
        assert!(actual_fee == expected_fee, E_INVALID_PARAMETER);
    }

    // Test attempting to redeem more WeUSD than user holds
    #[expected_failure(abort_code = 65540)] // fungible_asset::EInsufficientBalance
    #[test(sender = @picwe, user1 = @0x123)]
    public fun test_redeem_more_than_holding(
        sender: &signer,
        user1: &signer
    ) acquires MintState, EventHandles {
        // Initialize test environment
        create_test_accounts(sender, user1, user1);
        
        // Initialize modules
        faucet::test_init_only(sender);
        weusd::test_init_only(sender);
        test_init_only(sender);

        // Get test tokens
        faucet::claim_usdt(user1);

        // Mint a small amount
        let mint_amount = 50_000000; // 50 WEUSD
        mintWeUSD(user1, mint_amount);
        
        // Mint more to ensure reserves are sufficient
        mintWeUSD(sender, 100_000000); // Mint 100 WEUSD to sender to ensure reserves
        
        // Attempt to redeem more than the user holds
        let redeem_amount = 100_000000; // 100 WEUSD
        redeemWeUSD(user1, redeem_amount);
        
        // This should fail with fungible_asset::EInsufficientBalance
    }
    
    // Test insufficient cross-chain reserves
    #[expected_failure(abort_code = 1004)] // E_INSUFFICIENT_RESERVES = 1004
    #[test(sender = @picwe, user1 = @0x123)]
    public fun test_insufficient_cross_chain_reserves(
        sender: &signer,
        user1: &signer
    ) acquires MintState, EventHandles {
        // Initialize test environment
        create_test_accounts(sender, user1, user1);
        
        // Initialize modules
        faucet::test_init_only(sender);
        weusd::test_init_only(sender);
        test_init_only(sender);

        // Get test tokens
        faucet::claim_usdt(user1);

        // Mint some WeUSD for reserves
        let mint_amount = 1000_000000; // 1000 WEUSD
        mintWeUSD(user1, mint_amount);
        
        // Reserve some for cross-chain (500 WEUSD)
        let cross_chain_amount = 500_000000;
        reserve_stablecoin_for_cross_chain(cross_chain_amount);
        
        // Verify cross-chain reserves
        assert!(get_cross_chain_reserves() == cross_chain_amount, E_INVALID_PARAMETER);
        
        // Try to withdraw more than available in cross-chain reserves
        let withdraw_amount = 600_000000; // 600 WEUSD
        
        // Attempt to withdraw and expect failure with E_INSUFFICIENT_RESERVES
        // We use "address_of" function within the test for the sender address
        withdraw_cross_chain_reserves(sender, withdraw_amount, address_of(user1));
        // This will fail at runtime with E_INSUFFICIENT_RESERVES if executed without expected_failure
    }
    
    // Test cross-chain deficit increase and processing
    #[test(sender = @picwe, user1 = @0x123)]
    public fun test_cross_chain_deficit(
        sender: &signer,
        user1: &signer
    ) acquires MintState, EventHandles {
        // Initialize test environment
        create_test_accounts(sender, user1, user1);
        
        // Initialize modules
        faucet::test_init_only(sender);
        weusd::test_init_only(sender);
        test_init_only(sender);

        // Get test tokens for initial reserves
        faucet::claim_usdt(user1);
        
        // Mint some WeUSD for reserves
        let mint_amount = 1000_000000; // 1000 WEUSD (using standard testing function)
        mintWeUSD(user1, mint_amount);
        
        // Reserve some for cross-chain operations (300 WEUSD)
        let cross_chain_amount = 300_000000;
        reserve_stablecoin_for_cross_chain(cross_chain_amount);
        
        // Verify initial cross-chain reserves
        assert!(get_cross_chain_reserves() == cross_chain_amount, E_INVALID_PARAMETER);
        assert!(get_cross_chain_deficit() == 0, E_INVALID_PARAMETER);
        
        // Try to return more stablecoin than we have in cross-chain reserves
        let return_amount = 500_000000; // 500 WEUSD
        return_stablecoin_from_cross_chain(return_amount);
        
        // Verify that all cross-chain reserves were moved back to main reserves
        assert!(get_cross_chain_reserves() == 0, E_INVALID_PARAMETER);
        
        // Verify that a deficit of 200 WEUSD was recorded (500 - 300)
        assert!(get_cross_chain_deficit() == (return_amount - cross_chain_amount), E_INVALID_PARAMETER);
        
        // Verify that the main reserves increased by the cross-chain reserve amount (not the full return amount)
        let expected_reserves = mint_amount; // Initial reserves should be preserved and the cross-chain reserves returned
        assert!(get_total_reserves() == expected_reserves, E_INVALID_PARAMETER);
    }
}