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
