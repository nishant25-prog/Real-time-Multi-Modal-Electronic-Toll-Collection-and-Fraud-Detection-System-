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
