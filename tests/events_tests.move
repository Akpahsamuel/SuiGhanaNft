#[test_only]
module events::attendance_nft_tests {
    use sui::test_scenario::{Self as ts, Scenario};
    use sui::test_utils::{assert_eq};
    use sui::clock::{Self, Clock};
    use events::attendance_nft::{Self, AdminCap, Event, EventRegistry, ClaimedAttendance, AttendanceNFT};
    use std::string;
    use sui::transfer;
    use sui::object::{Self, ID};
    use std::vector;
    
    // Test addresses
    const ADMIN: address = @0xAD;
    const USER1: address = @0xA1;
    const USER2: address = @0xA2;
    
    // Test constants
    const EVENT_NAME: vector<u8> = b"Test Event";
    const EVENT_DESC: vector<u8> = b"Test Event Description";
    const EVENT_LOC: vector<u8> = b"Test Location";
    const EVENT_IMG: vector<u8> = b"https://example.com/image.png";
    const EVENT_PASSWORD: vector<u8> = b"password123";
    
    // Error codes for tests
    const EEventNotFound: u64 = 100;
    const ENFTNotFound: u64 = 101;
    
    // Helper function to set up test scenario with admin and registry
    fun setup_test(): (Scenario, Clock) {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        
        // First transaction: publish the module
        ts::next_tx(&mut scenario, ADMIN);
        {
            // Get the witness and initialize the module for testing
            let witness = attendance_nft::get_witness();
            attendance_nft::init_for_testing(witness, ts::ctx(&mut scenario));
        };
        
        (scenario, clock)
    }
    
    // Helper function to create an event for testing
    fun create_test_event(
        scenario: &mut Scenario, 
        clock: &Clock,
        date: u64, 
        expiration: u64, 
        max_attendees: u64
    ): ID {
        // Admin creates an event
        ts::next_tx(scenario, ADMIN);
        
        let admin_cap = ts::take_from_sender<AdminCap>(scenario);
        let mut registry = ts::take_shared<EventRegistry>(scenario);
        
        attendance_nft::create_event(
            &admin_cap,
            &mut registry,
            EVENT_NAME,
            EVENT_DESC,
            EVENT_LOC,
            date,
            EVENT_IMG,
            expiration,
            max_attendees,
            EVENT_PASSWORD,
            clock,
            ts::ctx(scenario)
        );
        
        // Get the event ID (we know it's the first shared Event)
        let event_id: ID;
        
        ts::next_tx(scenario, ADMIN);
        {
            // Check that Event was created
            assert!(ts::has_most_recent_shared<Event>(), EEventNotFound);
            let event = ts::take_shared<Event>(scenario);
            event_id = object::id(&event);
            ts::return_shared(event);
        };
        
        ts::return_to_sender(scenario, admin_cap);
        ts::return_shared(registry);
        
        event_id
    }
    
    #[test]
    fun test_init_and_admin_cap() {
        let (mut scenario, clock) = setup_test();
        
        // Check if admin cap was created and sent to admin
        ts::next_tx(&mut scenario, ADMIN);
        {
            assert!(ts::has_most_recent_for_sender<AdminCap>(&scenario), 0);
        };
        
        // Check if registry was created
        {
            let registry_exists = ts::has_most_recent_shared<EventRegistry>();
            assert!(registry_exists, 1);
            let mut registry = ts::take_shared<EventRegistry>(&mut scenario);
            ts::return_shared(registry);
        };
        
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }
    
    #[test]
    fun test_create_event() {
        let (mut scenario, clock) = setup_test();
        
        // Current time + 1 day for date
        let current_time = clock::timestamp_ms(&clock);
        let event_date = current_time + 86400000; // +1 day in ms
        let expiration = current_time + 172800000; // +2 days in ms
        let max_attendees = 100;
        
        let event_id = create_test_event(&mut scenario, &clock, event_date, expiration, max_attendees);
        
        // Verify event was created with correct properties
        ts::next_tx(&mut scenario, ADMIN);
        {
            let event = ts::take_shared_by_id<Event>(&mut scenario, event_id);
            let (name, desc, loc, date, _, exp, max, count) = attendance_nft::get_event_details(&event);
            
            assert_eq(name, string::utf8(EVENT_NAME));
            assert_eq(desc, string::utf8(EVENT_DESC));
            assert_eq(loc, string::utf8(EVENT_LOC));
            assert_eq(date, event_date);
            assert_eq(exp, expiration);
            assert_eq(max, max_attendees);
            assert_eq(count, 0);
            
            ts::return_shared(event);
        };
        
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }
    
    #[test]
    fun test_mint_nft() {
        let (mut scenario, clock) = setup_test();
        
        // Current time + 1 day for date
        let current_time = clock::timestamp_ms(&clock);
        let event_date = current_time + 86400000; // +1 day in ms
        let expiration = current_time + 172800000; // +2 days in ms
        let max_attendees = 100;
        
        let event_id = create_test_event(&mut scenario, &clock, event_date, expiration, max_attendees);
        
        // Get the ClaimedAttendance object first
        let claimed_id: ID;
        ts::next_tx(&mut scenario, ADMIN);
        {
            // Find the ClaimedAttendance object
            assert!(ts::has_most_recent_shared<ClaimedAttendance>(), 0);
            let claimed = ts::take_shared<ClaimedAttendance>(&mut scenario);
            claimed_id = object::id(&claimed);
            ts::return_shared(claimed);
        };
        
        // User1 mints an NFT
        ts::next_tx(&mut scenario, USER1);
        {
            let mut event = ts::take_shared_by_id<Event>(&mut scenario, event_id);
            let mut claimed = ts::take_shared_by_id<ClaimedAttendance>(&mut scenario, claimed_id);
            
            attendance_nft::mint_attendance_nft(
                &mut event,
                &mut claimed,
                EVENT_PASSWORD,
                &clock,
                ts::ctx(&mut scenario)
            );
            
            // Verify event counter increased
            let (_, _, _, _, _, _, _, count) = attendance_nft::get_event_details(&event);
            assert_eq(count, 1);
            
            // Verify user has claimed
            assert!(attendance_nft::has_claimed(&claimed, USER1), 0);
            
            ts::return_shared(event);
            ts::return_shared(claimed);
        };
        
        // Verify NFT was transferred to user
        ts::next_tx(&mut scenario, USER1);
        {
            // Check NFT is in USER1's inventory
            assert!(ts::has_most_recent_for_sender<AttendanceNFT>(&scenario), ENFTNotFound);
            let nft = ts::take_from_sender<AttendanceNFT>(&mut scenario);
            ts::return_to_sender(&mut scenario, nft);
        };
        
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }
    
    #[test]
    #[expected_failure(abort_code = attendance_nft::EAlreadyClaimed)]
    fun test_cannot_mint_twice() {
        let (mut scenario, clock) = setup_test();
        
        // Current time + 1 day for date
        let current_time = clock::timestamp_ms(&clock);
        let event_date = current_time + 86400000; // +1 day in ms
        let expiration = current_time + 172800000; // +2 days in ms
        let max_attendees = 100;
        
        let event_id = create_test_event(&mut scenario, &clock, event_date, expiration, max_attendees);
        
        // Get the ClaimedAttendance object first
        let claimed_id: ID;
        ts::next_tx(&mut scenario, ADMIN);
        {
            // Find the ClaimedAttendance object
            assert!(ts::has_most_recent_shared<ClaimedAttendance>(), 0);
            let claimed = ts::take_shared<ClaimedAttendance>(&mut scenario);
            claimed_id = object::id(&claimed);
            ts::return_shared(claimed);
        };
        
        // User1 mints an NFT
        ts::next_tx(&mut scenario, USER1);
        {
            let mut event = ts::take_shared_by_id<Event>(&mut scenario, event_id);
            let mut claimed = ts::take_shared_by_id<ClaimedAttendance>(&mut scenario, claimed_id);
            
            attendance_nft::mint_attendance_nft(
                &mut event,
                &mut claimed,
                EVENT_PASSWORD,
                &clock,
                ts::ctx(&mut scenario)
            );
            
            ts::return_shared(event);
            ts::return_shared(claimed);
        };
        
        // User1 tries to mint again - should fail
        ts::next_tx(&mut scenario, USER1);
        {
            let mut event = ts::take_shared_by_id<Event>(&mut scenario, event_id);
            let mut claimed = ts::take_shared_by_id<ClaimedAttendance>(&mut scenario, claimed_id);
            
            attendance_nft::mint_attendance_nft(
                &mut event,
                &mut claimed,
                EVENT_PASSWORD,
                &clock,
                ts::ctx(&mut scenario)
            );
            
            ts::return_shared(event);
            ts::return_shared(claimed);
        };
        
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }
    
    #[test]
    #[expected_failure(abort_code = attendance_nft::EInvalidPassword)]
    fun test_invalid_password() {
        let (mut scenario, clock) = setup_test();
        
        // Current time + 1 day for date
        let current_time = clock::timestamp_ms(&clock);
        let event_date = current_time + 86400000; // +1 day in ms
        let expiration = current_time + 172800000; // +2 days in ms
        let max_attendees = 100;
        
        let event_id = create_test_event(&mut scenario, &clock, event_date, expiration, max_attendees);
        
        // Get the ClaimedAttendance object first
        let claimed_id: ID;
        ts::next_tx(&mut scenario, ADMIN);
        {
            // Find the ClaimedAttendance object
            assert!(ts::has_most_recent_shared<ClaimedAttendance>(), 0);
            let claimed = ts::take_shared<ClaimedAttendance>(&mut scenario);
            claimed_id = object::id(&claimed);
            ts::return_shared(claimed);
        };
        
        // User1 tries to mint with wrong password
        ts::next_tx(&mut scenario, USER1);
        {
            let mut event = ts::take_shared_by_id<Event>(&mut scenario, event_id);
            let mut claimed = ts::take_shared_by_id<ClaimedAttendance>(&mut scenario, claimed_id);
            
            attendance_nft::mint_attendance_nft(
                &mut event,
                &mut claimed,
                b"wrong_password",
                &clock,
                ts::ctx(&mut scenario)
            );
            
            ts::return_shared(event);
            ts::return_shared(claimed);
        };
        
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }
    
    #[test]
    #[expected_failure(abort_code = attendance_nft::EEventExpired)]
    fun test_expired_event() {
        let (mut scenario, mut clock) = setup_test();
        
        // Current time + 1 day for date
        let current_time = clock::timestamp_ms(&clock);
        let event_date = current_time + 86400000; // +1 day in ms
        let expiration = current_time + 172800000; // +2 days in ms
        let max_attendees = 100;
        
        let event_id = create_test_event(&mut scenario, &clock, event_date, expiration, max_attendees);
        
        // Get the ClaimedAttendance object first
        let claimed_id: ID;
        ts::next_tx(&mut scenario, ADMIN);
        {
            // Find the ClaimedAttendance object
            assert!(ts::has_most_recent_shared<ClaimedAttendance>(), 0);
            let claimed = ts::take_shared<ClaimedAttendance>(&mut scenario);
            claimed_id = object::id(&claimed);
            ts::return_shared(claimed);
        };
        
        // Fast forward time past expiration
        clock::increment_for_testing(&mut clock, 259200000); // +3 days in ms
        
        // User1 tries to mint after expiration
        ts::next_tx(&mut scenario, USER1);
        {
            let mut event = ts::take_shared_by_id<Event>(&mut scenario, event_id);
            let mut claimed = ts::take_shared_by_id<ClaimedAttendance>(&mut scenario, claimed_id);
            
            attendance_nft::mint_attendance_nft(
                &mut event,
                &mut claimed,
                EVENT_PASSWORD,
                &clock,
                ts::ctx(&mut scenario)
            );
            
            ts::return_shared(event);
            ts::return_shared(claimed);
        };
        
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }
    
    #[test]
    #[expected_failure(abort_code = attendance_nft::ENoMintPermission)]
    fun test_max_attendees_reached() {
        let (mut scenario, clock) = setup_test();
        
        // Current time + 1 day for date
        let current_time = clock::timestamp_ms(&clock);
        let event_date = current_time + 86400000; // +1 day in ms
        let expiration = current_time + 172800000; // +2 days in ms
        let max_attendees = 1; // Only 1 attendee allowed
        
        let event_id = create_test_event(&mut scenario, &clock, event_date, expiration, max_attendees);
        
        // Get the ClaimedAttendance object first
        let claimed_id: ID;
        ts::next_tx(&mut scenario, ADMIN);
        {
            // Find the ClaimedAttendance object
            assert!(ts::has_most_recent_shared<ClaimedAttendance>(), 0);
            let claimed = ts::take_shared<ClaimedAttendance>(&mut scenario);
            claimed_id = object::id(&claimed);
            ts::return_shared(claimed);
        };
        
        // User1 mints an NFT
        ts::next_tx(&mut scenario, USER1);
        {
            let mut event = ts::take_shared_by_id<Event>(&mut scenario, event_id);
            let mut claimed = ts::take_shared_by_id<ClaimedAttendance>(&mut scenario, claimed_id);
            
            attendance_nft::mint_attendance_nft(
                &mut event,
                &mut claimed,
                EVENT_PASSWORD,
                &clock,
                ts::ctx(&mut scenario)
            );
            
            ts::return_shared(event);
            ts::return_shared(claimed);
        };
        
        // User2 tries to mint - should fail as max attendees reached
        ts::next_tx(&mut scenario, USER2);
        {
            let mut event = ts::take_shared_by_id<Event>(&mut scenario, event_id);
            let mut claimed = ts::take_shared_by_id<ClaimedAttendance>(&mut scenario, claimed_id);
            
            attendance_nft::mint_attendance_nft(
                &mut event,
                &mut claimed,
                EVENT_PASSWORD,
                &clock,
                ts::ctx(&mut scenario)
            );
            
            ts::return_shared(event);
            ts::return_shared(claimed);
        };
        
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }
    
    #[test]
    fun test_update_event() {
        let (mut scenario, clock) = setup_test();
        
        // Current time + 1 day for date
        let current_time = clock::timestamp_ms(&clock);
        let event_date = current_time + 86400000; // +1 day in ms
        let expiration = current_time + 172800000; // +2 days in ms
        let max_attendees = 100;
        
        let event_id = create_test_event(&mut scenario, &clock, event_date, expiration, max_attendees);
        
        // Admin updates event
        ts::next_tx(&mut scenario, ADMIN);
        {
            let admin_cap = ts::take_from_sender<AdminCap>(&mut scenario);
            let mut event = ts::take_shared_by_id<Event>(&mut scenario, event_id);
            
            let new_name = b"Updated Event";
            let new_desc = b"Updated Description";
            let new_loc = b"Updated Location";
            let new_date = current_time + 172800000; // +2 days
            let new_img = b"https://example.com/new-image.png";
            let new_exp = current_time + 259200000; // +3 days
            let new_max = 200;
            
            attendance_nft::update_event(
                &admin_cap,
                &mut event,
                new_name,
                new_desc,
                new_loc,
                new_date,
                new_img,
                new_exp,
                new_max,
                ts::ctx(&mut scenario)
            );
            
            // Verify updates
            let (name, desc, loc, date, _, exp, max, _) = attendance_nft::get_event_details(&event);
            assert_eq(name, string::utf8(new_name));
            assert_eq(desc, string::utf8(new_desc));
            assert_eq(loc, string::utf8(new_loc));
            assert_eq(date, new_date);
            assert_eq(exp, new_exp);
            assert_eq(max, new_max);
            
            ts::return_to_sender(&mut scenario, admin_cap);
            ts::return_shared(event);
        };
        
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }
    
    #[test]
    fun test_is_event_active() {
        let (mut scenario, mut clock) = setup_test();
        
        // Current time + 1 day for date
        let current_time = clock::timestamp_ms(&clock);
        let event_date = current_time + 86400000; // +1 day in ms
        let expiration = current_time + 172800000; // +2 days in ms
        let max_attendees = 100;
        
        let event_id = create_test_event(&mut scenario, &clock, event_date, expiration, max_attendees);
        
        // Check if event is active
        ts::next_tx(&mut scenario, ADMIN);
        {
            let event = ts::take_shared_by_id<Event>(&mut scenario, event_id);
            
            // Should be active
            assert!(attendance_nft::is_event_active(&event, &clock), 0);
            
            // Fast forward time past expiration
            clock::increment_for_testing(&mut clock, 259200000); // +3 days
            
            // Should not be active
            assert!(!attendance_nft::is_event_active(&event, &clock), 1);
            
            ts::return_shared(event);
        };
        
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }
} 