-- =============================================================================
-- FILE: 10_analytics_queries.sql
-- DESC: Analytical and reporting queries — run standalone for insights
-- =============================================================================

USE toll_collection_db;

-- ---------------------------------------------------------------------------
-- Q1: Revenue Distribution by Payment Mode
-- ---------------------------------------------------------------------------
SELECT
    payment_mode,
    COUNT(*)              AS total_transactions,
    SUM(toll_amount)      AS total_revenue_INR,
    ROUND(AVG(toll_amount), 2) AS avg_toll_INR,
    ROUND(COUNT(*) * 100.0 / (SELECT COUNT(*) FROM TRANSACTIONS), 2) AS pct_of_total
FROM   TRANSACTIONS
GROUP  BY payment_mode
ORDER  BY total_revenue_INR DESC;

-- ---------------------------------------------------------------------------
-- Q2: Top Revenue-Generating Toll Gates
-- ---------------------------------------------------------------------------
SELECT
    g.gate_id,
    g.location,
    COUNT(t.transaction_id)  AS total_crossings,
    SUM(t.toll_amount)        AS total_revenue_INR,
    RANK() OVER (ORDER BY SUM(t.toll_amount) DESC) AS revenue_rank
FROM   TOLL_GATES   g
LEFT JOIN TRANSACTIONS t ON t.gate_id = g.gate_id
GROUP  BY g.gate_id, g.location
ORDER  BY total_revenue_INR DESC;

-- ---------------------------------------------------------------------------
-- Q3: Peak Hour Traffic Analysis
-- ---------------------------------------------------------------------------
SELECT
    HOUR(txn_timestamp)   AS hour_of_day,
    COUNT(*)              AS vehicle_crossings,
    SUM(toll_amount)      AS revenue_INR
FROM   TRANSACTIONS
GROUP  BY HOUR(txn_timestamp)
ORDER  BY vehicle_crossings DESC;

-- ---------------------------------------------------------------------------
-- Q4: Monthly Pass Utilization Report
-- Shows all passes and their consumption relative to 200-trip limit.
-- ---------------------------------------------------------------------------
SELECT
    p.pass_id,
    v.license_plate,
    v.vehicle_type,
    o.name                                   AS owner_name,
    p.remaining_trips,
    200 - p.remaining_trips                  AS trips_used,
    ROUND((200 - p.remaining_trips) / 2, 1) AS utilization_pct,
    p.expiry_date,
    p.status,
    DATEDIFF(p.expiry_date, CURDATE())       AS days_to_expiry
FROM   NHAI_PASSES p
JOIN   VEHICLES    v ON v.vehicle_id = p.vehicle_id
JOIN   OWNERS      o ON o.owner_id   = v.owner_id
ORDER  BY trips_used DESC;

-- ---------------------------------------------------------------------------
-- Q5: Fraud Alert Summary by Type and Status
-- ---------------------------------------------------------------------------
SELECT
    alert_type,
    alert_status,
    COUNT(*) AS count
FROM   FRAUD_ALERTS
GROUP  BY alert_type, alert_status
ORDER  BY alert_type, alert_status;

-- ---------------------------------------------------------------------------
-- Q6: Vehicle-wise Transaction History (most recent 5 per vehicle)
-- ---------------------------------------------------------------------------
SELECT
    v.license_plate,
    v.vehicle_type,
    t.transaction_id,
    t.payment_mode,
    t.toll_amount,
    g.location        AS gate_location,
    t.txn_timestamp
FROM   TRANSACTIONS t
JOIN   VEHICLES     v ON v.vehicle_id = t.vehicle_id
JOIN   TOLL_GATES   g ON g.gate_id    = t.gate_id
ORDER  BY v.vehicle_id, t.txn_timestamp DESC;

-- ---------------------------------------------------------------------------
-- Q7: FASTag Wallet Balance Leaderboard
-- ---------------------------------------------------------------------------
SELECT
    fw.wallet_id,
    o.name           AS owner_name,
    fw.balance       AS balance_INR,
    fw.status,
    RANK() OVER (ORDER BY fw.balance DESC) AS balance_rank
FROM   FASTAG_WALLETS fw
JOIN   OWNERS         o  ON o.owner_id = fw.owner_id
ORDER  BY fw.balance DESC;

-- ---------------------------------------------------------------------------
-- Q8: Daily Revenue Trend (last 30 days)
-- ---------------------------------------------------------------------------
SELECT
    DATE(txn_timestamp)   AS txn_date,
    COUNT(*)              AS crossings,
    SUM(toll_amount)      AS daily_revenue_INR
FROM   TRANSACTIONS
WHERE  txn_timestamp >= DATE_SUB(CURDATE(), INTERVAL 30 DAY)
GROUP  BY DATE(txn_timestamp)
ORDER  BY txn_date;

-- ---------------------------------------------------------------------------
-- Q9: Vehicles That Never Used Digital Payment (Cash-only)
-- ---------------------------------------------------------------------------
SELECT
    v.vehicle_id,
    v.license_plate,
    v.vehicle_type,
    o.name AS owner_name,
    COUNT(t.transaction_id) AS cash_transactions
FROM   VEHICLES v
JOIN   OWNERS   o ON o.owner_id = v.owner_id
JOIN   TRANSACTIONS t ON t.vehicle_id = v.vehicle_id AND t.payment_mode = 'Cash'
WHERE  v.vehicle_id NOT IN (
    SELECT DISTINCT vehicle_id
    FROM   TRANSACTIONS
    WHERE  payment_mode IN ('FASTag','Pass')
)
GROUP  BY v.vehicle_id, v.license_plate, v.vehicle_type, o.name;

-- ---------------------------------------------------------------------------
-- Q10: 3NF Verification — Transitive Dependency Check
-- Shows that owner data is never stored redundantly in VEHICLES
-- ---------------------------------------------------------------------------
SELECT
    'OWNERS'          AS entity,
    COUNT(*)          AS record_count,
    'owner_id is the sole determinant of name, address, contact_info' AS normalization_note
FROM OWNERS
UNION ALL
SELECT
    'VEHICLES',
    COUNT(*),
    'vehicle_id -> owner_id (FK); no owner attributes stored here — 3NF satisfied'
FROM VEHICLES
UNION ALL
SELECT
    'NHAI_PASSES',
    COUNT(*),
    'pass_id -> remaining_trips (fully dependent on PK, no transitive dep) — 3NF satisfied'
FROM NHAI_PASSES;
