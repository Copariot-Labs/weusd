/// A module that implements a managed fungible asset for WEUSD token.
/// The deployer will create a new managed fungible asset with hardcoded name, symbol, and decimals.
module picwe::weusd {
    use aptos_framework::fungible_asset::{
        Self,
        MintRef,
        TransferRef,
        BurnRef,
        Metadata
    };
    use aptos_framework::object::{Self, Object};
    use aptos_framework::primary_fungible_store;
    use std::string::utf8;
    use std::option;

    // Declare friend modules
    friend picwe::weusd_mint_redeem;
    friend picwe::weusd_cross_chain_gas;

    const ASSET_SYMBOL: vector<u8> = b"WEUSD";
    const ENOT_POSITIVE: u64 = 1001;
    
    #[resource_group_member(group = aptos_framework::object::ObjectGroup)]
    /// Holds the reference to control token minting, transfer, and burning
    struct ManagedFungibleAsset has key {
        mint_ref: MintRef,
        transfer_ref: TransferRef,
        burn_ref: BurnRef
    }

    /// Initialize the metadata object and store the reference
    fun init_module(admin: &signer) {
        let constructor_ref = &object::create_named_object(admin, ASSET_SYMBOL);
        primary_fungible_store::create_primary_store_enabled_fungible_asset(
            constructor_ref,
            option::none(),
            utf8(b"WEUSD"), /* name */
            utf8(ASSET_SYMBOL), /* symbol */
            6, /* decimals */
            utf8(b"https://raw.githubusercontent.com/pipimove/logo/refs/heads/main/coin_weusd.ico"), /* icon */
            utf8(b"http://picwe.org") /* project */
        );
        
        // Create mint/burn/transfer reference
        let mint_ref = fungible_asset::generate_mint_ref(constructor_ref);
        let burn_ref = fungible_asset::generate_burn_ref(constructor_ref);
        let transfer_ref = fungible_asset::generate_transfer_ref(constructor_ref);
        let metadata_object_signer = object::generate_signer(constructor_ref);
        move_to(
            &metadata_object_signer,
            ManagedFungibleAsset { 
                mint_ref, 
                transfer_ref, 
                burn_ref
            }
        );
    }

    #[view]
    /// Return the address of the token metadata object
    public fun get_metadata(): Object<Metadata> {
        let asset_address = object::create_object_address(&@picwe, ASSET_SYMBOL);
        object::address_to_object<Metadata>(asset_address)
    }

    #[view]
    public fun balance(owner: address): u64 {
        let metadata = get_metadata();
        if (!primary_fungible_store::primary_store_exists(owner, metadata)) {
            // If the owner doesn't have a primary store, their balance is 0
            return 0
        };

        let store = primary_fungible_store::primary_store(owner, metadata);
        fungible_asset::balance(store)
    }

    #[view]
    /// Get the total supply
    public fun total_supply(): u64 {
        let metadata = get_metadata();
        let supply_opt = fungible_asset::supply(metadata);
        if (option::is_some(&supply_opt)) {
            (option::extract(&mut supply_opt) as u64)
        } else {
            0
        }
    }

    inline fun authorized_borrow_refs(
        asset: Object<Metadata>
    ): &ManagedFungibleAsset acquires ManagedFungibleAsset {
        borrow_global<ManagedFungibleAsset>(object::object_address(&asset))
    }

    /// Mint tokens - only callable by friend modules
    public(friend) fun mint(
        to: address, 
        amount: u64
    ) acquires ManagedFungibleAsset {
        assert!(amount > 0, ENOT_POSITIVE);
        let asset = get_metadata();
        let managed_fungible_asset = authorized_borrow_refs(asset);
        let to_wallet = primary_fungible_store::ensure_primary_store_exists(to, asset);
        let fa = fungible_asset::mint(&managed_fungible_asset.mint_ref, amount);
        fungible_asset::deposit_with_ref(
            &managed_fungible_asset.transfer_ref,
            to_wallet,
            fa
        );
    }

    /// Burn tokens - only callable by friend modules
    public(friend) fun burn(
        from: address,
        amount: u64
    ) acquires ManagedFungibleAsset {
        assert!(amount > 0, ENOT_POSITIVE);
        let asset = get_metadata();
        let managed_fungible_asset = authorized_borrow_refs(asset);
        let from_store = primary_fungible_store::primary_store(from, asset);
        fungible_asset::burn_from(
            &managed_fungible_asset.burn_ref,
            from_store,
            amount
        );
    }
    
    #[test_only]
    public fun test_init_only(creator: &signer) {
        init_module(creator);
    }

    #[test_only]
    public fun get_metadata_addr(): address {
        object::create_object_address(&@picwe, ASSET_SYMBOL)
    }
}
