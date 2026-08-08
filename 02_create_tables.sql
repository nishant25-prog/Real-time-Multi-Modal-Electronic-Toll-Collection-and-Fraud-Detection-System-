-- =============================================================================
-- FILE: 02_create_tables.sql
-- DESC: DDL for all 8 tables — normalized to 3NF
--
-- NORMALIZATION NOTES:
--   1NF : All attributes are atomic; no repeating groups.
--   2NF : Every non-key attribute depends on the ENTIRE primary key.
--         (No composite PKs here, so 2NF is automatic.)
--   3NF : No transitive dependencies.
--         - Owner details live only in OWNERS, not repeated in VEHICLES.
--         - Wallet balance lives in FASTAG_WALLETS, not in RFID_TAGS.
--         - Pass trips live in NHAI_PASSES, not in VEHICLES.
-- =============================================================================

USE toll_collection_db;

-- ---------------------------------------------------------------------------
-- 1. OWNERS
--    Stores vehicle owner/account holder details.
-- ---------------------------------------------------------------------------
CREATE TABLE OWNERS (
    owner_id     INT            NOT NULL AUTO_INCREMENT,
    name         VARCHAR(100)   NOT NULL,
    address      VARCHAR(255)   NOT NULL,
    contact_info VARCHAR(15)    NOT NULL,
    PRIMARY KEY (owner_id)
);

-- ---------------------------------------------------------------------------
-- 2. VEHICLES
--    Each vehicle belongs to exactly one owner.
--    license_plate is unique (real-world uniqueness enforced).
-- ---------------------------------------------------------------------------
CREATE TABLE VEHICLES (
    vehicle_id    INT            NOT NULL AUTO_INCREMENT,
    owner_id      INT            NOT NULL,
    license_plate VARCHAR(20)    NOT NULL,
    vehicle_type  ENUM('Car','Truck','Bus','Bike','LCV') NOT NULL,
    PRIMARY KEY (vehicle_id),
    UNIQUE  KEY uq_license_plate (license_plate),
    FOREIGN KEY (owner_id) REFERENCES OWNERS(owner_id)
        ON DELETE RESTRICT ON UPDATE CASCADE
);

-- ---------------------------------------------------------------------------
-- 3. FASTAG_WALLETS
--    One wallet per owner (one-to-one or one-to-many allowed by design).
--    balance CHECK >= 0 prevents negative balance at DB level.
-- ---------------------------------------------------------------------------
CREATE TABLE FASTAG_WALLETS (
    wallet_id INT            NOT NULL AUTO_INCREMENT,
    owner_id  INT            NOT NULL,
    balance   DECIMAL(10,2)  NOT NULL DEFAULT 0.00,
    status    ENUM('Active','Blacklisted','Suspended') NOT NULL DEFAULT 'Active',
    PRIMARY KEY (wallet_id),
    FOREIGN KEY (owner_id) REFERENCES OWNERS(owner_id)
        ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT chk_wallet_balance CHECK (balance >= 0)
);

-- ---------------------------------------------------------------------------
-- 4. RFID_TAGS
--    Each RFID tag is attached to exactly one vehicle.
--    epc_code is unique per physical tag.
-- ---------------------------------------------------------------------------
CREATE TABLE RFID_TAGS (
    tag_id    INT          NOT NULL AUTO_INCREMENT,
    vehicle_id INT          NOT NULL,
    epc_code  VARCHAR(50)  NOT NULL,
    status    ENUM('Active','Inactive','Blacklisted') NOT NULL DEFAULT 'Active',
    PRIMARY KEY (tag_id),
    UNIQUE  KEY uq_epc_code (epc_code),
    FOREIGN KEY (vehicle_id) REFERENCES VEHICLES(vehicle_id)
        ON DELETE RESTRICT ON UPDATE CASCADE
);

-- ---------------------------------------------------------------------------
-- 5. NHAI_PASSES
--    Monthly pass limited to 200 trips.
--    remaining_trips CHECK enforced at DB level.
-- ---------------------------------------------------------------------------
CREATE TABLE NHAI_PASSES (
    pass_id         INT     NOT NULL AUTO_INCREMENT,
    vehicle_id      INT     NOT NULL,
    remaining_trips INT     NOT NULL DEFAULT 200,
    expiry_date     DATE    NOT NULL,
    status          ENUM('Active','Expired','Suspended') NOT NULL DEFAULT 'Active',
    PRIMARY KEY (pass_id),
    FOREIGN KEY (vehicle_id) REFERENCES VEHICLES(vehicle_id)
        ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT chk_trips_range CHECK (remaining_trips BETWEEN 0 AND 200)
);

-- ---------------------------------------------------------------------------
-- 6. TOLL_GATES
--    Physical toll plazas. lane_count must be positive.
-- ---------------------------------------------------------------------------
CREATE TABLE TOLL_GATES (
    gate_id    INT          NOT NULL AUTO_INCREMENT,
    location   VARCHAR(150) NOT NULL,
    lane_count INT          NOT NULL,
    PRIMARY KEY (gate_id),
    CONSTRAINT chk_lane_count CHECK (lane_count > 0)
);

-- ---------------------------------------------------------------------------
-- 7. TRANSACTIONS
--    Central fact table. Every vehicle crossing generates one row.
--    payment_mode records which of the three modes was actually used.
--    toll_amount >= 0 (Pass transactions are 0.00 — prepaid upfront monthly).
-- ---------------------------------------------------------------------------
CREATE TABLE TRANSACTIONS (
    transaction_id INT           NOT NULL AUTO_INCREMENT,
    vehicle_id     INT           NOT NULL,
    gate_id        INT           NOT NULL,
    payment_mode   ENUM('FASTag','Pass','Cash') NOT NULL,
    toll_amount    DECIMAL(10,2) NOT NULL,
    txn_timestamp  DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (transaction_id),
    FOREIGN KEY (vehicle_id) REFERENCES VEHICLES(vehicle_id)
        ON DELETE RESTRICT ON UPDATE CASCADE,
    FOREIGN KEY (gate_id) REFERENCES TOLL_GATES(gate_id)
        ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT chk_toll_nonneg CHECK (toll_amount >= 0)
);

-- ---------------------------------------------------------------------------
-- 8. FRAUD_ALERTS
--    Generated by triggers and fraud-audit procedures.
--    alert_type categorises the fraud pattern detected.
--    transaction_id may be NULL when alert is raised pre-insert (pass-share
--    triggers must insert with NULL then update, or use a temp log).
-- ---------------------------------------------------------------------------
CREATE TABLE FRAUD_ALERTS (
    alert_id       INT  NOT NULL AUTO_INCREMENT,
    transaction_id INT  NULL,
    alert_type     ENUM(
        'ClonedTag',
        'PassSharing',
        'DoubleDip',
        'CashMismatch',
        'LowTrips',
        'ExpiredPass'
    ) NOT NULL,
    alert_status   ENUM('Open','Reviewed','Resolved') NOT NULL DEFAULT 'Open',
    alert_timestamp DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    notes          VARCHAR(255) NULL,
    PRIMARY KEY (alert_id),
    FOREIGN KEY (transaction_id) REFERENCES TRANSACTIONS(transaction_id)
        ON DELETE SET NULL ON UPDATE CASCADE
);

-- ---------------------------------------------------------------------------
-- Indexes for query performance
-- ---------------------------------------------------------------------------
CREATE INDEX idx_txn_vehicle    ON TRANSACTIONS (vehicle_id);
CREATE INDEX idx_txn_gate       ON TRANSACTIONS (gate_id);
CREATE INDEX idx_txn_timestamp  ON TRANSACTIONS (txn_timestamp);
CREATE INDEX idx_txn_mode       ON TRANSACTIONS (payment_mode);
CREATE INDEX idx_pass_vehicle   ON NHAI_PASSES  (vehicle_id);
CREATE INDEX idx_tag_vehicle    ON RFID_TAGS    (vehicle_id);
CREATE INDEX idx_wallet_owner   ON FASTAG_WALLETS (owner_id);
