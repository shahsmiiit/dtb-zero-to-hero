# 📘 COPY INTO — Idempotent Ingestion & Exactly-Once Processing

## 🗺️ Roadmap for This Session

```
PHASE 1 — The Ingestion Problem (why COPY INTO exists)
PHASE 2 — What COPY INTO is and how it works
PHASE 3 — Idempotency & Exactly-Once (the most critical concept)
PHASE 4 — Schema Handling (inference, evolution, custom SELECT)
PHASE 5 — Incremental Processing (adding new files)
PHASE 6 — COPY INTO vs Autoloader (when to use which)
```

---

# 🟢 PHASE 1 — The Ingestion Problem

## What You're Actually Trying to Do

Raw files land in your ADLS/Volume landing zone from external systems — CSV exports, JSON API dumps, Avro from Kafka, etc. You need to get them into Delta tables for processing.

```
ADLS Landing Zone                    Delta Table
──────────────────                   ───────────
/input/invoice_01.csv  ──────────→   dev.bronze.invoices
/input/invoice_02.csv  ──────────→   (all rows, no duplicates,
/input/invoice_03.csv  ──────────→    exactly once)
```

The naive approach and its problems:

```
Option A: spark.read.csv(...).write.format("delta").mode("append")
    ❌ If you run this twice → duplicate rows
    ❌ No tracking of which files were already loaded
    ❌ Re-running the pipeline on failure = disaster

Option B: Track processed files yourself in a metadata table
    ❌ You have to build + maintain this tracking logic
    ❌ Error-prone, non-standard, hard to audit
    ❌ Reinventing what Databricks already built

Option C: COPY INTO ✅
    ✅ Tracks which files were processed automatically
    ✅ Re-running never causes duplicates
    ✅ Built-in schema inference, evolution, transformation
    ✅ Zero custom tracking code needed
```

---

## The Engineering Term: Idempotent Pipeline

**Idempotent** = running the same operation multiple times produces the same result as running it once.

```
Idempotent:
    Run 1: load invoice_01.csv → 500 rows inserted
    Run 2: same command → 0 rows inserted (file already loaded)
    Run 3: same command → 0 rows inserted
    
    Final table: always exactly 500 rows from invoice_01.csv ✅

NOT idempotent (plain append):
    Run 1: load invoice_01.csv → 500 rows inserted
    Run 2: same command → 500 MORE rows inserted (duplicates!)
    Run 3: same command → 500 MORE rows inserted (more duplicates!)
    
    Final table: 1500 rows, 1000 are duplicates ❌
```

**This is why idempotency is a non-negotiable engineering property for data pipelines.** Production pipelines re-run constantly — due to failures, retries, scheduled reruns, debugging. If your pipeline isn't idempotent, every retry corrupts your data.

---

# 🟢 PHASE 2 — What COPY INTO Is

## Definition

`COPY INTO` is a **SQL command** in Databricks that:
- Reads files from a source location (volume, ADLS path)
- Loads them into a Delta table
- **Tracks every file it has processed**
- **Skips files it has already loaded** on subsequent runs

Supported file formats: CSV, JSON, Avro, Parquet, Text, Binary

---

## Basic Syntax

```sql
COPY INTO target_table
FROM source_path
FILEFORMAT = format
FILES = 'pattern'
FORMAT_OPTIONS (option = value, ...)
COPY_OPTIONS (option = value, ...)
```

## Real Example from the Video

```sql
COPY INTO dev.bronze.invoice_cp
FROM '/Volumes/dev/bronze/landing/input'
FILEFORMAT = CSV
FILES = '*.csv'                          -- load all CSV files in the folder
FORMAT_OPTIONS (
    'mergeSchema' = 'true',              -- handle schema evolution
    'header' = 'true'                    -- treat first row as column names
)
COPY_OPTIONS (
    'mergeSchema' = 'true'               -- merge inferred schema into table
)
```

---

## What Each Part Does

```
COPY INTO dev.bronze.invoice_cp
    → destination Delta table
    → will be created if it doesn't exist (with placeholder schema)

FROM '/Volumes/dev/bronze/landing/input'
    → source folder path (volume, ADLS, or DBFS path)
    → reads ALL files matching the pattern

FILEFORMAT = CSV
    → tell Databricks how to parse the files
    → no quotes needed around the format name

FILES = '*.csv'
    → glob pattern: only load .csv files
    → can also be: '*.json', 'invoice_*.csv', specific filenames

FORMAT_OPTIONS
    → options for reading the file format
    → 'header' = 'true' → treat row 1 as column names (CSV-specific)
    → 'mergeSchema' = 'true' → if new files have extra columns, add them

COPY_OPTIONS
    → options for the COPY INTO operation itself
    → 'mergeSchema' = 'true' → merge inferred schema into target table
    → needed when table was created with no columns (placeholder)
```

---

### 🧠 Quick Check #1

> **Q1:** You run COPY INTO. It loads 500 rows. You run it again without adding new files. How many rows are inserted?
>
> *Zero. COPY INTO tracks processed files and skips them on rerun. This is the exactly-once guarantee.*

> **Q2:** What does `FILES = '*.csv'` do?
>
> *It's a glob pattern that matches all files ending in `.csv` in the source folder. Only those files are loaded — not JSON, not Parquet, not other formats.*

---

# 🟡 PHASE 3 — Idempotency: How COPY INTO Actually Tracks Files

## The Metadata Mechanism

This is the engineering heart of COPY INTO. You need to understand *how* it knows which files were already loaded.

```
When you run COPY INTO:
    1. Databricks reads the source folder
    2. Checks its metadata log: "which files have I already processed?"
    3. Filters out already-processed files
    4. Loads ONLY the new files
    5. Updates the metadata log with newly processed filenames
```

## Where Is This Metadata Stored?

```
Every Delta table has a _delta_log folder in ADLS:
    abfss://container@storage.dfs.core.windows.net/
        └── <metastore-id>/<catalog-id>/<schema-id>/<table-id>/
                └── _delta_log/
                        ├── 000.json       ← table created
                        ├── 001.json       ← first COPY INTO
                        └── _copy_into_log ← ← ← HERE
                                ├── invoice_01.csv ← already processed
                                └── invoice_02.csv ← already processed
```

**The COPY INTO log is stored inside the Delta log directory of the target table.**

```
This means:
    ✅ Metadata travels with the table (not stored separately)
    ✅ If you clone the table, the tracking comes with it
    ✅ Visible via DESCRIBE EXTENDED (find table location → navigate in Azure)
    ✅ No external database needed to track file state
```

---

## The Exactly-Once Guarantee in Practice

```
Day 1 run:
    Source folder: [invoice_01.csv, invoice_02.csv]
    _copy_into_log: [empty]
    Action: load both files → 500 + 600 = 1100 rows
    _copy_into_log: [invoice_01.csv, invoice_02.csv]

Day 1 retry (pipeline failed after load, re-runs):
    Source folder: [invoice_01.csv, invoice_02.csv]
    _copy_into_log: [invoice_01.csv, invoice_02.csv]
    Action: skip both (already processed) → 0 rows ✅
    Table still has 1100 rows, no duplicates ✅

Day 2 run (new file arrives):
    Source folder: [invoice_01.csv, invoice_02.csv, invoice_03.csv]
    _copy_into_log: [invoice_01.csv, invoice_02.csv]
    Action: load only invoice_03.csv → 222 rows
    _copy_into_log: [invoice_01.csv, invoice_02.csv, invoice_03.csv]
    Table now has 1322 rows ✅
```

---

# 🟡 PHASE 4 — Schema Handling

## Three Schema Scenarios COPY INTO Handles

### Scenario 1: Placeholder Table (Schema Inference)

```sql
-- Create empty table with NO columns defined
CREATE TABLE dev.bronze.invoice_cp;
-- Table exists, schema: (empty)

-- COPY INTO infers schema from the CSV files automatically
COPY INTO dev.bronze.invoice_cp
FROM '/Volumes/dev/bronze/landing/input'
FILEFORMAT = CSV
FORMAT_OPTIONS ('header' = 'true', 'mergeSchema' = 'true')
COPY_OPTIONS ('mergeSchema' = 'true')
-- After this runs: table has columns matching the CSV headers
```

```
Why 'mergeSchema' in COPY_OPTIONS?
    Table had no schema → inferred schema must be MERGED INTO the table definition
    Without this: error ("table schema doesn't match file schema")
    With this: table adopts the inferred schema ✅
```

### Scenario 2: Pre-defined Table Schema

```sql
-- Create table with explicit schema
CREATE TABLE dev.bronze.invoice_alt (
    invoice_number STRING,
    stock_code     STRING,
    quantity       DOUBLE,
    insert_date    TIMESTAMP   -- extra column, not in source CSV
);

-- COPY INTO with custom SELECT to map + transform
COPY INTO dev.bronze.invoice_alt
FROM (
    SELECT
        invoice_number,
        stock_code,
        CAST(quantity AS DOUBLE),
        current_timestamp() AS insert_date    -- populate custom column
    FROM read_files(...)
)
FILEFORMAT = CSV
FORMAT_OPTIONS ('header' = 'true', 'mergeSchema' = 'true')
-- No COPY_OPTIONS mergeSchema needed — schema already defined
```

**Why no `COPY_OPTIONS mergeSchema` here?**
```
Table already has a defined schema.
There's nothing to merge INTO — the schema is already set.
Adding it would cause an error or be ignored.

COPY_OPTIONS mergeSchema is ONLY needed when:
    Table was created as a placeholder (no columns)
    AND you want COPY INTO to define the schema for you
```

### Scenario 3: Schema Evolution (New Columns in New Files)

```
File 1 (Jan): invoice_number, stock_code, quantity
File 2 (Feb): invoice_number, stock_code, quantity, discount   ← NEW column

FORMAT_OPTIONS ('mergeSchema' = 'true')
    → Detects new column in Feb file
    → Adds 'discount' column to the table
    → Jan rows get NULL for 'discount' (they didn't have it)
    → Feb rows have actual discount values
```

---

## Custom SELECT for Transformation During Ingestion

This is powerful — you can transform data AS you ingest it:

```sql
COPY INTO dev.bronze.invoice_alt
FROM (
    SELECT
        invoice_number,
        stock_code,
        CAST(quantity AS DOUBLE),          -- type cast
        UPPER(description) AS description, -- transformation
        current_timestamp() AS insert_date,-- add audit column
        'batch_001' AS batch_id            -- add metadata column
    FROM read_files(
        '/Volumes/dev/bronze/landing/input',
        format => 'csv',
        header => true
    )
)
FILEFORMAT = CSV
FORMAT_OPTIONS ('header' = 'true')
```

**This means COPY INTO is not just a file loader — it's a mini-ETL step:**
```
Extract:    reads from the source folder
Transform:  applies the SELECT query
Load:       writes to the Delta table
+ Tracking: maintains the exactly-once metadata
```

---

### 🧠 Quick Check #2

> **Q1:** When do you need `COPY_OPTIONS ('mergeSchema' = 'true')` vs `FORMAT_OPTIONS ('mergeSchema' = 'true')`?
>
> *`FORMAT_OPTIONS mergeSchema` handles schema evolution in the SOURCE files (new columns across files). `COPY_OPTIONS mergeSchema` handles merging the inferred schema INTO the target table — only needed when the table has no pre-defined schema (placeholder table).*

> **Q2:** Your CSV source files have a `sale_price` column stored as STRING. Your Delta table expects DOUBLE. How do you fix this during ingestion?
>
> *Use a custom SELECT query: `CAST(sale_price AS DOUBLE) AS sale_price`. The transformation happens at ingestion time, before writing to the table.*

---

# 🟠 PHASE 5 — Incremental Processing in Practice

## The Day-by-Day Flow

This is how COPY INTO works in a real daily pipeline:

```
SETUP (once):
    Create target Delta table (placeholder or defined schema)
    Create volume landing zone folder
    Write COPY INTO command in a notebook

DAILY PIPELINE (automated):
    New CSV files land in /Volumes/.../landing/input/
    COPY INTO command runs (scheduled via Databricks Workflows)
    
    COPY INTO:
        1. Lists all files in the folder
        2. Cross-references with _copy_into_log
        3. Identifies NEW files only
        4. Loads new files into Delta table
        5. Updates _copy_into_log
    
    Result: table grows incrementally, no duplicates, no manual tracking
```

---

## What "Incremental" Means Here

```
Day 1:  folder has [01.csv, 02.csv]  → loads both → 1100 rows in table
Day 2:  folder has [01.csv, 02.csv, 03.csv] → loads only 03.csv → 1322 rows
Day 3:  folder has [01.csv, 02.csv, 03.csv, 04.csv] → loads only 04.csv → ...
```

**You don't need to move or delete old files.** COPY INTO remembers what it loaded. Old files can stay in the folder indefinitely — they're simply skipped.

---

# 🔴 PHASE 6 — COPY INTO vs Autoloader

The video explicitly positions these as complementary tools for different scales. This comparison is essential.

## The Core Difference

```
COPY INTO        → batch-style, SQL command, run on demand or scheduled
Autoloader       → streaming-style, continuous, event-driven file detection
```

---

## COPY INTO: How It Finds New Files

```
Every run: lists ALL files in the source folder
           compares against _copy_into_log
           identifies new ones

Cost of listing:
    100 files   → fast, negligible
    10,000 files → acceptable
    1,000,000 files → SLOW, expensive
                       Azure charges per list operation
                       Listing 1M files takes significant time
```

**COPY INTO doesn't scale well to millions of files because it re-lists the entire folder every run.**

---

## Autoloader: How It Finds New Files

```
Instead of listing the whole folder every run:
    Uses Azure Event Grid notifications
    
    When a new file lands in ADLS:
        Azure fires an event: "new file: invoice_04.csv arrived"
        Autoloader receives the event
        Processes ONLY that specific new file
        
Cost of detection:
    1M files in folder? Doesn't matter.
    Only the NEW event triggers processing.
    No full folder listing needed.
```

---

## Decision Framework

| Question | COPY INTO | Autoloader |
|---|---|---|
| **Files per day** | Hundreds to thousands | Millions+ |
| **Processing style** | Batch (scheduled runs) | Streaming (continuous) |
| **Directory structure** | Simple flat folder | Complex nested directories |
| **Latency** | Minutes (next scheduled run) | Seconds (event-driven) |
| **Setup complexity** | Simple SQL command | More configuration |
| **Use in pipelines** | Workflows notebook task | Structured Streaming job |
| **Exactly-once?** | ✅ Yes | ✅ Yes (checkpointing) |

```
Choose COPY INTO when:
    ✅ Batch ingestion (hourly/daily)
    ✅ Simple folder structure
    ✅ File counts manageable (< tens of thousands per run)
    ✅ SQL-first team, simplicity preferred
    ✅ Getting started / prototyping

Choose Autoloader when:
    ✅ Continuous/near-real-time ingestion
    ✅ Millions of files per day
    ✅ Complex nested directory structures
    ✅ Streaming pipelines (Delta Live Tables)
    ✅ Large-scale production data lakes
```

---

## The Full Ingestion Picture

```
Files arrive in ADLS
        │
        ├── Hundreds/day, batch OK?
        │       └── COPY INTO ✅
        │               SQL command
        │               Scheduled in Workflows
        │               Simple, idempotent, exactly-once
        │
        └── Millions/day, near-real-time needed?
                └── Autoloader ✅ (next video)
                        Structured Streaming
                        Event-driven file detection
                        Exactly-once via checkpoints
```

---

## 🗺️ Concept Connection Map

```
COPY INTO
    ├── solves → idempotent batch file ingestion
    ├── tracks files via → _copy_into_log in Delta log directory
    ├── guarantees → exactly-once processing
    ├── supports → schema inference, evolution, custom SELECT
    ├── scales to → thousands of files (not millions)
    └── contrasts with → Autoloader (event-driven, millions of files)

Idempotency
    ├── why it matters → pipelines retry on failure constantly
    ├── how COPY INTO achieves it → _copy_into_log metadata
    └── connects to → earlier concept: IF NOT EXISTS, overwrite mode

Schema Handling
    ├── placeholder table → COPY_OPTIONS mergeSchema
    ├── new columns in files → FORMAT_OPTIONS mergeSchema
    └── transformation → custom SELECT inside COPY INTO

Incremental Processing
    ├── COPY INTO → checks log, loads only new files
    └── connects to → Autoloader (next session, event-driven)
```

---

## 📝 Active Recall Prompts

**Day 1:**
> *"What is idempotency? Why is it non-negotiable for data pipelines? How does COPY INTO achieve it?"*
>
> *"Where is the COPY INTO tracking metadata stored? Why does it living there (vs a separate table) matter?"*

**Day 3:**
> *"When do you use `COPY_OPTIONS mergeSchema` vs `FORMAT_OPTIONS mergeSchema`? Give a concrete scenario for each."*
>
> *"Your COPY INTO pipeline ran successfully, then the job failed in a downstream task. The scheduler retries the whole job. What happens when COPY INTO runs again?"*

**Day 7:**
> *"You're designing ingestion for two scenarios: (A) 500 CSV files land daily from an ERP export, (B) IoT devices generate 2M JSON files per hour. Which ingestion tool for each and why? What exactly-once mechanism does each use?"*

---
