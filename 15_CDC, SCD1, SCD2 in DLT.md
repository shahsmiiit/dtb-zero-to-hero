# 🗺️ LEARNING ROADMAP — CDC, SCD1, SCD2 in DLT

> **Level: 🔴 Advanced** — this is where junior and senior engineers diverge

| Phase | Topic | Difficulty |
|-------|-------|-----------|
| 0 | **The Real World Problem** — Databases change. How do you track that? | 🟡 Intermediate |
| 1 | **CDC** — Change Data Capture, from first principles | 🟡 Intermediate |
| 2 | **SCD1** — Overwrite. Simple but lossy. | 🟡 Intermediate |
| 3 | **SCD2** — Full history. The gold standard. | 🔴 Advanced |
| 4 | **DLT's `APPLY CHANGES INTO`** — The declarative CDC engine | 🔴 Advanced |
| 5 | **Backloading** — Seeding an SCD2 table with historical data | 🔴 Advanced |
| 6 | **Delete & Truncate** — Handling hard deletes in SCD tables | 🔴 Advanced |

---

---

# 📖 PHASE 0 — The Real World Problem

## Everything You've Built Assumes One Thing: Data Only Arrives

Every pipeline you've built so far handles **appends** — new rows arriving, new files landing. Your streaming tables read new rows. Your checkpoints track new offsets.

But the real world doesn't only append. It **changes**.

---

## The Scenario: A Customer Database

Your company has a `customers` table in a production PostgreSQL database:

```
customer_id | name          | email                | city        | plan
------------|---------------|----------------------|-------------|-------
1001        | Alice Kumar   | alice@email.com      | Mumbai      | Free
1002        | Bob Chen      | bob@email.com        | Delhi       | Pro
1003        | Sarah Ahmed   | sarah@email.com      | Bangalore   | Free
```

Over the next week, real things happen:

```
Day 2: Alice upgrades from Free → Pro
Day 3: Bob moves from Delhi → Chennai
Day 4: Sarah cancels and her record is DELETED
Day 5: New customer David joins
```

**Your analytics team's questions:**
- "What plan is Alice on right now?" → current state
- "What plan was Alice on last month?" → historical state
- "When did Bob change cities?" → change history
- "How many customers deleted their accounts this quarter?" → delete tracking

A simple append-only pipeline **cannot answer any of the historical questions**. You need a strategy for handling **changes to existing records**.

> This is the problem that CDC, SCD1, and SCD2 solve. Each is a different answer to the same question.

---

---

# 📖 PHASE 1 — CDC: Change Data Capture 📡

## What Is CDC? (First Principles)

**Change Data Capture** is a technique for capturing every change that happens in a source database — every INSERT, UPDATE, and DELETE — and streaming those changes downstream.

Think of it as a **transaction log reader**. Every database maintains an internal log of every operation (this is how crash recovery works). CDC reads that log and publishes changes as events.

---

## What a CDC Event Looks Like

Instead of receiving the full updated table, you receive a **stream of change events**:

```
┌──────────────┬─────────────┬────────────────────────────────────────────────────────┐
│ operation    │ timestamp   │ data                                                    │
├──────────────┼─────────────┼────────────────────────────────────────────────────────┤
│ INSERT       │ Day 1 09:00 │ {id:1001, name:Alice, city:Mumbai, plan:Free}           │
│ INSERT       │ Day 1 09:01 │ {id:1002, name:Bob, city:Delhi, plan:Pro}               │
│ INSERT       │ Day 1 09:02 │ {id:1003, name:Sarah, city:Bangalore, plan:Free}        │
│ UPDATE       │ Day 2 14:30 │ {id:1001, name:Alice, city:Mumbai, plan:Pro}  ← plan ↑ │
│ UPDATE       │ Day 3 11:00 │ {id:1002, name:Bob, city:Chennai, plan:Pro}  ← city ↑  │
│ DELETE       │ Day 4 16:00 │ {id:1003, name:Sarah}                                  │
│ INSERT       │ Day 5 10:00 │ {id:1004, name:David, city:Pune, plan:Free}             │
└──────────────┴─────────────┴────────────────────────────────────────────────────────┘
```

This stream lands in your Bronze layer. Now you need to decide: **what do you build from it?**

Two answers: **SCD Type 1** or **SCD Type 2**.

---

## 🗺️ Concept Connection Map — CDC

```
CDC (Change Data Capture)
    ├── reads from → database transaction log (PostgreSQL WAL, MySQL binlog)
    ├── captures → INSERT, UPDATE, DELETE events with timestamps
    ├── lands in → Bronze layer as a stream of change events
    ├── connects to → Autoloader / Kafka (delivery mechanism for CDC events)
    ├── prerequisite for → SCD1 and SCD2 processing
    └── contrasts with → full table snapshot (inefficient, no history)
```

---

---

# 📖 PHASE 2 — SCD Type 1: The Simple Overwrite 🔄

## SCD = Slowly Changing Dimension

**Slowly Changing Dimension (SCD)** is a data warehousing concept for handling records that change infrequently (not every second — hence "slowly"). The "Dimension" part comes from data warehouse terminology (dimension tables store descriptive attributes — customers, products, employees).

The core question: **When a record changes, what do you do?**

**SCD Type 1 answer: Overwrite. Forget the old value.**

---

## How SCD1 Works

Starting state:
```
customer_id | name  | city   | plan
------------|-------|--------|-----
1001        | Alice | Mumbai | Free
```

CDC event arrives: Alice upgraded to Pro.

SCD1 result:
```
customer_id | name  | city   | plan
------------|-------|--------|-----
1001        | Alice | Mumbai | Pro   ← overwritten
```

The old `Free` value is **gone forever**.

---

## When SCD1 Is Appropriate

| Use Case | SCD1 Appropriate? |
|----------|------------------|
| Correcting a typo in a name | ✅ Yes — old typo has no value |
| Tracking current email address | ✅ Yes — you only need the latest |
| Tracking subscription plan history | ❌ No — you'd lose when they upgraded |
| Compliance auditing | ❌ No — you need the full history |
| Current inventory levels | ✅ Yes — only latest count matters |

**Rule of thumb:** SCD1 when history has no business value. SCD2 when history matters.

---

## SCD1 in DLT: `APPLY CHANGES INTO`

DLT provides a declarative CDC processor called `APPLY CHANGES INTO`. For SCD1:

```python
import dlt
from pyspark.sql.functions import col

# Step 1: Bronze — land the raw CDC events
@dlt.table(name="customers_cdc_bronze")
def customers_cdc_bronze():
    return (
        spark.readStream
            .format("cloudFiles")
            .option("cloudFiles.format", "json")
            .option("cloudFiles.schemaLocation", "/Volumes/dev/etl/landing/cdc_schemas/")
            .load("/Volumes/dev/etl/landing/cdc_events/")
    )

# Step 2: Apply SCD1 — UPSERT (update or insert, no history)
dlt.apply_changes(
    target        = "customers_silver_scd1",    # ← table to write into
    source        = "customers_cdc_bronze",      # ← stream of CDC events
    keys          = ["customer_id"],             # ← what identifies a unique record
    sequence_by   = col("cdc_timestamp"),        # ← order events by time (most recent wins)
    apply_as_deletes = col("operation") == "DELETE",  # ← DELETE events remove rows
    except_column_list = ["operation", "cdc_timestamp"]  # ← don't store these meta columns
)
```

**What `apply_changes` does under the hood:**
- `INSERT` event → inserts new row
- `UPDATE` event → finds existing row by `key`, overwrites with new values
- `DELETE` event → removes the row
- If two events arrive out of order → `sequence_by` ensures the most recent value wins

---

## The `sequence_by` Field — Why It's Critical

CDC events can arrive **out of order** (network delays, batch processing). Without `sequence_by`, you might apply an older event on top of a newer one:

```
Events arriving:
    10:05 UPDATE → plan = Pro      ← arrives FIRST (out of order)
    10:03 UPDATE → plan = Free     ← arrives SECOND

Without sequence_by:  result = Free  ← WRONG (older event applied last)
With sequence_by:     result = Pro   ← CORRECT (latest timestamp wins)
```

Always set `sequence_by` to the event timestamp from your source system.

---

## ✅ Quick Quiz #1 — CDC & SCD1

**Q1:** A customer's email address has a typo — it was stored as `alce@email.com` instead of `alice@email.com`. The correction arrives as a CDC UPDATE event. Should you use SCD1 or SCD2?
<details><summary>Answer</summary>SCD1 — this is a data correction, not a meaningful business change. The old typo has no value. Overwrite it.</details>

**Q2:** Two CDC UPDATE events arrive: at 14:00 (plan→Pro) and at 13:45 (plan→Free), but they arrive in reverse order. Which value does `sequence_by = col("cdc_timestamp")` preserve?
<details><summary>Answer</summary>Pro — the 14:00 event has the later timestamp, so it wins regardless of arrival order.</details>

**Q3:** What is the `keys` parameter in `apply_changes` used for?
<details><summary>Answer</summary>It identifies which column(s) uniquely identify a record. DLT uses this to know which existing row to UPDATE or DELETE when a change event arrives.</details>

---

---

# 📖 PHASE 3 — SCD Type 2: Full History 📚

## The Insight: Sometimes The Past IS The Data

SCD2's philosophy is different: **every version of a record is valuable**. When Alice upgrades from Free to Pro, you want to know:
- She was on Free from Day 1 to Day 2
- She's been on Pro from Day 2 onwards

**SCD Type 2 answer: Never overwrite. Close the old row. Create a new row.**

---

## How SCD2 Works — Step by Step

### Initial State (Day 1 — Alice joins)
```
customer_id | name  | plan | start_date | end_date   | is_current
------------|-------|------|------------|------------|----------
1001        | Alice | Free | 2024-01-01 | NULL       | TRUE
```

- `start_date` = when this version became active
- `end_date` = NULL means "still current"
- `is_current` = TRUE means "this is the latest version"

---

### Day 2 — Alice upgrades to Pro (UPDATE CDC event arrives)

SCD2 does two things atomically:
1. **Close the old row** — set `end_date` = today, `is_current` = FALSE
2. **Insert a new row** — the new version, with `start_date` = today

```
customer_id | name  | plan | start_date | end_date   | is_current
------------|-------|------|------------|------------|----------
1001        | Alice | Free | 2024-01-01 | 2024-01-02 | FALSE  ← closed
1001        | Alice | Pro  | 2024-01-02 | NULL       | TRUE   ← new current
```

Both rows exist. History is preserved.

---

### Day 3 — Bob changes city (UPDATE event arrives)

```
customer_id | name | plan | city    | start_date | end_date   | is_current
------------|------|------|---------|------------|------------|----------
1002        | Bob  | Pro  | Delhi   | 2024-01-01 | 2024-01-03 | FALSE  ← closed
1002        | Bob  | Pro  | Chennai | 2024-01-03 | NULL       | TRUE   ← new current
```

---

### Now You Can Answer Any Question

```sql
-- Current state of all customers
SELECT * FROM customers_silver_scd2 WHERE is_current = TRUE

-- What plan was Alice on January 15th?
SELECT * FROM customers_silver_scd2
WHERE customer_id = 1001
  AND start_date <= '2024-01-15'
  AND (end_date > '2024-01-15' OR end_date IS NULL)

-- Full history of Bob's city changes
SELECT city, start_date, end_date
FROM customers_silver_scd2
WHERE customer_id = 1002
ORDER BY start_date
```

**SCD1 can answer 0 of these historical questions. SCD2 can answer all of them.**

---

## SCD2 in DLT: `APPLY CHANGES INTO` with `stored_as_scd_type`

```python
import dlt
from pyspark.sql.functions import col

# Bronze CDC events (same as before)
@dlt.table(name="customers_cdc_bronze")
def customers_cdc_bronze():
    return (
        spark.readStream
            .format("cloudFiles")
            .option("cloudFiles.format", "json")
            .option("cloudFiles.schemaLocation", "/Volumes/dev/etl/landing/cdc_schemas/")
            .load("/Volumes/dev/etl/landing/cdc_events/")
    )

# SCD2 Silver — full history table
dlt.apply_changes(
    target        = "customers_silver_scd2",
    source        = "customers_cdc_bronze",
    keys          = ["customer_id"],
    sequence_by   = col("cdc_timestamp"),
    apply_as_deletes = col("operation") == "DELETE",
    except_column_list = ["operation", "cdc_timestamp"],
    stored_as_scd_type = 2              # ← THIS is what turns it into SCD2
)
```

**One parameter difference from SCD1:** `stored_as_scd_type = 2`

DLT automatically manages:
- `__START_AT` — when this version became active (based on `sequence_by`)
- `__END_AT` — when this version was closed (NULL = current)
- The close-old / insert-new logic for every UPDATE event

---

## SCD1 vs SCD2 Side-by-Side

| Property | SCD1 | SCD2 |
|----------|------|------|
| **History kept?** | ❌ No — overwrites | ✅ Yes — full version history |
| **Row count grows?** | No (1 row per key) | Yes (N rows per key over time) |
| **Can answer "what was X on date Y?"** | ❌ No | ✅ Yes |
| **Storage cost** | Lower | Higher |
| **Complexity** | Simple | Higher |
| **DLT parameter** | `stored_as_scd_type = 1` (default) | `stored_as_scd_type = 2` |
| **Use for** | Corrections, current-only lookups | Auditing, compliance, time-travel analytics |

---

## 🗺️ Concept Connection Map — SCD1 vs SCD2

```
APPLY CHANGES INTO (DLT's CDC engine)
    ├── keys → identifies unique records
    ├── sequence_by → ensures correct ordering of out-of-order events
    ├── apply_as_deletes → which operation column value = DELETE
    ├── except_column_list → metadata columns to exclude from target table
    │
    ├── stored_as_scd_type = 1
    │     ├── behavior → UPSERT (insert or overwrite)
    │     ├── history → NONE (old values lost)
    │     └── use for → corrections, current-only lookups
    │
    └── stored_as_scd_type = 2
          ├── behavior → close old row + insert new row
          ├── history → FULL (every version preserved)
          ├── DLT adds → __START_AT, __END_AT columns automatically
          └── use for → auditing, compliance, time-travel analytics
```

---

## ✅ Quick Quiz #2 — SCD1 vs SCD2

**Q1:** Your company's legal team needs to prove what data they held about each customer at any point in time (GDPR compliance). SCD1 or SCD2?
<details><summary>Answer</summary>SCD2 — only SCD2 preserves the full version history. SCD1 would overwrite old values, making compliance auditing impossible.</details>

**Q2:** Alice has been a customer for 3 years and changed plans 8 times. How many rows does she have in an SCD1 table vs an SCD2 table?
<details><summary>Answer</summary>SCD1: 1 row (always the latest). SCD2: 9 rows (1 initial + 8 changes = 9 versions).</details>

**Q3:** In an SCD2 table, what does `__END_AT = NULL` mean?
<details><summary>Answer</summary>This is the current active version of the record — it hasn't been closed/superseded yet.</details>

**Q4:** Which DLT parameter is the only meaningful difference between an SCD1 and SCD2 `apply_changes` call?
<details><summary>Answer</summary>`stored_as_scd_type = 1` vs `stored_as_scd_type = 2`.</details>

---

---

# 📖 PHASE 4 — DLT's `APPLY CHANGES INTO` In Depth ⚙️

## The Full Anatomy

```python
dlt.apply_changes(
    target             = "target_table_name",      # WHERE to write
    source             = "source_cdc_stream",       # WHERE CDC events come from
    keys               = ["col1", "col2"],          # WHAT identifies a unique record
    sequence_by        = col("event_timestamp"),    # HOW to order events (latest wins)
    apply_as_deletes   = col("op") == "D",          # WHICH events mean DELETE
    apply_as_truncates = col("op") == "T",          # WHICH events mean TRUNCATE ALL
    except_column_list = ["op", "event_timestamp"], # WHICH columns to EXCLUDE from target
    stored_as_scd_type = 2                          # SCD1 or SCD2
)
```

---

## The `apply_as_truncates` Parameter

This is a special operation worth its own explanation.

**Scenario:** Your source system sends a `TRUNCATE` event — meaning "delete ALL records in this table." This is different from individual DELETE events.

```python
apply_as_truncates = col("operation") == "TRUNCATE"
```

When DLT sees this:
- **SCD1:** Deletes ALL rows from the target table
- **SCD2:** Closes ALL current rows (sets `__END_AT` to the truncate timestamp)

**When does this happen in practice?**
- Source system does a full rebuild (wipe + reload)
- Compliance-driven data erasure ("right to be forgotten" for all records)
- End-of-period resets (close all open records at year-end)

---

## The `except_column_list` Parameter — What To Exclude

Your CDC events contain **metadata columns** that aren't part of the actual data:

```json
{
    "customer_id": 1001,
    "name": "Alice",
    "plan": "Pro",
    "operation": "UPDATE",        ← metadata
    "cdc_timestamp": "2024-01-02" ← metadata
}
```

You don't want `operation` and `cdc_timestamp` stored in your Silver table — they're control fields. `except_column_list` excludes them:

```python
except_column_list = ["operation", "cdc_timestamp"]
```

Result in Silver:
```
customer_id | name  | plan | __START_AT  | __END_AT
------------|-------|------|-------------|----------
1001        | Alice | Pro  | 2024-01-02  | NULL
```

Clean. No control columns leaking into analytics tables.

---

## The Target Table: Must Be a Streaming Table

**Critical constraint:** The `target` of `apply_changes` must be declared as a **Streaming Table** (not a Materialized View). DLT enforces this because:

- SCD tables receive incremental updates (new CDC events → new/updated rows)
- Streaming Tables support this incremental write pattern
- Materialized Views would recompute from scratch — wrong for CDC

```python
# CORRECT pattern:
@dlt.table(name="customers_silver_scd2")   # ← declare the target
def customers_silver_scd2():
    pass   # ← empty — apply_changes will write into this

dlt.apply_changes(
    target = "customers_silver_scd2",       # ← same name
    ...
)
```

Same empty-shell pattern as Append Flow — declare the container, then wire the writer.

---

## ✅ Quick Quiz #3 — APPLY CHANGES INTO

**Q1:** Your CDC stream has a column `op` with values `"I"` (insert), `"U"` (update), `"D"` (delete). Write the `apply_as_deletes` parameter.
<details><summary>Answer</summary>`apply_as_deletes = col("op") == "D"`</details>

**Q2:** Why must the target of `apply_changes` be a Streaming Table and not a Materialized View?
<details><summary>Answer</summary>SCD tables are built incrementally — CDC events arrive continuously and each run appends/modifies rows. Materialized Views recompute entirely from scratch each run, which is wrong for CDC (you'd lose all history on every run).</details>

**Q3:** What is `apply_as_truncates` for? Give a real-world scenario where you'd use it.
<details><summary>Answer</summary>It handles events where the entire source table is wiped. Real-world example: a source system does a year-end reset and sends a TRUNCATE event before reloading. In SCD2, all current rows are closed. In SCD1, all rows are deleted.</details>

---

---

# 📖 PHASE 5 — Backloading an SCD2 Table 📦

## The Problem: You Have History That Predates Your Pipeline

You've just built a shiny new SCD2 pipeline. But your production PostgreSQL database has **5 years of history** sitting in it. Your new pipeline will only capture changes going forward.

The business asks: *"Can we see Alice's full plan history, including before we built this pipeline?"*

Without backloading: You can only show changes from Day 1 of the pipeline.
With backloading: You load the historical snapshots first, then stream changes on top.

---

## What Backloading Means

**Backloading** = seeding a streaming/SCD table with historical data before the live CDC stream takes over.

The typical source of historical data:
- A full database export (CSV/Parquet snapshot of the table at a point in time)
- A series of daily snapshots stored in ADLS
- A manually constructed history from existing logs

---

## The Backloading Strategy in DLT

You use **Append Flow** (which you already know!) to load historical data as a separate flow into the SCD2 target:

```python
import dlt
from pyspark.sql.functions import col, lit, to_timestamp

# ── The SCD2 target table ─────────────────────────────────────────────────────
@dlt.table(name="customers_silver_scd2")
def customers_silver_scd2():
    pass


# ── Flow 1: Historical backload (one-time, from snapshot files) ───────────────
@dlt.append_flow(target="customers_silver_scd2")
def backload_historical_customers():
    return (
        spark.read                                    # ← batch read (not stream)
            .format("parquet")
            .load("/Volumes/dev/etl/backload/customers_historical/")
        .withColumn("__START_AT", col("snapshot_date"))
        .withColumn("__END_AT", lit(None).cast("timestamp"))
        .drop("snapshot_date")
    )


# ── Flow 2: Live CDC stream (ongoing) ─────────────────────────────────────────
dlt.apply_changes(
    target             = "customers_silver_scd2",
    source             = "customers_cdc_bronze",
    keys               = ["customer_id"],
    sequence_by        = col("cdc_timestamp"),
    apply_as_deletes   = col("operation") == "DELETE",
    except_column_list = ["operation", "cdc_timestamp"],
    stored_as_scd_type = 2
)
```

---

## The Backloading Sequence (Order Matters)

```
Step 1: Load historical snapshots into SCD2 table (backload flow)
        → Alice: Free (2019-01-01 → 2021-06-15)
        → Alice: Pro  (2021-06-15 → 2023-03-20)

Step 2: Live CDC stream starts from the cutover date
        → Alice: Enterprise (2023-03-20 → NULL)  ← new current

Result: Full 5-year history of Alice, unbroken
```

**The sequencing trick:** The backloaded historical rows must have `__START_AT`/`__END_AT` timestamps that predate the earliest CDC event. This way, the live CDC stream picks up cleanly where the backload ends.

---

## ⚠️ Backloading Pitfalls

| Pitfall | What Happens | Fix |
|---------|-------------|-----|
| Overlapping timestamps | Historical rows and CDC rows cover same time period → duplicates | Ensure cutover date is clean — CDC starts exactly where backload ends |
| Wrong `__END_AT` on last historical row | Last historical row has NULL end date, but CDC also creates a row for same key | Set `__END_AT` on last historical row to the CDC cutover timestamp |
| Running backload flow on every pipeline run | Historical data re-inserted every run → duplicates | Use a one-time trigger or add a condition to skip if already loaded |

---

## ✅ Quick Quiz #4 — Backloading

**Q1:** You're backloading 5 years of customer history. Your live CDC stream starts from `2024-01-01`. What should the `__END_AT` value be for Alice's last historical snapshot row?
<details><summary>Answer</summary>`2024-01-01` (the cutover date) — so the live CDC row starts exactly where the historical row ends, with no gap or overlap.</details>

**Q2:** Why do you use `spark.read` (batch) instead of `spark.readStream` for the backload flow?
<details><summary>Answer</summary>Historical data is a static snapshot — it doesn't change. Batch read processes it once. If you used `readStream`, it would try to track new files in that folder incrementally, which isn't what you want for a one-time historical load.</details>

---

---

# 📖 PHASE 6 — Delete & Truncate in SCD Tables 🗑️

## Handling Deletes: The Nuance Between SCD1 and SCD2

When a DELETE CDC event arrives, the behavior depends on which SCD type you're using:

---

### Deletes in SCD1 — Physical Removal

```python
apply_as_deletes = col("operation") == "DELETE"
```

SCD1 behavior: The row is **physically removed** from the target table.

```
Before: customer_id=1003 (Sarah) exists in customers_silver_scd1
DELETE event arrives for customer_id=1003
After: customer_id=1003 is GONE from the table
```

**Implication:** You lose all knowledge that Sarah ever existed. For GDPR "right to be forgotten," this is exactly what you want. For analytics continuity, it's a problem (her historical order counts disappear from your Gold tables).

---

### Deletes in SCD2 — Soft Close (Not Physical Removal)

In SCD2, a DELETE doesn't physically remove rows. It **closes the current row** by setting `__END_AT`:

```
Before:
customer_id | name  | plan | __START_AT  | __END_AT
1003        | Sarah | Free | 2024-01-01  | NULL       ← current

DELETE event arrives

After:
customer_id | name  | plan | __START_AT  | __END_AT
1003        | Sarah | Free | 2024-01-01  | 2024-01-04  ← closed (not deleted)
```

Sarah's history is preserved. You can still answer "how many customers were active in Q1?" correctly, because Sarah was active in Q1 even if she deleted her account in Q2.

---

### The `apply_as_truncates` Deep Dive

**Truncate = delete everything at once.**

In SCD2, a truncate event closes ALL currently active rows:

```
Before:
customer_id | name  | __START_AT  | __END_AT
1001        | Alice | 2024-01-01  | NULL       ← current
1002        | Bob   | 2024-01-01  | NULL       ← current

TRUNCATE event arrives at 2024-02-01

After:
customer_id | name  | __START_AT  | __END_AT
1001        | Alice | 2024-01-01  | 2024-02-01  ← all closed
1002        | Bob   | 2024-01-01  | 2024-02-01  ← all closed
```

No rows are physically deleted — all history is preserved, all records are just closed.

---

## The "Right to Be Forgotten" Problem in SCD2

GDPR says: "When a customer requests data deletion, remove ALL their data."

But SCD2 keeps all historical rows. How do you handle this?

**Option 1 — Physical delete after the fact:**
```sql
DELETE FROM customers_silver_scd2 WHERE customer_id = 1003
```
This bypasses DLT and directly modifies the underlying Delta table. Valid for compliance, but now your lineage shows data that no longer exists upstream.

**Option 2 — Pseudonymization:**
Overwrite identifying columns with a placeholder:
```sql
UPDATE customers_silver_scd2
SET name = 'DELETED_USER', email = 'DELETED'
WHERE customer_id = 1003
```
History shape is preserved (for counting purposes), PII is removed.

**Option 3 — Delta Lake `VACUUM` + `TIME TRAVEL` considerations:**
After physically deleting, run `VACUUM` to remove old versions of the Delta table that contain the deleted records. This is a real production concern — Delta time travel retains deleted data in old snapshots until vacuum runs.

---

## ✅ Quick Quiz #5 — Deletes & Truncates

**Q1:** In SCD2, a DELETE event arrives for customer_id=1001. Is the row physically removed?
<details><summary>Answer</summary>No — the current row is closed (its `__END_AT` is set to the delete timestamp). Historical rows remain. No physical removal happens automatically.</details>

**Q2:** A TRUNCATE event arrives in SCD1 vs SCD2. What happens in each?
<details><summary>Answer</summary>SCD1: All rows are physically deleted — the table is empty. SCD2: All currently active rows are closed (their `__END_AT` is set) — historical rows remain, no data is physically removed.</details>

**Q3:** A customer invokes their GDPR "right to be forgotten." Your SCD2 table has 12 historical rows for them. What are your two main options?
<details><summary>Answer</summary>1. Physical DELETE of all rows + VACUUM to purge Delta history. 2. Pseudonymization — overwrite PII columns with "DELETED" placeholder, preserving the record count/shape but removing identifying data.</details>

---

---

# 📊 Full System Architecture — Everything Together

```
SOURCE (PostgreSQL / MySQL)
    │
    │ [CDC stream via Debezium / Kafka / native connector]
    ↓
Bronze Layer (Raw CDC Events — Streaming Table)
    customers_cdc_bronze
    {customer_id, name, plan, city, operation, cdc_timestamp}
    │
    ├── [Backload flow] ← one-time historical snapshot
    │
    └── [apply_changes → SCD1]          [apply_changes → SCD2]
          customers_silver_scd1               customers_silver_scd2
          (current state only)                (full version history)
          1 row per customer                  N rows per customer
               │                                    │
               ↓                                    ↓
         [Gold — current metrics]           [Gold — time-series analytics]
         "How many Pro customers today?"    "How many customers were Pro in Q3 2023?"
```

---

# 🗺️ Master Concept Connection Map — Full Session

```
CDC → SCD → DLT Pipeline
    │
    ├── CDC (Change Data Capture)
    │     ├── captures → INSERT, UPDATE, DELETE, TRUNCATE from source DB
    │     ├── lands in → Bronze as stream of change events
    │     └── prerequisite for → both SCD1 and SCD2 processing
    │
    ├── SCD Type 1
    │     ├── behavior → UPSERT (overwrite on update, delete on delete)
    │     ├── history → NONE
    │     ├── stored_as_scd_type = 1 (default)
    │     └── use for → corrections, current-only lookups
    │
    ├── SCD Type 2
    │     ├── behavior → close old row + insert new row
    │     ├── history → FULL (__START_AT, __END_AT)
    │     ├── stored_as_scd_type = 2
    │     ├── delete behavior → soft close (not physical remove)
    │     └── use for → auditing, time-travel analytics, compliance
    │
    ├── APPLY CHANGES INTO
    │     ├── keys → unique record identifier
    │     ├── sequence_by → timestamp for ordering out-of-order events
    │     ├── apply_as_deletes → filter expression for DELETE events
    │     ├── apply_as_truncates → filter expression for TRUNCATE events
    │     ├── except_column_list → metadata columns to exclude
    │     └── target must be → Streaming Table (not Materialized View)
    │
    └── Backloading
          ├── pattern → Append Flow with batch read of historical snapshots
          ├── cutover point → __END_AT of last historical row = CDC start date
          └── pitfall → avoid overlap between historical rows and live CDC rows
```

---

# 📝 Active Recall Prompts — Spaced Repetition

### 🔁 Day 1
- *"Explain the difference between SCD1 and SCD2 to a business analyst who asks: 'Why do we have two rows for Alice?'"*
- *"What are the 5 key parameters of `apply_changes`? What does each one do?"*
- *"A DELETE event arrives. What physically happens in SCD1 vs SCD2?"*

### 🔁 Day 3
- *"Design the full CDC pipeline for a product catalog table where product prices change frequently, and you need to answer 'what was the price of Product X on December 1st?' Write the Bronze table and the `apply_changes` call."*
- *"Why does the `sequence_by` parameter exist? What breaks without it? Give a concrete example with timestamps."*
- *"Explain the backloading strategy. What's the most common mistake engineers make with it?"*

### 🔁 Day 7
- *"End-to-end design challenge: A bank needs to track customer credit limits, which change frequently. They need: current state for credit decisions, full history for regulatory audits, GDPR compliance for data deletion, and a Gold table showing average credit limit by customer segment per quarter. Design the complete DLT pipeline — Bronze, SCD1, SCD2, Gold, and the GDPR deletion strategy."*
- *"Compare Append Flow (from last session) and `apply_changes`. When would you use each? Can they be combined? When?"*

---

# 🚀 What's Coming Next

You've now covered the entire DLT track. The natural progression from here:

| Topic | Why It Follows |
|-------|---------------|
| **DLT Data Quality / Expectations** | You know how to build pipelines — now enforce that bad rows don't corrupt them |
| **Unity Catalog Governance** | Row-level security, column masking, access control on the tables you've built |
| **Databricks Workflows + DLT** | Orchestrating DLT pipelines with other tasks (dbt, Python notebooks) in a production DAG |
| **Delta Lake Optimization** | `OPTIMIZE`, `ZORDER`, `VACUUM` — keeping your Bronze/Silver/Gold tables fast and cheap |

You've gone from "what is a pipeline" all the way to production-grade CDC with full history tracking. That's a serious level-up. 🚀
