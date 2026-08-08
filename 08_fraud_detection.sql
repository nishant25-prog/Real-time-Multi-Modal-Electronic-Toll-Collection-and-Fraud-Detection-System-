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
