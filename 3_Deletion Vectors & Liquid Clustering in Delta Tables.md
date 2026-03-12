# 📘 Deletion Vectors & Liquid Clustering in Delta Tables

## 🗺️ Roadmap for This Session

```
PHASE 1 — Foundation: How Parquet files actually work (the WHY)
PHASE 2 — Partitioning & Z-Ordering (prerequisite context)
PHASE 3 — Deletion Vectors: the problem + the solution
PHASE 4 — Liquid Clustering: the problem + the solution
PHASE 5 — How all 3 optimization techniques compare
```

---

# 🟢 PHASE 1 — Foundation: How Parquet Files Actually Work

## You Cannot Edit a Parquet File

This is the single most important thing to understand before anything else in this session.

Parquet is the file format Delta tables use under the hood in ADLS. And Parquet files are **immutable** — meaning once written, they cannot be edited in place.

```
Traditional database (like MySQL):
    Row exists in a page/block on disk
    UPDATE salary → go to that row, change the byte
    ✅ surgical, in-place edit

Parquet file (used by Delta/Spark):
    Row exists inside a compressed columnar file
    UPDATE salary → cannot edit the file
    Instead: read entire file → apply change → write brand new file → delete old file
    ❌ rewrites the whole file for one row change
```

This is the **fundamental constraint** that both Deletion Vectors and Liquid Clustering are solving around.

---

## What Does a Delta Table Actually Look Like in ADLS?

```
dev/bronze/sales/                      ← table folder
    ├── _delta_log/                    ← transaction log (the "phone book")
    │     ├── 000.json                 ← "table was created"
    │     ├── 001.json                 ← "3 rows inserted"
    │     └── 002.json                 ← "2 rows deleted"
    ├── part-00001.parquet             ← actual data file (say, 1M rows)
    ├── part-00002.parquet             ← actual data file (say, 1M rows)
    └── part-00003.parquet             ← actual data file (say, 1M rows)
```

When Spark reads your table, it:
1. Reads `_delta_log` to understand current state
2. Reads the relevant Parquet files
3. Assembles the result

**Key insight:** Delta's intelligence is in the `_delta_log`. The Parquet files are just dumb storage.

---

### 🧠 Quick Check #1
> **Q:** Why can't Spark just edit one row inside a Parquet file directly?
>
> *Parquet files are immutable — they cannot be modified in place. Any change requires reading the file, applying the change in memory, writing a new file, and deleting the old one.*

---

# 🟢 PHASE 2 — Prerequisite Context: Partitioning & Z-Ordering

The video references these as prerequisites for Liquid Clustering. Let's cover them enough to understand *why* Liquid Clustering exists.

## Partitioning — The Old Optimization

**Problem:** Your sales table has 1 billion rows across 1000 Parquet files. You query `WHERE country = 'India'`. Spark has to scan all 1000 files to find India rows.

**Partitioning solution:** Physically organize files by the partition column.

```
Without partitioning:
    part-00001.parquet  ← has India, USA, UK, Germany rows mixed
    part-00002.parquet  ← has India, USA, UK, Germany rows mixed
    Query WHERE country='India' → must scan ALL files ❌

With partitioning by country:
    /country=India/part-00001.parquet   ← ONLY India rows
    /country=USA/part-00001.parquet     ← ONLY USA rows
    /country=UK/part-00001.parquet      ← ONLY UK rows
    Query WHERE country='India' → scan ONLY /country=India/ folder ✅
```

**This is called partition pruning** — Spark skips entire folders it doesn't need.

**The problem with partitioning:**
```
Works great for LOW cardinality columns (country = ~200 values)
Breaks badly for HIGH cardinality columns:

Partitioned by InvoiceNumber (millions of unique values):
    /InvoiceNumber=10001/part.parquet  ← 1 row
    /InvoiceNumber=10002/part.parquet  ← 1 row
    ... millions of tiny files ...
    ❌ "small files problem" — worse than no partitioning
```

---

## Z-Ordering — The Next Optimization

**Problem:** You want to optimize on a high cardinality column but can't partition it.

**Z-Ordering solution:** Co-locate related data *within* files using a space-filling curve algorithm. Rows with similar column values are physically stored close together in the same file.

```
Without Z-order (InvoiceNumber scattered across files):
    file1: invoices 1, 5000, 2, 9999, 3, 7777 (random order)
    Query WHERE InvoiceNumber = 5000 → must check many files

With Z-order on InvoiceNumber:
    file1: invoices 1–3000     (low range grouped)
    file2: invoices 3001–6000  (mid range grouped)
    file3: invoices 6001–9999  (high range grouped)
    Query WHERE InvoiceNumber = 5000 → only file2 needed ✅
```

**Problems with Z-Ordering:**
```
❌ You must manually run OPTIMIZE + ZORDER periodically
❌ Every OPTIMIZE rewrites ALL files — expensive
❌ New incoming data is NOT automatically Z-ordered
   You have to run OPTIMIZE again after every load
❌ Only works well for 1-2 columns at most
```

**This is exactly the gap Liquid Clustering fills.**

---

# 🟠 PHASE 3 — Deletion Vectors

## The Problem (Concrete Example)

```
part-00001.parquet has 1,000,000 rows
You want to delete 35 rows where InvoiceNumber = 5464

Without Deletion Vectors:
    Read all 1,000,000 rows into memory
    Filter out the 35 rows
    Write 999,965 rows as a new Parquet file
    Delete the old file
    
    Cost: rewrite 1M rows to remove 35 rows ❌ 
    Time: expensive
    Resources: high I/O, memory, compute
```

This is death by a thousand cuts in a busy production table where deletes happen constantly (GDPR compliance, corrections, MERGE operations).

---

## The Solution: Deletion Vectors

```
part-00001.parquet has 1,000,000 rows
You want to delete 35 rows where InvoiceNumber = 5464

With Deletion Vectors:
    Write a small "deletion vector" file that says:
    "rows at positions [342, 891, 1205, ...35 positions total] are deleted"
    
    Original Parquet file: untouched ✅
    Cost: write one tiny vector file, not rewrite 1M rows ✅
    
When reading:
    Spark reads part-00001.parquet
    Checks deletion vector: "skip these 35 row positions"
    Returns 999,965 rows to you
    
Physical cleanup:
    Later, when OPTIMIZE runs → THEN the file is rewritten 
    with those 35 rows actually removed
```

```
ADLS after deletion with vectors enabled:
    part-00001.parquet              ← original, untouched
    part-00001.parquet.dv           ← tiny vector file marking deleted rows
    _delta_log/003.json             ← records "deletion vector added"
```

---

## Enabling/Disabling Deletion Vectors

```sql
-- Enable (default in modern Databricks)
ALTER TABLE dev.bronze.sales
SET TBLPROPERTIES ('delta.enableDeletionVectors' = 'true');

-- Disable (forces old behavior — full file rewrites on delete)
ALTER TABLE dev.bronze.sales
SET TBLPROPERTIES ('delta.enableDeletionVectors' = 'false');

-- Check current state
DESCRIBE EXTENDED dev.bronze.sales;
-- Look for: enableDeletionVector = true/false in Table Properties
```

---

## What DESCRIBE HISTORY Tells You

```sql
DESCRIBE HISTORY dev.bronze.sales;
```

```
WITHOUT deletion vectors (after a DELETE):
    operationMetrics:
        numFilesRemoved: 3       ← old files deleted
        numFilesAdded: 3         ← new files written (rewrites)
        numDeletionVectorsAdded: 0

WITH deletion vectors (after a DELETE):
    operationMetrics:
        numFilesRemoved: 0       ← no files touched ✅
        numFilesAdded: 0         ← no new files written ✅
        numDeletionVectorsAdded: 3  ← just tiny vector files
```

This is your proof that deletion vectors are working.

---

## When Do Deleted Rows Actually Get Removed?

```
DELETE with vectors enabled:
    Day 1: rows flagged, file untouched, vector file written
    Day 2: rows still physically in file (but hidden from reads)
    Day N: OPTIMIZE command runs (manually or via predictive optimize)
           → NOW the file is rewritten, flagged rows physically removed
           → Vector file deleted (no longer needed)
```

```sql
-- Trigger physical cleanup manually
OPTIMIZE dev.bronze.sales;
```

**Requirements:**
- Delta Lake 2.3.0+
- Databricks Runtime 12.2 LTS+

---

### 🧠 Quick Check #2

> **Q1:** You delete 10 rows from a 5M row Parquet file with deletion vectors enabled. How many Parquet files are rewritten immediately?
>
> *Zero. A tiny deletion vector file is written. The Parquet file is untouched until OPTIMIZE runs.*

> **Q2:** After enabling deletion vectors, you run `DESCRIBE HISTORY`. You see `numFilesAdded: 0, numDeletionVectorsAdded: 5`. What does this tell you?
>
> *Deletion vectors are working correctly — 5 vector files were created marking deleted rows, but no Parquet files were rewritten.*

---

# 🔴 PHASE 4 — Liquid Clustering

## The Problem It Solves

Recall from Phase 2:
- Partitioning → fails on high cardinality columns
- Z-Ordering → must be manually re-run, doesn't auto-apply to new data

```
Real production scenario:
    Table: 10TB sales data
    New data lands every hour
    Analysts query frequently by InvoiceNumber (millions of unique values)
    
    Partition by InvoiceNumber → millions of tiny files ❌
    Z-Order → run OPTIMIZE every hour? Rewrites 10TB every hour? ❌
    
    You need something that:
    ✅ Handles high cardinality
    ✅ Automatically applies to new incoming data
    ✅ Doesn't rewrite everything each time
    ✅ Manages file sizing automatically
```

**Liquid Clustering is the answer.**

---

## How Liquid Clustering Works

```
You declare: "cluster this table by InvoiceNumber"

Delta now:
    Knows which column(s) matter for clustering
    As new data arrives → incrementally groups related rows into same files
    Runs clustering in the background (or during OPTIMIZE)
    Does NOT rewrite the entire table each time — only processes new/changed files
```

```
Without clustering:
    file1: invoices [5001, 102, 8834, 23, 6612, ...]  ← random scatter
    file2: invoices [44, 9001, 7732, 156, 3344, ...]

With liquid clustering on InvoiceNumber (after settling):
    file1: invoices [1–2500]     ← related values grouped
    file2: invoices [2501–5000]
    file3: invoices [5001–7500]
    
    Query WHERE InvoiceNumber = 6000 → only file3 scanned ✅
```

---

## Enabling Liquid Clustering

```sql
-- On an EXISTING table:
ALTER TABLE dev.bronze.sales CLUSTER BY (InvoiceNumber);

-- On a NEW table (CTAS style):
CREATE TABLE dev.bronze.sales_clustered
CLUSTER BY (InvoiceNumber)
AS SELECT * FROM dev.bronze.sales;

-- Multiple cluster columns:
ALTER TABLE dev.bronze.sales CLUSTER BY (Country, InvoiceNumber);

-- Remove clustering entirely:
ALTER TABLE dev.bronze.sales CLUSTER BY NONE;
```

**Constraints:**
- Cluster columns must be within the **first 32 columns** of your schema
- Delta Lake 3.1.0+ required
- Databricks Runtime 13.3 LTS+ required

---

## Liquid Clustering vs Partitioning vs Z-Ordering

| Property | Partitioning | Z-Ordering | Liquid Clustering |
|---|---|---|---|
| **Best for cardinality** | Low (country, year) | Medium | High (invoice IDs, user IDs) |
| **Auto-applies to new data?** | ✅ Yes | ❌ No | ✅ Yes |
| **Requires manual OPTIMIZE?** | ❌ No | ✅ Yes (every load) | ❌ No (incremental) |
| **Rewrites all files?** | ❌ No | ✅ Yes (full) | ❌ No (incremental only) |
| **Small files problem?** | ❌ Risk (high cardinality) | ❌ No | ❌ No (auto-managed) |
| **Multiple columns?** | ⚠️ Gets complex | ⚠️ 1-2 columns max | ✅ Yes, cleaner |
| **Maturity** | Oldest | Middle | Newest (Delta 3.1+) |

---

## When to Use Each

```
Use PARTITIONING when:
  ✅ Column has very low cardinality (year, month, country, status)
  ✅ Queries almost always filter by this column
  ✅ Data distribution is relatively even across partition values

Use Z-ORDERING when:
  ✅ Medium cardinality column
  ✅ Table is mostly static (rare writes)
  ✅ You can afford to run OPTIMIZE periodically
  ⚠️  Avoid if data is updated frequently

Use LIQUID CLUSTERING when:
  ✅ High cardinality column (IDs, invoice numbers, user IDs)
  ✅ Data arrives continuously (streaming or frequent batch)
  ✅ Access patterns vary or are unpredictable
  ✅ You want automatic, maintenance-free optimization
  ✅ Table is growing rapidly
```

---

## The Full Delta Optimization Picture Together

```
Your Delta Table
    │
    ├── WRITES (INSERT/UPDATE/DELETE)
    │       └── Deletion Vectors → avoid expensive rewrites on DELETE
    │
    ├── FILE ORGANIZATION (for fast reads)
    │       ├── Partitioning    → folder-level pruning (low cardinality)
    │       ├── Z-Ordering      → within-file co-location (medium cardinality)
    │       └── Liquid Cluster  → automatic, incremental (high cardinality)
    │
    └── MAINTENANCE
            └── OPTIMIZE → triggers physical cleanup of deletion vectors
                           + applies/refines clustering
```

---

## 🗺️ Concept Connection Map

```
Deletion Vectors
    ├── solves → expensive file rewrites on DELETE/UPDATE
    ├── defers → physical cleanup to OPTIMIZE command
    ├── requires → Delta 2.3.0+, DBR 12.2 LTS+
    └── contrasts with → old behavior (full rewrite on every delete)

Liquid Clustering
    ├── solves → partitioning failure on high cardinality columns
    ├── improves on → Z-Ordering (auto-applies, incremental, multi-column)
    ├── requires → Delta 3.1.0+, DBR 13.3 LTS+
    └── contrasts with → Partitioning (low cardinality) + Z-Order (manual)

OPTIMIZE command
    ├── triggers → physical deletion of flagged rows (deletion vectors)
    ├── triggers → incremental reclustering (liquid clustering)
    └── connects to → both features as the "maintenance executor"
```

---

## 📝 Active Recall Prompts

**Day 1:**
> *"Without notes: what is the core problem deletion vectors solve? Walk through what happens when you delete 50 rows with and without deletion vectors enabled."*

**Day 3:**
> *"Why does partitioning fail for high cardinality columns? What is the 'small files problem'?"*
>
> *"What does OPTIMIZE do differently when deletion vectors are enabled vs when they're not?"*

**Day 7:**
> *"Your team has a 5TB table that receives new data every 30 minutes. Analysts query by `user_id` (100M unique values). Which optimization technique would you choose and why? Rule out the alternatives explicitly."*

---
