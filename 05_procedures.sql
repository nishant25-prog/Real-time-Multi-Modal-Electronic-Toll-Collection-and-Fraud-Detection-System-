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
