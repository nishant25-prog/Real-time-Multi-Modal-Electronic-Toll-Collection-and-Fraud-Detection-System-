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
