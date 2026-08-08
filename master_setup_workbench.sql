-- ===== 01_create_database.sql =====
-- =============================================================================
-- FILE: 01_create_database.sql
-- DESC: Create the toll collection database
-- =============================================================================

DROP DATABASE IF EXISTS toll_collection_db;
CREATE DATABASE toll_collection_db
    CHARACTER SET utf8mb4
    COLLATE utf8mb4_unicode_ci;

USE toll_collection_db;

-- ===== 02_create_tables.sql =====
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

-- ===== 04_functions.sql =====
-- =============================================================================
-- FILE: 04_functions.sql
-- DESC: Stored functions used across procedures and ad-hoc queries
-- =============================================================================

USE toll_collection_db;
DELIMITER $$

-- ---------------------------------------------------------------------------
-- fn_calculate_toll
-- Returns the standard toll charge for a given vehicle type.
-- Rates (INR): Car/LCV=65, Truck=130, Bus=120, Bike=35
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS fn_calculate_toll$$
CREATE FUNCTION fn_calculate_toll(p_vehicle_type VARCHAR(20))
RETURNS DECIMAL(10,2)
DETERMINISTIC
BEGIN
    DECLARE v_amount DECIMAL(10,2);
    CASE p_vehicle_type
        WHEN 'Car'   THEN SET v_amount = 65.00;
        WHEN 'Truck' THEN SET v_amount = 130.00;
        WHEN 'Bus'   THEN SET v_amount = 120.00;
        WHEN 'Bike'  THEN SET v_amount = 35.00;
        WHEN 'LCV'   THEN SET v_amount = 75.00;
        ELSE              SET v_amount = 65.00;
    END CASE;
    RETURN v_amount;
END$$

-- ---------------------------------------------------------------------------
-- fn_get_fastag_balance
-- Returns the current FASTag wallet balance for a vehicle.
-- Returns -1 if no active wallet is linked (no tag or blacklisted).
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS fn_get_fastag_balance$$
CREATE FUNCTION fn_get_fastag_balance(p_vehicle_id INT)
RETURNS DECIMAL(10,2)
READS SQL DATA
BEGIN
    DECLARE v_balance DECIMAL(10,2) DEFAULT -1;

    SELECT fw.balance INTO v_balance
    FROM   RFID_TAGS rt
    JOIN   VEHICLES v   ON rt.vehicle_id = v.vehicle_id
    JOIN   FASTAG_WALLETS fw ON fw.owner_id = v.owner_id
    WHERE  rt.vehicle_id = p_vehicle_id
      AND  rt.status      = 'Active'
      AND  fw.status      = 'Active'
    LIMIT  1;

    RETURN COALESCE(v_balance, -1);
END$$

-- ---------------------------------------------------------------------------
-- fn_get_pass_trips_remaining
-- Returns remaining trips for the active NHAI pass of a vehicle.
-- Returns -1 if no valid pass exists.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS fn_get_pass_trips_remaining$$
CREATE FUNCTION fn_get_pass_trips_remaining(p_vehicle_id INT)
RETURNS INT
READS SQL DATA
BEGIN
    DECLARE v_trips INT DEFAULT -1;

    SELECT remaining_trips INTO v_trips
    FROM   NHAI_PASSES
    WHERE  vehicle_id   = p_vehicle_id
      AND  status       = 'Active'
      AND  expiry_date >= CURDATE()
    LIMIT  1;

    RETURN COALESCE(v_trips, -1);
END$$

-- ---------------------------------------------------------------------------
-- fn_is_fastag_valid
-- Returns 1 if the vehicle has an active RFID tag AND sufficient wallet
-- balance to cover p_toll_amount. Returns 0 otherwise.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS fn_is_fastag_valid$$
CREATE FUNCTION fn_is_fastag_valid(p_vehicle_id INT, p_toll_amount DECIMAL(10,2))
RETURNS TINYINT(1)
READS SQL DATA
BEGIN
    DECLARE v_balance DECIMAL(10,2);
    SET v_balance = fn_get_fastag_balance(p_vehicle_id);
    IF v_balance >= p_toll_amount THEN
        RETURN 1;
    END IF;
    RETURN 0;
END$$

-- ---------------------------------------------------------------------------
-- fn_is_pass_valid
-- Returns 1 if the vehicle has an active, non-expired NHAI pass with > 0
-- trips remaining. Returns 0 otherwise.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS fn_is_pass_valid$$
CREATE FUNCTION fn_is_pass_valid(p_vehicle_id INT)
RETURNS TINYINT(1)
READS SQL DATA
BEGIN
    DECLARE v_trips INT;
    SET v_trips = fn_get_pass_trips_remaining(p_vehicle_id);
    IF v_trips > 0 THEN
        RETURN 1;
    END IF;
    RETURN 0;
END$$

DELIMITER ;

-- ===== 05_procedures.sql =====
-- =============================================================================
-- FILE: 05_procedures.sql
-- DESC: Core stored procedures — hierarchical payment engine + admin utilities
-- =============================================================================

USE toll_collection_db;
DELIMITER $$

-- ---------------------------------------------------------------------------
-- sp_process_toll
-- The main hierarchical payment engine.
-- Decision order: FASTag → NHAI Pass → Cash
-- Uses SAVEPOINTs so a failed payment mode cleanly falls back to the next.
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_process_toll$$
CREATE PROCEDURE sp_process_toll(
    IN  p_vehicle_id  INT,
    IN  p_gate_id     INT,
    OUT p_mode_used   VARCHAR(20),
    OUT p_result_msg  VARCHAR(255)
)
sp_block: BEGIN
    DECLARE v_vehicle_type  VARCHAR(20);
    DECLARE v_toll_amount   DECIMAL(10,2);
    DECLARE v_wallet_id     INT;
    DECLARE v_pass_id       INT;
    DECLARE v_owner_id      INT;

    -- Fetch vehicle type
    SELECT vehicle_type, owner_id
    INTO   v_vehicle_type, v_owner_id
    FROM   VEHICLES
    WHERE  vehicle_id = p_vehicle_id;

    IF v_vehicle_type IS NULL THEN
        SET p_mode_used  = 'NONE';
        SET p_result_msg = 'ERROR: Vehicle not found.';
        LEAVE sp_block;
    END IF;

    SET v_toll_amount = fn_calculate_toll(v_vehicle_type);

    START TRANSACTION;

    -- -------------------------------------------------------------------------
    -- Step 1: Try FASTag payment
    -- -------------------------------------------------------------------------
    SAVEPOINT sp_fastag;

    IF fn_is_fastag_valid(p_vehicle_id, v_toll_amount) THEN
        -- Get active wallet for this owner
        SELECT wallet_id INTO v_wallet_id
        FROM   FASTAG_WALLETS
        WHERE  owner_id = v_owner_id
          AND  status   = 'Active'
        LIMIT  1;

        UPDATE FASTAG_WALLETS
           SET balance = balance - v_toll_amount
         WHERE wallet_id = v_wallet_id;

        INSERT INTO TRANSACTIONS (vehicle_id, gate_id, payment_mode, toll_amount)
        VALUES (p_vehicle_id, p_gate_id, 'FASTag', v_toll_amount);

        COMMIT;
        SET p_mode_used  = 'FASTag';
        SET p_result_msg = CONCAT('FASTag payment of INR ', v_toll_amount, ' successful. Wallet debited.');
    -- -------------------------------------------------------------------------
    -- Step 2: FASTag failed — try NHAI Pass
    -- -------------------------------------------------------------------------
    ELSEIF fn_is_pass_valid(p_vehicle_id) THEN
        ROLLBACK TO SAVEPOINT sp_fastag;
        SAVEPOINT sp_pass;

        SELECT pass_id INTO v_pass_id
        FROM   NHAI_PASSES
        WHERE  vehicle_id   = p_vehicle_id
          AND  status       = 'Active'
          AND  expiry_date >= CURDATE()
        LIMIT  1;

        UPDATE NHAI_PASSES
           SET remaining_trips = remaining_trips - 1
         WHERE pass_id = v_pass_id;

        -- Pass usage logged with toll_amount = 0 (pass already paid upfront)
        INSERT INTO TRANSACTIONS (vehicle_id, gate_id, payment_mode, toll_amount)
        VALUES (p_vehicle_id, p_gate_id, 'Pass', 0.00);

        COMMIT;
        SET p_mode_used  = 'Pass';
        SET p_result_msg = CONCAT('NHAI Pass used. Trip count decremented. Pass ID: ', v_pass_id);
    -- -------------------------------------------------------------------------
    -- Step 3: No digital payment — default to Cash
    -- -------------------------------------------------------------------------
    ELSE
        ROLLBACK TO SAVEPOINT sp_fastag;

        INSERT INTO TRANSACTIONS (vehicle_id, gate_id, payment_mode, toll_amount)
        VALUES (p_vehicle_id, p_gate_id, 'Cash', v_toll_amount);

        COMMIT;
        SET p_mode_used  = 'Cash';
        SET p_result_msg = CONCAT('Cash payment required: INR ', v_toll_amount, '. Barrier opened on manual collection.');
    END IF;

END$$

-- ---------------------------------------------------------------------------
-- sp_topup_fastag
-- Add funds to an existing FASTag wallet.
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_topup_fastag$$
CREATE PROCEDURE sp_topup_fastag(
    IN  p_wallet_id  INT,
    IN  p_amount     DECIMAL(10,2),
    OUT p_new_balance DECIMAL(10,2),
    OUT p_msg        VARCHAR(255)
)
BEGIN
    DECLARE v_status VARCHAR(20);
    DECLARE v_exists INT DEFAULT 0;

    SELECT COUNT(*), status INTO v_exists, v_status
    FROM   FASTAG_WALLETS
    WHERE  wallet_id = p_wallet_id
    GROUP  BY status;

    IF v_exists = 0 THEN
        SET p_msg = 'ERROR: Wallet not found.';
        SET p_new_balance = -1;
    ELSEIF v_status != 'Active' THEN
        SET p_msg = CONCAT('ERROR: Wallet is ', v_status, '. Top-up not allowed.');
        SET p_new_balance = -1;
    ELSEIF p_amount <= 0 THEN
        SET p_msg = 'ERROR: Top-up amount must be positive.';
        SET p_new_balance = -1;
    ELSE
        UPDATE FASTAG_WALLETS
           SET balance = balance + p_amount
         WHERE wallet_id = p_wallet_id;

        SELECT balance INTO p_new_balance
        FROM   FASTAG_WALLETS
        WHERE  wallet_id = p_wallet_id;

        SET p_msg = CONCAT('Wallet ', p_wallet_id, ' topped up by INR ', p_amount,
                           '. New balance: INR ', p_new_balance);
    END IF;
END$$

-- ---------------------------------------------------------------------------
-- sp_register_owner
-- Register a new vehicle owner account.
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_register_owner$$
CREATE PROCEDURE sp_register_owner(
    IN  p_name        VARCHAR(100),
    IN  p_address     VARCHAR(255),
    IN  p_contact     VARCHAR(15),
    OUT p_owner_id    INT,
    OUT p_msg         VARCHAR(255)
)
BEGIN
    IF p_name IS NULL OR TRIM(p_name) = '' THEN
        SET p_owner_id = -1;
        SET p_msg = 'ERROR: Owner name cannot be blank.';
    ELSEIF p_contact IS NULL OR TRIM(p_contact) = '' THEN
        SET p_owner_id = -1;
        SET p_msg = 'ERROR: Contact info cannot be blank.';
    ELSE
        INSERT INTO OWNERS (name, address, contact_info)
        VALUES (TRIM(p_name), TRIM(p_address), TRIM(p_contact));
        SET p_owner_id = LAST_INSERT_ID();
        SET p_msg = CONCAT('Owner registered. owner_id = ', p_owner_id);
    END IF;
END$$

-- ---------------------------------------------------------------------------
-- sp_register_vehicle
-- Register a new vehicle under an existing owner.
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_register_vehicle$$
CREATE PROCEDURE sp_register_vehicle(
    IN  p_owner_id     INT,
    IN  p_plate        VARCHAR(20),
    IN  p_type         VARCHAR(20),
    OUT p_vehicle_id   INT,
    OUT p_msg          VARCHAR(255)
)
BEGIN
    DECLARE v_owner_count INT DEFAULT 0;
    DECLARE v_plate_count INT DEFAULT 0;

    SELECT COUNT(*) INTO v_owner_count FROM OWNERS WHERE owner_id = p_owner_id;
    IF v_owner_count = 0 THEN
        SET p_vehicle_id = -1;
        SET p_msg = 'ERROR: Owner not found.';
    ELSE
        SELECT COUNT(*) INTO v_plate_count
        FROM VEHICLES WHERE license_plate = UPPER(TRIM(p_plate));

        IF v_plate_count > 0 THEN
            SET p_vehicle_id = -1;
            SET p_msg = 'ERROR: License plate already registered.';
        ELSE
            INSERT INTO VEHICLES (owner_id, license_plate, vehicle_type)
            VALUES (p_owner_id, UPPER(TRIM(p_plate)), p_type);
            SET p_vehicle_id = LAST_INSERT_ID();
            SET p_msg = CONCAT('Vehicle registered. vehicle_id = ', p_vehicle_id);
        END IF;
    END IF;
END$$

-- ---------------------------------------------------------------------------
-- sp_renew_nhai_pass
-- Reset an NHAI pass to 200 trips and extend expiry by p_months months.
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_renew_nhai_pass$$
CREATE PROCEDURE sp_renew_nhai_pass(
    IN  p_vehicle_id  INT,
    IN  p_months      INT,
    OUT p_msg         VARCHAR(255)
)
BEGIN
    DECLARE v_pass_id INT DEFAULT 0;

    SELECT pass_id INTO v_pass_id
    FROM   NHAI_PASSES
    WHERE  vehicle_id = p_vehicle_id
    ORDER  BY pass_id DESC
    LIMIT  1;

    IF v_pass_id = 0 THEN
        SET p_msg = 'No existing pass found. Create a new one via sp_add_new_nhai_pass.';
    ELSE
        UPDATE NHAI_PASSES
           SET remaining_trips = 200,
               expiry_date     = DATE_ADD(
                                    GREATEST(expiry_date, CURDATE()),
                                    INTERVAL p_months MONTH),
               status          = 'Active'
         WHERE pass_id = v_pass_id;
        SET p_msg = CONCAT('Pass ', v_pass_id, ' renewed for ', p_months,
                           ' month(s). Trips reset to 200.');
    END IF;
END$$

-- ---------------------------------------------------------------------------
-- sp_expire_stale_passes
-- Batch job: mark all passes whose expiry_date has passed as Expired.
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_expire_stale_passes$$
CREATE PROCEDURE sp_expire_stale_passes(OUT p_updated_count INT)
BEGIN
    UPDATE NHAI_PASSES
       SET status = 'Expired'
     WHERE expiry_date < CURDATE()
       AND status != 'Expired';

    SET p_updated_count = ROW_COUNT();
END$$

DELIMITER ;

-- ===== 06_triggers.sql =====
-- =============================================================================
-- FILE: 06_triggers.sql
-- DESC: Five triggers enforcing integrity, fraud detection, and auto-alerts
-- =============================================================================

USE toll_collection_db;
DELIMITER $$

-- ---------------------------------------------------------------------------
-- trg_prevent_negative_balance
-- BEFORE UPDATE on FASTAG_WALLETS
-- Blocks any update that would make balance go below zero.
-- ---------------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_prevent_negative_balance$$
CREATE TRIGGER trg_prevent_negative_balance
BEFORE UPDATE ON FASTAG_WALLETS
FOR EACH ROW
BEGIN
    IF NEW.balance < 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'FRAUD GUARD: FASTag wallet balance cannot go negative.';
    END IF;
END$$

-- ---------------------------------------------------------------------------
-- trg_auto_expire_pass
-- BEFORE UPDATE on NHAI_PASSES
-- If expiry_date has passed, force status = Expired before the update lands.
-- ---------------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_auto_expire_pass$$
CREATE TRIGGER trg_auto_expire_pass
BEFORE UPDATE ON NHAI_PASSES
FOR EACH ROW
BEGIN
    IF NEW.expiry_date < CURDATE() AND NEW.status != 'Expired' THEN
        SET NEW.status = 'Expired';
    END IF;
END$$

-- ---------------------------------------------------------------------------
-- trg_low_trip_alert
-- AFTER UPDATE on NHAI_PASSES
-- When remaining_trips drops below 5, auto-insert a LowTrips fraud alert
-- linked to the most recent transaction for that vehicle.
-- ---------------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_low_trip_alert$$
CREATE TRIGGER trg_low_trip_alert
AFTER UPDATE ON NHAI_PASSES
FOR EACH ROW
BEGIN
    DECLARE v_last_txn_id INT DEFAULT NULL;

    IF NEW.remaining_trips < 5 AND OLD.remaining_trips >= 5 THEN
        SELECT transaction_id INTO v_last_txn_id
        FROM   TRANSACTIONS
        WHERE  vehicle_id = NEW.vehicle_id
        ORDER  BY txn_timestamp DESC
        LIMIT  1;

        INSERT INTO FRAUD_ALERTS (transaction_id, alert_type, alert_status, notes)
        VALUES (
            v_last_txn_id,
            'LowTrips',
            'Open',
            CONCAT('Pass ID ', NEW.pass_id, ' for vehicle_id ', NEW.vehicle_id,
                   ' has only ', NEW.remaining_trips, ' trip(s) remaining. Renewal recommended.')
        );
    END IF;
END$$

-- ---------------------------------------------------------------------------
-- trg_double_dip_check
-- BEFORE INSERT on TRANSACTIONS
-- If payment_mode = FASTag, checks whether the same vehicle already has a
-- Pass transaction at the same gate within the last 5 minutes (Double Dip).
-- Inserts a fraud alert but still allows the transaction to proceed.
-- ---------------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_double_dip_check$$
CREATE TRIGGER trg_double_dip_check
BEFORE INSERT ON TRANSACTIONS
FOR EACH ROW
BEGIN
    DECLARE v_dup_count INT DEFAULT 0;

    IF NEW.payment_mode = 'FASTag' THEN
        SELECT COUNT(*) INTO v_dup_count
        FROM   TRANSACTIONS
        WHERE  vehicle_id    = NEW.vehicle_id
          AND  gate_id       = NEW.gate_id
          AND  payment_mode  = 'Pass'
          AND  txn_timestamp >= DATE_SUB(NOW(), INTERVAL 5 MINUTE);

        IF v_dup_count > 0 THEN
            INSERT INTO FRAUD_ALERTS (transaction_id, alert_type, alert_status, notes)
            VALUES (
                NULL,
                'DoubleDip',
                'Open',
                CONCAT('Vehicle ', NEW.vehicle_id, ' at Gate ', NEW.gate_id,
                       ' has both Pass and FASTag transactions within 5 min window.')
            );
        END IF;
    END IF;
END$$

-- ---------------------------------------------------------------------------
-- trg_prevent_pass_sharing
-- BEFORE INSERT on TRANSACTIONS
-- If payment_mode = Pass, verifies the active pass for this vehicle was not
-- used by a DIFFERENT vehicle in the last 60 seconds.
-- Blocks the transaction and inserts a PassSharing alert if violation found.
-- ---------------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_prevent_pass_sharing$$
CREATE TRIGGER trg_prevent_pass_sharing
BEFORE INSERT ON TRANSACTIONS
FOR EACH ROW
BEGIN
    DECLARE v_pass_id      INT DEFAULT NULL;
    DECLARE v_other_uses   INT DEFAULT 0;

    IF NEW.payment_mode = 'Pass' THEN
        -- Find the active pass for this vehicle
        SELECT pass_id INTO v_pass_id
        FROM   NHAI_PASSES
        WHERE  vehicle_id   = NEW.vehicle_id
          AND  status       = 'Active'
          AND  expiry_date >= CURDATE()
        LIMIT  1;

        IF v_pass_id IS NOT NULL THEN
            -- Check if any OTHER vehicle used the same pass_id linkage
            -- (simulated by checking if the pass_id's vehicle_id differs from
            --  any recent Pass transaction for the same pass_id vehicle family)
            SELECT COUNT(*) INTO v_other_uses
            FROM   TRANSACTIONS t
            JOIN   NHAI_PASSES  p ON p.vehicle_id = t.vehicle_id
            WHERE  p.pass_id       = v_pass_id
              AND  t.vehicle_id   != NEW.vehicle_id
              AND  t.payment_mode  = 'Pass'
              AND  t.txn_timestamp >= DATE_SUB(NOW(), INTERVAL 60 SECOND);

            IF v_other_uses > 0 THEN
                INSERT INTO FRAUD_ALERTS (transaction_id, alert_type, alert_status, notes)
                VALUES (
                    NULL,
                    'PassSharing',
                    'Open',
                    CONCAT('Pass ID ', v_pass_id, ' may be shared. Used by another vehicle ',
                           'within the last 60 seconds. Transaction for vehicle_id=',
                           NEW.vehicle_id, ' at gate_id=', NEW.gate_id, ' flagged.')
                );
                SIGNAL SQLSTATE '45001'
                    SET MESSAGE_TEXT = 'FRAUD DETECTED: Pass sharing suspected. Transaction blocked.';
            END IF;
        END IF;
    END IF;
END$$

DELIMITER ;

-- ===== 07_cursors.sql =====
-- =============================================================================
-- FILE: 07_cursors.sql
-- DESC: Cursor-based stored procedures for reports and batch processing
-- =============================================================================

USE toll_collection_db;
DELIMITER $$

-- ---------------------------------------------------------------------------
-- sp_generate_monthly_revenue_report
-- Uses a cursor over TOLL_GATES to compute revenue per gate for a given
-- month/year. Outputs a result set with gate-wise revenue breakdown.
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_generate_monthly_revenue_report$$
CREATE PROCEDURE sp_generate_monthly_revenue_report(
    IN p_month INT,
    IN p_year  INT
)
BEGIN
    DECLARE v_gate_id       INT;
    DECLARE v_location      VARCHAR(150);
    DECLARE v_revenue       DECIMAL(12,2);
    DECLARE v_txn_count     INT;
    DECLARE v_done          TINYINT(1) DEFAULT 0;

    DECLARE gate_cursor CURSOR FOR
        SELECT gate_id, location FROM TOLL_GATES;

    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_done = 1;

    -- Temp table to collect results for final SELECT
    DROP TEMPORARY TABLE IF EXISTS tmp_revenue_report;
    CREATE TEMPORARY TABLE tmp_revenue_report (
        gate_id      INT,
        location     VARCHAR(150),
        txn_count    INT,
        total_revenue DECIMAL(12,2)
    );

    OPEN gate_cursor;

    gate_loop: LOOP
        FETCH gate_cursor INTO v_gate_id, v_location;
        IF v_done THEN
            LEAVE gate_loop;
        END IF;

        SELECT COUNT(*), COALESCE(SUM(toll_amount), 0)
        INTO   v_txn_count, v_revenue
        FROM   TRANSACTIONS
        WHERE  gate_id    = v_gate_id
          AND  MONTH(txn_timestamp) = p_month
          AND  YEAR(txn_timestamp)  = p_year;

        INSERT INTO tmp_revenue_report VALUES (v_gate_id, v_location, v_txn_count, v_revenue);
    END LOOP gate_loop;

    CLOSE gate_cursor;

    SELECT gate_id,
           location,
           txn_count          AS total_transactions,
           total_revenue      AS revenue_INR
    FROM   tmp_revenue_report
    ORDER  BY total_revenue DESC;

    DROP TEMPORARY TABLE tmp_revenue_report;
END$$

-- ---------------------------------------------------------------------------
-- sp_list_low_balance_fastags
-- Uses a cursor over FASTAG_WALLETS to find wallets below a given threshold.
-- Outputs wallet_id, owner name, and current balance.
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_list_low_balance_fastags$$
CREATE PROCEDURE sp_list_low_balance_fastags(
    IN p_threshold DECIMAL(10,2)
)
BEGIN
    DECLARE v_wallet_id   INT;
    DECLARE v_owner_id    INT;
    DECLARE v_balance     DECIMAL(10,2);
    DECLARE v_owner_name  VARCHAR(100);
    DECLARE v_done        TINYINT(1) DEFAULT 0;

    DECLARE wallet_cursor CURSOR FOR
        SELECT wallet_id, owner_id, balance
        FROM   FASTAG_WALLETS
        WHERE  balance < p_threshold
          AND  status  = 'Active';

    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_done = 1;

    DROP TEMPORARY TABLE IF EXISTS tmp_low_balance;
    CREATE TEMPORARY TABLE tmp_low_balance (
        wallet_id  INT,
        owner_name VARCHAR(100),
        balance    DECIMAL(10,2)
    );

    OPEN wallet_cursor;

    wallet_loop: LOOP
        FETCH wallet_cursor INTO v_wallet_id, v_owner_id, v_balance;
        IF v_done THEN LEAVE wallet_loop; END IF;

        SELECT name INTO v_owner_name
        FROM   OWNERS
        WHERE  owner_id = v_owner_id;

        INSERT INTO tmp_low_balance VALUES (v_wallet_id, v_owner_name, v_balance);
    END LOOP wallet_loop;

    CLOSE wallet_cursor;

    SELECT wallet_id, owner_name, balance AS balance_INR
    FROM   tmp_low_balance
    ORDER  BY balance ASC;

    DROP TEMPORARY TABLE tmp_low_balance;
END$$

-- ---------------------------------------------------------------------------
-- sp_scan_fraud_by_mode
-- Cursor-based batch fraud scanner. Iterates all transactions and runs
-- rule-based checks inline. Inserts new FRAUD_ALERTS where not already logged.
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_scan_fraud_by_mode$$
CREATE PROCEDURE sp_scan_fraud_by_mode()
BEGIN
    DECLARE v_txn_id       INT;
    DECLARE v_vehicle_id   INT;
    DECLARE v_gate_id      INT;
    DECLARE v_mode         VARCHAR(10);
    DECLARE v_amount       DECIMAL(10,2);
    DECLARE v_ts           DATETIME;
    DECLARE v_vtype        VARCHAR(20);
    DECLARE v_expected     DECIMAL(10,2);
    DECLARE v_alert_exists INT;
    DECLARE v_done         TINYINT(1) DEFAULT 0;
    DECLARE v_new_alerts   INT DEFAULT 0;

    DECLARE txn_cursor CURSOR FOR
        SELECT t.transaction_id, t.vehicle_id, t.gate_id,
               t.payment_mode, t.toll_amount, t.txn_timestamp,
               v.vehicle_type
        FROM   TRANSACTIONS t
        JOIN   VEHICLES v ON v.vehicle_id = t.vehicle_id;

    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_done = 1;

    OPEN txn_cursor;

    txn_loop: LOOP
        FETCH txn_cursor INTO v_txn_id, v_vehicle_id, v_gate_id,
                              v_mode, v_amount, v_ts, v_vtype;
        IF v_done THEN LEAVE txn_loop; END IF;

        -- Cash integrity check: compare actual amount with expected rate
        IF v_mode = 'Cash' THEN
            SET v_expected = fn_calculate_toll(v_vtype);

            -- Flag if collected amount deviates more than 10% from expected
            IF ABS(v_amount - v_expected) > (v_expected * 0.10) THEN
                SELECT COUNT(*) INTO v_alert_exists
                FROM   FRAUD_ALERTS
                WHERE  transaction_id = v_txn_id
                  AND  alert_type     = 'CashMismatch';

                IF v_alert_exists = 0 THEN
                    INSERT INTO FRAUD_ALERTS (transaction_id, alert_type, alert_status, notes)
                    VALUES (
                        v_txn_id,
                        'CashMismatch',
                        'Open',
                        CONCAT('txn_id=', v_txn_id, ': vehicle_type=', v_vtype,
                               ' expected INR ', v_expected, ' but collected INR ', v_amount)
                    );
                    SET v_new_alerts = v_new_alerts + 1;
                END IF;
            END IF;
        END IF;

    END LOOP txn_loop;

    CLOSE txn_cursor;

    SELECT v_new_alerts AS new_fraud_alerts_inserted;
END$$

DELIMITER ;

-- ===== 08_fraud_detection.sql =====
-- =============================================================================
-- FILE: 08_fraud_detection.sql
-- DESC: Standalone fraud detection queries + sp_run_full_fraud_audit procedure
-- =============================================================================

USE toll_collection_db;

-- ===========================================================================
-- SECTION A: Ad-hoc Fraud Detection Queries (run these any time)
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- Query 1: Clone Tag Detection
-- Find vehicles/EPC codes that appear at 2+ DIFFERENT gates within 10 minutes.
-- A single physical vehicle cannot travel between distant gates in 10 minutes.
-- ---------------------------------------------------------------------------
SELECT
    r.epc_code,
    t1.vehicle_id,
    t1.transaction_id  AS txn_1,
    t1.gate_id         AS gate_1,
    t1.txn_timestamp   AS time_1,
    t2.transaction_id  AS txn_2,
    t2.gate_id         AS gate_2,
    t2.txn_timestamp   AS time_2,
    TIMESTAMPDIFF(MINUTE, t1.txn_timestamp, t2.txn_timestamp) AS minutes_apart
FROM   TRANSACTIONS t1
JOIN   TRANSACTIONS t2
       ON  t1.vehicle_id  = t2.vehicle_id
       AND t1.gate_id    != t2.gate_id
       AND t1.transaction_id < t2.transaction_id
       AND ABS(TIMESTAMPDIFF(MINUTE, t1.txn_timestamp, t2.txn_timestamp)) <= 10
JOIN   RFID_TAGS r ON r.vehicle_id = t1.vehicle_id
WHERE  t1.payment_mode = 'FASTag'
  AND  t2.payment_mode = 'FASTag';

-- ---------------------------------------------------------------------------
-- Query 2: Pass Sharing Detection
-- Find pass_ids linked to transactions for MULTIPLE distinct vehicle_ids.
-- A pass is bound to one vehicle; usage by another vehicle = fraud.
-- ---------------------------------------------------------------------------
SELECT
    p.pass_id,
    p.vehicle_id       AS registered_vehicle,
    t.vehicle_id       AS transacting_vehicle,
    COUNT(*)           AS suspicious_txns,
    MIN(t.txn_timestamp) AS first_seen,
    MAX(t.txn_timestamp) AS last_seen
FROM   NHAI_PASSES  p
JOIN   TRANSACTIONS t
       ON  t.payment_mode = 'Pass'
       AND t.vehicle_id  != p.vehicle_id
WHERE  p.status = 'Active'
GROUP  BY p.pass_id, p.vehicle_id, t.vehicle_id
HAVING COUNT(*) > 0;

-- ---------------------------------------------------------------------------
-- Query 3: Double Dipping
-- Find vehicles charged via BOTH FASTag and Pass at same gate within 5 min.
-- ---------------------------------------------------------------------------
SELECT
    t1.vehicle_id,
    t1.gate_id,
    t1.transaction_id  AS fastag_txn,
    t1.txn_timestamp   AS fastag_time,
    t2.transaction_id  AS pass_txn,
    t2.txn_timestamp   AS pass_time,
    TIMESTAMPDIFF(MINUTE, t2.txn_timestamp, t1.txn_timestamp) AS minutes_apart
FROM   TRANSACTIONS t1
JOIN   TRANSACTIONS t2
       ON  t1.vehicle_id  = t2.vehicle_id
       AND t1.gate_id     = t2.gate_id
       AND t1.payment_mode = 'FASTag'
       AND t2.payment_mode = 'Pass'
       AND ABS(TIMESTAMPDIFF(MINUTE, t1.txn_timestamp, t2.txn_timestamp)) <= 5;

-- ---------------------------------------------------------------------------
-- Query 4: Cash Integrity — Amount Mismatch
-- Cash transactions where collected amount deviates from expected vehicle rate.
-- ---------------------------------------------------------------------------
SELECT
    t.transaction_id,
    t.vehicle_id,
    v.license_plate,
    v.vehicle_type,
    fn_calculate_toll(v.vehicle_type) AS expected_toll_INR,
    t.toll_amount                     AS collected_INR,
    t.toll_amount - fn_calculate_toll(v.vehicle_type) AS discrepancy_INR
FROM   TRANSACTIONS t
JOIN   VEHICLES v ON v.vehicle_id = t.vehicle_id
WHERE  t.payment_mode = 'Cash'
  AND  ABS(t.toll_amount - fn_calculate_toll(v.vehicle_type)) > 0.50;

-- ---------------------------------------------------------------------------
-- Query 5: Open Fraud Alerts Summary
-- ---------------------------------------------------------------------------
SELECT
    alert_type,
    COUNT(*)                             AS total_alerts,
    SUM(alert_status = 'Open')           AS open_alerts,
    SUM(alert_status = 'Reviewed')       AS reviewed_alerts,
    SUM(alert_status = 'Resolved')       AS resolved_alerts,
    MIN(alert_timestamp)                 AS first_alert,
    MAX(alert_timestamp)                 AS latest_alert
FROM   FRAUD_ALERTS
GROUP  BY alert_type
ORDER  BY open_alerts DESC;


-- ===========================================================================
-- SECTION B: Full Fraud Audit Procedure
-- ===========================================================================

DELIMITER $$

-- ---------------------------------------------------------------------------
-- sp_run_full_fraud_audit
-- Runs all four fraud checks and populates FRAUD_ALERTS for any new findings.
-- Returns a summary of how many new alerts were inserted per category.
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_run_full_fraud_audit$$
CREATE PROCEDURE sp_run_full_fraud_audit()
BEGIN
    DECLARE v_clone_count       INT DEFAULT 0;
    DECLARE v_cash_count        INT DEFAULT 0;
    DECLARE v_total_new         INT DEFAULT 0;

    -- -----------------------------------------------------------------------
    -- Check 1: Clone Tag — insert alert for each pair not already flagged
    -- -----------------------------------------------------------------------
    INSERT INTO FRAUD_ALERTS (transaction_id, alert_type, alert_status, notes)
    SELECT DISTINCT
        t1.transaction_id,
        'ClonedTag',
        'Open',
        CONCAT('EPC ', r.epc_code, ' seen at gate ', t1.gate_id,
               ' and gate ', t2.gate_id, ' within ',
               ABS(TIMESTAMPDIFF(MINUTE, t1.txn_timestamp, t2.txn_timestamp)),
               ' minute(s).')
    FROM   TRANSACTIONS t1
    JOIN   TRANSACTIONS t2
           ON  t1.vehicle_id   = t2.vehicle_id
           AND t1.gate_id     != t2.gate_id
           AND t1.transaction_id < t2.transaction_id
           AND ABS(TIMESTAMPDIFF(MINUTE, t1.txn_timestamp, t2.txn_timestamp)) <= 10
    JOIN   RFID_TAGS r ON r.vehicle_id = t1.vehicle_id
    WHERE  t1.payment_mode = 'FASTag'
      AND  t2.payment_mode = 'FASTag'
      AND  NOT EXISTS (
               SELECT 1 FROM FRAUD_ALERTS fa
               WHERE  fa.transaction_id = t1.transaction_id
                 AND  fa.alert_type     = 'ClonedTag'
           );

    SET v_clone_count = ROW_COUNT();

    -- -----------------------------------------------------------------------
    -- Check 2: Cash Mismatch — insert alert for each unlogged mismatch
    -- -----------------------------------------------------------------------
    INSERT INTO FRAUD_ALERTS (transaction_id, alert_type, alert_status, notes)
    SELECT
        t.transaction_id,
        'CashMismatch',
        'Open',
        CONCAT('vehicle_id=', t.vehicle_id, ' (', v.vehicle_type,
               ') expected INR ', fn_calculate_toll(v.vehicle_type),
               ' but received INR ', t.toll_amount)
    FROM   TRANSACTIONS t
    JOIN   VEHICLES v ON v.vehicle_id = t.vehicle_id
    WHERE  t.payment_mode = 'Cash'
      AND  ABS(t.toll_amount - fn_calculate_toll(v.vehicle_type)) > 0.50
      AND  NOT EXISTS (
               SELECT 1 FROM FRAUD_ALERTS fa
               WHERE  fa.transaction_id = t.transaction_id
                 AND  fa.alert_type     = 'CashMismatch'
           );

    SET v_cash_count = ROW_COUNT();

    SET v_total_new = v_clone_count + v_cash_count;

    SELECT
        v_clone_count   AS new_clone_tag_alerts,
        v_cash_count    AS new_cash_mismatch_alerts,
        v_total_new     AS total_new_alerts_inserted;
END$$

DELIMITER ;

-- ===== 09_data_entry.sql =====
-- =============================================================================
-- FILE: 09_data_entry.sql
-- DESC: Safe data-entry wrapper procedures — validated inserts for all tables
--       Call these from the MySQL CLI to add new records interactively.
-- =============================================================================

USE toll_collection_db;
DELIMITER $$

-- ---------------------------------------------------------------------------
-- sp_add_new_owner
-- Usage: CALL sp_add_new_owner('Amit Kumar', 'Delhi', '9876543210');
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_add_new_owner$$
CREATE PROCEDURE sp_add_new_owner(
    IN  p_name    VARCHAR(100),
    IN  p_address VARCHAR(255),
    IN  p_contact VARCHAR(15)
)
BEGIN
    DECLARE v_id  INT;
    DECLARE v_msg VARCHAR(255);
    CALL sp_register_owner(p_name, p_address, p_contact, v_id, v_msg);
    SELECT v_id AS new_owner_id, v_msg AS message;
END$$

-- ---------------------------------------------------------------------------
-- sp_add_new_vehicle
-- Usage: CALL sp_add_new_vehicle(1, 'MH12AB1234', 'Car');
-- vehicle_type options: Car | Truck | Bus | Bike | LCV
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_add_new_vehicle$$
CREATE PROCEDURE sp_add_new_vehicle(
    IN  p_owner_id    INT,
    IN  p_plate       VARCHAR(20),
    IN  p_type        VARCHAR(20)
)
BEGIN
    DECLARE v_id  INT;
    DECLARE v_msg VARCHAR(255);
    CALL sp_register_vehicle(p_owner_id, p_plate, p_type, v_id, v_msg);
    SELECT v_id AS new_vehicle_id, v_msg AS message;
END$$

-- ---------------------------------------------------------------------------
-- sp_add_new_fastag
-- Links a new RFID tag to a vehicle AND creates an Active wallet for the owner.
-- Usage: CALL sp_add_new_fastag(3, 'EPC-NEW-001', 500.00);
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_add_new_fastag$$
CREATE PROCEDURE sp_add_new_fastag(
    IN  p_vehicle_id   INT,
    IN  p_epc_code     VARCHAR(50),
    IN  p_initial_load DECIMAL(10,2)
)
BEGIN
    DECLARE v_owner_id     INT DEFAULT NULL;
    DECLARE v_epc_exists   INT DEFAULT 0;
    DECLARE v_tag_id       INT;
    DECLARE v_wallet_id    INT;

    SELECT owner_id INTO v_owner_id
    FROM   VEHICLES
    WHERE  vehicle_id = p_vehicle_id;

    IF v_owner_id IS NULL THEN
        SELECT -1 AS new_tag_id, 'ERROR: Vehicle not found.' AS message;
    ELSE
        SELECT COUNT(*) INTO v_epc_exists
        FROM   RFID_TAGS
        WHERE  epc_code = UPPER(TRIM(p_epc_code));

        IF v_epc_exists > 0 THEN
            SELECT -1 AS new_tag_id, 'ERROR: EPC code already registered.' AS message;
        ELSE
            -- Create RFID tag
            INSERT INTO RFID_TAGS (vehicle_id, epc_code, status)
            VALUES (p_vehicle_id, UPPER(TRIM(p_epc_code)), 'Active');
            SET v_tag_id = LAST_INSERT_ID();

            -- Create FASTag wallet for the owner
            INSERT INTO FASTAG_WALLETS (owner_id, balance, status)
            VALUES (v_owner_id, COALESCE(p_initial_load, 0), 'Active');
            SET v_wallet_id = LAST_INSERT_ID();

            SELECT v_tag_id    AS new_tag_id,
                   v_wallet_id AS new_wallet_id,
                   'FASTag registered and wallet created.' AS message;
        END IF;
    END IF;
END$$

-- ---------------------------------------------------------------------------
-- sp_add_new_nhai_pass
-- Creates a new NHAI Monthly Pass for a vehicle.
-- Usage: CALL sp_add_new_nhai_pass(4, 1);   -- vehicle 4, 1 month validity
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_add_new_nhai_pass$$
CREATE PROCEDURE sp_add_new_nhai_pass(
    IN  p_vehicle_id      INT,
    IN  p_months_validity INT
)
BEGIN
    DECLARE v_vehicle_exists INT DEFAULT 0;
    DECLARE v_pass_id        INT;
    DECLARE v_expiry         DATE;

    SELECT COUNT(*) INTO v_vehicle_exists
    FROM   VEHICLES
    WHERE  vehicle_id = p_vehicle_id;

    IF v_vehicle_exists = 0 THEN
        SELECT -1 AS new_pass_id, 'ERROR: Vehicle not found.' AS message;
    ELSEIF p_months_validity <= 0 THEN
        SELECT -1 AS new_pass_id, 'ERROR: Validity must be at least 1 month.' AS message;
    ELSE
        SET v_expiry = DATE_ADD(CURDATE(), INTERVAL p_months_validity MONTH);

        INSERT INTO NHAI_PASSES (vehicle_id, remaining_trips, expiry_date, status)
        VALUES (p_vehicle_id, 200, v_expiry, 'Active');
        SET v_pass_id = LAST_INSERT_ID();

        SELECT v_pass_id  AS new_pass_id,
               v_expiry   AS expiry_date,
               'NHAI Pass created with 200 trips.' AS message;
    END IF;
END$$

-- ---------------------------------------------------------------------------
-- sp_add_new_toll_gate
-- Usage: CALL sp_add_new_toll_gate('NH-58 Haridwar Toll, Uttarakhand', 6);
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_add_new_toll_gate$$
CREATE PROCEDURE sp_add_new_toll_gate(
    IN  p_location   VARCHAR(150),
    IN  p_lane_count INT
)
BEGIN
    IF p_lane_count <= 0 THEN
        SELECT -1 AS new_gate_id, 'ERROR: Lane count must be positive.' AS message;
    ELSE
        INSERT INTO TOLL_GATES (location, lane_count)
        VALUES (TRIM(p_location), p_lane_count);
        SELECT LAST_INSERT_ID() AS new_gate_id, 'Toll gate registered.' AS message;
    END IF;
END$$

-- ---------------------------------------------------------------------------
-- sp_enter_manual_cash_transaction
-- Record a cash payment manually (used by booth operator).
-- Usage: CALL sp_enter_manual_cash_transaction(4, 1, 35.00);
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_enter_manual_cash_transaction$$
CREATE PROCEDURE sp_enter_manual_cash_transaction(
    IN  p_vehicle_id  INT,
    IN  p_gate_id     INT,
    IN  p_amount      DECIMAL(10,2)
)
BEGIN
    DECLARE v_expected    DECIMAL(10,2);
    DECLARE v_vtype       VARCHAR(20);
    DECLARE v_txn_id      INT;

    SELECT vehicle_type INTO v_vtype
    FROM   VEHICLES
    WHERE  vehicle_id = p_vehicle_id;

    IF v_vtype IS NULL THEN
        SELECT -1 AS new_txn_id, 'ERROR: Vehicle not found.' AS message;
    ELSEIF p_amount <= 0 THEN
        SELECT -1 AS new_txn_id, 'ERROR: Amount must be positive.' AS message;
    ELSE
        SET v_expected = fn_calculate_toll(v_vtype);

        INSERT INTO TRANSACTIONS (vehicle_id, gate_id, payment_mode, toll_amount)
        VALUES (p_vehicle_id, p_gate_id, 'Cash', p_amount);
        SET v_txn_id = LAST_INSERT_ID();

        SELECT v_txn_id   AS new_txn_id,
               p_amount   AS collected_INR,
               v_expected AS expected_INR,
               IF(ABS(p_amount - v_expected) > 0.50,
                  'WARNING: Amount differs from expected rate. Flagged for review.',
                  'Cash transaction recorded successfully.') AS message;
    END IF;
END$$

-- ---------------------------------------------------------------------------
-- sp_view_vehicle_status
-- Quick status lookup by license plate — shows all credentials.
-- Usage: CALL sp_view_vehicle_status('DL01CA1234');
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_view_vehicle_status$$
CREATE PROCEDURE sp_view_vehicle_status(IN p_plate VARCHAR(20))
BEGIN
    SELECT
        v.vehicle_id,
        v.license_plate,
        v.vehicle_type,
        o.name                        AS owner_name,
        o.contact_info,
        -- FASTag info
        rt.tag_id,
        rt.epc_code,
        rt.status                     AS tag_status,
        fw.wallet_id,
        fw.balance                    AS wallet_balance_INR,
        fw.status                     AS wallet_status,
        -- NHAI Pass info
        np.pass_id,
        np.remaining_trips,
        np.expiry_date,
        np.status                     AS pass_status,
        -- Calculated eligibility
        fn_calculate_toll(v.vehicle_type) AS applicable_toll_INR,
        fn_is_fastag_valid(v.vehicle_id, fn_calculate_toll(v.vehicle_type)) AS fastag_eligible,
        fn_is_pass_valid(v.vehicle_id)                                       AS pass_eligible
    FROM       VEHICLES       v
    JOIN       OWNERS         o  ON o.owner_id   = v.owner_id
    LEFT JOIN  RFID_TAGS      rt ON rt.vehicle_id = v.vehicle_id AND rt.status = 'Active'
    LEFT JOIN  FASTAG_WALLETS fw ON fw.owner_id   = v.owner_id   AND fw.status = 'Active'
    LEFT JOIN  NHAI_PASSES    np ON np.vehicle_id = v.vehicle_id AND np.status = 'Active'
    WHERE      v.license_plate = UPPER(TRIM(p_plate));
END$$

DELIMITER ;

-- ===== 03_insert_sample_data.sql =====
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

SELECT 'Database setup complete. toll_collection_db is ready.' AS STATUS;
