# 📘 Delta Tables — MERGE, UPSERT, SCD1 & Soft Deletes

## 🗺️ Roadmap for This Session

```
PHASE 1 — The Problem: Why MERGE exists
PHASE 2 — Core Concepts: Target, Source, Matching Key
PHASE 3 — The 3 MERGE conditions (MATCHED / NOT MATCHED / NOT MATCHED BY SOURCE)
PHASE 4 — Hard Delete vs Soft Delete
PHASE 5 — Schema Evolution (bonus concept this video introduces)
PHASE 6 — SCD1 explained properly
```

---

# 🟢 PHASE 1 — The Problem MERGE Solves

## Real World Scenario First

You have an `EMP` table in your data warehouse. It has 5 employees. Every day, your HR system sends you a file of **changes** — some employees got salary raises, one new employee joined.

Your naive options:

```
Option A: DELETE everything, INSERT everything fresh
    ❌ Destroys history
    ❌ Expensive — rewrites entire table daily
    ❌ Loses audit trail

Option B: Just INSERT the new file as new rows
    ❌ Now you have duplicate employees
    ❌ Old salary AND new salary both exist
    ❌ Downstream queries break

Option C: MERGE — the right answer
    ✅ Update rows that already exist
    ✅ Insert rows that are genuinely new
    ✅ Optionally handle rows that disappeared
    ✅ One atomic operation
```

**MERGE is the engineering-correct solution to incremental data loads.**

This pattern is so common in data engineering it has a formal name: **UPSERT** (Update + Insert).

---

# 🟢 PHASE 2 — Core Concepts: Target, Source, Key

## The Mental Model

```
TARGET TABLE                    SOURCE TABLE
(what you have)                 (what came in today)
────────────────                ────────────────────
EMP_ID | NAME   | SALARY        EMP_ID | NAME   | SALARY
101    | Alice  | 10,000        101    | Alice  | 15,000  ← salary changed
102    | Bob    | 20,000        102    | Bob    | 20,000  ← no change
103    | Carol  | 18,000        104    | Dave   | 22,000  ← Dave updated
104    | Dave   | 21,000        106    | Rohan  | 17,000  ← NEW employee
105    | Eve    | 19,000        
                                ← 103 (Carol) missing from source
                                ← 105 (Eve) missing from source
```

**The matching key** = `EMP_ID`. This is the column that defines "is this the same record?"

Three things can happen when you compare source to target:

```
1. Key exists in BOTH         → record exists, may need UPDATE
2. Key in SOURCE only         → brand new record, needs INSERT
3. Key in TARGET only         → record disappeared from source, needs DELETE or flag
```

These map directly to the 3 MERGE conditions.

---

# 🟡 PHASE 3 — The 3 MERGE Conditions

## The Syntax Structure

```sql
MERGE INTO dev.bronze.EMP AS e        -- TARGET (what you're modifying)
USING dev.bronze.EMP_updates AS u     -- SOURCE (incoming data)
ON e.EMP_ID = u.EMP_ID                -- MATCHING KEY

WHEN MATCHED THEN                     -- Condition 1
  UPDATE SET e.SALARY = u.SALARY

WHEN NOT MATCHED THEN                 -- Condition 2
  INSERT *

WHEN NOT MATCHED BY SOURCE THEN       -- Condition 3
  DELETE;
```

---

## Condition 1: WHEN MATCHED

```
Meaning: This EMP_ID exists in BOTH target and source
Action:  Update the target row with source values

EMP_ID 101 → exists in both → UPDATE salary from 10k to 15k ✅
EMP_ID 102 → exists in both → UPDATE (even if same value, still runs)
EMP_ID 104 → exists in both → UPDATE salary
```

You can also add extra conditions:
```sql
WHEN MATCHED AND e.SALARY <> u.SALARY THEN
  UPDATE SET e.SALARY = u.SALARY
-- Only update if salary actually changed — avoids unnecessary writes
```

---

## Condition 2: WHEN NOT MATCHED

```
Meaning: This EMP_ID exists in SOURCE but NOT in target
Action:  Insert it as a new row into target

EMP_ID 106 (Rohan) → only in source → INSERT new row ✅
```

```sql
-- If source and target have identical columns:
WHEN NOT MATCHED THEN INSERT *

-- If schemas differ (target has extra columns):
WHEN NOT MATCHED THEN
  INSERT (EMP_ID, EMP_NAME, DEPARTMENT, SALARY)
  VALUES (u.EMP_ID, u.EMP_NAME, u.DEPARTMENT, u.SALARY)
```

---

## Condition 3: WHEN NOT MATCHED BY SOURCE

```
Meaning: This EMP_ID exists in TARGET but NOT in source
         (record disappeared — employee left? data issue?)
Action:  DELETE it OR mark it as inactive

EMP_ID 103 (Carol) → only in target → disappeared from source
EMP_ID 105 (Eve)   → only in target → disappeared from source
```

```sql
-- Hard delete: physically remove the row
WHEN NOT MATCHED BY SOURCE THEN DELETE

-- OR soft delete: keep the row, just flag it
WHEN NOT MATCHED BY SOURCE THEN
  UPDATE SET e.is_active = 'N'
```

---

### 🧠 Quick Check #1

> **Q1:** Source has EMP_ID 107. Target does not. Which condition fires?
>
> *`WHEN NOT MATCHED` — key is in source only → INSERT*

> **Q2:** Target has EMP_ID 102. Source does not. Which condition fires?
>
> *`WHEN NOT MATCHED BY SOURCE` — key is in target only → DELETE or flag*

> **Q3:** Both source and target have EMP_ID 101. Which condition fires?
>
> *`WHEN MATCHED` → UPDATE*

---

# 🟠 PHASE 4 — Hard Delete vs Soft Delete

## Hard Delete

```sql
WHEN NOT MATCHED BY SOURCE THEN DELETE
```

```
Before merge:   EMP table has 5 rows (IDs: 101,102,103,104,105)
After merge:    EMP table has 4 rows (IDs: 101,102,104,106)
                103 and 105 are physically gone
```

**When to use:**
- Data is truly invalid/wrong and should not exist
- You're sure you never need to audit "who was deleted and when"
- Regulatory rules don't require you to keep it

**Risk:**
- Irreversible (well, Delta time travel can help, but it's not a clean pattern)
- You lose the audit trail — *why* was this record removed?

---

## Soft Delete

Instead of deleting, you **add a flag column** and mark the record as inactive.

```
Step 1: Add is_active column to target table
Step 2: Merge sets is_active = 'Y' for active, 'N' for inactive
Step 3: Downstream queries filter WHERE is_active = 'Y'
```

```sql
-- Add the column (schema evolution handles this gracefully in Delta)
ALTER TABLE dev.bronze.EMP ADD COLUMN is_active STRING;

-- Now the merge:
MERGE INTO dev.bronze.EMP AS e
USING dev.bronze.EMP_updates AS u
ON e.EMP_ID = u.EMP_ID

WHEN MATCHED THEN
  UPDATE SET e.SALARY = u.SALARY, e.is_active = 'Y'

WHEN NOT MATCHED THEN
  INSERT (EMP_ID, EMP_NAME, DEPARTMENT, SALARY, is_active)
  VALUES (u.EMP_ID, u.EMP_NAME, u.DEPARTMENT, u.SALARY, 'Y')

WHEN NOT MATCHED BY SOURCE THEN
  UPDATE SET e.is_active = 'N';    -- mark as gone, don't delete
```

**Result:**
```
EMP_ID | NAME  | SALARY | is_active
101    | Alice | 15,000 | Y          ← updated, active
102    | Bob   | 20,000 | Y          ← active
103    | Carol | 18,000 | N          ← gone from source, flagged
104    | Dave  | 22,000 | Y          ← updated, active
105    | Eve   | 19,000 | N          ← gone from source, flagged
106    | Rohan | 17,000 | Y          ← new insert, active
```

---

## Hard vs Soft Delete — Decision Guide

| Question | Hard Delete | Soft Delete |
|---|---|---|
| Do you need audit trail? | ❌ No | ✅ Yes |
| Can you afford to lose old records? | ✅ Yes | ❌ No |
| Do analysts need to see "inactive" history? | ❌ No | ✅ Yes |
| Regulatory/compliance requirement to retain? | ❌ No | ✅ Yes |
| Simpler pipeline? | ✅ Yes | More columns/logic needed |

**In production data engineering, soft delete is almost always preferred.** You can always filter out `is_active = 'N'`, but you can never recover a hard-deleted row from a business perspective.

---

# 🟡 PHASE 5 — Schema Evolution (Bonus Concept)

## What happened when we added `is_active`?

```sql
ALTER TABLE dev.bronze.EMP ADD COLUMN is_active STRING;
```

In a traditional database, adding a column to a large table can be expensive — it rewrites the whole table.

In **Delta tables**, this is nearly instant because:

```
Delta stores data as Parquet files + a transaction log (_delta_log)

Adding a column = updating the schema definition in the transaction log
                  NOT rewriting any Parquet files

Existing rows? → They just show NULL for the new column
New rows?      → They populate the new column normally
```

This is **schema evolution** — Delta tables can adapt their structure without rewriting data. This is unique to Delta and is a major reason why it's preferred over plain Parquet in Databricks.

---

# 🔴 PHASE 6 — SCD1 Properly Explained

## What is SCD? (Slowly Changing Dimensions)

This is a **data warehousing concept** — predates Databricks. When you have a dimension table (like employees, products, customers) and their attributes change over time, you need a strategy for handling those changes.

There are multiple types. The video covers **Type 1**.

## SCD Type 1 — Overwrite

```
Philosophy: "We only care about the CURRENT state. History doesn't matter."

Employee 101 had salary 10,000. Now it's 15,000.
SCD1 says: just overwrite. Old value is gone. Current = 15,000.
```

```
Before:  EMP_ID 101 | salary: 10,000
After:   EMP_ID 101 | salary: 15,000   ← 10,000 is gone forever
```

**MERGE with UPDATE = SCD1 implementation.** That's the entire connection.

```
SCD1 = Upsert = MERGE (update if exists, insert if new)
```

## Why Does the Type Number Matter?

| SCD Type | Strategy | Keeps History? |
|---|---|---|
| **Type 1** | Overwrite current record | ❌ No |
| **Type 2** | Add new row with version/date | ✅ Full history |
| **Type 3** | Add column for previous value | ✅ One version back |

Your video implements **Type 1** (simplest). Types 2 and 3 are more complex — you'll encounter them later in your data engineering journey.

---

## Full Annotated Merge — Everything Together

```sql
MERGE INTO dev.bronze.EMP AS e          -- TARGET: table being updated
USING dev.bronze.EMP_updates AS u       -- SOURCE: incoming delta/changes
ON e.EMP_ID = u.EMP_ID                  -- KEY: how we match records

-- Condition 1: key in both → UPDATE
WHEN MATCHED THEN
  UPDATE SET
    e.SALARY = u.SALARY,
    e.is_active = 'Y'

-- Condition 2: key only in source → INSERT
WHEN NOT MATCHED THEN
  INSERT (EMP_ID, EMP_NAME, DEPARTMENT, SALARY, is_active)
  VALUES (u.EMP_ID, u.EMP_NAME, u.DEPARTMENT, u.SALARY, 'Y')

-- Condition 3: key only in target → SOFT DELETE
WHEN NOT MATCHED BY SOURCE THEN
  UPDATE SET e.is_active = 'N';
```

---

## 🗺️ Concept Connection Map

```
MERGE Operation
    ├── implements → UPSERT pattern (Update + Insert)
    ├── implements → SCD Type 1 (overwrite current state)
    ├── connects to → Schema Evolution (ALTER TABLE for soft delete column)
    ├── hard delete path → WHEN NOT MATCHED BY SOURCE THEN DELETE
    └── soft delete path → WHEN NOT MATCHED BY SOURCE THEN UPDATE flag

Soft Delete
    ├── requires → is_active column (schema evolution to add it)
    ├── preferred over → hard delete in production
    └── connects to → audit trail, compliance, data history

SCD1
    ├── synonym for → UPSERT / MERGE pattern
    ├── contrasts with → SCD2 (adds rows for history)
    └── characteristic → only current state preserved
```

---

### 🧠 Final Quiz

> **Q1:** What does UPSERT stand for and what two SQL operations does it combine?
>
> *Update + Insert. If the key exists → update. If the key is new → insert.*

> **Q2:** You run a MERGE. Source has 4 rows, target has 5 rows, 3 keys overlap. How many rows are updated, inserted, and eligible for delete?
>
> *3 updated (matched), 1 inserted (new in source), 2 eligible for delete/flag (in target only).*

> **Q3:** Why is soft delete preferred over hard delete in most production systems?
>
> *Soft delete preserves the record with a flag — you keep audit history, can recover meaning, and meet compliance requirements. Hard delete permanently removes data with no business-level recovery.*

> **Q4:** What is SCD1 and how does MERGE implement it?
>
> *SCD1 = overwrite current record, no history kept. MERGE implements it via WHEN MATCHED → UPDATE, which overwrites old values with new ones.*

> **Q5:** When you `ALTER TABLE` to add `is_active`, what happens to existing rows in Delta?
>
> *They get NULL for the new column. Delta doesn't rewrite existing Parquet files — it updates the schema in the transaction log only.*

---

## 📝 Active Recall Prompts

**Day 1:**
> *"Draw the 3 MERGE conditions from memory. For each: what triggers it, what action it takes."*

**Day 3:**
> *"Your pipeline runs daily. Source sends only changed/new records. Walk through exactly what MERGE does to your target table — row by row logic."*
>
> *"Why would you choose soft delete over hard delete? Give a real-world example."*

**Day 7:**
> *"Explain SCD1 to someone who's never heard of it. Then show the SQL. Then explain what would need to change to make it SCD2 instead."*

---
