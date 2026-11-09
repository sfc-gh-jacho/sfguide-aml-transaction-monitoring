# AML Transaction Monitoring in Snowflake

**Owner:** Janet Cho · **Last reviewed:** November 2026 · **License:** [Apache 2.0](LICENSE)

A customer-facing, step-by-step guide to transparent, explainable anti-money-laundering detection in SQL:

- **Structuring**: cash deposits just under a reporting threshold
- **Rapid movement of funds**: pass-through accounts
- **Funnel accounts**: many senders, one large outbound wire
- **High-risk geography**: round-amount wires to high-risk-tier countries
- **Risk scoring** into an explainable, prioritized alert queue
- **A Dynamic Table** that re-scores alerts as new transactions arrive
- **Region-based investigator access** with a mapping-table row access policy
- **Optional Cortex `AI_COMPLETE`** case summaries that an investigator reviews

**Live guide:** https://sfc-gh-jacho.github.io/sfguide-aml-transaction-monitoring/

The site is fully static and doesn't connect to any Snowflake account. Its result tables come from a real end-to-end run of the script on synthetic data.

## Prerequisites

- **Enterprise Edition or higher** for the row access policy (Step 11). The rules and Dynamic Table work on any edition.
- **Cortex AI functions** for the optional Step 12. The script uses `llama3.3-70b`. Swap in another model if it isn't available in your region, or enable cross-region inference.
- **A role to run it.** ACCOUNTADMIN is simplest in a sandbox. For regulated environments, use the least-privilege option below.

### Least-privilege option (no ACCOUNTADMIN)

The script starts with `SET demo_role = 'ACCOUNTADMIN';`. To run without ACCOUNTADMIN, an administrator runs the commented block at the top of Step 1 once:

```sql
USE ROLE ACCOUNTADMIN;
CREATE ROLE IF NOT EXISTS AML_DEMO_ROLE;
GRANT CREATE DATABASE  ON ACCOUNT TO ROLE AML_DEMO_ROLE;
GRANT CREATE WAREHOUSE ON ACCOUNT TO ROLE AML_DEMO_ROLE;          -- or USAGE on an existing warehouse
GRANT CREATE ROLE      ON ACCOUNT TO ROLE AML_DEMO_ROLE;          -- investigator roles (Step 11)
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE AML_DEMO_ROLE;  -- AI_COMPLETE (Step 12 only)
GRANT ROLE AML_DEMO_ROLE TO USER <YOUR_USER>;
```

Then change the first line to `SET demo_role = 'AML_DEMO_ROLE';`. The role owns everything it creates, and the investigator roles are granted to it. This path was tested end to end and produced identical results.

## Run the demo in Snowsight

1. Download [`sql/aml_transaction_monitoring.sql`](sql/aml_transaction_monitoring.sql).
2. In Snowsight, open **Projects → Worksheets** and create a new SQL worksheet.
3. Paste the script and run it top to bottom in the same worksheet. Step 10 uses session variables. No find-and-replace is needed.
4. Step 12 suspends the Dynamic Table at the end. Keep it suspended, or drop it, when you're not demoing.
5. When you're done, uncomment and run Step 13 (Cleanup).

A full run takes a few minutes on an XSMALL warehouse. The optional AI step uses a few thousand tokens.

## What the run produces

- About 500,000 synthetic transactions over 90 days, with 12 planted typologies
- **12 alerts**: 4 structuring, 3 rapid movement, 2 funnel accounts, 3 high-risk geography, plus 1 more after the Dynamic Table demo adds new activity
- Region access: East investigators see 7 alerts, West 6, and the manager all 13

> **This is not a performance claim, and not regulatory guidance.** The 12 alerts are the 12 cases deliberately planted in synthetic data. Normal activity is generated so it can't trip any rule: cash deposits stay under $4,000, wires are at most $20,000, and international wires only go to low- or medium-risk countries. On real data these rules will produce false positives and need tuning, backtesting and model validation, as any monitoring program does. The thresholds are illustrative and jurisdiction-specific.

## What gets created

| Object | Name |
|---|---|
| Database | `AML_DEMO_DB` (schema `MONITORING`) |
| Warehouse | `AML_WH` (XSMALL, 60 s auto-suspend) |
| Tables | `AML_SETTINGS`, `AML_COUNTRY_RISK`, `AML_CUSTOMERS`, `AML_ACCOUNTS`, `AML_TRANSACTIONS`, `AML_REGION_ACCESS`, `AML_CASE_SUMMARIES` |
| Rule views | `AML_RULE_STRUCTURING`, `AML_RULE_RAPID`, `AML_RULE_FUNNEL`, `AML_RULE_GEO`, `AML_ALERT_QUEUE` |
| Dynamic Table | `AML_ALERTS` (1-minute target lag; suspended at the end of Step 12) |
| Row access policy and roles | `aml_region_policy`, `AML_INVESTIGATOR_EAST`, `AML_INVESTIGATOR_WEST`, `AML_MANAGER` |

## Customize with Cortex Code

[Cortex Code](https://docs.snowflake.com/en/user-guide/cortex-code/cortex-code) can adapt this guide to your own data. Open the repo folder in Cortex Code and try prompts like:

- "Map my transactions table to AML_TRANSACTIONS, run the four rules on last month's activity, and summarize the alert volumes by rule before creating anything permanent."
- "Set AML_SETTINGS to my jurisdiction's cash reporting threshold, then backtest the structuring rule over 90 days and show how alert volume changes at 5%, 10% and 15% bands."
- "Add a dormant-account-reactivation rule (no activity for 180 days, then large wires) with an explanation column, and include it in the risk score."

Ask it to review the plan with you before it creates or changes any objects in your account.

## Repository layout

```
LICENSE                              Apache License 2.0
vendor/prism/                        Prism.js (MIT), served locally
index.html                           Single-page guide
styles.css                           Styling (Snowflake palette)
script.js                            Loads SQL steps, Prism highlighting, copy buttons, results tables
sql/aml_transaction_monitoring.sql   Full demo script (split into steps by "-- [step:<id>]" markers)
data/sample_results.json             Results captured from a real run
```

To preview locally: `python3 -m http.server 8000`

## License

Licensed under the [Apache License, Version 2.0](LICENSE). Prism.js, used for syntax highlighting, is bundled in `vendor/prism/` under its own MIT license, so the pages make no third-party requests.

## Disclaimer

All customers, accounts, countries and transactions are synthetic. Customers are IDs only, and countries are coded (`CTRY_A`–`CTRY_L`), so no real jurisdiction is labeled high risk. The rules, thresholds and scores are illustrative and educational. They are not BSA/AML, FinCEN or any other regulatory guidance, and not a production transaction monitoring system. The repository contains no credentials, account identifiers or connection details.
