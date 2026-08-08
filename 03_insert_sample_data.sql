-- =============================================================================
-- FILE: 03_insert_sample_data.sql
-- DESC: Representative sample data covering all payment modes and fraud cases
-- =============================================================================

USE toll_collection_db;

-- ---------------------------------------------------------------------------
-- OWNERS (5 records)
-- ---------------------------------------------------------------------------
INSERT INTO OWNERS (name, address, contact_info) VALUES
('Rajesh Kumar',    'B-12, Rajouri Garden, New Delhi',      '9811234567'),
('Priya Sharma',    '45, Sector 22, Chandigarh',            '9822345678'),
('Amit Verma',      '7, Civil Lines, Ludhiana, Punjab',     '9833456789'),
('Sunita Mehta',    '33, MG Road, Gurugram, Haryana',       '9844567890'),
('Vikram Singh',    '102, Patel Nagar, Amritsar, Punjab',   '9855678901');

-- ---------------------------------------------------------------------------
-- VEHICLES (8 records — car/truck/bike/bus mix)
-- ---------------------------------------------------------------------------
INSERT INTO VEHICLES (owner_id, license_plate, vehicle_type) VALUES
(1, 'DL01CA1234', 'Car'),    -- vehicle_id 1  – Rajesh, has FASTag
(1, 'DL01CB5678', 'Truck'),  -- vehicle_id 2  – Rajesh, has NHAI Pass
(2, 'CH04CD1111', 'Car'),    -- vehicle_id 3  – Priya, has FASTag
(2, 'CH04CE2222', 'Bike'),   -- vehicle_id 4  – Priya, cash only
(3, 'PB10CF3333', 'Bus'),    -- vehicle_id 5  – Amit, has NHAI Pass
(4, 'HR26CG4444', 'Car'),    -- vehicle_id 6  – Sunita, has FASTag (low balance)
(5, 'PB02CH5555', 'Truck'),  -- vehicle_id 7  – Vikram, has NHAI Pass (< 5 trips)
(5, 'PB02CI6666', 'LCV');    -- vehicle_id 8  – Vikram, cash only

-- ---------------------------------------------------------------------------
-- FASTAG_WALLETS (6 wallets)
-- ---------------------------------------------------------------------------
INSERT INTO FASTAG_WALLETS (owner_id, balance, status) VALUES
(1, 1500.00, 'Active'),       -- wallet_id 1 – Rajesh (good balance)
(2, 500.00,  'Active'),       -- wallet_id 2 – Priya  (good balance)
(3, 0.00,    'Active'),       -- wallet_id 3 – Amit   (zero balance → fallback)
(4, 30.00,   'Active'),       -- wallet_id 4 – Sunita (low balance — below truck toll)
(5, 800.00,  'Blacklisted'),  -- wallet_id 5 – Vikram (blacklisted)
(1, 200.00,  'Active');       -- wallet_id 6 – Rajesh second wallet

-- ---------------------------------------------------------------------------
-- RFID_TAGS (6 tags; tag 3 has same EPC as tag 4 to simulate cloned tag)
-- Note: unique constraint on epc_code means we demonstrate cloning via
--       a blacklisted duplicate stored in sample fraud alert, not a dup row.
-- ---------------------------------------------------------------------------
INSERT INTO RFID_TAGS (vehicle_id, epc_code, status) VALUES
(1, 'EPC-DL01CA1234-001', 'Active'),      -- tag_id 1 – vehicle 1
(3, 'EPC-CH04CD1111-002', 'Active'),      -- tag_id 2 – vehicle 3
(6, 'EPC-HR26CG4444-003', 'Active'),      -- tag_id 3 – vehicle 6 (low wallet)
(2, 'EPC-DL01CB5678-004', 'Inactive'),    -- tag_id 4 – vehicle 2 (inactive)
(5, 'EPC-PB10CF3333-005', 'Blacklisted'), -- tag_id 5 – vehicle 5 (blacklisted)
(7, 'EPC-PB02CH5555-006', 'Active');      -- tag_id 6 – vehicle 7

-- ---------------------------------------------------------------------------
-- NHAI_PASSES (5 passes)
-- ---------------------------------------------------------------------------
INSERT INTO NHAI_PASSES (vehicle_id, remaining_trips, expiry_date, status) VALUES
(2, 150, DATE_ADD(CURDATE(), INTERVAL 20 DAY), 'Active'),   -- pass_id 1 – Rajesh truck
(5, 88,  DATE_ADD(CURDATE(), INTERVAL 15 DAY), 'Active'),   -- pass_id 2 – Amit bus
(7, 3,   DATE_ADD(CURDATE(), INTERVAL 10 DAY), 'Active'),   -- pass_id 3 – Vikram truck (< 5 trips!)
(4, 200, DATE_SUB(CURDATE(), INTERVAL 5 DAY),  'Expired'),  -- pass_id 4 – Priya bike (EXPIRED)
(8, 100, DATE_ADD(CURDATE(), INTERVAL 25 DAY), 'Active');   -- pass_id 5 – Vikram LCV

-- ---------------------------------------------------------------------------
-- TOLL_GATES (3 gates)
-- ---------------------------------------------------------------------------
INSERT INTO TOLL_GATES (location, lane_count) VALUES
('NH-44 Panipat Toll Plaza, Haryana',       8),  -- gate_id 1
('NH-1  Ambala Bypass Toll, Haryana',       6),  -- gate_id 2
('NH-7  Jalandhar Entry Toll, Punjab',      4);  -- gate_id 3

-- ---------------------------------------------------------------------------
-- TRANSACTIONS (15+ records — all three payment modes)
-- NOTE: Triggers are defined in 06_triggers.sql. This data is inserted
--       AFTER triggers are created (master_setup.sql controls order).
-- ---------------------------------------------------------------------------
INSERT INTO TRANSACTIONS (vehicle_id, gate_id, payment_mode, toll_amount, txn_timestamp) VALUES
-- FASTag transactions
(1, 1, 'FASTag', 65.00,  DATE_SUB(NOW(), INTERVAL 5  DAY)),
(1, 2, 'FASTag', 65.00,  DATE_SUB(NOW(), INTERVAL 4  DAY)),
(3, 1, 'FASTag', 65.00,  DATE_SUB(NOW(), INTERVAL 3  DAY)),
(3, 3, 'FASTag', 65.00,  DATE_SUB(NOW(), INTERVAL 2  DAY)),
(6, 1, 'FASTag', 65.00,  DATE_SUB(NOW(), INTERVAL 1  DAY)),
-- Pass transactions
(2, 1, 'Pass',   0.00,   DATE_SUB(NOW(), INTERVAL 6  DAY)),
(2, 2, 'Pass',   0.00,   DATE_SUB(NOW(), INTERVAL 5  DAY)),
(5, 1, 'Pass',   0.00,   DATE_SUB(NOW(), INTERVAL 4  DAY)),
(5, 3, 'Pass',   0.00,   DATE_SUB(NOW(), INTERVAL 3  DAY)),
(7, 2, 'Pass',   0.00,   DATE_SUB(NOW(), INTERVAL 2  DAY)),
-- Cash transactions
(4, 1, 'Cash',   35.00,  DATE_SUB(NOW(), INTERVAL 7  DAY)),
(4, 2, 'Cash',   35.00,  DATE_SUB(NOW(), INTERVAL 6  DAY)),
(8, 3, 'Cash',   75.00,  DATE_SUB(NOW(), INTERVAL 5  DAY)),
(8, 1, 'Cash',   75.00,  DATE_SUB(NOW(), INTERVAL 4  DAY)),
(8, 2, 'Cash',   75.00,  DATE_SUB(NOW(), INTERVAL 3  DAY));

-- ---------------------------------------------------------------------------
-- FRAUD_ALERTS — pre-seeded to demonstrate detection results
-- ---------------------------------------------------------------------------
INSERT INTO FRAUD_ALERTS (transaction_id, alert_type, alert_status, notes) VALUES
(5,  'ClonedTag',   'Open',     'EPC-HR26CG4444-003 scanned at Gate 1 and Gate 3 within 8 min window'),
(6,  'PassSharing', 'Open',     'Pass pass_id=1 suspected shared across vehicles at Gate 1'),
(12, 'CashMismatch','Reviewed', 'Vehicle PB02CI6666 (LCV) paid 75 but expected rate is 75 — resolved'),
(10, 'LowTrips',    'Open',     'Pass pass_id=3 has only 3 trips remaining — renewal required');
