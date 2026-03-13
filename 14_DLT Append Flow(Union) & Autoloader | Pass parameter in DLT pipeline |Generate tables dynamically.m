# 🗺️ LEARNING ROADMAP — DLT Part 3: Autoloader + Append Flow + Dynamic Pipelines

> **Your level: 🟡 Intermediate** — you know DLT basics, now we go deeper

| Phase | Topic | Difficulty |
|-------|-------|-----------|
| 0 | **The New Problem** — What gaps still exist after DLT basics | 🟡 Intermediate |
| 1 | **Autoloader + DLT** — File ingestion inside a declarative pipeline | 🟡 Intermediate |
| 2 | **Append Flow** — Why normal union breaks streaming, and how to fix it | 🔴 Advanced |
| 3 | **Dynamic Pipelines** — Parameterizing DLT to generate tables at runtime | 🔴 Advanced |
| 4 | **Full Picture** — How all 3 fit together in one production pipeline | 🔴 Advanced |

---

---

# 📖 PHASE 0 — The New Problems This Video Solves

Before jumping into code, let's understand **exactly what pain points** these three features address. Every feature exists because of a real engineering headache.

---

## Problem 1: Files Keep Landing in Cloud Storage

Your upstream systems drop CSV/JSON/Parquet files into Azure Data Lake Storage (ADLS) every hour. You already know Autoloader from earlier. But now the question is:

> *"How do I plug Autoloader into a DLT pipeline? Where does the checkpoint go? How do I specify the schema?"*

In a regular notebook, you'd manage `checkpointLocation` yourself. Inside DLT, the rules change slightly.

---

## Problem 2: You Have TWO Streaming Sources That Need To Be One Table

Imagine this real scenario:

```
Source A: Historical orders flowing from orders_raw (Delta table)
Source B: New orders arriving as CSV files via Autoloader (ADLS)

Goal: One unified orders table that combines both
```

Your instinct: "Just do a `.union()`!"

**Why that breaks with streaming:** A naive union of two streaming DataFrames means DLT has to re-read both sources entirely every run. As data grows, this becomes a full reprocessing job. You lose all the incremental benefits that make streaming tables efficient.

> **Append Flow** is the engineering solution to this — incrementally append from multiple streaming sources into one target table.

---

## Problem 3: Runtime-Driven Table Creation

Your business team says:
> *"We need separate Gold tables filtered by each order status: `O` (open), `F` (fulfilled), `P` (pending)..."*

The naive approach: copy-paste the same aggregation function 5 times, changing the filter each time. That's brittle, hard to maintain, and embarrassing in code review.

> **Pipeline parameterization** lets you pass a config value at runtime and generate N tables from a loop — without touching the pipeline code.

---

---

# 📖 PHASE 1 — Autoloader Inside DLT 🗂️

## Quick Recap: What Autoloader Does (First Principles)

Autoloader watches a cloud storage folder. When new files arrive, it reads them incrementally — only the new files, never re-reading what's already processed. It tracks this via a checkpoint.

**In a regular notebook**, you write:
```python
spark.readStream
    .format("cloudFiles")
    .option("cloudFiles.format", "csv")
    .option("cloudFiles.schemaLocation", "/path/to/schema")
    .option("cloudFiles.schemaEvolutionMode", "none")
    .load("/path/to/landing/files/")
```

And you also write: `.option("checkpointLocation", "/path/to/checkpoint")`

---

## Inside DLT: What Changes?

**One key difference:** DLT manages the checkpoint automatically. You don't specify `checkpointLocation` — DLT creates it internally under `databricks_internal/<pipeline-id>/`. This is the same checkpoint concept you learned, just abstracted away.

Everything else stays the same.

---

## Setting Up the Storage Structure First

Before writing code, you need two things in your managed volume:

```
Dev (catalog)
  └── ETL (schema)
        └── Landing (managed volume)
              ├── files/              ← CSV files land here (your "inbox")
              └── autoloader_schemas/ ← Autoloader stores discovered schema here
```

**Why separate the schema folder?**
Autoloader needs to persist the schema it infers (or you define). If you restart the pipeline, it reads the schema from this folder instead of re-inferring from scratch. This prevents schema drift bugs.

---

## The Autoloader DLT Code

```python
import dlt

# Define paths from the managed volume
landing_path = "/Volumes/dev/etl/landing/files/"
schema_location = "/Volumes/dev/etl/landing/autoloader_schemas/"

# Define the schema explicitly (best practice — don't trust auto-inference in production)
from pyspark.sql.types import StructType, StructField, StringType, LongType, DoubleType

orders_schema = StructType([
    StructField("order_key", LongType()),
    StructField("customer_key", LongType()),
    StructField("order_status", StringType()),
    StructField("total_price", DoubleType()),
    StructField("order_date", StringType()),
    StructField("market_segment", StringType())
])

@dlt.table(
    name="orders_autoloader_bronze",
    comment="Orders ingested from CSV files via Autoloader",
    table_properties={"quality": "bronze"}
)
def orders_autoloader_bronze():
    return (
        spark.readStream
            .format("cloudFiles")                              # ← Autoloader format
            .schema(orders_schema)                             # ← explicit schema
            .option("cloudFiles.format", "csv")                # ← incoming file type
            .option("cloudFiles.schemaLocation", schema_location)  # ← schema persistence
            .option("cloudFiles.schemaEvolutionMode", "none")  # ← no schema drift allowed
            # ❌ NO checkpointLocation needed — DLT manages it
            .load(landing_path)                                # ← watch this folder
    )
```

---

## The `schemaEvolutionMode = "none"` Decision

This is a real engineering decision worth understanding:

| Mode | Behavior | When To Use |
|------|----------|------------|
| `"none"` | If new columns appear in files → pipeline fails | Production — you want to know immediately if schema changed |
| `"addNewColumns"` | New columns added automatically to table | Exploratory / flexible ingestion |
| `"rescue"` | Unexpected columns saved to a `_rescued_data` column | When you want to capture unknown data without failing |

In production, `"none"` is the safest. A schema change from upstream is a *contract violation* — you want it to fail loudly, not silently corrupt your Silver and Gold tables.

---

## ✅ Quick Quiz #1 — Autoloader in DLT

**Q1:** In a regular notebook Autoloader setup, you specify `checkpointLocation`. Why don't you need to in DLT?
<details><summary>Answer</summary>DLT automatically creates and manages checkpoint files internally under `databricks_internal/<pipeline-id>/`. The pipeline ID is the organizational key.</details>

**Q2:** You're ingesting partner data files. The partner occasionally adds new columns without warning. Which `schemaEvolutionMode` would you use to capture unexpected columns without breaking the pipeline?
<details><summary>Answer</summary>`"rescue"` — unexpected columns get saved to `_rescued_data` rather than crashing the pipeline.</details>

**Q3:** What is the `autoloader_schemas` folder for? What happens if you delete it?
<details><summary>Answer</summary>It stores the persisted schema Autoloader inferred or you defined. Deleting it forces Autoloader to re-infer the schema on next run, which risks schema mismatch if files have changed.</details>

---

---

# 📖 PHASE 2 — Append Flow: Merging Streaming Sources 🌊🌊→🌊

## The Core Problem (In Depth)

Let's think carefully about why normal union fails with streaming.

### Scenario
You have:
- `orders_bronze` — a Streaming Table fed from `orders_raw` (a Delta table with 7.5M rows)
- `orders_autoloader_bronze` — a Streaming Table fed from Autoloader (CSV files in ADLS)

You want: `orders_union_bronze` = all rows from both sources combined.

### Why `.union()` Breaks This

```python
# WRONG approach — do NOT do this
@dlt.table(name="orders_union_bronze")
def orders_union_bronze():
    stream_a = dlt.read_stream("orders_bronze")
    stream_b = dlt.read_stream("orders_autoloader_bronze")
    return stream_a.union(stream_b)   # ← This re-reads BOTH from scratch every run
```

**The problem:** When you `.union()` two streaming sources this way, Spark treats it as a stateless operation — on every pipeline run, it processes both streams from the beginning. With 7.5 million existing rows in `orders_bronze`, run 100 means re-reading 750 million rows worth of history. Your cost and latency explode.

---

## The Engineering Solution: Append Flow

**Append Flow** is DLT's mechanism for saying:

> *"I have a target table. I want to incrementally append data INTO it from multiple streaming sources. Each source tracks its own checkpoint. Nobody re-reads history."*

It decouples the **target table** from its **input flows**. You define:
1. **The target table** (empty shell — just schema, no source)
2. **One or more flow functions** (each reads from one streaming source and appends to the target)

Each flow function has its own checkpoint → each source is tracked independently → only new data moves.

---

## The Three-Part Append Flow Pattern

```python
import dlt
from pyspark.sql.functions import current_timestamp

# ── STEP 1: Declare the target table (no source — just an empty shell) ──────────

@dlt.table(
    name="orders_union_bronze",
    comment="Unified orders from Delta table + Autoloader files"
)
def orders_union_bronze():
    pass   # ← intentionally empty — this is just the table definition


# ── STEP 2: Flow 1 — append from orders_bronze (existing Delta streaming table) ─

@dlt.append_flow(target="orders_union_bronze")   # ← points to the target table above
def append_from_orders_bronze():
    return dlt.read_stream("orders_bronze")        # ← reads incrementally (checkpointed)


# ── STEP 3: Flow 2 — append from Autoloader bronze table ─────────────────────────

@dlt.append_flow(target="orders_union_bronze")   # ← same target
def append_from_autoloader():
    return dlt.read_stream("orders_autoloader_bronze")  # ← reads incrementally (checkpointed)
```

---

## How This Works Internally — The Checkpoint Isolation

```
orders_union_bronze (target table)
    │
    ├── append_from_orders_bronze
    │       └── Checkpoint A: "I've read up to offset 7,510,000 from orders_bronze"
    │
    └── append_from_autoloader
            └── Checkpoint B: "I've read 3 files from landing/files/"
```

Each flow has its **own independent checkpoint**. They don't interfere with each other. On every run:
- Flow A reads only new rows from `orders_bronze` since last run
- Flow B reads only new CSV files since last run
- Both results are appended to `orders_union_bronze`

**Result:** Fully incremental, no re-reads, no wasted compute.

---

## Visual: Before and After Append Flow

```
WITHOUT Append Flow (union approach):
    Run 1: reads 7.5M + 0 files  = 7.5M rows processed
    Run 2: reads 7.5M + 2 files  = 7.5M rows RE-PROCESSED + 2 files
    Run 3: reads 7.5M + 5 files  = 7.5M rows RE-PROCESSED + 5 files  ← disaster

WITH Append Flow:
    Run 1: reads 7.5M + 0 files  = 7.5M rows processed
    Run 2: reads 10K new + 2 files = only new data
    Run 3: reads 0 new + 3 files   = only new files  ← efficient
```

---

## The Full Pipeline So Far

```
orders_raw (Delta table)
    ↓ [Streaming Table]
orders_bronze ──────────────────────────────────┐
                                                 ├── [append_flow] → orders_union_bronze
ADLS landing/files/ (CSV files)                  │
    ↓ [Autoloader - Streaming Table]             │
orders_autoloader_bronze ───────────────────────┘
                                                 ↓
                                          orders_union_bronze (union target)
                                                 ↓ [join with customer_bronze]
                                          orders_silver (Materialized View)
                                                 ↓ [aggregate]
                                          orders_aggregated_gold (Materialized View)
```

---

## 🗺️ Concept Connection Map — Append Flow

```
Append Flow
    ├── solves → naive union re-read problem with streaming sources
    ├── requires → target table defined separately (empty shell pattern)
    ├── each flow has → its own independent checkpoint
    ├── decorator → @dlt.append_flow(target="table_name")
    ├── connects to → Checkpoint concept (same as Autoloader, Streaming Tables)
    └── contrasts with → .union() on streams (stateless, re-reads all history)
```

---

## ✅ Quick Quiz #2 — Append Flow

**Q1:** You union two streaming tables using `.union()`. On the 50th pipeline run, what data does it process?
<details><summary>Answer</summary>It re-reads ALL historical data from both sources from the beginning — not just new data. This grows linearly with data volume.</details>

**Q2:** In Append Flow, why is the target table defined with an empty `pass` function body?
<details><summary>Answer</summary>The target table is just a container/schema definition. It has no source itself — data flows INTO it from the `@dlt.append_flow` functions. Separating the definition from the flows allows multiple independent sources to write to the same table.</details>

**Q3:** You have 3 streaming sources (Kafka, Autoloader, Delta CDC feed) that all need to be unioned into one table. How many `@dlt.append_flow` decorators do you need?
<details><summary>Answer</summary>3 — one per source, each pointing to the same target table. Each flow has its own independent checkpoint.</details>

**Q4:** What is the key operational benefit of Append Flow over a naive `.union()`?
<details><summary>Answer</summary>Each flow maintains its own checkpoint, so each source is read incrementally — only new data since last run. No historical re-processing.</details>

---

---

# 📖 PHASE 3 — Dynamic Pipelines: Parameterization 🔧

## The Problem: Copy-Paste Pipeline Hell

Your business team wants separate Gold tables per order status:

```python
# NAIVE APPROACH — copy-paste 5 times:

@dlt.table(name="orders_ag_o_gold")
def orders_ag_o_gold():
    return dlt.read("orders_silver").filter(col("order_status") == "o").groupBy(...)

@dlt.table(name="orders_ag_f_gold")
def orders_ag_f_gold():
    return dlt.read("orders_silver").filter(col("order_status") == "f").groupBy(...)

@dlt.table(name="orders_ag_p_gold")
def orders_ag_p_gold():
    return dlt.read("orders_silver").filter(col("order_status") == "p").groupBy(...)
# ... and so on
```

**Problems with this:**
- Adding a new status = edit pipeline code, redeploy
- All 5 functions are identical except the filter value
- When the aggregation logic changes, you update 5 places (and miss one)
- Not scalable — what if there are 20 statuses?

---

## The Solution: Pipeline Configuration Parameters

DLT pipelines accept **key-value configuration parameters** that you set in the pipeline UI (or API). These are accessible at runtime via `spark.conf.get("key")`.

**Setup in Pipeline UI:**
```
Key:   custom.order_status
Value: o,f
```

This comma-separated string is your input. The pipeline reads it, splits it, and loops.

---

## The Dynamic Table Generation Pattern

```python
from pyspark.sql.functions import count, sum, current_timestamp, col

# ── Read the parameter at pipeline startup ─────────────────────────────────────
order_statuses_raw = spark.conf.get("custom.order_status", "o,f")
# spark.conf.get("key", "default") ← "o,f" is the fallback if not set

order_statuses = order_statuses_raw.split(",")
# result: ["o", "f"]

# ── Loop: create one Gold table per status ────────────────────────────────────
for status in order_statuses:

    # Python closure trick: capture `status` value correctly in each loop iteration
    def make_gold_table(s=status):    # ← s=status captures current value, not reference
        @dlt.table(
            name=f"orders_ag_{s}_gold",      # ← dynamic name: orders_ag_o_gold, orders_ag_f_gold
            comment=f"Gold aggregation for order status: {s}",
            table_properties={"quality": "gold", "status_filter": s}
        )
        def dynamic_gold():
            return (
                dlt.read("orders_silver")
                .filter(col("order_status") == s)        # ← filter by this status
                .groupBy("market_segment")
                .agg(
                    count("order_key").alias("count_orders"),
                    sum("total_price").alias("sum_total_price")
                )
                .withColumn("insert_date", current_timestamp())
            )
    
    make_gold_table(status)    # ← call the wrapper to register the table
```

**What DLT creates:**
```
Value: "o,f"
    → orders_ag_o_gold  (filtered to order_status = 'o')
    → orders_ag_f_gold  (filtered to order_status = 'f')

Value: "o,f,p"  (change config, no code change)
    → orders_ag_o_gold
    → orders_ag_f_gold
    → orders_ag_p_gold  ← automatically created
```

---

## ⚠️ The Python Closure Trap — Why `s=status` Matters

This is a subtle but critical Python concept that bites engineers in loops.

```python
# BROKEN — classic Python closure bug:
for status in ["o", "f"]:
    @dlt.table(name=f"orders_ag_{status}_gold")
    def dynamic_gold():
        return dlt.read("orders_silver").filter(col("order_status") == status)
        #                                                              ^^^^^^
        # By the time this runs, `status` = "f" for BOTH tables
        # Both tables filter on "f" — the loop variable has been overwritten
```

```python
# FIXED — capture by value with default argument:
for status in ["o", "f"]:
    def make_table(s=status):      # ← s is captured NOW as a copy
        @dlt.table(name=f"orders_ag_{s}_gold")
        def dynamic_gold():
            return dlt.read("orders_silver").filter(col("order_status") == s)
    make_table()
```

**The rule:** When creating functions inside a loop in Python, always capture loop variables using `variable=variable` in the function signature. Otherwise, all functions share the same reference to the final loop value.

---

## Changing Parameters Without Touching Code

This is the real power. Once built, the pipeline is config-driven:

| Business Ask | How You Respond |
|-------------|----------------|
| "Add order status P" | Go to pipeline config → change `"o,f"` to `"o,f,p"` → run |
| "Remove order status F" | Change `"o,f"` to `"o"` → run → `orders_ag_f_gold` disappears |
| "Add 10 new statuses" | Change the config string → 10 new tables auto-created |

**Zero code changes. Zero redeployment.**

---

## 🗺️ Concept Connection Map — Dynamic Pipelines

```
Pipeline Parameterization
    ├── reads config via → spark.conf.get("custom.order_status")
    ├── set in → Pipeline UI (key-value configuration)
    ├── enables → runtime-driven table generation (loop over values)
    ├── pattern → make_table(s=status) wrapper to avoid closure bug
    ├── contrasts with → hardcoded copy-paste functions (brittle)
    └── connects to → DLT declarative model (you define what, DLT handles how)
```

---

## ✅ Quick Quiz #3 — Dynamic Pipelines

**Q1:** You set the pipeline config `custom.order_status = "o,f,p,c"`. How many Gold tables does the dynamic loop create?
<details><summary>Answer</summary>4 — one per status: `orders_ag_o_gold`, `orders_ag_f_gold`, `orders_ag_p_gold`, `orders_ag_c_gold`.</details>

**Q2:** Why is the `make_table(s=status)` wrapper pattern needed instead of defining the decorated function directly inside the loop?
<details><summary>Answer</summary>Python closures capture variable references, not values. Without the wrapper, by the time DLT executes each function, `status` has been overwritten by the final loop value — all tables filter on the same status. The `s=status` default argument captures the current value immediately.</details>

**Q3:** A new order status `X` emerges. What do you change to add `orders_ag_x_gold` to the pipeline?
<details><summary>Answer</summary>Only the pipeline configuration — change `custom.order_status` from `"o,f"` to `"o,f,x"`. No code changes required.</details>

**Q4:** How do you read a pipeline configuration parameter inside DLT notebook code?
<details><summary>Answer</summary>`spark.conf.get("custom.order_status")` — with an optional second argument as a default value if the key isn't set.</details>

---

---

# 📖 PHASE 4 — The Full Production Pipeline 🏭

## Everything Together — Annotated Architecture

```python
import dlt
from pyspark.sql.functions import current_timestamp, count, sum, col
from pyspark.sql.types import StructType, StructField, StringType, LongType, DoubleType

# ── CONFIG ────────────────────────────────────────────────────────────────────
landing_path    = "/Volumes/dev/etl/landing/files/"
schema_location = "/Volumes/dev/etl/landing/autoloader_schemas/"

orders_schema = StructType([...])  # define explicitly


# ══ BRONZE LAYER ══════════════════════════════════════════════════════════════

# 1. Existing Delta table source (incremental streaming)
@dlt.table(name="orders_bronze", table_properties={"quality": "bronze"})
def orders_bronze():
    return spark.readStream.table("dev.bronze.orders_raw")


# 2. Autoloader file source (incremental file ingestion)
@dlt.table(name="orders_autoloader_bronze", table_properties={"quality": "bronze"})
def orders_autoloader_bronze():
    return (
        spark.readStream
            .format("cloudFiles")
            .schema(orders_schema)
            .option("cloudFiles.format", "csv")
            .option("cloudFiles.schemaLocation", schema_location)
            .option("cloudFiles.schemaEvolutionMode", "none")
            .load(landing_path)
    )


# 3. Union target table (empty shell — receives append flows)
@dlt.table(name="orders_union_bronze", table_properties={"quality": "bronze"})
def orders_union_bronze():
    pass


# 4. Append Flow: from orders_bronze → union table
@dlt.append_flow(target="orders_union_bronze")
def append_delta_orders():
    return dlt.read_stream("orders_bronze")


# 5. Append Flow: from autoloader → union table
@dlt.append_flow(target="orders_union_bronze")
def append_autoloader_orders():
    return dlt.read_stream("orders_autoloader_bronze")


# ══ CUSTOMER BRONZE ═══════════════════════════════════════════════════════════
@dlt.table(name="customer_bronze", table_properties={"quality": "bronze"})
def customer_bronze():
    return spark.read.table("dev.bronze.customer_raw")


# ══ SILVER LAYER ══════════════════════════════════════════════════════════════
@dlt.view(name="join_view")
def join_view():
    orders = dlt.read_stream("orders_union_bronze")   # ← now reads from union
    customers = dlt.read("customer_bronze")
    return orders.join(customers, orders.customer_key == customers.customer_key, "left")


@dlt.table(name="orders_silver", table_properties={"quality": "silver"})
def orders_silver():
    return dlt.read("join_view").withColumn("insert_date", current_timestamp())


# ══ GOLD LAYER — DYNAMIC ══════════════════════════════════════════════════════
order_statuses = spark.conf.get("custom.order_status", "o,f").split(",")

for status in order_statuses:
    def make_gold(s=status):
        @dlt.table(
            name=f"orders_ag_{s}_gold",
            table_properties={"quality": "gold"}
        )
        def dynamic_gold():
            return (
                dlt.read("orders_silver")
                .filter(col("order_status") == s)
                .groupBy("market_segment")
                .agg(
                    count("order_key").alias("count_orders"),
                    sum("total_price").alias("sum_total_price")
                )
                .withColumn("insert_date", current_timestamp())
            )
    make_gold(status)
```

---

## The Full DAG — Visual

```
orders_raw ──────────────────→ orders_bronze ───────────────┐
                                                              │ [append_flow]
ADLS/landing/files/ ──→ orders_autoloader_bronze ────────────┤
                                                              ↓
                                                    orders_union_bronze
                                                              ↓
customer_raw ──────────────→ customer_bronze ─────→ join_view (temp)
                                                              ↓
                                                    orders_silver
                                                              ↓
                                            ┌─────────────────┼─────────────────┐
                                            ↓                 ↓                 ↓
                                   orders_ag_o_gold  orders_ag_f_gold  orders_ag_p_gold
                                   (status = 'o')    (status = 'f')    (status = 'p')
```

---

## 🗺️ Master Concept Connection Map — Full Session

```
This Session
    ├── Autoloader in DLT
    │     ├── format → "cloudFiles"
    │     ├── checkpoint → managed by DLT (no manual specification)
    │     ├── schemaLocation → persisted in managed volume folder
    │     ├── schemaEvolutionMode = "none" → production-safe, fails on schema change
    │     └── connects to → Streaming Table (same incremental checkpoint mechanism)
    │
    ├── Append Flow
    │     ├── solves → naive union re-read problem
    │     ├── pattern → empty target table + @dlt.append_flow per source
    │     ├── each flow → independent checkpoint → independent incremental reads
    │     └── contrasts with → .union() on streams (re-reads all history each run)
    │
    └── Dynamic Pipelines
          ├── parameters → set in Pipeline UI config (key-value)
          ├── read via → spark.conf.get("key", "default")
          ├── generates → N tables from 1 loop (no copy-paste)
          ├── Python closure trap → use make_table(s=status) wrapper
          └── operational benefit → add/remove tables by changing config, zero code changes
```

---

## ✅ Final Comprehensive Quiz

**Q1:** A new team member suggests using `.union()` to combine two streaming tables. What specific problem do you tell them will happen on the 100th pipeline run?
<details><summary>Answer</summary>On every run, `.union()` re-reads all historical data from both sources from the beginning. By run 100, if the table has 100M rows, it processes all 100M rows again — instead of just the few thousand new ones. Cost and runtime grow linearly with data size.</details>

**Q2:** Walk through exactly what happens on the second Autoloader run after 3 new CSV files land in the `files/` folder:
<details><summary>Answer</summary>The Append Flow reads the checkpoint for `append_from_autoloader` → checkpoint says "I've processed X files" → Autoloader detects 3 new files beyond checkpoint → reads only those 3 files → appends rows to `orders_union_bronze` → updates checkpoint to include the 3 new files. Zero re-reads of previously processed files.</details>

**Q3:** Design question: Your pipeline currently generates Gold tables for statuses `["o", "f"]`. The business adds 8 new statuses. What do you change, and what do you NOT change?
<details><summary>Answer</summary>Change ONLY the pipeline config: update `custom.order_status` to `"o,f,s1,s2,s3,s4,s5,s6,s7,s8"`. Change NOTHING in the notebook code. The loop generates all 10 tables automatically.</details>

**Q4:** Why is `schemaEvolutionMode = "none"` safer than `"addNewColumns"` in a production pipeline?
<details><summary>Answer</summary>With `"none"`, if the upstream CSV adds a column you didn't expect, the pipeline fails loudly — alerting you to a contract change before it silently propagates through Silver and Gold layers. With `"addNewColumns"`, the new column silently appears, potentially breaking downstream aggregations or confusing analysts.</details>

---

---

# 📝 Active Recall Prompts — Spaced Repetition

### 🔁 Day 1
- *"Explain Append Flow to someone who just learned DLT basics. What problem does it solve? How is it different from `.union()`?"*
- *"What are the 3 Autoloader configuration options you always set in DLT? What does each one do?"*

### 🔁 Day 3
- *"You need to combine 4 streaming sources into one Bronze table. Sketch the Append Flow structure: how many `@dlt.table` decorators? How many `@dlt.append_flow` decorators? How many checkpoints exist?"*
- *"Explain the Python closure bug in pipeline loops. Write both the broken version and the fixed version."*

### 🔁 Day 7
- *"Design a complete DLT pipeline: 3 data sources (Kafka topic, ADLS CSV files, existing Delta table) → unified Bronze → Silver (join with reference data) → dynamic Gold tables split by region (passed as parameter). Write the full skeleton code."*
- *"A data engineer says: 'I'll just use `.union()` — Append Flow is overengineering.' Make the technical argument for why they're wrong, using numbers."*

---

# 🚀 What's Coming Next

Based on the transcript preview, you're heading into the deepest DLT concepts:

| Next Topic | What It Means |
|-----------|---------------|
| **Change Data Feed (CDF)** | Your source system sends you the full history of changes — inserts, updates, AND deletes. How do you process all three? |
| **Change Data Capture (CDC) Tables in DLT** | Building a DLT pipeline that correctly handles CDC events — the upstream system is a transactional DB, and you need to mirror its state |
| **SCD Type 2** | Slowly Changing Dimensions — tracking the full history of how a record changed over time (e.g., a customer's address changed 3 times — keep all 3 versions) |

These are the topics that separate junior from senior data engineers. Everything you've built so far — Medallion, DLT, Autoloader, Append Flow, Checkpoints — feeds directly into making CDC and SCD work correctly. 🚀
