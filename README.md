# Real-time Multi-Modal Electronic Toll Collection & Fraud Detection System

**Course:** UCS310 – Database Management Systems  
**Institute:** Thapar Institute of Engineering and Technology  
**Group:** Kartikeya Khullar (1024030355), Gavisht Singh (1024030358), Nishant Bimra (1024030354)  
**Lab Instructor:** Dr. Amrita Dahiya  

---

## Prerequisites — Install MySQL 8.0

MySQL is not installed by default. Follow these steps:

1. Download **MySQL Installer** from: `https://dev.mysql.com/downloads/installer/`  
   Choose "MySQL Installer for Windows" (the full ~450 MB version).

2. Run the installer → choose **Developer Default** → click through defaults.  
   Set a **root password** you'll remember (e.g., `root` or `admin123`).

3. After install, open **Start Menu → MySQL 8.0 Command Line Client** and enter your password. You should see the `mysql>` prompt — MySQL is running.

4. (Optional) Add MySQL to PATH so `mysql` works from any terminal:  
   `C:\Program Files\MySQL\MySQL Server 8.0\bin` → add to System Environment Variables → Path.

---

## Setup — Run Once

Open a terminal and run:

```
mysql -u root -p < "C:/Users/KARTIKEYA/Desktop/TollCollectionSystem/sql/master_setup.sql"
```

Or from inside the MySQL CLI:

```sql
SOURCE C:/Users/KARTIKEYA/Desktop/TollCollectionSystem/sql/master_setup.sql;
```

This creates `toll_collection_db` and loads all tables, functions, procedures, triggers, cursors, and sample data.

---

## Database Schema (8 Tables — 3NF)

| Table | Purpose |
|-------|---------|
| OWNERS | Vehicle owner accounts |
| VEHICLES | Registered vehicles (FK → OWNERS) |
| FASTAG_WALLETS | FASTag wallet balances (FK → OWNERS) |
| RFID_TAGS | RFID tags linked to vehicles |
| NHAI_PASSES | Monthly passes — 200 trip limit |
| TOLL_GATES | Physical toll plazas |
| TRANSACTIONS | Every vehicle crossing event |
| FRAUD_ALERTS | Auto-generated fraud flags |

---

## Core Workflow — Process a Toll

```sql
USE toll_collection_db;

CALL sp_process_toll(1, 1, @mode, @msg);
SELECT @mode AS payment_mode, @msg AS result;
```

The procedure automatically tries:
1. **FASTag** — deducts from wallet if active & funded
2. **NHAI Pass** — decrements trip count if valid & non-expired
3. **Cash** — logs manual payment as fallback

---

## Data Entry Commands

```sql
-- Register a new owner
CALL sp_add_new_owner('Ravi Malhotra', 'Sector 15, Noida', '9900112233');

-- Register a vehicle (use the owner_id returned above)
CALL sp_add_new_vehicle(6, 'UP14BX9999', 'Car');

-- Add FASTag + wallet (vehicle_id, EPC code, initial balance)
CALL sp_add_new_fastag(9, 'EPC-UP14BX9999-007', 1000.00);

-- Issue NHAI monthly pass (vehicle_id, months validity)
CALL sp_add_new_nhai_pass(9, 1);

-- Add a new toll gate
CALL sp_add_new_toll_gate('NH-58 Haridwar Toll, Uttarakhand', 6);

-- Top-up FASTag wallet (wallet_id, amount)
CALL sp_topup_fastag(1, 500.00, @new_bal, @msg);
SELECT @new_bal, @msg;

-- Enter manual cash transaction (vehicle_id, gate_id, amount)
CALL sp_enter_manual_cash_transaction(4, 1, 35.00);

-- View full credentials for a license plate
CALL sp_view_vehicle_status('DL01CA1234');
```

---

## Reports & Analytics

```sql
-- Monthly revenue by gate (month=5, year=2025)
CALL sp_generate_monthly_revenue_report(5, 2025);

-- Low FASTag balance warnings (threshold INR 100)
CALL sp_list_low_balance_fastags(100.00);

-- Batch fraud scan (cash mismatch + clone tag detection)
CALL sp_scan_fraud_by_mode();

-- Full fraud audit
CALL sp_run_full_fraud_audit();

-- Expire all stale NHAI passes
CALL sp_expire_stale_passes(@n);
SELECT @n AS passes_expired;

-- Renew an NHAI pass (vehicle_id, additional months)
CALL sp_renew_nhai_pass(2, 1, @msg);
SELECT @msg;
```

Run all analytics queries from `10_analytics_queries.sql` directly in MySQL CLI.

---

## PL/SQL Components Summary

| Type | Name | Purpose |
|------|------|---------|
| Procedure | sp_process_toll | Hierarchical FASTag→Pass→Cash engine with SAVEPOINTs |
| Procedure | sp_topup_fastag | Add funds to FASTag wallet |
| Procedure | sp_register_owner / sp_register_vehicle | New account registration |
| Procedure | sp_renew_nhai_pass | Reset trips, extend expiry |
| Procedure | sp_expire_stale_passes | Batch expiry update |
| Procedure | sp_run_full_fraud_audit | Full cross-mode fraud scan |
| Procedure | sp_generate_monthly_revenue_report | Cursor-based gate revenue report |
| Procedure | sp_scan_fraud_by_mode | Cursor-based transaction scanner |
| Procedure | sp_list_low_balance_fastags | Cursor-based wallet balance report |
| Function | fn_calculate_toll | Toll rate by vehicle type |
| Function | fn_get_fastag_balance | Current wallet balance lookup |
| Function | fn_get_pass_trips_remaining | Remaining pass trips lookup |
| Function | fn_is_fastag_valid | FASTag eligibility check |
| Function | fn_is_pass_valid | NHAI Pass eligibility check |
| Trigger | trg_prevent_negative_balance | Block wallet going < 0 |
| Trigger | trg_auto_expire_pass | Auto-expire on date check |
| Trigger | trg_low_trip_alert | Auto-alert when trips < 5 |
| Trigger | trg_double_dip_check | Detect FASTag+Pass double charge |
| Trigger | trg_prevent_pass_sharing | Block cross-vehicle pass use |

---

## Fraud Detection Scenarios in Sample Data

| Scenario | How to See It |
|----------|--------------|
| Cloned Tag | Run Query 1 in `08_fraud_detection.sql` |
| Pass Sharing | Run Query 2 in `08_fraud_detection.sql` |
| Double Dipping | Run Query 3 in `08_fraud_detection.sql` |
| Cash Mismatch | Run Query 4 in `08_fraud_detection.sql` |
| Low Trip Alert | Check FRAUD_ALERTS after any pass update |
| Full Audit | `CALL sp_run_full_fraud_audit();` |
