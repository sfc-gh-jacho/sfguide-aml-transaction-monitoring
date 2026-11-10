/*
================================================================================
 AML TRANSACTION MONITORING - DEMO SCRIPT
 Transparent, explainable anti-money-laundering detection in SQL:
 - Structuring (deposits just under a reporting threshold)
 - Rapid movement of funds (pass-through accounts)
 - Funnel accounts (many senders, one large outbound wire)
 - High-risk geography (round-amount wires to high-risk countries)
 - Risk scoring into a prioritized, explainable alert queue
 - A Dynamic Table that keeps alerts fresh as transactions arrive
 - Region-based investigator access with a row access policy
 - Optional: AI-drafted case summaries with Cortex AI_COMPLETE

 Scenario: 90 days of activity at a fictional bank. ~500,000 normal
 transactions, with a dozen planted typologies for the rules to find.

 The rules, thresholds and scores are ILLUSTRATIVE and educational. They are
 not BSA/AML, FinCEN or any other regulatory guidance, and not a production
 transaction monitoring system.

 This script creates its own objects (AML_DEMO_DB, AML_WH and AML_ roles)
 and changes nothing that already exists. Step 13 removes everything.

 ALL DATA IS SYNTHETIC. Customers are IDs only; countries are coded
 (CTRY_A-CTRY_L) so no real jurisdiction is labeled high risk.
================================================================================
*/

-- [step:setup]
-- ============================================================================
-- STEP 1: SETUP
-- ============================================================================

-- Choose the role that runs the guide:
--   'ACCOUNTADMIN'  - simplest, for sandbox accounts
--   'AML_DEMO_ROLE' - least privilege; create it once with the block below
SET demo_role = 'ACCOUNTADMIN';

-- OPTIONAL: least-privilege demo role. An administrator runs this ONCE,
-- then set demo_role = 'AML_DEMO_ROLE' above.
-- USE ROLE ACCOUNTADMIN;
-- CREATE ROLE IF NOT EXISTS AML_DEMO_ROLE COMMENT = 'Runs the AML monitoring demo';
-- GRANT CREATE DATABASE  ON ACCOUNT TO ROLE AML_DEMO_ROLE;   -- demo database (owned by this role)
-- GRANT CREATE WAREHOUSE ON ACCOUNT TO ROLE AML_DEMO_ROLE;   -- XSMALL warehouse + Dynamic Table
-- GRANT CREATE ROLE      ON ACCOUNT TO ROLE AML_DEMO_ROLE;   -- investigator roles (Step 11)
-- GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE AML_DEMO_ROLE;  -- AI_COMPLETE (Step 12 only)
-- SET my_user = CURRENT_USER();
-- GRANT ROLE AML_DEMO_ROLE TO USER IDENTIFIER($my_user);

USE ROLE IDENTIFIER($demo_role);

CREATE WAREHOUSE IF NOT EXISTS AML_WH
    WAREHOUSE_SIZE = XSMALL AUTO_SUSPEND = 60 AUTO_RESUME = TRUE INITIALLY_SUSPENDED = TRUE;
USE WAREHOUSE AML_WH;

CREATE OR REPLACE DATABASE AML_DEMO_DB;
CREATE SCHEMA IF NOT EXISTS AML_DEMO_DB.MONITORING;
USE SCHEMA AML_DEMO_DB.MONITORING;

-- [step:reference]
-- ============================================================================
-- STEP 2: REFERENCE DATA - Settings, Countries, Customers and Accounts
-- ============================================================================

-- Rule settings live in a table, so analysts can tune them without editing
-- code. The reporting threshold is jurisdiction-specific: set your own.
CREATE OR REPLACE TABLE AML_SETTINGS (
    REPORTING_THRESHOLD   NUMBER(12,2),   -- cash reporting threshold
    STRUCTURING_BAND_PCT  NUMBER(4,2),    -- "just under" = within this % below it
    LARGE_WIRE            NUMBER(12,2)    -- what counts as a large wire
);
INSERT INTO AML_SETTINGS VALUES (10000, 0.10, 50000);

-- Coded countries with an illustrative risk tier
CREATE OR REPLACE TABLE AML_COUNTRY_RISK AS
SELECT 'CTRY_' || CHR(65 + SEQ4())                                         AS country_code,
       CASE WHEN SEQ4() < 6 THEN 'LOW' WHEN SEQ4() < 9 THEN 'MEDIUM' ELSE 'HIGH' END AS risk_tier
FROM TABLE(GENERATOR(ROWCOUNT => 12));

-- 2,000 customers (IDs only, no names)
CREATE OR REPLACE TABLE AML_CUSTOMERS AS
SELECT
    'C' || LPAD(SEQ4() + 1, 4, '0')                                         AS customer_id,
    DECODE(MOD(ABS(HASH(SEQ4(), 'seg')), 10), 0, 'CORPORATE', 1, 'SMALL_BUSINESS', 2, 'SMALL_BUSINESS', 'RETAIL') AS segment,
    DECODE(MOD(ABS(HASH(SEQ4(), 'kyc')), 10), 0, 'HIGH', 1, 'MEDIUM', 2, 'MEDIUM', 'LOW')                    AS kyc_risk,
    IFF(MOD(SEQ4(), 2) = 0, 'EAST', 'WEST')                                 AS region
FROM TABLE(GENERATOR(ROWCOUNT => 2000));

-- 3,000 accounts
CREATE OR REPLACE TABLE AML_ACCOUNTS AS
SELECT
    'A' || LPAD(SEQ4() + 1, 4, '0')                                         AS account_id,
    'C' || LPAD(MOD(SEQ4(), 2000) + 1, 4, '0')                              AS customer_id,
    DECODE(MOD(SEQ4(), 3), 0, 'CHECKING', 1, 'SAVINGS', 'BUSINESS')         AS account_type
FROM TABLE(GENERATOR(ROWCOUNT => 3000));

SELECT kyc_risk, region, COUNT(*) AS customers
FROM AML_CUSTOMERS GROUP BY kyc_risk, region ORDER BY kyc_risk, region;

-- [step:transactions]
-- ============================================================================
-- STEP 3: 90 DAYS OF TRANSACTIONS
-- ============================================================================
-- 500,000 normal transactions, generated deterministically. Normal activity
-- is designed to be clean: cash deposits under $4,000, wires of at most
-- $20,000, and international wires only to LOW or MEDIUM risk countries.

CREATE OR REPLACE TABLE AML_TRANSACTIONS (
    TXN_ID                NUMBER,
    ACCOUNT_ID            VARCHAR(10),
    TXN_TS                TIMESTAMP_NTZ(0),
    TXN_TYPE              VARCHAR(20),
    DIRECTION             VARCHAR(3),     -- IN or OUT
    AMOUNT                NUMBER(14,2),
    COUNTERPARTY          VARCHAR(30),
    COUNTERPARTY_COUNTRY  VARCHAR(10)
);

INSERT INTO AML_TRANSACTIONS
WITH g AS (
    SELECT SEQ4() AS n,
           MOD(ABS(HASH(SEQ4(), 'type')), 100) AS t,
           MOD(ABS(HASH(SEQ4(), 'amt')), 1000000) / 1000000 AS r
    FROM TABLE(GENERATOR(ROWCOUNT => 500000))
)
SELECT
    n + 1,
    'A' || LPAD(MOD(ABS(HASH(n, 'acct')), 3000) + 1, 4, '0'),
    DATEADD(SECOND, MOD(ABS(HASH(n, 'ts')), 90 * 86400), '2026-08-01'::TIMESTAMP_NTZ),
    CASE WHEN t < 25 THEN 'CARD_PURCHASE' WHEN t < 45 THEN 'CASH_DEPOSIT' WHEN t < 65 THEN 'ACH_CREDIT'
         WHEN t < 80 THEN 'ACH_DEBIT'     WHEN t < 90 THEN 'WIRE_OUT'     ELSE 'WIRE_IN' END,
    CASE WHEN t < 25 OR (t >= 65 AND t < 90) THEN 'OUT' ELSE 'IN' END,
    ROUND(CASE WHEN t < 25 THEN 5    + r * 495
               WHEN t < 45 THEN 50   + r * 3950
               WHEN t < 65 THEN 500  + r * 5500
               WHEN t < 80 THEN 100  + r * 2900
               ELSE             500  + r * 19500 END, 2),
    CASE WHEN t < 25 THEN 'MERCHANT_' || LPAD(MOD(ABS(HASH(n, 'cp')), 400), 3, '0')
         WHEN t < 45 THEN 'BRANCH_'   || LPAD(MOD(ABS(HASH(n, 'cp')), 40), 2, '0')
         WHEN t < 65 THEN 'EMPLOYER_' || LPAD(MOD(ABS(HASH(n, 'cp')), 150), 3, '0')
         WHEN t < 80 THEN 'BILLER_'   || LPAD(MOD(ABS(HASH(n, 'cp')), 80), 2, '0')
         ELSE             'EXT_'      || LPAD(MOD(ABS(HASH(n, 'cp')), 900), 3, '0') END,
    CASE WHEN t >= 80 THEN 'CTRY_' || CHR(65 + MOD(ABS(HASH(n, 'ctry')), 9)) ELSE 'CTRY_A' END   -- A-I only
FROM g;

-- [step:plant]
-- ============================================================================
-- STEP 4: PLANT THE TYPOLOGIES
-- ============================================================================
-- Twelve known cases hidden among 500,000 normal transactions.

-- Structuring: repeated cash deposits just under the $10,000 threshold
INSERT INTO AML_TRANSACTIONS VALUES
(900001, 'A0101', '2026-10-05 10:12:00', 'CASH_DEPOSIT', 'IN', 9500.00, 'BRANCH_03', 'CTRY_A'),
(900002, 'A0101', '2026-10-06 15:40:00', 'CASH_DEPOSIT', 'IN', 9800.00, 'BRANCH_07', 'CTRY_A'),
(900003, 'A0101', '2026-10-08 11:05:00', 'CASH_DEPOSIT', 'IN', 9700.00, 'BRANCH_03', 'CTRY_A'),
(900004, 'A0101', '2026-10-09 09:30:00', 'CASH_DEPOSIT', 'IN', 9900.00, 'BRANCH_12', 'CTRY_A'),
(900011, 'A0502', '2026-09-14 12:00:00', 'CASH_DEPOSIT', 'IN', 9450.00, 'BRANCH_20', 'CTRY_A'),
(900012, 'A0502', '2026-09-16 16:20:00', 'CASH_DEPOSIT', 'IN', 9600.00, 'BRANCH_21', 'CTRY_A'),
(900013, 'A0502', '2026-09-18 10:45:00', 'CASH_DEPOSIT', 'IN', 9850.00, 'BRANCH_20', 'CTRY_A'),
(900021, 'A1203', '2026-10-20 09:10:00', 'CASH_DEPOSIT', 'IN', 9990.00, 'BRANCH_05', 'CTRY_A'),
(900022, 'A1203', '2026-10-21 09:15:00', 'CASH_DEPOSIT', 'IN', 9975.00, 'BRANCH_05', 'CTRY_A'),
(900023, 'A1203', '2026-10-22 09:05:00', 'CASH_DEPOSIT', 'IN', 9980.00, 'BRANCH_06', 'CTRY_A'),
(900024, 'A1203', '2026-10-23 09:20:00', 'CASH_DEPOSIT', 'IN', 9995.00, 'BRANCH_05', 'CTRY_A'),
(900025, 'A1203', '2026-10-24 09:00:00', 'CASH_DEPOSIT', 'IN', 9960.00, 'BRANCH_06', 'CTRY_A'),
(900031, 'A2404', '2026-08-25 14:00:00', 'CASH_DEPOSIT', 'IN', 9300.00, 'BRANCH_30', 'CTRY_A'),
(900032, 'A2404', '2026-08-27 13:30:00', 'CASH_DEPOSIT', 'IN', 9550.00, 'BRANCH_31', 'CTRY_A'),
(900033, 'A2404', '2026-08-30 15:10:00', 'CASH_DEPOSIT', 'IN', 9400.00, 'BRANCH_30', 'CTRY_A'),

-- Rapid movement: large wire in, (almost) all of it out again within 48 hours
(900101, 'A0333', '2026-09-03 09:00:00', 'WIRE_IN',  'IN',  185000.00, 'EXT_SHELL_01', 'CTRY_C'),
(900102, 'A0333', '2026-09-04 16:00:00', 'WIRE_OUT', 'OUT', 182500.00, 'EXT_SHELL_02', 'CTRY_E'),
(900111, 'A1444', '2026-10-11 11:30:00', 'WIRE_IN',  'IN',   92000.00, 'EXT_SHELL_03', 'CTRY_B'),
(900112, 'A1444', '2026-10-12 07:45:00', 'WIRE_OUT', 'OUT',  90100.00, 'EXT_SHELL_04', 'CTRY_F'),
(900121, 'A2555', '2026-08-18 10:00:00', 'WIRE_IN',  'IN',  250000.00, 'EXT_SHELL_05', 'CTRY_G'),
(900122, 'A2555', '2026-08-19 09:00:00', 'WIRE_OUT', 'OUT', 120000.00, 'EXT_SHELL_06', 'CTRY_D'),
(900123, 'A2555', '2026-08-20 01:30:00', 'WIRE_OUT', 'OUT', 125000.00, 'EXT_SHELL_07', 'CTRY_H'),

-- High-risk geography: round-amount wires to HIGH risk-tier countries
(900301, 'A0909', '2026-09-22 13:00:00', 'WIRE_OUT', 'OUT',  50000.00, 'EXT_GEO_01', 'CTRY_J'),
(900302, 'A1616', '2026-10-02 10:30:00', 'WIRE_OUT', 'OUT', 120000.00, 'EXT_GEO_02', 'CTRY_L'),
(900303, 'A2121', '2026-10-15 15:45:00', 'WIRE_OUT', 'OUT',  30000.00, 'EXT_GEO_03', 'CTRY_K');

-- Funnel accounts: many unrelated senders, then one large wire out
INSERT INTO AML_TRANSACTIONS
SELECT 900201 + SEQ4(), 'A0777',
       DATEADD(HOUR, SEQ4() * 10, '2026-09-08 08:00:00'::TIMESTAMP_NTZ),
       'WIRE_IN', 'IN', 4500 + MOD(SEQ4() * 389, 5300),
       'EXT_FUNNEL1_' || LPAD(SEQ4() + 1, 2, '0'), 'CTRY_' || CHR(65 + MOD(SEQ4(), 6))
FROM TABLE(GENERATOR(ROWCOUNT => 14));
INSERT INTO AML_TRANSACTIONS VALUES
(900230, 'A0777', '2026-09-14 12:00:00', 'WIRE_OUT', 'OUT', 87350.00, 'EXT_COLLECT_01', 'CTRY_D');

INSERT INTO AML_TRANSACTIONS
SELECT 900251 + SEQ4(), 'A1888',
       DATEADD(HOUR, SEQ4() * 12, '2026-10-18 09:00:00'::TIMESTAMP_NTZ),
       'WIRE_IN', 'IN', 4800 + MOD(SEQ4() * 457, 2400),
       'EXT_FUNNEL2_' || LPAD(SEQ4() + 1, 2, '0'), 'CTRY_' || CHR(66 + MOD(SEQ4(), 5))
FROM TABLE(GENERATOR(ROWCOUNT => 12));
INSERT INTO AML_TRANSACTIONS VALUES
(900280, 'A1888', '2026-10-24 17:00:00', 'WIRE_OUT', 'OUT', 64900.00, 'EXT_COLLECT_02', 'CTRY_B');

SELECT COUNT(*) AS transactions, SUM(IFF(direction = 'IN', amount, 0)) AS total_in,
       SUM(IFF(direction = 'OUT', amount, 0)) AS total_out
FROM AML_TRANSACTIONS;

-- What an analyst sees without monitoring: an ordinary-looking ledger.
-- A structuring case is hidden in here. Can you spot it?
SELECT txn_id, txn_ts, txn_type, direction, amount, counterparty
FROM AML_TRANSACTIONS
WHERE account_id = 'A1203' AND txn_ts BETWEEN '2026-10-17' AND '2026-10-27'
ORDER BY txn_ts;

-- [step:structuring]
-- ============================================================================
-- STEP 5: RULE A - STRUCTURING
-- ============================================================================
-- Three or more cash deposits within 7 days, each within 10% below the
-- reporting threshold. Splitting cash to stay under a threshold is a classic
-- way to avoid a currency transaction report.

CREATE OR REPLACE VIEW AML_RULE_STRUCTURING AS
WITH s AS (SELECT * FROM AML_SETTINGS),
near AS (
    SELECT t.account_id, t.txn_ts, t.amount
    FROM AML_TRANSACTIONS t, s
    WHERE t.txn_type = 'CASH_DEPOSIT'
      AND t.amount <  s.reporting_threshold
      AND t.amount >= s.reporting_threshold * (1 - s.structuring_band_pct)
),
windows AS (
    SELECT a.account_id, a.txn_ts AS window_start,
           MAX(b.txn_ts) AS window_end, COUNT(*) AS deposits, SUM(b.amount) AS total
    FROM near a
    JOIN near b ON b.account_id = a.account_id
               AND b.txn_ts BETWEEN a.txn_ts AND DATEADD(DAY, 7, a.txn_ts)
    GROUP BY a.account_id, a.txn_ts
    HAVING COUNT(*) >= 3
)
SELECT
    'STRUCTURING'                                                    AS rule,
    account_id, window_start, window_end, total                      AS amount,
    35                                                               AS rule_weight,
    deposits || ' cash deposits between $' || TRIM(TO_VARCHAR(s.reporting_threshold * (1 - s.structuring_band_pct), '9,999'))
        || ' and $' || TRIM(TO_VARCHAR(s.reporting_threshold, '99,999')) || ' within '
        || GREATEST(1, DATEDIFF(DAY, window_start, window_end)) || ' days, totalling $'
        || TRIM(TO_VARCHAR(total, '999,999'))                              AS explanation
FROM windows, AML_SETTINGS s
QUALIFY ROW_NUMBER() OVER (PARTITION BY account_id ORDER BY deposits DESC, window_start) = 1;

SELECT * FROM AML_RULE_STRUCTURING ORDER BY window_start;

-- [step:rapid]
-- ============================================================================
-- STEP 6: RULE B - RAPID MOVEMENT OF FUNDS
-- ============================================================================
-- A large wire in, followed within 48 hours by outgoing wires totalling at
-- least 90% of it. The account is a pass-through, not a destination.

CREATE OR REPLACE VIEW AML_RULE_RAPID AS
SELECT
    'RAPID_MOVEMENT'                                                 AS rule,
    i.account_id,
    i.txn_ts                                                         AS window_start,
    MAX(o.txn_ts)                                                    AS window_end,
    i.amount,
    30                                                               AS rule_weight,
    '$' || TRIM(TO_VARCHAR(i.amount, '999,999')) || ' wired in from ' || i.counterparty_country || ', then $'
        || TRIM(TO_VARCHAR(SUM(o.amount), '999,999')) || ' (' || ROUND(SUM(o.amount) / i.amount * 100) || '%) wired out in '
        || DATEDIFF(HOUR, i.txn_ts, MAX(o.txn_ts)) || ' hours across ' || COUNT(*) || ' wire(s)' AS explanation
FROM AML_TRANSACTIONS i
JOIN AML_SETTINGS s ON i.amount >= s.large_wire
JOIN AML_TRANSACTIONS o
  ON o.account_id = i.account_id
 AND o.txn_type   = 'WIRE_OUT'
 AND o.txn_ts     > i.txn_ts
 AND o.txn_ts    <= DATEADD(HOUR, 48, i.txn_ts)
WHERE i.txn_type = 'WIRE_IN'
GROUP BY i.account_id, i.txn_ts, i.amount, i.counterparty_country
HAVING SUM(o.amount) >= 0.9 * i.amount;

SELECT * FROM AML_RULE_RAPID ORDER BY window_start;

-- [step:funnel]
-- ============================================================================
-- STEP 7: RULE C - FUNNEL ACCOUNTS
-- ============================================================================
-- A wire out of $25,000+ where, in the 7 days before it, the account received
-- wires from 10+ different senders totalling $50,000+, and the outbound wire
-- moves at least half of that money on.

CREATE OR REPLACE VIEW AML_RULE_FUNNEL AS
SELECT
    'FUNNEL_ACCOUNT'                                                 AS rule,
    o.account_id,
    MIN(i.txn_ts)                                                    AS window_start,
    o.txn_ts                                                         AS window_end,
    o.amount,
    35                                                               AS rule_weight,
    COUNT(DISTINCT i.counterparty) || ' different senders wired $' || TRIM(TO_VARCHAR(SUM(i.amount), '999,999'))
        || ' in ' || DATEDIFF(DAY, MIN(i.txn_ts), o.txn_ts) || ' days, then $'
        || TRIM(TO_VARCHAR(o.amount, '999,999')) || ' left in a single wire'  AS explanation
FROM AML_TRANSACTIONS o
JOIN AML_TRANSACTIONS i
  ON i.account_id = o.account_id
 AND i.txn_type   = 'WIRE_IN'
 AND i.txn_ts     < o.txn_ts
 AND i.txn_ts    >= DATEADD(DAY, -7, o.txn_ts)
WHERE o.txn_type = 'WIRE_OUT'
  AND o.amount  >= 25000
GROUP BY o.account_id, o.txn_ts, o.amount
HAVING COUNT(DISTINCT i.counterparty) >= 10
   AND SUM(i.amount) >= 50000
   AND o.amount >= 0.5 * SUM(i.amount);

SELECT * FROM AML_RULE_FUNNEL ORDER BY window_start;

-- [step:geo]
-- ============================================================================
-- STEP 8: RULE D - HIGH-RISK GEOGRAPHY
-- ============================================================================
-- Round-amount wires of $10,000+ to HIGH risk-tier countries. Round amounts
-- to high-risk destinations are a common red flag in typology guidance.

CREATE OR REPLACE VIEW AML_RULE_GEO AS
SELECT
    'HIGH_RISK_GEO'                                                  AS rule,
    t.account_id,
    t.txn_ts                                                         AS window_start,
    t.txn_ts                                                         AS window_end,
    t.amount,
    25                                                               AS rule_weight,
    'Round-amount wire of $' || TRIM(TO_VARCHAR(t.amount, '999,999')) || ' to ' || t.counterparty_country
        || ' (risk tier ' || c.risk_tier || ')'                        AS explanation
FROM AML_TRANSACTIONS t
JOIN AML_COUNTRY_RISK c ON c.country_code = t.counterparty_country
WHERE t.txn_type = 'WIRE_OUT'
  AND c.risk_tier = 'HIGH'
  AND t.amount >= 10000
  AND MOD(t.amount, 1000) = 0;

SELECT * FROM AML_RULE_GEO ORDER BY window_start;

-- [step:scoring]
-- ============================================================================
-- STEP 9: RISK SCORING AND THE ALERT QUEUE (Dynamic Table)
-- ============================================================================
-- Score = rule weight + customer KYC risk + size of the money involved,
-- capped at 100. A Dynamic Table keeps the queue fresh within TARGET_LAG of
-- new transactions arriving, with no scheduler or task.

CREATE OR REPLACE DYNAMIC TABLE AML_ALERTS
    TARGET_LAG = '1 minute'
    WAREHOUSE  = AML_WH
AS
WITH hits AS (
    SELECT rule, account_id, window_start, window_end, amount, rule_weight, explanation FROM AML_RULE_STRUCTURING
    UNION ALL SELECT rule, account_id, window_start, window_end, amount, rule_weight, explanation FROM AML_RULE_RAPID
    UNION ALL SELECT rule, account_id, window_start, window_end, amount, rule_weight, explanation FROM AML_RULE_FUNNEL
    UNION ALL SELECT rule, account_id, window_start, window_end, amount, rule_weight, explanation FROM AML_RULE_GEO
)
SELECT
    DECODE(h.rule, 'STRUCTURING', 'STR', 'RAPID_MOVEMENT', 'RPD', 'FUNNEL_ACCOUNT', 'FNL', 'GEO')
        || '-' || LPAD(ROW_NUMBER() OVER (PARTITION BY h.rule ORDER BY h.window_start), 3, '0') AS alert_id,
    h.rule,
    LEAST(100, h.rule_weight
               + DECODE(c.kyc_risk, 'HIGH', 25, 'MEDIUM', 15, 5)
               + LEAST(40, ROUND(h.amount / 5000)))                  AS risk_score,
    c.customer_id, c.segment, c.kyc_risk, c.region,
    h.account_id, h.window_start, h.window_end, h.amount, h.explanation
FROM hits h
JOIN AML_ACCOUNTS  a ON a.account_id  = h.account_id
JOIN AML_CUSTOMERS c ON c.customer_id = a.customer_id;

-- The queue investigators work from, highest risk first
SELECT alert_id, rule, risk_score, customer_id, kyc_risk, region, window_start::DATE AS start_date, explanation
FROM AML_ALERTS
ORDER BY risk_score DESC, window_start;

-- Signal vs. noise: transactions scanned vs. alerts raised per rule
SELECT
    r.rule,
    (SELECT COUNT(*) FROM AML_TRANSACTIONS)                          AS transactions_scanned,
    COUNT(a.alert_id)                                                AS alerts
FROM (SELECT column1 AS rule FROM VALUES ('STRUCTURING'), ('RAPID_MOVEMENT'), ('FUNNEL_ACCOUNT'), ('HIGH_RISK_GEO')) r
LEFT JOIN AML_ALERTS a ON a.rule = r.rule
GROUP BY r.rule
ORDER BY alerts DESC;

-- New activity arrives: another structuring pattern
INSERT INTO AML_TRANSACTIONS VALUES
(900401, 'A2828', '2026-10-26 10:00:00', 'CASH_DEPOSIT', 'IN', 9650.00, 'BRANCH_14', 'CTRY_A'),
(900402, 'A2828', '2026-10-27 11:30:00', 'CASH_DEPOSIT', 'IN', 9720.00, 'BRANCH_15', 'CTRY_A'),
(900403, 'A2828', '2026-10-28 12:15:00', 'CASH_DEPOSIT', 'IN', 9880.00, 'BRANCH_14', 'CTRY_A');

-- Within a minute the Dynamic Table refreshes on its own. To see it now:
ALTER DYNAMIC TABLE AML_ALERTS REFRESH;

SELECT rule, COUNT(*) AS alerts FROM AML_ALERTS GROUP BY rule ORDER BY rule;

SELECT name, state, refresh_action, refresh_trigger, data_timestamp
FROM TABLE(INFORMATION_SCHEMA.DYNAMIC_TABLE_REFRESH_HISTORY(NAME => 'AML_DEMO_DB.MONITORING.AML_ALERTS'))
ORDER BY data_timestamp DESC
LIMIT 3;

-- [step:investigate]
-- ============================================================================
-- STEP 10: INVESTIGATE ONE CASE
-- ============================================================================
-- Drill from the highest-risk structuring alert into the account's full
-- activity around that window.

SET (case_account, case_start, case_end) = (
    SELECT account_id, window_start, window_end
    FROM AML_ALERTS WHERE rule = 'STRUCTURING'
    ORDER BY risk_score DESC, window_start LIMIT 1
);

SELECT t.txn_ts, t.txn_type, t.direction, t.amount, t.counterparty,
       IFF(t.txn_type = 'CASH_DEPOSIT'
           AND t.amount >= s.reporting_threshold * (1 - s.structuring_band_pct)
           AND t.amount <  s.reporting_threshold, 'NEAR THRESHOLD', '')  AS flag
FROM AML_TRANSACTIONS t, AML_SETTINGS s
WHERE t.account_id = $case_account
  AND t.txn_ts BETWEEN DATEADD(DAY, -2, $case_start::TIMESTAMP_NTZ)
                   AND DATEADD(DAY,  2, $case_end::TIMESTAMP_NTZ)
ORDER BY t.txn_ts;

-- [step:access]
-- ============================================================================
-- STEP 11: REGION-BASED INVESTIGATOR ACCESS (Row Access Policy)
-- ============================================================================
-- Investigators see only alerts for customers in their region. Access is
-- driven by a mapping table, so adding an investigator is an INSERT, not a
-- policy change.

CREATE ROLE IF NOT EXISTS AML_INVESTIGATOR_EAST;
CREATE ROLE IF NOT EXISTS AML_INVESTIGATOR_WEST;
CREATE ROLE IF NOT EXISTS AML_MANAGER;
GRANT ROLE AML_INVESTIGATOR_EAST TO ROLE IDENTIFIER($demo_role);
GRANT ROLE AML_INVESTIGATOR_WEST TO ROLE IDENTIFIER($demo_role);
GRANT ROLE AML_MANAGER           TO ROLE IDENTIFIER($demo_role);

CREATE OR REPLACE TABLE AML_REGION_ACCESS (ROLE_NAME VARCHAR, REGION VARCHAR);
INSERT INTO AML_REGION_ACCESS VALUES
    ('AML_INVESTIGATOR_EAST', 'EAST'),
    ('AML_INVESTIGATOR_WEST', 'WEST'),
    ('AML_MANAGER', 'EAST'), ('AML_MANAGER', 'WEST');

CREATE OR REPLACE ROW ACCESS POLICY aml_region_policy AS (region_val VARCHAR) RETURNS BOOLEAN ->
    CURRENT_ROLE() IN ('ACCOUNTADMIN', 'AML_DEMO_ROLE')
    OR EXISTS (SELECT 1 FROM AML_DEMO_DB.MONITORING.AML_REGION_ACCESS m
               WHERE m.role_name = CURRENT_ROLE() AND m.region = region_val);

-- The queue investigators query, protected by the policy
CREATE OR REPLACE VIEW AML_ALERT_QUEUE AS
SELECT alert_id, rule, risk_score, customer_id, kyc_risk, region, account_id,
       window_start, amount, explanation
FROM AML_ALERTS;

ALTER VIEW AML_ALERT_QUEUE ADD ROW ACCESS POLICY aml_region_policy ON (region);

GRANT USAGE ON WAREHOUSE AML_WH TO ROLE AML_INVESTIGATOR_EAST;
GRANT USAGE ON WAREHOUSE AML_WH TO ROLE AML_INVESTIGATOR_WEST;
GRANT USAGE ON WAREHOUSE AML_WH TO ROLE AML_MANAGER;
GRANT USAGE ON DATABASE AML_DEMO_DB TO ROLE AML_INVESTIGATOR_EAST;
GRANT USAGE ON DATABASE AML_DEMO_DB TO ROLE AML_INVESTIGATOR_WEST;
GRANT USAGE ON DATABASE AML_DEMO_DB TO ROLE AML_MANAGER;
GRANT USAGE ON SCHEMA AML_DEMO_DB.MONITORING TO ROLE AML_INVESTIGATOR_EAST;
GRANT USAGE ON SCHEMA AML_DEMO_DB.MONITORING TO ROLE AML_INVESTIGATOR_WEST;
GRANT USAGE ON SCHEMA AML_DEMO_DB.MONITORING TO ROLE AML_MANAGER;
GRANT SELECT ON VIEW AML_DEMO_DB.MONITORING.AML_ALERT_QUEUE TO ROLE AML_INVESTIGATOR_EAST;
GRANT SELECT ON VIEW AML_DEMO_DB.MONITORING.AML_ALERT_QUEUE TO ROLE AML_INVESTIGATOR_WEST;
GRANT SELECT ON VIEW AML_DEMO_DB.MONITORING.AML_ALERT_QUEUE TO ROLE AML_MANAGER;

USE ROLE AML_INVESTIGATOR_EAST;
SELECT 'AML_INVESTIGATOR_EAST' AS role, COUNT(*) AS alerts_visible, LISTAGG(DISTINCT region, ',') AS regions
FROM AML_DEMO_DB.MONITORING.AML_ALERT_QUEUE;

USE ROLE AML_INVESTIGATOR_WEST;
SELECT 'AML_INVESTIGATOR_WEST' AS role, COUNT(*) AS alerts_visible, LISTAGG(DISTINCT region, ',') AS regions
FROM AML_DEMO_DB.MONITORING.AML_ALERT_QUEUE;

USE ROLE AML_MANAGER;
SELECT 'AML_MANAGER' AS role, COUNT(*) AS alerts_visible, LISTAGG(DISTINCT region, ',') AS regions
FROM AML_DEMO_DB.MONITORING.AML_ALERT_QUEUE;

USE ROLE IDENTIFIER($demo_role);

-- [step:ai]
-- ============================================================================
-- STEP 12: (OPTIONAL) AI-DRAFTED CASE SUMMARIES WITH CORTEX
-- ============================================================================
-- AI_COMPLETE drafts a short, factual case summary for the five highest-risk
-- alerts, using only the facts in the alert. An investigator reviews and
-- edits it; the model does not make decisions.
-- Requires Cortex AI functions. If llama3.3-70b isn't available in your
-- region, swap in another model (for example 'claude-haiku-4-5'), or enable
-- cross-region inference.

CREATE OR REPLACE TABLE AML_CASE_SUMMARIES AS
SELECT
    alert_id, rule, risk_score, customer_id,
    AI_COMPLETE(
        'llama3.3-70b',
        'You are assisting an anti-money-laundering investigator. Using ONLY the facts below, '
        || 'write a neutral 3-sentence case summary: what happened, why it matched the rule, and '
        || 'what the investigator should review next. Do not speculate beyond the facts, do not '
        || 'conclude that a crime occurred, and do not invent names. '
        || 'Facts: rule=' || rule || '; risk_score=' || risk_score || '; customer=' || customer_id
        || '; segment=' || segment || '; kyc_risk=' || kyc_risk || '; account=' || account_id
        || '; detail=' || explanation || '.',
        {'temperature': 0, 'max_tokens': 220}
    )::STRING AS case_summary
FROM AML_ALERTS
QUALIFY ROW_NUMBER() OVER (ORDER BY risk_score DESC, alert_id) <= 5;

SELECT alert_id, rule, risk_score, case_summary FROM AML_CASE_SUMMARIES ORDER BY risk_score DESC, alert_id;

-- Suspend the Dynamic Table when you're done demoing
ALTER DYNAMIC TABLE AML_ALERTS SUSPEND;

-- [step:cleanup]
-- ============================================================================
-- STEP 13: CLEANUP (Optional - uncomment to remove demo objects)
-- ============================================================================

-- USE ROLE IDENTIFIER($demo_role);
-- DROP DATABASE IF EXISTS AML_DEMO_DB;    -- tables, views, Dynamic Table, policy
-- DROP WAREHOUSE IF EXISTS AML_WH;
-- DROP ROLE IF EXISTS AML_INVESTIGATOR_EAST;
-- DROP ROLE IF EXISTS AML_INVESTIGATOR_WEST;
-- DROP ROLE IF EXISTS AML_MANAGER;
-- UNSET (case_account, case_start, case_end, demo_role);
-- If you created the least-privilege role, an administrator removes it:
-- USE ROLE ACCOUNTADMIN;
-- DROP ROLE IF EXISTS AML_DEMO_ROLE;
