# 📘 Autoloader — Streaming File Ingestion at Scale

## 🗺️ Roadmap for This Session

```
PHASE 1 — Bridge: Where COPY INTO ends, Autoloader begins
PHASE 2 — What Autoloader is (architecture first)
PHASE 3 — File Detection Modes (Directory Listing vs File Notification)
PHASE 4 — Writing an Autoloader Query (anatomy of every option)
PHASE 5 — Checkpointing: How exactly-once works at scale
PHASE 6 — Schema Evolution Modes (all 4, when to use each)
PHASE 7 — Autoloader vs COPY INTO: Final decision framework
```

---

# 🟢 PHASE 1 — Bridge: Where COPY INTO Ends

## The Exact Limitation We're Solving

From last session, you know COPY INTO's weakness:

```
COPY INTO detects new files by:
    1. LIST all files in the source folder
    2. Compare against _copy_into_log
    3. Load only new ones

Cost of step 1 as files grow:
    1,000 files    →  fast ✅
    100,000 files  →  slow ⚠️
    10,000,000 files → very slow, Azure charges per list API call ❌

Also: COPY INTO doesn't handle nested folders well
    /data/2024/01/15/*.csv
    /data/2024/01/16/*.csv
    /data/2024/01/17/*.csv
    → Complex glob patterns, expensive re-listing
```

**Autoloader solves both problems** — scales to millions of files AND handles deeply nested folder structures efficiently.

---

# 🟢 PHASE 2 — What Autoloader Is (Architecture First)

## The Fundamental Difference in Design

```
COPY INTO approach:
    "I'll check what's in the folder every time I run"
    → Polling model (like repeatedly checking your mailbox)

Autoloader approach:
    "The folder will TELL ME when something new arrives"
    → Event-driven model (like getting a notification when mail arrives)
    
    OR (default): uses a smarter, scalable listing strategy
    with a state database (RocksDB) so it never re-processes
```

---

## What Autoloader Actually Is Under the Hood

```
Autoloader = Structured Streaming + cloudFiles source format

Structured Streaming = Apache Spark's continuous processing engine
                       (the same engine that processes Kafka, socket streams, etc.)

cloudFiles = a special Spark streaming source created by Databricks
             that understands cloud object storage (ADLS, S3, GCS, DBFS)
             and detects new files incrementally
```

**This means Autoloader IS a streaming job.** You can run it:
- **Continuously** (streaming mode — always on, processes files as they arrive)
- **As a batch** (trigger once — process all new files, then stop)

You choose via the `trigger` setting.

---

## The Two Modes of Operation

```
STREAMING MODE (continuous):
    Stream starts → runs forever
    New file arrives → processed within seconds
    Use: real-time/near-real-time pipelines
    
    writeStream.trigger(processingTime="1 minute")
    → checks for new files every 1 minute

BATCH MODE (trigger once):
    Stream starts → processes all new files → stops
    Use: scheduled batch pipelines (like COPY INTO)
    Run via Databricks Workflows on a schedule
    
    writeStream.trigger(availableNow=True)
    → process everything new right now, then finish
```

---

### 🧠 Quick Check #1

> **Q1:** Is Autoloader a SQL command like COPY INTO, or something different?
>
> *Different. COPY INTO is a SQL command. Autoloader is a PySpark/Scala structured streaming query using the `cloudFiles` source format. It's code, not a SQL command.*

> **Q2:** You want Autoloader to run as a scheduled batch job (like COPY INTO). What trigger do you use?
>
> *`trigger(availableNow=True)` — processes all new files once and stops. Schedule this notebook in Databricks Workflows.*

---

# 🟡 PHASE 3 — File Detection Modes

## Mode 1: Directory Listing (Default)

```
How it works:
    Autoloader periodically scans the source folder(s)
    Uses RocksDB (a fast embedded key-value store) to remember:
        "I've already processed these files"
    On each scan: new files = (all files) - (already tracked files)
    Processes only new files

Where does it store this state?
    In the CHECKPOINT directory you provide
    Under: /checkpoint/autoloader/_schemas/ and related folders
    
Scalability:
    RocksDB is fast and can track millions of file entries
    Much more scalable than COPY INTO's _copy_into_log approach
    ✅ Works for millions of files
```

```
Analogy:
    Imagine a librarian who keeps a card catalogue of every book seen.
    When new books arrive, they check the catalogue:
    "Is this book already logged? No → log it and process it"
    The card catalogue (RocksDB) makes this fast even with millions of books.
```

---

## Mode 2: File Notification (Event-Driven)

```
How it works:
    You enable cloud-native file events:
        Azure → Event Grid + Queue Storage
        AWS   → SNS + SQS
        GCP   → Pub/Sub
    
    When a file lands in ADLS:
        Azure Event Grid fires: "new file: invoice_04.csv just arrived"
        Message goes to a queue
        Autoloader reads from the queue → processes that specific file
    
    No folder scanning ever needed
    Near-instant detection (seconds after file lands)
    
Requirements:
    ❌ Elevated cloud permissions to set up Event Grid + Queue
       (your service principal needs rights to create Azure resources)
    ❌ Additional Azure infrastructure (Event Grid, Queue Storage)
    ✅ Lowest latency
    ✅ True event-driven architecture
```

---

## Switching Between Modes

```python
# Default: directory listing
spark.readStream.format("cloudFiles") \
    .option("cloudFiles.format", "csv") \
    # no useNotifications option needed

# File notification mode:
spark.readStream.format("cloudFiles") \
    .option("cloudFiles.format", "csv") \
    .option("cloudFiles.useNotifications", "true") \   # ← this switches modes
```

---

## Which Mode to Choose

```
Directory Listing (default):
    ✅ No extra cloud permissions needed
    ✅ Works out of the box
    ✅ Scales to millions of files (RocksDB)
    ✅ Use for: most scenarios, batch or streaming
    ⚠️  Slight latency vs notification mode

File Notification:
    ✅ Lowest latency (seconds from file arrival to processing)
    ✅ No folder scanning — pure event-driven
    ✅ Use for: real-time streaming, sub-minute SLAs
    ❌ Requires elevated cloud permissions
    ❌ More infrastructure to set up/maintain
```

---

# 🟠 PHASE 4 — Anatomy of an Autoloader Query

## The Complete Code Pattern

```python
# ── READ STREAM ─────────────────────────────────────────────────
df = (
    spark.readStream
    .format("cloudFiles")                          # ← Autoloader's source format
    .option("cloudFiles.format", "csv")            # ← format of the actual files
    .option("pathGlobFilter", "*.csv")             # ← only process .csv files
    .option("header", "true")                      # ← CSV has header row
    .option("cloudFiles.schemaLocation",           # ← where to store/evolve schema
            "/Volumes/dev/bronze/checkpoint/autoloader/_schemas")
    .option("cloudFiles.schemaHints",              # ← override types for specific cols
            "quantity INT, unit_price DOUBLE")
    .load("/Volumes/dev/bronze/landing/*/*/*")     # ← source path (wildcard for nested)
    .select(
        "*",                                       # ← all data columns
        "_metadata.file_name".alias("source_file") # ← add audit column
    )
)

# ── WRITE STREAM ────────────────────────────────────────────────
(
    df.writeStream
    .format("delta")                               # ← write to Delta table
    .outputMode("append")                          # ← always append for file ingestion
    .option("checkpointLocation",                  # ← state for exactly-once
            "/Volumes/dev/bronze/checkpoint/autoloader")
    .option("mergeSchema", "true")                 # ← allow schema evolution in Delta
    .trigger(availableNow=True)                    # ← batch mode: process all new, then stop
    .toTable("dev.bronze.invoice_al")              # ← target Delta table
)
```

---

## Every Option Explained

### On the READ side:

```
.format("cloudFiles")
    → Tells Spark: use the Autoloader source
    → Not "csv" or "json" here — that goes in cloudFiles.format

.option("cloudFiles.format", "csv")
    → The actual format of the files being read
    → Separate from .format("cloudFiles") above
    → Common values: "csv", "json", "avro", "parquet"

.option("pathGlobFilter", "*.csv")
    → Wildcard filter at the FILE level
    → Even though the folder has wildcard paths,
      this ensures only .csv files are picked up
    → Useful when a folder has mixed file types

.option("header", "true")
    → CSV-specific: treat first row as column names
    → Same as you'd use in spark.read.csv()

.option("cloudFiles.schemaLocation", "/path/to/schema")
    → WHERE Autoloader stores the evolving schema definition
    → Must persist across runs (use a stable volume path)
    → Autoloader reads this on startup to know current schema
    → Writes updates here when schema evolves

.option("cloudFiles.schemaHints", "quantity INT, unit_price DOUBLE")
    → By default, Autoloader reads everything as STRING (safest)
    → Schema hints override specific columns with proper types
    → Only need to specify columns where type matters
    → Other columns remain as inferred (usually STRING)

.load("/Volumes/dev/bronze/landing/*/*/*")
    → Source path with wildcards
    → */*/* = any subfolder 3 levels deep
    → Matches: /landing/2024/01/15/, /landing/2024/01/16/, etc.
    → Autoloader recursively discovers files under all matching paths
```

---

### On the WRITE side:

```
.outputMode("append")
    → New files add new rows — never update existing rows
    → Correct mode for file ingestion
    → "complete" and "update" modes don't apply here

.option("checkpointLocation", "/path/to/checkpoint")
    → THE most important option
    → Where Autoloader stores its state:
        - Which files have been processed
        - Current streaming offsets
        - RocksDB metadata
    → Must be stable, persistent path (volume, ADLS)
    → NEVER change this path — changing it = losing all tracking state
    → Each Autoloader stream needs its OWN checkpoint location
    
.option("mergeSchema", "true")
    → When new columns appear in source files,
      allow them to be added to the Delta table
    → Works with schema evolution modes

.trigger(availableNow=True)
    → Batch mode: "process all available new files, then stop"
    → Equivalent of "incremental batch" 
    → Alternative: .trigger(processingTime="1 minute") for continuous

.toTable("dev.bronze.invoice_al")
    → Writes to a Unity Catalog table
    → Creates it if doesn't exist
    → Alternative: .start("/path/") to write to path instead
```

---

## The `_metadata` Column — Audit Trail

```python
.select("*", "_metadata.file_name".alias("source_file"))
```

Every file read by Autoloader has a hidden `_metadata` struct containing:

```
_metadata.file_name     → "invoice_2024_01_15.csv"
_metadata.file_path     → full path to the file
_metadata.file_size     → file size in bytes
_metadata.file_modification_time → when file was last modified
```

**Why add source_file to your Delta table?**
```
Data quality issue found → trace back to which exact file caused it
Audit requirement → prove when data arrived and from where
Debugging → "why does row 5001 have a wrong value?" → source_file = "bad_export.csv"
```

This is a **standard practice** in production ingestion pipelines.

---

### 🧠 Quick Check #2

> **Q1:** You have two Autoloader streams — one for invoices, one for customers. Can they share the same checkpoint location?
>
> *No. Each stream must have its own checkpoint location. Sharing would corrupt both streams' state — they'd interfere with each other's file tracking.*

> **Q2:** Autoloader reads all columns as STRING by default. Your analysis needs `quantity` as INT. How do you fix this without creating a separate transformation?
>
> *Use `schemaHints`: `.option("cloudFiles.schemaHints", "quantity INT")`. This tells Autoloader to cast that specific column to INT during read.*

> **Q3:** What's the difference between `cloudFiles.format` and the `.format()` method?
>
> *`.format("cloudFiles")` tells Spark to use the Autoloader engine. `.option("cloudFiles.format", "csv")` tells Autoloader what format the actual source files are. They are different levels — one picks the engine, one picks the file format.*

---

# 🔴 PHASE 5 — Checkpointing: How Exactly-Once Works at Scale

## The Problem Streaming Faces

```
Continuous stream running, processing files all day.
Suddenly: cluster crashes, network failure, job killed.

Without checkpointing:
    Stream restarts from scratch
    → Reprocesses files already loaded
    → Duplicate rows in Delta table ❌

With checkpointing:
    Stream restarts
    → Reads checkpoint: "I was at offset X, had processed files A,B,C"
    → Resumes from exactly where it left off
    → No reprocessing, no duplicates ✅
```

---

## What's Inside the Checkpoint Directory

```
/Volumes/dev/bronze/checkpoint/autoloader/
    ├── commits/                    ← which micro-batches completed
    │     ├── 0                     ← batch 0 committed
    │     ├── 1                     ← batch 1 committed
    │     └── 2                     ← batch 2 committed
    ├── offsets/                    ← what file offsets were consumed
    │     ├── 0                     ← offset for batch 0
    │     └── 1                     ← offset for batch 1
    ├── sources/
    │     └── 0/
    │           └── rocksdb/        ← ← ← THE TRACKER
    │                 └── ...       ← RocksDB database tracking all processed files
    └── _schemas/                   ← schema evolution history
          └── 0                     ← current schema version
```

---

## RocksDB — Why It Enables Scale

```
COPY INTO uses:
    A simple log file listing processed filenames
    → Works for thousands of files
    → Gets slow for millions

Autoloader uses:
    RocksDB — an embedded key-value store optimized for:
        - Fast lookups ("have I seen this file before?")
        - Fast writes ("mark this file as processed")
        - Handles tens of millions of entries efficiently
    
    Result: "Have I seen invoice_5000000.csv before?"
    RocksDB answers in microseconds, even with 5M tracked files ✅
```

---

## The Golden Rule of Checkpoints

```
✅ DO:
    Use a stable, persistent path (Volume or ADLS)
    Give each Autoloader stream its own unique checkpoint path
    Never manually edit files inside the checkpoint folder
    Back up checkpoint if this is a critical production stream

❌ NEVER:
    Change the checkpoint path for an existing stream
        → Autoloader thinks it's a brand new stream
        → Reprocesses ALL files from scratch
        → Potential massive duplicates in your Delta table

    Delete the checkpoint folder while the stream has unprocessed files
        → Same consequence as above

    Share checkpoint between two streams
        → Corrupts both
```

---

# 🟠 PHASE 6 — Schema Evolution Modes

## Why Schema Evolution Matters

In real data engineering, source file schemas are not static:
- Upstream system adds a new column next quarter
- A data provider sends an extra field starting next month
- Old files have 10 columns, new files have 12 columns

Autoloader has 4 strategies for handling this. **You must choose the right one for your use case.**

---

## Mode 1: addNewColumns (Default)

```
Behavior:
    New column appears in an incoming file
    
    Step 1: Stream fails (throws schema mismatch error)
    Step 2: Autoloader automatically updates _schemas/
            to include the new column
    Step 3: You re-run the stream
    Step 4: Stream succeeds, new column added to Delta table
    Step 5: Old rows have NULL for the new column

Is this really "automatic" if it fails first?
    Yes — the failure is the signal that schema changed
    The update to _schemas happens automatically during the failure
    Re-run = stream works with new schema
    Requires mergeSchema=true on the writeStream

Best for:
    ✅ Controlled environments where schema changes are expected
       but should be visible (failure = notification something changed)
    ✅ When you want downstream systems to be aware of schema changes
```

---

## Mode 2: rescue

```python
.option("cloudFiles.schemaEvolutionMode", "rescue")
```

```
Behavior:
    New column appears in an incoming file
    
    Stream does NOT fail ✅
    New column is NOT added to the Delta table schema
    Instead: new column's value is stored as JSON
             inside a special column called _rescued_data
    
Result in Delta table:
    invoice_number | stock_code | quantity | _rescued_data
    INV001         | SC001      | 5        | null
    INV002         | SC002      | 3        | {"state":"CA","new_state":"California"}
    ← row from new file → extra columns captured as JSON

Accessing rescued data:
    SELECT 
        invoice_number,
        get_json_object(_rescued_data, '$.state') AS state
    FROM dev.bronze.invoice_al
    WHERE _rescued_data IS NOT NULL

Best for:
    ✅ You don't want streams to fail on schema changes
    ✅ You still want to capture the new data for later investigation
    ✅ Production streams where uptime > perfect schema
    ✅ "Fail safe" mode
```

---

## Mode 3: none

```python
.option("cloudFiles.schemaEvolutionMode", "none")
```

```
Behavior:
    New column appears in an incoming file
    
    Stream continues without failure ✅
    New column is completely IGNORED ✅
    No _rescued_data column either
    New column values are silently discarded

Result in Delta table:
    invoice_number | stock_code | quantity
    INV001         | SC001      | 5
    INV002         | SC002      | 3
    ← row from new file → extra columns just gone, no trace

Best for:
    ✅ You have strict schema contract — extra fields are noise
    ✅ You don't want rescued data cluttering your table
    ✅ Downstream consumers expect exact schema, no surprises
    ⚠️  Risk: data loss — you never know what was in those new columns
```

---

## Mode 4: failOnNewColumns

```python
.option("cloudFiles.schemaEvolutionMode", "failOnNewColumns")
```

```
Behavior:
    New column appears in an incoming file
    
    Stream FAILS IMMEDIATELY ❌
    Does NOT auto-update schema
    Does NOT rescue data
    
    You must MANUALLY:
        Option A: Fix the source file (remove extra columns)
        Option B: Update the schema manually, restart stream

Best for:
    ✅ Strict governance environments
    ✅ Data contracts are enforced — any schema change = rejected
    ✅ "Alert me, don't auto-handle" philosophy
    ✅ Financial/compliance pipelines where unexpected columns = data quality issue
```

---

## The 4 Modes Side by Side

```
New column arrives in source file...

addNewColumns:    Stream fails → auto-updates schema → re-run works
                  ⚠️ Needs intervention   ✅ Schema stays accurate

rescue:           Stream continues → new col in _rescued_data JSON
                  ✅ No intervention    ⚠️ Data in JSON, not native column

none:             Stream continues → new col silently dropped
                  ✅ No intervention    ❌ Data loss

failOnNewColumns: Stream fails → you fix manually → restart
                  ❌ Always needs intervention   ✅ Strictest control
```

| Mode | Stream Fails? | Data Captured? | Intervention Needed? | Use When |
|---|---|---|---|---|
| **addNewColumns** | First time only | ✅ Full column | Re-run once | Default, most common |
| **rescue** | ❌ Never | ✅ As JSON | None | Production uptime critical |
| **none** | ❌ Never | ❌ Discarded | None | Strict schema contract |
| **failOnNewColumns** | ✅ Always | ❌ None | Every time | Governance/compliance |

---

### 🧠 Quick Check #3

> **Q1:** You run a financial pipeline. Schema changes must be rejected and investigated. Which mode?
>
> *`failOnNewColumns` — stream fails immediately on schema change, forcing manual investigation before resuming.*

> **Q2:** Your production stream must never stop. New columns are possible but rare. You want to capture the data without breaking. Which mode?
>
> *`rescue` — stream never fails, new column values are captured in `_rescued_data` for later inspection.*

> **Q3:** After using `addNewColumns` mode, your stream failed due to a new column. You didn't change any code. You just re-ran it. Did Autoloader automatically update the schema?
>
> *Yes. During the failure, Autoloader automatically updated the `_schemas` folder in the checkpoint location. Re-running uses the updated schema — new column is now included.*

---

# 🟣 PHASE 7 — Autoloader vs COPY INTO: Final Framework

## They Solve the Same Problem, Differently

```
SAME GOAL: "Load new files from cloud storage into Delta, exactly once"

DIFFERENT APPROACH:
    COPY INTO  → SQL command, batch, folder scan each time
    Autoloader → Streaming, RocksDB tracking, event-driven or scalable scan
```

---

## Complete Decision Matrix

| Factor | COPY INTO | Autoloader |
|---|---|---|
| **Interface** | SQL command | PySpark/Scala code |
| **Processing style** | Batch only | Batch OR streaming |
| **Files per day** | Up to tens of thousands | Millions+ |
| **Nested folders** | Complex glob patterns | Native wildcard support |
| **Latency** | Next scheduled run | Seconds (streaming mode) |
| **Exactly-once tracking** | _copy_into_log in Delta log | RocksDB in checkpoint |
| **Schema evolution** | mergeSchema option | 4 dedicated modes |
| **Setup complexity** | Minimal (SQL) | More code required |
| **Audit column** | Manual via SELECT | Built-in `_metadata` |
| **Transformation** | Custom SELECT | .select() on DataFrame |
| **Scale limit** | ~Thousands of files | No practical limit |
| **Best for** | Simple batch ingestion | Scale + streaming |

---

## The Real-World Progression

```
Project starts:
    10 CSV files per day
    → COPY INTO ✅ (simple, SQL, done in 5 minutes)

Project grows:
    50,000 files per day
    → Still COPY INTO probably fine, monitor performance

Project matures:
    500,000 files per day, nested folders, near-real-time needed
    → Migrate to Autoloader ✅

Enterprise scale:
    Millions of files per hour, streaming SLA, schema evolution
    → Autoloader + File Notification mode + rescue schema evolution
```

---

## 🗺️ Concept Connection Map

```
Autoloader
    ├── built on → Structured Streaming (cloudFiles source)
    ├── extends → COPY INTO (same goal, higher scale)
    ├── exactly-once via → Checkpoint + RocksDB (not _copy_into_log)
    ├── file detection → Directory Listing (default) or File Notification
    ├── schema evolution → 4 modes (addNewColumns, rescue, none, failOnNewColumns)
    └── audit trail → _metadata.file_name column

Checkpoint
    ├── contains → RocksDB (file tracking) + offsets + schema history
    ├── rule → one checkpoint per stream, never change path
    └── enables → fault tolerance, exactly-once on restarts

Schema Evolution Modes
    ├── addNewColumns → fail once, auto-update, re-run (default)
    ├── rescue → never fail, JSON column for new data
    ├── none → never fail, new cols discarded silently
    └── failOnNewColumns → always fail, manual governance
```

---

## 📝 Active Recall Prompts

**Day 1:**
> *"Explain the difference between Directory Listing and File Notification modes in Autoloader. When would you choose each?"*
>
> *"What is the checkpoint location? What would happen if you deleted it? What would happen if you changed its path?"*

**Day 3:**
> *"Walk through all 4 schema evolution modes. For each: does the stream fail? Is the data captured? When would you use it?"*
>
> *"A new file arrives with an extra column `discount_pct`. Your mode is `rescue`. What does the Delta table look like? How do you query the rescued data?"*

**Day 7:**
> *"Your team ingests 2M JSON files per hour from IoT sensors across 500 devices (files land in /sensors/device_id/date/hour/*.json). Design the full Autoloader setup: detection mode, schema evolution mode, checkpoint path strategy, trigger type. Justify every choice."*

---

**Next up: Delta Live Tables (DLT)** — the declarative pipeline framework that builds on everything you've learned (Autoloader, Delta, streaming) into a fully managed, self-healing pipeline with built-in data quality rules. 🚀
