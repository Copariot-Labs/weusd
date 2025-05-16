module picwe::faucet {
    use std::signer;
    use std::string::utf8;
    use std::option;
    use aptos_framework::object::{Self, Object};
    use aptos_framework::fungible_asset::{Self, Metadata, MintRef, BurnRef, TransferRef};
    use aptos_framework::primary_fungible_store;

    // Constants
    const USDT_SYMBOL: vector<u8> = b"USDT";
    const USDT_DECIMALS: u8 = 6;
    const FAUCET_AMOUNT_USDT: u64 = 1000000_000000;    // 1000000 USDT (6 decimals)
    
    // Error constants
    const E_NOT_INITIALIZED: u64 = 2001;
    const E_UNAUTHORIZED: u64 = 2002;
    const E_INVALID_AMOUNT: u64 = 2003;

    #[resource_group_member(group = aptos_framework::object::ObjectGroup)]
    struct USDTToken has key {
        mint_ref: MintRef,
        burn_ref: BurnRef,
        transfer_ref: TransferRef
    }

    fun init_module(admin: &signer) {
        let usdt_constructor_ref = &object::create_named_object(admin, USDT_SYMBOL);
        primary_fungible_store::create_primary_store_enabled_fungible_asset(
            usdt_constructor_ref,
            option::none(),
            utf8(b"USDT Token"), /* name */
            utf8(USDT_SYMBOL), /* symbol */
            USDT_DECIMALS, /* decimals */
            utf8(b"https://usdt.com/favicon.ico"), /* icon */
            utf8(b"https://usdt.com") /* project */
        );
        
        let usdt_mint_ref = fungible_asset::generate_mint_ref(usdt_constructor_ref);
        let usdt_burn_ref = fungible_asset::generate_burn_ref(usdt_constructor_ref);
        let usdt_transfer_ref = fungible_asset::generate_transfer_ref(usdt_constructor_ref);
        let usdt_metadata_object_signer = object::generate_signer(usdt_constructor_ref);
        move_to(
            &usdt_metadata_object_signer,
            USDTToken { 
                mint_ref: usdt_mint_ref, 
                burn_ref: usdt_burn_ref,
                transfer_ref: usdt_transfer_ref
            }
        );
    }

    #[view]
    public fun get_usdt_metadata(): Object<Metadata> {
        let asset_address = object::create_object_address(&@picwe, USDT_SYMBOL);
        object::address_to_object<Metadata>(asset_address)
    }

    #[view] 
    public fun get_usdt_balance(owner: address): u64 {
        let metadata = get_usdt_metadata();
        let store = primary_fungible_store::primary_store(owner, metadata);
        fungible_asset::balance(store)
    }

    public entry fun claim_usdt(sender: &signer) acquires USDTToken {
        let asset = get_usdt_metadata();
        let managed_fungible_asset = borrow_global<USDTToken>(object::object_address(&asset));
        let to_wallet = primary_fungible_store::ensure_primary_store_exists(signer::address_of(sender), asset);
        let fa = fungible_asset::mint(&managed_fungible_asset.mint_ref, FAUCET_AMOUNT_USDT);
        fungible_asset::deposit_with_ref(
            &managed_fungible_asset.transfer_ref,
            to_wallet,
            fa
        );
    }

    #[test_only]
    public fun test_init_only(creator: &signer) {
        init_module(creator);
    }
} 