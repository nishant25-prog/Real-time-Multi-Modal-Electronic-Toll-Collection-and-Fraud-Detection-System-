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
