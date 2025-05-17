/*
/// Module: events
module events::events;
*/

// For Move coding conventions, see
// https://docs.sui.io/concepts/sui-move-concepts/conventions

#[allow(unused_variable, unused_const)]
module events::attendance_nft {
    use sui::url::{Self, Url};
    use std::string::{Self, String};
    use sui::event;
    use std::hash;
    use sui::package;
    use sui::display;
    use sui::dynamic_field;
    use sui::clock::{Self, Clock};

    // Error codes
    const EInvalidPassword: u64 = 0;
    const EAlreadyClaimed: u64 = 1;
    const EEventNotFound: u64 = 2;
    const EEventExpired: u64 = 3;
    const ENoMintPermission: u64 = 4;

    // Structs

    /// Capability that represents admin authority
    public struct AdminCap has key, store {
        id: UID
    }

    /// The one-time witness for the module
    public struct ATTENDANCE_NFT has drop {}

    /// Event data stored for each event
    public struct Event has key, store {
        id: UID,
        name: String,
        description: String,
        location: String,
        /// Timestamp in milliseconds for when the event occurs
        date: u64,
        image_url: Url,
        /// Timestamp in milliseconds after which NFTs can no longer be minted
        expiration: u64,
        max_attendees: u64,
        attendee_count: u64,
        password_hash: vector<u8>
    }

    /// Collection of events
    public struct EventRegistry has key {
        id: UID,
        events_count: u64
    }

    /// The NFT that represents attendance
    public struct AttendanceNFT has key, store {
        id: UID,
        event_id: ID,
        name: String,
        description: String,
        image_url: Url,
        event_date: u64,
        location: String,
        /// The sequential number of this NFT in the event
        serial_number: u64
    }

    /// Save addresses that have claimed NFT for a given event
    public struct ClaimedAttendance has key {
        id: UID,
        event_id: ID
    }

    // Events

    /// Emitted when a new event is created
    public struct EventCreated has copy, drop {
        event_id: ID,
        name: String,
        date: u64,
        location: String
    }

    /// Emitted when an NFT is minted
    public struct NFTMinted has copy, drop {
        event_id: ID,
        attendee: address,
        nft_id: ID,
        serial_number: u64
    }

    /// One-time function called when the module is published
    fun init(witness: ATTENDANCE_NFT, ctx: &mut TxContext) {
        // Create an admin capability and send it to the publisher
        let admin_cap = AdminCap {
            id: object::new(ctx)
        };
        transfer::transfer(admin_cap, tx_context::sender(ctx));

        // Create event registry
        let registry = EventRegistry {
            id: object::new(ctx),
            events_count: 0
        };
        transfer::share_object(registry);

        // Set up the Publisher for the package
        let publisher = package::claim(witness, ctx);

        // Define the display properties for AttendanceNFT
        let keys = vector[
            string::utf8(b"name"),
            string::utf8(b"description"),
            string::utf8(b"image_url"),
            string::utf8(b"event_date"),
            string::utf8(b"location"),
            string::utf8(b"serial_number"),
        ];

        let values = vector[
            string::utf8(b"{name}"),
            string::utf8(b"{description}"),
            string::utf8(b"{image_url}"),
            string::utf8(b"{event_date}"),
            string::utf8(b"{location}"),
            string::utf8(b"#{serial_number}"),
        ];

        let mut display = display::new_with_fields<AttendanceNFT>(
            &publisher, keys, values, ctx
        );
        display::update_version(&mut display);
        transfer::public_transfer(display, tx_context::sender(ctx));
        transfer::public_transfer(publisher, tx_context::sender(ctx));
    }

    // Admin functions

    /// Create a new event (admin only)
    public entry fun create_event(
        _: &AdminCap,
        registry: &mut EventRegistry,
        name: vector<u8>,
        description: vector<u8>,
        location: vector<u8>,
        date: u64,
        image_url: vector<u8>,
        expiration: u64,
        max_attendees: u64,
        password: vector<u8>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let event_id = object::new(ctx);
        let event_object_id = object::uid_to_inner(&event_id);

        // Hash the password for secure storage
        let password_hash = hash::sha2_256(password);

        let event = Event {
            id: event_id,
            name: string::utf8(name),
            description: string::utf8(description),
            location: string::utf8(location),
            date,
            image_url: url::new_unsafe_from_bytes(image_url),
            expiration,
            max_attendees,
            attendee_count: 0,
            password_hash
        };

        // Create claimed attendance tracker
        let claimed = ClaimedAttendance {
            id: object::new(ctx),
            event_id: event_object_id
        };

        registry.events_count = registry.events_count + 1;
        
        // Emit event
        event::emit(EventCreated {
            event_id: event_object_id,
            name: string::utf8(name),
            date,
            location: string::utf8(location)
        });

        transfer::share_object(event);
        transfer::share_object(claimed);
    }

    /// Update event details (admin only)
    public entry fun update_event(
        _: &AdminCap,
        event: &mut Event,
        name: vector<u8>,
        description: vector<u8>,
        location: vector<u8>,
        date: u64,
        image_url: vector<u8>,
        expiration: u64,
        max_attendees: u64,
        ctx: &mut TxContext
    ) {
        event.name = string::utf8(name);
        event.description = string::utf8(description);
        event.location = string::utf8(location);
        event.date = date;
        event.image_url = url::new_unsafe_from_bytes(image_url);
        event.expiration = expiration;
        event.max_attendees = max_attendees;
    }

    /// Update event password (admin only)
    public entry fun update_password(
        _: &AdminCap,
        event: &mut Event,
        password: vector<u8>,
        ctx: &mut TxContext
    ) {
        let password_hash = hash::sha2_256(password);
        event.password_hash = password_hash;
    }

    // Public functions

    /// Mint an NFT for event attendance
    public entry fun mint_attendance_nft(
        event: &mut Event,
        claimed: &mut ClaimedAttendance,
        password: vector<u8>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let sender = tx_context::sender(ctx);
        
        // Check if event has expired
        assert!(is_event_active(event, clock), EEventExpired);
        
        // Check if max attendees limit has been reached
        assert!(event.attendee_count < event.max_attendees, ENoMintPermission);
        
        // Verify password
        let provided_hash = hash::sha2_256(password);
        assert!(vector::length(&provided_hash) == vector::length(&event.password_hash), EInvalidPassword);
        
        let mut password_correct = true;
        let mut i = 0;
        let len = vector::length(&provided_hash);
        
        while (i < len) {
            if (*vector::borrow(&provided_hash, i) != *vector::borrow(&event.password_hash, i)) {
                password_correct = false;
                break
            };
            i = i + 1;
        };
        
        assert!(password_correct, EInvalidPassword);
        
        // Check if user has already claimed
        let event_id = object::id(event);
        let attendee_field_name = get_attendee_field_name(sender);
        
        assert!(!dynamic_field::exists_(&claimed.id, attendee_field_name), EAlreadyClaimed);
        
        // Mark as claimed
        dynamic_field::add(&mut claimed.id, attendee_field_name, true);
        
        // Increment attendance count and mint NFT
        event.attendee_count = event.attendee_count + 1;
        
        let nft = AttendanceNFT {
            id: object::new(ctx),
            event_id,
            name: event.name,
            description: event.description,
            image_url: event.image_url,
            event_date: event.date,
            location: event.location,
            serial_number: event.attendee_count
        };
        
        let nft_id = object::id(&nft);
        
        // Emit event
        event::emit(NFTMinted {
            event_id,
            attendee: sender,
            nft_id,
            serial_number: event.attendee_count
        });
        
        transfer::transfer(nft, sender);
    }

    // Helper functions

    /// Generate a unique field name for an attendee
    fun get_attendee_field_name(attendee: address): vector<u8> {
        let bytes = std::bcs::to_bytes(&attendee);
        bytes
    }

    /// Get the current time in milliseconds
    fun get_current_time(clock: &Clock): u64 {
        clock::timestamp_ms(clock)
    }

    // View functions

    /// Get event details
    public fun get_event_details(event: &Event): (String, String, String, u64, Url, u64, u64, u64) {
        (
            event.name,
            event.description,
            event.location,
            event.date,
            event.image_url,
            event.expiration,
            event.max_attendees,
            event.attendee_count
        )
    }

    /// Check if an event is active (not expired)
    public fun is_event_active(event: &Event, clock: &Clock): bool {
        get_current_time(clock) <= event.expiration
    }

    /// Check if an address has claimed an NFT for a specific event
    public fun has_claimed(claimed: &ClaimedAttendance, attendee: address): bool {
        let attendee_field_name = get_attendee_field_name(attendee);
        dynamic_field::exists_(&claimed.id, attendee_field_name)
    }

    // For testing
    #[test_only]
    public fun get_witness(): ATTENDANCE_NFT {
        ATTENDANCE_NFT {}
    }
    
    #[test_only]
    public fun init_for_testing(witness: ATTENDANCE_NFT, ctx: &mut TxContext) {
        init(witness, ctx)
    }
}