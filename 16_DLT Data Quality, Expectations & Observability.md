# 🗺️ LEARNING ROADMAP — DLT Data Quality, Expectations & Observability

> **Level: 🟡 Intermediate → 🔴 Advanced** — you know how to build pipelines, now you make them trustworthy

| Phase | Topic | Difficulty |
|-------|-------|-----------|
| 0 | **The Problem** — Why pipelines lie silently without quality checks | 🟢 Beginner |
| 1 | **What Are Expectations?** — The declarative quality layer | 🟡 Intermediate |
| 2 | **The 3 Actions** — Warn, Drop, Fail — when to use each | 🟡 Intermediate |
| 3 | **Writing Expectations in Code** — Decorators, dictionaries, patterns | 🟡 Intermediate |
| 4 | **Complex Scenarios** — Multi-rule, multi-dataset, joined views | 🔴 Advanced |
| 5 | **Monitoring & Observability** — Event logs, SQL queries, dashboards | 🔴 Advanced |

---

---

# 📖 PHASE 0 — The Problem: Pipelines That Lie Silently

## The Scenario Every Data Engineer Eventually Faces

You've built a beautiful pipeline. Bronze → Silver → Gold. Medallion architecture. SCD2. Autoloader. Everything runs green in the DAG.

Then one Monday morning, a business analyst opens their dashboard and says:

> *"Why are there orders with a negative price? Why do 3,000 customer records have no market segment? Our revenue report is off by £2 million."*

You check your pipeline. **It ran successfully. No errors. No failures.**

The bad data entered at Bronze, flowed through Silver, got aggregated into Gold, and contaminated your reports — silently, automatically, at scale.

---

## Why This Happens: The Garbage In, Garbage Out Problem

Your pipeline code says:

```python
@dlt.table(name="orders_silver")
def orders_silver():
    return dlt.read("orders_bronze").join(customers, ...)
```

This code has no opinion about data quality. It processes whatever arrives — valid rows, invalid rows, corrupted rows, test data accidentally pushed to production — all treated equally.

**This is the engineering gap Expectations fill.**

> Without expectations: your pipeline is a pipe — it moves whatever flows through it.
> With expectations: your pipeline is a filter — it enforces contracts about what's allowed through.

---

## The Contract Analogy

Think of your data pipeline as a supply chain. When a supplier ships you goods:
- You have a **contract** specifying what's acceptable (dimensions, weight, condition)
- Goods are **inspected on arrival**
- Violations are handled according to agreed terms: **log it, reject it, or halt the shipment**

Expectations are exactly this — a **data contract** enforced at pipeline runtime.

---

---

# 📖 PHASE 1 — What Are Expectations? 🔍

## Precise Definition

**Expectations** are declarative data quality rules attached to DLT datasets. They define:
1. **A condition** — what "valid" means for a column or row
2. **An action** — what to do when a row violates the condition

They run automatically on every row that flows through the decorated table or view, on every pipeline run.

---

## The Mental Model: Row-Level Validation Gate

```
Raw CDC / Streaming data arrives
         ↓
   ┌─────────────────────────────┐
   │   DLT EXPECTATION GATE      │
   │                             │
   │  Rule: order_status IN      │
   │        ['O', 'F', 'P']     │
   │                             │
   │  ✅ valid row  → passes     │
   │  ❌ invalid row → [action]  │
   └─────────────────────────────┘
         ↓
   Target table (Silver / Gold)
```

Every row is evaluated against every attached expectation. The action determines what happens to violating rows.

---

## Where Do Expectations Sit in the Medallion Architecture?

```
Bronze (raw, no quality rules — accept everything)
    ↓
  [EXPECTATIONS APPLIED HERE — Silver layer entry gate]
Silver (cleaned, quality-enforced data)
    ↓
Gold (aggregated from trusted Silver data)
```

**The engineering principle:** Let Bronze be the raw record of truth — no filtering. Apply quality gates at the Bronze → Silver transition. This way:
- You always have the original bad row in Bronze for debugging
- Silver and Gold only contain rows that passed your defined contracts
- You can re-derive Silver from Bronze after fixing quality rules

---

## 🗺️ Concept Connection Map — Expectations

```
Expectations (DLT Data Quality)
    ├── what → declarative row-level validation rules
    ├── where → attached to @dlt.table or @dlt.view decorators
    ├── when → evaluated on every row, every pipeline run
    ├── 3 actions → Warn / Drop / Fail
    ├── connects to → Medallion Architecture (Bronze→Silver quality gate)
    ├── contrasts with → no validation (silent bad data propagation)
    └── monitored via → DLT pipeline UI + event log SQL queries
```

---

---

# 📖 PHASE 2 — The 3 Actions: Warn, Drop, Fail ⚠️🗑️🛑

This is the most important decision you make when defining an expectation. The action determines how the pipeline responds to bad data. Each serves a different engineering purpose.

---

## Action 1: `warn` — Log and Continue (Default)

**Behavior:** Rows that fail the rule are **still written to the target table**. The violation is logged in the DLT event log and shown in the pipeline UI with a count.

**Mental model:** A speed camera that photographs you but lets you drive on.

```
10,000 rows arrive
    → 9,997 pass the expectation
    → 3 fail the expectation
    
Result: All 10,000 rows written to target table
        Event log records: "3 rows failed valid_order_status"
        Pipeline status: ✅ Success
```

**When to use it:**
- During development — you want to see what's failing without blocking the pipeline
- Rules where bad data is acceptable for now but you want visibility
- Monitoring for upstream data quality degradation (alerting, not blocking)
- When you own the pipeline but not the source — you can't block the flow, but you need to track violations

**When NOT to use it:**
- Rules where bad data would corrupt aggregations (use Drop or Fail instead)
- Regulatory compliance where bad data must never appear in outputs

---

## Action 2: `drop` — Silently Remove Bad Rows

**Behavior:** Rows that fail the rule are **excluded from the target table**. They simply don't make it through. The pipeline continues. The violation count is logged.

**Mental model:** A bouncer at a club — the person who doesn't meet the dress code is turned away, but the club stays open.

```
10,000 rows arrive
    → 9,997 pass the expectation
    → 3 fail the expectation

Result: 9,997 rows written to target table (3 silently removed)
        Event log records: "3 rows dropped by valid_order_status"
        Pipeline status: ✅ Success
```

**When to use it:**
- Rows that are genuinely invalid and should never reach analytics (test data, corrupted records)
- You want clean Silver/Gold without stopping the pipeline
- Upstream sends occasional bad rows you can't control

**When NOT to use it:**
- When dropped rows represent business-critical events (a dropped order could mean lost revenue tracking)
- When you need to audit or quarantine bad rows (consider a separate quarantine table instead)

---

## Action 3: `fail` — Stop Everything

**Behavior:** If **any** row fails the rule, the **entire pipeline run stops immediately** with an error. No data is written. The run is marked as Failed in the UI.

**Mental model:** A circuit breaker — if something's wrong, cut the power rather than let damage spread.

```
10,000 rows arrive
    → 9,997 pass the expectation
    → 3 fail the expectation

Result: PIPELINE STOPS. Zero rows written to target.
        Error log: "Pipeline failed: 3 rows violated valid_order_price"
        Pipeline status: ❌ Failed
        Downstream tables: NOT updated
```

**When to use it:**
- Rules where even one bad row invalidates the entire dataset (financial reconciliation, compliance reporting)
- Schema-level guarantees — if `order_key` is null, something is fundamentally broken upstream
- When bad data flowing downstream would be worse than no data at all
- SLAs where stale-but-clean data is preferable to fresh-but-dirty data

**When NOT to use it:**
- High-volume streaming pipelines where occasional bad rows are expected
- Rules that aren't truly critical — using `fail` for minor issues = unnecessary pipeline downtime

---

## The Decision Framework

```
Ask yourself: "What's the worst that happens if a bad row reaches Gold?"

│ Bad row is mildly annoying        → WARN   (visibility without blocking)
│ Bad row corrupts metrics          → DROP   (remove it, pipeline continues)
│ Bad row means something is        
│ fundamentally broken upstream     → FAIL   (stop, alert, investigate)
```

---

## Side-by-Side Comparison

| Property | warn | drop | fail |
|----------|------|------|------|
| Bad rows in target table? | ✅ Yes | ❌ No | ❌ No (nothing written) |
| Pipeline continues? | ✅ Yes | ✅ Yes | ❌ No — stops |
| Violations logged? | ✅ Yes | ✅ Yes | ✅ Yes (error log) |
| Use case | Monitoring | Cleaning | Hard guarantee |
| Downstream impact | Bad data flows through | Clean data flows through | Nothing flows through |

---

## ✅ Quick Quiz #1 — Actions

**Q1:** Your Gold table aggregates revenue by region. A bad row with `total_price = -500` would make your revenue appear lower than reality. Which action?
<details><summary>Answer</summary>Drop — remove invalid price rows before they corrupt the aggregation. The pipeline continues; the bad row doesn't reach Gold.</details>

**Q2:** Your pipeline processes payroll data. If any employee record is missing a salary, the entire payroll run should halt rather than pay some employees incorrectly. Which action?
<details><summary>Answer</summary>Fail — a missing salary is a fundamental data contract violation. Stopping the pipeline is safer than running partial payroll.</details>

**Q3:** You're onboarding a new upstream data source and want to understand how often their data violates your schema before deciding on a permanent action. Which action?
<details><summary>Answer</summary>Warn — observe violation counts across several runs without blocking the pipeline. Use the data to decide whether Drop or Fail is appropriate once you understand the pattern.</details>

---

---

# 📖 PHASE 3 — Writing Expectations in Code 💻

## The Two Decorator Patterns

DLT gives you two ways to attach expectations:

### Pattern 1: Single Rule — `@dlt.expect`

```python
@dlt.table(name="orders_silver")
@dlt.expect("valid_order_status", "order_status IN ('O', 'F', 'P')")
def orders_silver():
    return dlt.read("orders_bronze")
```

Clean and readable for one rule. But if you have 5 rules, you get 5 decorator lines stacked up — messy.

---

### Pattern 2: Multiple Rules — `@dlt.expect_all` with a Dictionary

```python
# Define rules separately — clean, reusable, easy to maintain
orders_quality_rules = {
    "valid_order_status": "order_status IN ('O', 'F', 'P')",
    "valid_order_price":  "total_price > 0",
    "order_key_not_null": "order_key IS NOT NULL"
}

@dlt.table(name="orders_silver")
@dlt.expect_all(orders_quality_rules)
def orders_silver():
    return dlt.read("orders_bronze")
```

**Why dictionaries are the engineering best practice:**
- Rules live separately from the function — change rules without touching transformation logic
- Same rule dictionary can be applied to multiple tables
- Easy to add/remove rules without restructuring the function
- Rules are self-documenting (the key is the rule name, the value is the condition)

---

## The Full Decorator Variants — with Actions

| Decorator | Action on Failure |
|-----------|------------------|
| `@dlt.expect("name", condition)` | warn (default) |
| `@dlt.expect_or_drop("name", condition)` | drop |
| `@dlt.expect_or_fail("name", condition)` | fail |
| `@dlt.expect_all(rules_dict)` | warn (all rules) |
| `@dlt.expect_all_or_drop(rules_dict)` | drop (any rule fails → row dropped) |
| `@dlt.expect_all_or_fail(rules_dict)` | fail (any rule fails → pipeline stops) |

---

## Full Production Code Example

```python
import dlt
from pyspark.sql.functions import col, current_timestamp, count, sum

# ── DEFINE QUALITY RULES AS DICTIONARIES ─────────────────────────────────────

orders_rules = {
    "valid_order_status": "order_status IN ('O', 'F', 'P')",
    "valid_order_price":  "total_price > 0",
    "order_key_not_null": "order_key IS NOT NULL"
}

customer_rules = {
    "valid_market_segment": "market_segment IS NOT NULL",
    "customer_key_not_null": "customer_key IS NOT NULL"
}

# ── BRONZE LAYER — no expectations (accept everything, raw record) ─────────────

@dlt.table(
    name="orders_bronze",
    table_properties={"quality": "bronze"}
)
def orders_bronze():
    return spark.readStream.table("dev.bronze.orders_raw")


@dlt.table(
    name="customer_bronze",
    table_properties={"quality": "bronze"}
)
def customer_bronze():
    return spark.read.table("dev.bronze.customer_raw")


# ── SILVER LAYER — expectations enforced here ─────────────────────────────────

@dlt.table(
    name="orders_silver",
    table_properties={"quality": "silver"}
)
@dlt.expect_all_or_drop(orders_rules)     # ← DROP rows violating any order rule
def orders_silver():
    return (
        dlt.read_stream("orders_bronze")
        .join(dlt.read("customer_bronze"), "customer_key", "left")
        .withColumn("insert_date", current_timestamp())
    )


@dlt.table(
    name="customer_silver",
    table_properties={"quality": "silver"}
)
@dlt.expect_all(customer_rules)           # ← WARN on customer rule violations
def customer_silver():
    return dlt.read("customer_bronze")


# ── GOLD LAYER — no expectations (Silver already cleaned) ─────────────────────

@dlt.table(name="orders_aggregated_gold")
def orders_aggregated_gold():
    return (
        dlt.read("orders_silver")
        .groupBy("market_segment")
        .agg(
            count("order_key").alias("count_orders"),
            sum("total_price").alias("sum_total_price")
        )
        .withColumn("insert_date", current_timestamp())
    )
```

---

## Why Expectations Rarely Go On Gold Tables

**The engineering logic:**
- Gold tables aggregate from Silver
- Silver has already been filtered/dropped/failed by expectations
- If Silver is clean, Gold is clean by construction
- Putting expectations on Gold = redundant double-checking
- Exception: if Gold has its own business rules independent of Silver (e.g., "aggregated revenue must be > 0")

---

## Mixed Actions on the Same Table

You can attach multiple expectation decorators with **different actions** to the same table:

```python
@dlt.table(name="orders_silver")
@dlt.expect_or_fail("order_key_not_null", "order_key IS NOT NULL")  # ← FAIL: null key = broken pipeline
@dlt.expect_or_drop("valid_order_price", "total_price > 0")          # ← DROP: negative price = bad row
@dlt.expect("valid_status", "order_status IN ('O','F','P')")          # ← WARN: unusual status = log it
def orders_silver():
    return dlt.read_stream("orders_bronze")
```

**Reading this like a data contract:**
- Missing `order_key`? This is catastrophic — stop everything.
- Negative price? Invalid — exclude it, but keep processing.
- Unusual status? Suspicious — log it, but don't block or remove.

---

## ✅ Quick Quiz #2 — Writing Expectations

**Q1:** You have 6 quality rules for a Silver table. Why is `@dlt.expect_all(rules_dict)` better than 6 separate `@dlt.expect` decorators?
<details><summary>Answer</summary>Rules defined as a dictionary are separated from transformation logic, reusable across tables, easier to add/remove without restructuring the function, and self-documenting via key names.</details>

**Q2:** Write the decorator for: "if ANY row has a null `customer_id`, drop that row — but the pipeline should continue."
<details><summary>Answer</summary>`@dlt.expect_or_drop("customer_id_not_null", "customer_id IS NOT NULL")`</details>

**Q3:** What is `@dlt.expect_all_or_fail(rules_dict)` doing when any single row violates any single rule?
<details><summary>Answer</summary>The entire pipeline run stops immediately. No rows are written to the target table. The violation is logged in the event log with which rule was violated.</details>

---

---

# 📖 PHASE 4 — Complex Scenarios 🔧

## Scenario 1: Expectations on Views (Intermediate Steps)

Expectations can be placed on `@dlt.view` as well as `@dlt.table`. This matters when you want to validate before a join:

```python
# Validate orders BEFORE the join — catch bad rows early
@dlt.view
@dlt.expect_or_drop("valid_order_status", "order_status IN ('O', 'F', 'P')")
def orders_validated_view():
    return dlt.read_stream("orders_bronze")

# Now join the already-validated view
@dlt.table(name="orders_silver")
def orders_silver():
    return (
        dlt.read("orders_validated_view")     # ← already filtered
        .join(dlt.read("customer_bronze"), "customer_key", "left")
    )
```

**Why validate before a join?**
A bad row in a join can produce unexpected results — especially with outer joins, where a bad `customer_key` might match no customer and produce nulls in Silver. Better to drop the bad row before the join than after.

---

## Scenario 2: What Happens to Violation Counts After a Join?

This is a subtle but important concept.

**Setup:**
- `orders_bronze` has 10,000 rows, 3 with invalid status
- `customer_bronze` has 1,000 customers
- Expectation is on the joined Silver table

**The join amplification effect:**
If you apply expectations after a join, the violation count in the UI reflects rows in the joined output — not just the source. A single bad order row that joins to 5 customers would appear as 5 violations. This can make violation counts misleading.

**Best practice:** Apply expectations as early as possible — ideally before joins — to keep violation counts clean and traceable.

---

## Scenario 3: Rules That Reference Multiple Columns

Expectations support any valid SQL expression:

```python
rules = {
    # Single column check
    "price_positive":          "total_price > 0",

    # Multi-column logical rule
    "end_after_start":         "end_date > start_date OR end_date IS NULL",

    # Compound condition
    "valid_fulfilled_order":   "order_status != 'F' OR total_price > 0",
    # Logic: if status is Fulfilled, price must be positive
    # (open orders can have 0 price, fulfilled ones cannot)

    # NOT NULL check
    "key_not_null":            "order_key IS NOT NULL",

    # Range check
    "reasonable_price":        "total_price BETWEEN 0.01 AND 1000000"
}
```

Any SQL `WHERE` clause condition is valid as an expectation rule. If the condition evaluates to `TRUE` → row passes. `FALSE` or `NULL` → row fails.

---

## ⚠️ The NULL Trap in Expectations

**Critical engineering detail:** A condition that evaluates to `NULL` is treated as a **failure**.

```python
# Example:
"valid_price": "total_price > 0"

# If total_price IS NULL:
#   NULL > 0 = NULL (not TRUE)
#   → row FAILS the expectation
```

This means if you want to **allow nulls** in a non-critical column:

```python
# Explicitly allow nulls:
"valid_price_if_present": "total_price IS NULL OR total_price > 0"
# → passes if null (we allow it) OR if positive (valid value)
```

Always be explicit about your null handling in expectations.

---

## ✅ Quick Quiz #3 — Complex Scenarios

**Q1:** You have an expectation on a Silver table after a join. Your violation count shows 50 failures, but you only see 10 bad rows in Bronze. What likely happened?
<details><summary>Answer</summary>Join amplification — each of the 10 bad Bronze rows matched multiple rows in the joined table, multiplying the violation count. Apply expectations before the join to get clean, traceable counts.</details>

**Q2:** Write a rule that allows `discount_percentage` to be NULL (not yet calculated) but if present, must be between 0 and 100.
<details><summary>Answer</summary>`"valid_discount": "discount_percentage IS NULL OR (discount_percentage >= 0 AND discount_percentage <= 100)"`</details>

**Q3:** An expectation condition is `total_price > 0`. A row arrives with `total_price = NULL`. Does it pass or fail?
<details><summary>Answer</summary>Fails — `NULL > 0` evaluates to `NULL`, which is not `TRUE`. DLT treats NULL evaluation as a failure.</details>

---

---

# 📖 PHASE 5 — Monitoring & Observability 📊

## Why Observability Is As Important As The Rules Themselves

Setting up expectations is the first half. The second half is knowing:
- Which rules are failing right now?
- How many rows failed yesterday vs. today?
- Is the violation rate increasing (upstream data degrading)?
- Which pipeline run introduced failures?

Without observability, your expectations are silent. With it, they become a **data quality monitoring system**.

---

## The DLT Pipeline UI — First Line of Observability

When a pipeline runs with expectations, the UI shows for each dataset:

```
┌─────────────────────────────────────────────────────┐
│ orders_silver                                        │
│                                                      │
│ Records written:     9,997                           │
│                                                      │
│ Expectations:                                        │
│   valid_order_status    ⚠️ 2 records failed          │
│   valid_order_price     ⚠️ 1 record failed           │
│   order_key_not_null    ✅ 0 failures                │
└─────────────────────────────────────────────────────┘
```

This gives you **per-rule, per-run failure counts** at a glance. But it's ephemeral — you can't query it programmatically or trend it over time from the UI alone.

---

## The Event Log — Your Persistent Audit Trail

DLT automatically writes a **structured event log** to a Delta table for every pipeline run. This log captures:
- Pipeline start/end events
- Cluster provisioning events
- Expectation violations (per rule, per run, with counts)
- Errors and stack traces

**Where is the event log?**
```python
# The event log is stored in a system table — access via:
event_log_path = f"/pipelines/{pipeline_id}/system/events"

# Or in Unity Catalog:
# dev.etl.<pipeline_name>.system.events
```

---

## Querying the Event Log — Practical SQL Patterns

### Step 1: Create a Base View Over the Event Log

```sql
-- Run this once to create a reusable view
CREATE OR REPLACE TEMP VIEW event_log_raw AS
SELECT * FROM delta.`/pipelines/{your_pipeline_id}/system/events`;
```

---

### Step 2: Find the Latest Pipeline Update ID

```sql
-- Each pipeline run creates an "update" — get the most recent one
CREATE OR REPLACE TEMP VIEW latest_update AS
SELECT origin.update_id
FROM event_log_raw
WHERE event_type = 'create_update'   -- marks the start of a run
ORDER BY timestamp DESC
LIMIT 1;
```

---

### Step 3: Query Data Quality Failures for the Latest Run

```sql
-- Extract expectation violation details from the event log
SELECT
    timestamp,
    origin.flow_name                                          AS dataset_name,
    details:flow_progress:data_quality:dropped_records        AS rows_dropped,
    explode(
        from_json(
            details:flow_progress:data_quality:expectations,
            'ARRAY<STRUCT<name STRING, failed_records BIGINT, passed_records BIGINT>>'
        )
    )                                                         AS expectation_detail
FROM event_log_raw
WHERE event_type = 'flow_progress'
  AND origin.update_id = (SELECT update_id FROM latest_update)
  AND details:flow_progress:status = 'COMPLETED'
ORDER BY timestamp DESC;
```

**What this returns:**
```
dataset_name    | rows_dropped | expectation_detail.name      | failed | passed
----------------|--------------|------------------------------|--------|-------
orders_silver   | 3            | valid_order_status            | 2      | 9998
orders_silver   | 3            | valid_order_price             | 1      | 9999
customer_silver | 0            | valid_market_segment          | 0      | 1000
```

---

### Step 4: Trend Analysis Across Multiple Runs

```sql
-- Are violations increasing over time? (data quality trend)
SELECT
    DATE(timestamp)                                           AS run_date,
    origin.flow_name                                          AS dataset,
    SUM(details:flow_progress:data_quality:dropped_records)   AS total_dropped,
    COUNT(DISTINCT origin.update_id)                          AS pipeline_runs
FROM event_log_raw
WHERE event_type = 'flow_progress'
  AND details:flow_progress:status = 'COMPLETED'
GROUP BY run_date, dataset
ORDER BY run_date DESC;
```

This query shows you if your violation rate is growing — a signal that upstream data quality is degrading.

---

### Step 5: Build a Monitoring Dashboard

Once you have these SQL queries, you can:
1. Save them as Databricks SQL queries
2. Schedule them to refresh automatically
3. Pin results to a Databricks Dashboard
4. Set up alerts: "if `total_dropped > 1000`, send a Slack notification"

This transforms DLT expectations from passive rules into an **active data quality monitoring system**.

---

## The Observability Architecture

```
DLT Pipeline Runs
        ↓
Event Log (Delta table — auto-written by DLT)
        ↓
SQL Queries (extract expectation violation details)
        ↓
    ┌───────────────┬────────────────────────────┐
    ↓               ↓                            ↓
Run-level       Trend analysis            Alert if
violation       (violations growing?)     threshold exceeded
counts          
    ↓               ↓                            ↓
        Databricks SQL Dashboard + Slack/Email Alerts
```

---

## ✅ Quick Quiz #4 — Monitoring & Observability

**Q1:** The DLT pipeline UI shows 5 violation counts for `valid_order_status` after today's run. You need to check if this is worse than yesterday. Where do you look?
<details><summary>Answer</summary>The event log Delta table — query it across multiple `update_id` values (pipeline runs) to trend violation counts over time. The UI only shows the current run.</details>

**Q2:** You query the event log and see `dropped_records = 0` for a rule but `failed_records = 50`. What action is this expectation configured with?
<details><summary>Answer</summary>Warn — rows failed the rule (50 failures logged) but were not dropped (0 dropped). With `drop`, `dropped_records` would equal `failed_records`.</details>

**Q3:** Why do you create a `latest_update` view before querying quality failures?
<details><summary>Answer</summary>Each pipeline run creates a new `update_id`. Without filtering to the latest, your query returns violations from ALL historical runs mixed together — making it impossible to analyze a specific run's quality.</details>

---

---

# 📖 Full Production Pattern — Putting It All Together

```python
import dlt
from pyspark.sql.functions import current_timestamp, count, sum

# ─── QUALITY RULE DICTIONARIES ─────────────────────────────────────────────────
# Defined once, reused across tables — single source of truth for quality contracts

orders_drop_rules = {                               # Violations → row dropped
    "valid_order_status": "order_status IN ('O', 'F', 'P')",
    "valid_order_price":  "total_price > 0"
}

orders_fail_rules = {                               # Violations → pipeline stops
    "order_key_not_null": "order_key IS NOT NULL"
}

customer_warn_rules = {                             # Violations → logged only
    "valid_market_segment": "market_segment IS NOT NULL"
}


# ─── BRONZE — no rules ─────────────────────────────────────────────────────────
@dlt.table(name="orders_bronze", table_properties={"quality": "bronze"})
def orders_bronze():
    return spark.readStream.table("dev.bronze.orders_raw")

@dlt.table(name="customer_bronze", table_properties={"quality": "bronze"})
def customer_bronze():
    return spark.read.table("dev.bronze.customer_raw")


# ─── SILVER — all quality gates here ──────────────────────────────────────────
@dlt.table(name="orders_silver", table_properties={"quality": "silver"})
@dlt.expect_all_or_fail(orders_fail_rules)          # ← hardest rule first
@dlt.expect_all_or_drop(orders_drop_rules)          # ← drop invalid rows
def orders_silver():
    return (
        dlt.read_stream("orders_bronze")
        .join(dlt.read("customer_bronze"), "customer_key", "left")
        .withColumn("insert_date", current_timestamp())
    )

@dlt.table(name="customer_silver", table_properties={"quality": "silver"})
@dlt.expect_all(customer_warn_rules)                # ← warn only
def customer_silver():
    return dlt.read("customer_bronze")


# ─── GOLD — aggregates from clean Silver ────────────────────────────────────
@dlt.table(name="orders_aggregated_gold")
def orders_aggregated_gold():
    return (
        dlt.read("orders_silver")
        .groupBy("market_segment")
        .agg(
            count("order_key").alias("count_orders"),
            sum("total_price").alias("sum_total_price")
        )
        .withColumn("insert_date", current_timestamp())
    )
```

---

# 🗺️ Master Concept Connection Map — Full Session

```
DLT Data Quality & Observability
    │
    ├── Expectations
    │     ├── what → declarative row-level validation rules
    │     ├── 3 actions → warn / drop / fail
    │     ├── syntax → @dlt.expect / @dlt.expect_all / *_or_drop / *_or_fail
    │     ├── best practice → define rules as dict, apply at Bronze→Silver gate
    │     ├── NULL trap → NULL evaluation = failure (be explicit about nulls)
    │     └── apply before joins → avoids amplified violation counts
    │
    ├── Actions Decision Framework
    │     ├── warn → visibility without blocking (monitoring, development)
    │     ├── drop → remove bad rows, pipeline continues (cleaning)
    │     └── fail → stop everything, data contract violated (compliance)
    │
    └── Observability
          ├── DLT UI → per-rule violation counts, current run only
          ├── Event log → persistent Delta table, all runs, queryable
          ├── SQL patterns → latest_update view → violation details → trends
          └── Dashboard → schedule queries → alert on threshold breach
```

---

# 📝 Active Recall Prompts — Spaced Repetition

### 🔁 Day 1
- *"Explain the 3 expectation actions to a business stakeholder. What does each one mean for their data?"*
- *"Why do expectations almost never go on Bronze tables? What's the engineering principle?"*
- *"What's the difference between `@dlt.expect_all_or_drop` and `@dlt.expect_or_drop`? When does each make sense?"*

### 🔁 Day 3
- *"A rule condition is `total_price > 0`. A row arrives with `total_price = NULL`. Walk through exactly what DLT does — does it pass or fail? What action triggers?"*
- *"You have 3 rules: one that should fail the pipeline, one that should drop rows, one that should just warn. Write the full decorator stack for a Silver table."*
- *"Explain how you'd query the event log to build a weekly data quality report showing violation trends per table, per rule."*

### 🔁 Day 7
- *"Full system design: An e-commerce platform has orders arriving via Autoloader (CSV) and CDC from PostgreSQL. Design the complete quality layer: which rules go where, which actions, what monitoring SQL queries would you schedule, and what alerts would you configure. Justify every decision."*
- *"A colleague says: 'I put expectations on every layer — Bronze, Silver, and Gold.' What's wrong with this, and how would you refactor it?"*

---

# 🚀 What's Next

You've now completed the full DLT track. The natural senior-engineer progression:

| Topic | Why It Follows Naturally |
|-------|-------------------------|
| **Unity Catalog — Row-Level Security & Column Masking** | You now have clean, quality-enforced data — now control WHO can see what columns/rows |
| **Delta Lake Optimization — OPTIMIZE, ZORDER, VACUUM** | Your tables grow with every pipeline run — learn to keep them fast and cheap |
| **Databricks Workflows — Orchestrating DLT + dbt + Python** | Production pipelines mix DLT with other tools — orchestrate them together |
| **Cost Management on Azure Databricks** | Every compute decision you've made has a cost — learn to read and optimize your Azure spend |

You've gone from raw files and streams, through Medallion Architecture, SCD2, CDC, Append Flow — all the way to declarative data contracts with full observability. That's a complete, production-grade data engineering skillset. 🎯
