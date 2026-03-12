# Delta Live Tables on Databricks/Azure

| Phase | Topic  |
|-------|-------|
| 0 | **The Data Problem** — Why any of this exists |
| 1 | **Medallion Architecture** — The filing system analogy | 
| 2 | **What is DLT?** — Declarative vs Imperative thinking | |
| 3 | **DLT's 3 Dataset Types** — The building blocks | 
| 4 | **Writing DLT Code** — Decorators, syntax, reading across tables |
| 5 | **Configuring & Running a Pipeline** — The UI + modes | 
| 6 | **DLT Internals** — Where does data actually live? | 
| 7 | **Incremental Processing + Modifying Pipelines** | 
| 8 | **Data Lineage** — Unity Catalog's superpower | 

---

---

# 📖 PHASE 0 — The Data Problem (Why Does Any Of This Exist?)

## 🧱 Start from First Principles: What Is a Data Engineer's Job?

Imagine you work at a company. Every day:
- Users place **orders** on your website
- Sensors send **readings** from machines
- Apps generate **logs** by the millions

All of this raw data lands **somewhere** — files, databases, streams. Your job as a data engineer is to take that messy raw data and turn it into something **clean, reliable, and useful** so that:
- Analysts can query it
- Dashboards can display it
- ML models can train on it

The process of moving data from raw → useful is called a **pipeline**.

---

## 🔥 The Problem With Building Pipelines The Hard Way

Before tools like DLT existed, you'd write pipelines manually (notebooks, scripts). Every single time you built one, you had to handle:

```
❌ "When my cluster crashes mid-run, how do I retry only the failed part?"
❌ "Someone added a new column to the source — my pipeline broke. Now what?"
❌ "10 million rows came in. Did I accidentally re-process 5 million old ones?"
❌ "A bad row slipped through. Where did it come from? Which step failed to catch it?"
❌ "I wrote the same boilerplate cluster-setup code for the 12th pipeline this month"
```

These aren't edge cases. These are **daily realities in production data engineering**.

> **This is the pain DLT was built to eliminate.** Keep this in mind — every DLT feature you learn is a direct answer to one of these problems.

---

---

# 📖 PHASE 1 — Medallion Architecture 🥇🥈🥉

## 🧠 The Mental Model: Think of a Filing System

Imagine you receive 1,000 raw documents every day — receipts, scanned forms, emails, photos. You have three rooms to store them:

| Room | What Goes In | Condition of Documents |
|------|-------------|----------------------|
| **Bronze Room** | Everything, immediately | Raw, messy, unverified — exactly as received |
| **Silver Room** | Processed copies | Cleaned, validated, duplicates removed |
| **Gold Room** | Summary reports | Ready-to-use, aggregated, business-ready |

You **never throw away the Bronze Room**. Why? Because if you mess up Silver or Gold processing, you can always re-derive them from the originals in Bronze.

This is the **Medallion Architecture** — also called the **Multi-Hop Architecture**.

---

## 🥉 Bronze Layer — "Land it, don't touch it"

**What it is:** The raw ingestion layer. Data arrives and is stored exactly as-is.

**Why it exists:**
- You need a permanent record of what arrived, when
- Re-processing is possible anytime (raw data is never lost)
- Fast ingestion — no transformation overhead

**What it looks like in practice:**
```
orders_raw arrives (CSV/stream) → stored in Bronze exactly as received
customer_raw arrives → stored in Bronze exactly as received
```

**Think of it as:** The inbox on your desk. Everything piles in, sorted by arrival time.

---

## 🥈 Silver Layer — "Clean it, join it, trust it"

**What it is:** Cleaned, validated, joined data. Business logic starts here.

**Why it exists:**
- Analysts need consistent, reliable data — not raw noise
- Joins happen here (orders + customers in one place)
- Bad rows are filtered, timestamps normalized, nulls handled

**What it looks like in practice:**
```
orders_bronze + customer_bronze → joined, cleaned → orders_silver
```

**Think of it as:** The organized folder on your desk. Filed correctly, duplicates removed, ready to reference.

---

## 🥇 Gold Layer — "Answer the question"

**What it is:** Pre-aggregated, business-ready output. Optimized for consumption.

**Why it exists:**
- Analysts don't want to re-run heavy joins every time they query
- Dashboards need fast, pre-computed answers
- "How many orders per market segment?" is answered in milliseconds

**What it looks like in practice:**
```
orders_silver → GROUP BY market_segment → COUNT orders → orders_aggregated_gold
```

**Think of it as:** The printed summary report handed to your manager.

---

## 🗺️ Concept Connection Map — Medallion Architecture

```
Medallion Architecture
    ├── Bronze Layer
    │     ├── Raw data, no transformation
    │     ├── connects to → Silver (feeds into)
    │     └── purpose → audit trail, re-processing safety net
    ├── Silver Layer
    │     ├── Cleaned + joined Bronze data
    │     ├── prerequisite for → Gold
    │     └── contains → business logic, quality checks
    └── Gold Layer
          ├── Aggregated, summarized
          ├── serves → Dashboards, analysts, ML
          └── contrasts with → Raw Bronze (opposite ends of the pipeline)
```

---

## ✅ Quick Quiz #1 — Medallion Architecture

> Answer in your head before reading the answer.

**Q1:** Raw log files arrive from IoT sensors every minute. Which layer stores them immediately without any processing?
<details><summary>Answer</summary>Bronze — raw, unmodified, as-arrived.</details>

**Q2:** A data analyst needs a table showing "total revenue per customer segment per month." Which layer should serve this?
<details><summary>Answer</summary>Gold — pre-aggregated, business-ready output.</details>

**Q3:** You discover the Bronze layer has duplicate rows. Where do you fix them?
<details><summary>Answer</summary>Silver — that's where cleaning and deduplication happens. Bronze stays untouched by design.</details>

**Q4:** Why do we keep Bronze at all? Why not just go straight to Silver?
<details><summary>Answer</summary>Bronze is your safety net. If Silver transformation logic has a bug, you can always re-derive Silver from Bronze. Without it, bad data propagates with no recovery path.</details>

---

---

# 📖 PHASE 2 — What Is DLT? (The Core Mindset Shift)

## 🧠 Imperative vs Declarative — This Is The Most Important Concept

Before DLT, you wrote **imperative** pipelines. Let's understand what that means.

### Imperative Thinking (What you were doing before)

```python
# YOU tell the machine EXACTLY how to do every step

df = spark.read.table("orders_raw")          # Step 1: Read
df = df.filter(df.status != "invalid")        # Step 2: Filter
df = df.join(customers, on="customer_id")     # Step 3: Join
df = df.withColumn("insert_ts", current_timestamp())  # Step 4: Enrich
df.write.mode("append").saveAsTable("silver") # Step 5: Write
# Step 6: Handle errors yourself
# Step 7: Manage schema yourself
# Step 8: Track what you already processed yourself
```

**YOU are responsible for:**
- The exact order of steps
- Retries on failure
- Schema changes when source changes
- Making sure you don't re-process old data
- Cluster lifecycle

---

### Declarative Thinking (What DLT does)

```python
# YOU tell DLT WHAT you want to exist. DLT figures out HOW.

@dlt.table
def orders_silver():
    return (
        dlt.read("orders_bronze")
        .filter(col("status") != "invalid")
        .join(dlt.read("customers"), on="customer_id")
        .withColumn("insert_ts", current_timestamp())
    )
```

**DLT is responsible for:**
- Running this in the right order
- Retries on failure
- Schema evolution
- Incremental tracking
- Cluster provisioning + teardown

> **The analogy:** Imperative = you giving turn-by-turn driving directions. Declarative = typing "Pizza Place, 5th Ave" into Google Maps and letting it figure out the route, traffic, and rerouting if a road is closed.

---

## 🔑 What DLT Actually Is — A Precise Definition

**Delta Live Tables (DLT)** is a **declarative ETL framework** built by Databricks that:
1. Lets you define data transformations as Python/SQL functions
2. Automatically manages the **orchestration** (what runs first, what depends on what)
3. Handles **cluster lifecycle** (spins up, runs, tears down)
4. Enforces **data quality** (bad rows tracked or blocked)
5. Supports **incremental processing** (don't reprocess what's already done)
6. Integrates with **Unity Catalog** for lineage tracking

**Important constraints to know:**
- Requires **Databricks Premium plan** (not free/standard)
- Needs a **special job compute cluster** (not your regular all-purpose cluster)
- Code lives in **notebooks** (Python or SQL)

---

## ✅ Quick Quiz #2 — DLT Fundamentals

**Q1:** In one sentence, what is the core difference between imperative and declarative pipelines?
<details><summary>Answer</summary>Imperative = you define HOW each step runs. Declarative = you define WHAT result you want, and DLT handles HOW.</details>

**Q2:** Name 3 things you'd have to manage yourself in an imperative pipeline that DLT handles for you.
<details><summary>Answer</summary>Any 3 from: cluster lifecycle, retries, schema evolution, incremental tracking, data quality checks, task order/dependency management.</details>

**Q3:** Can you run a DLT pipeline on a Databricks Standard plan?
<details><summary>Answer</summary>No — DLT requires the Premium plan.</details>

---

---

# 📖 PHASE 3 — DLT's 3 Dataset Types 🏗️

This is where most beginners get confused. Let's build the intuition carefully.

## 🧠 Start With What You Already Know

In a regular database or Databricks:

| Concept | What It Is |
|---------|-----------|
| **Table** | Data stored physically on disk. Querying it = reading stored rows. |
| **View** | Just a saved SQL query. No data stored. Each query re-runs the SQL. |

Now DLT extends this with **3 types**, each with a specific job:

---

## Type 1: 🌊 Streaming Table

### The Problem It Solves
You have a source (like `orders_raw`) where **new rows arrive constantly** — every hour, every minute. You don't want to re-read all 50 million historical rows every pipeline run. You want to read **only the new rows since last time**.

### What It Is
A **Streaming Table** is a DLT-managed Delta table that:
- Reads from a **streaming source** using `spark.readStream`
- Processes **only new records** each run (incremental)
- Physically stores data in Unity Catalog
- Tracks where it left off using a **checkpoint** (think of it as a bookmark)

### When To Use It
- Source is append-only (logs, events, raw orders arriving)
- You're reading from Autoloader (new files in ADLS)
- You're reading from Kafka

### Key Signal: `spark.readStream`
If your read uses `readStream` → it's a Streaming Table.

```python
@dlt.table(name="orders_bronze")
def orders_bronze():
    return spark.readStream.table("dev.bronze.orders_raw")
    #            ^^^^^^^^^^^ streaming = incremental
```

### The Bookmark/Checkpoint Analogy
Imagine reading a 1,000-page book. You place a **bookmark** at page 300 before you sleep. Tomorrow, you open to page 301 — you don't re-read pages 1-300.

That bookmark = the **checkpoint file** DLT maintains for every Streaming Table. After each run, it records "I've processed up to offset X." Next run, it starts from X+1.

---

## Type 2: 🗄️ Materialized View

### The Problem It Solves
You need to **join, aggregate, or transform** data — but you want the result **stored** (not re-computed on every query). And unlike a Streaming Table, you're not reading from a live stream — you're computing from a batch of existing data.

### What It Is
A **Materialized View** is a DLT-managed Delta table that:
- Reads from a **batch source** using `spark.read` or `dlt.read()`
- **Re-computes entirely** on every pipeline run
- Physically stores the result in Unity Catalog
- Used for: joins, aggregations, transformations

### When To Use It
- You're joining two tables
- You're aggregating data (COUNT, SUM, AVG by group)
- You're applying business logic transformations

### Key Signal: `spark.read` or `dlt.read()`
If your read uses `read` (not `readStream`) → it's a Materialized View.

```python
@dlt.table(name="customer_bronze")
def customer_bronze():
    return spark.read.table("dev.bronze.customer_raw")
    #            ^^^^ batch = Materialized View
```

> [!NOTE]
> **Why "Materialized"?**  
> In database theory, a **view** is just a stored query — data isn't stored, it re-runs each time.  
> A **materialized view** actually stores the computed result physically. Querying it is fast because the computation already happened.
---

## Type 3: 👻 View (DLT View)

### The Problem It Solves
You have a complex transformation (like a join) that you want to **break into logical steps** for clean code — but you don't need that intermediate result stored anywhere. It's just a temporary stepping stone.

### What It Is
A **DLT View** is:
- An intermediate transformation step
- **NOT stored physically** (no data on disk)
- Only exists **during pipeline execution**
- Not visible in your Unity Catalog schema after the run

### When To Use It
- You're joining two tables and the join result is just a stepping stone to a Silver table
- You want clean, readable code without creating unnecessary stored tables

### Key Signal: `@dlt.view` decorator
```python
@dlt.view(name="join_view")    # ← @dlt.view not @dlt.table
def join_view():
    orders = dlt.read_stream("orders_bronze")
    customers = dlt.read("customer_bronze")
    return orders.join(customers, orders.customer_key == customers.customer_key, "left")
```

---

## 📊 Side-by-Side Comparison Table

| Property | Streaming Table | Materialized View | View |
|----------|----------------|------------------|------|
| **Stored physically?** | ✅ Yes | ✅ Yes | ❌ No |
| **Visible in schema?** | ✅ Yes | ✅ Yes | ❌ No |
| **Source type** | Streaming (incremental) | Batch | Either |
| **Processing mode** | Incremental only | Full recompute each run | Intermediate only |
| **Decorator** | `@dlt.table` + `readStream` | `@dlt.table` + `read` | `@dlt.view` |
| **Use for** | Raw ingestion (Bronze) | Joins, aggregations (Silver, Gold) | Temp join steps |
| **Has checkpoint?** | ✅ Yes (tracks offsets) | ❌ No | ❌ No |

---

## 🗺️ Concept Connection Map — Dataset Types

```
DLT Dataset Types
    ├── Streaming Table
    │     ├── uses → spark.readStream
    │     ├── connects to → Checkpoint concept (Autoloader uses same mechanism)
    │     ├── stored → YES (in databricks_internal/<pipeline-id>/)
    │     └── contrasts with → Materialized View (batch vs stream)
    ├── Materialized View
    │     ├── uses → spark.read / dlt.read()
    │     ├── prerequisite for → understanding Gold aggregation tables
    │     └── contrasts with → regular View (stored vs not stored)
    └── View (DLT View)
          ├── uses → @dlt.view decorator
          ├── NOT stored → invisible after pipeline run
          └── purpose → code organization, intermediate steps only
```

---

## ✅ Quick Quiz #3 — Dataset Types

**Q1:** You're reading from a Kafka topic (new events every second). Which dataset type?
<details><summary>Answer</summary>Streaming Table — real-time/incremental source, use `readStream`.</details>

**Q2:** You need to aggregate daily sales by product category and store the result for dashboards. Which dataset type?
<details><summary>Answer</summary>Materialized View — batch aggregation, stored result.</details>

**Q3:** You want to join `orders_bronze` and `customers_bronze` as a stepping stone before creating your silver table. You don't need this join stored. Which dataset type?
<details><summary>Answer</summary>DLT View — intermediate, not stored, use `@dlt.view`.</details>

**Q4:** What's the decorator difference between a Streaming Table and a Materialized View?
<details><summary>Answer</summary>Both use `@dlt.table` — the difference is the **read method**: `readStream` = Streaming Table, `read` = Materialized View.</details>

---

---

# 📖 PHASE 4 — Writing DLT Code 💻

## The Decorator Pattern — How DLT "Knows" What To Build

In Python, a **decorator** is the `@something` line above a function. It's like a label that says "treat this function as X."

In DLT:
- `@dlt.table` → "this function's return value = a DLT dataset (streaming or materialized)"
- `@dlt.view` → "this function's return value = a temporary DLT view"

The function **always returns a DataFrame** — that DataFrame describes the transformation DLT should apply.

```python
import dlt
from pyspark.sql.functions import current_timestamp, count, sum

@dlt.table(
    name="orders_bronze",                          # explicit name (optional)
    comment="Raw orders — streaming ingestion",    # documentation
    table_properties={"quality": "bronze"}         # metadata tags
)
def orders_bronze():                               # function name = fallback name
    return (
        spark.readStream                           # ← readStream = Streaming Table
        .table("dev.bronze.orders_raw")
    )
```

---

## Reading Between DLT Datasets — `dlt.read()` vs `spark.read.table()`

This trips up beginners. Inside a pipeline, when reading a table that DLT itself manages:

| Method | When To Use |
|--------|------------|
| `dlt.read("table_name")` | Read a **DLT-managed table** from within the same pipeline (batch) |
| `dlt.read_stream("table_name")` | Read a **DLT-managed streaming table** from within the same pipeline |
| `spark.read.table("catalog.schema.table")` | Read an **external table** (outside the pipeline) |
| `spark.readStream.table(...)` | Read an **external streaming source** |

**Why the distinction?** `dlt.read()` ensures consistency — DLT coordinates reads so all datasets in one pipeline run see the same snapshot of data. `spark.read.table()` bypasses this coordination.

---

## The Full Pipeline — All 5 Datasets, Start to Finish

```python
import dlt
from pyspark.sql.functions import current_timestamp, count, sum

# ─── BRONZE LAYER ─────────────────────────────────────────────────

@dlt.table(
    name="orders_bronze",
    comment="Raw orders - streaming ingestion",
    table_properties={"quality": "bronze"}
)
def orders_bronze():
    # readStream → Streaming Table → incremental reads
    return spark.readStream.table("dev.bronze.orders_raw")


@dlt.table(
    name="customer_bronze",
    comment="Raw customers - batch ingestion",
    table_properties={"quality": "bronze"}
)
def customer_bronze():
    # read → Materialized View → full batch read
    return spark.read.table("dev.bronze.customer_raw")


# ─── INTERMEDIATE VIEW (not stored) ────────────────────────────────

@dlt.view(name="join_view")
def join_view():
    orders = dlt.read_stream("orders_bronze")    # ← reading DLT streaming table
    customers = dlt.read("customer_bronze")       # ← reading DLT materialized view
    return orders.join(
        customers,
        orders.customer_key == customers.customer_key,
        "left"
    )


# ─── SILVER LAYER ──────────────────────────────────────────────────

@dlt.table(
    name="orders_silver",
    comment="Joined and enriched orders",
    table_properties={"quality": "silver"}
)
def orders_silver():
    return (
        dlt.read("join_view")                     # reads the view above
        .withColumn("insert_date", current_timestamp())
    )


# ─── GOLD LAYER ────────────────────────────────────────────────────

@dlt.table(
    name="orders_aggregated_gold",
    comment="Aggregated orders by market segment",
    table_properties={"quality": "gold"}
)
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

## Annotated Data Flow

```
orders_raw (external source)
    ↓ [spark.readStream — Streaming Table]
orders_bronze (Bronze, stored, incremental)
    ↓ [dlt.read_stream]
    ↓                        customer_raw (external)
    ↓                            ↓ [spark.read — Materialized View]
    ↓                        customer_bronze (Bronze, stored, batch)
    ↓                            ↓ [dlt.read]
    └──────────────┬─────────────┘
                   ↓ [join — @dlt.view]
               join_view (NOT stored, temp)
                   ↓ [dlt.read]
               orders_silver (Silver, stored, Materialized View)
                   ↓ [dlt.read]
          orders_aggregated_gold (Gold, stored, Materialized View)
```

---

## ✅ Quick Quiz #4 — DLT Code

**Q1:** Why do you use `dlt.read("orders_bronze")` instead of `spark.read.table("dev.etl.orders_bronze")` inside a pipeline?
<details><summary>Answer</summary>`dlt.read()` reads the pipeline's current-run version, ensuring consistency. `spark.read.table()` bypasses DLT's coordination and could read stale data.</details>

**Q2:** A function is decorated with `@dlt.table` and uses `spark.readStream`. What type of DLT dataset does this create?
<details><summary>Answer</summary>Streaming Table — `@dlt.table` + `readStream` = Streaming Table.</details>

**Q3:** What does the `name` parameter in `@dlt.table(name="orders_bronze")` do? What happens if you omit it?
<details><summary>Answer</summary>It explicitly names the table. If omitted, DLT uses the Python function name as the table name.</details>

---

---

# 📖 PHASE 5 — Configuring & Running a DLT Pipeline ⚙️

## Creating a Pipeline in the Databricks UI

When you create a DLT pipeline, you configure these key settings:

### Product Edition — Choose Your Features

| Edition | What You Get |
|---------|-------------|
| **Core** | Streaming Tables, Materialized Views, aggregations. **No CDC, no Data Quality** |
| **Pro** | Everything in Core + **Change Data Capture (CDC)** |
| **Advanced** | Everything in Pro + **Data Quality (expectations, monitoring)** |

For learning, Core is enough. Production systems often need Advanced.

---

### Pipeline Mode — Triggered vs Continuous

| Mode | How It Works | Use When |
|------|-------------|----------|
| **Triggered** | Runs once (on demand or scheduled), then stops | Batch workloads, scheduled daily runs |
| **Continuous** | Runs forever, processing data as it arrives | Real-time streaming workloads |

**Analogy:** Triggered = a dishwasher you run once a night. Continuous = a conveyor belt that never stops.

---

### Development Mode vs Production Mode

This is about **what happens to your cluster after the pipeline finishes**:

| Mode | Cluster After Run | Why Use It |
|------|------------------|-----------|
| **Development** | Stays alive (warm) | Debugging — you can attach notebook, re-run, inspect quickly |
| **Production** | Terminates immediately | Cost savings — no idle cluster costs in production |

> **Rule of thumb:** Always develop in Development mode. Switch to Production before scheduling for real workloads.

---

## The Pipeline DAG — What DLT Shows You

When a pipeline runs, Databricks shows you a **DAG (Directed Acyclic Graph)** — a visual of your datasets and their dependencies:

```
orders_raw ──→ orders_bronze ──┐
                                ├──→ join_view ──→ orders_silver ──→ orders_aggregated_gold
customer_raw ──→ customer_bronze ──┘
```

Each node is color-coded:
- 🟢 Green = succeeded
- 🔴 Red = failed
- ⏳ Yellow = running

This is how you debug — one glance shows exactly where a pipeline broke.

---

## ✅ Quick Quiz #5 — Pipeline Configuration

**Q1:** You're building a real-time fraud detection pipeline that must process transactions within seconds. Which pipeline mode?
<details><summary>Answer</summary>Continuous — processes data as it arrives without stopping.</details>

**Q2:** Your pipeline failed at the Silver layer during a test run. You want to inspect the cluster logs and re-run quickly without waiting for a new cluster. Which development mode should you be in?
<details><summary>Answer</summary>Development mode — cluster stays alive after failure for debugging.</details>

**Q3:** Which DLT edition do you need if you want to track data quality (bad row counts, failed expectations)?
<details><summary>Answer</summary>Advanced edition.</details>

---

---

# 📖 PHASE 6 — DLT Internals 🔬 (Advanced)

> This is where we go under the hood. Understanding this makes you a better engineer.

## Where Does DLT Actually Store Data?

When you create a DLT pipeline targeting `dev.etl`, you'd expect tables to be stored directly there. But DLT has a **two-layer architecture**:

### Layer 1: What You See (Logical Layer)
In Unity Catalog → `dev.etl`:
- `orders_bronze` (appears as a streaming table)
- `customer_bronze` (appears as a materialized view)
- `orders_silver`
- `orders_aggregated_gold`

### Layer 2: Where Data Actually Lives (Physical Layer)
In `databricks_internal/<pipeline-id>/`:
- Internal Delta tables backing each dataset
- Checkpoint folders for streaming tables

The tables you see in `dev.etl` are **abstractions** (pointers) to the real physical tables underneath.

---

## The Pipeline ID — The Master Key

Every DLT pipeline has a **unique Pipeline ID** (like `a1b2c3d4-xxxx-xxxx-xxxx-xxxxxxxxxxxx`).

**This ID ties everything together:**
- All datasets created by the pipeline are tagged with this ID
- Internal storage uses this ID as a folder name
- **Critical warning:** If you delete the pipeline → ALL datasets disappear

```
Delete pipeline a1b2c3d4 → 
    dev.etl.orders_bronze disappears ⚠️
    dev.etl.orders_silver disappears ⚠️
    dev.etl.orders_aggregated_gold disappears ⚠️
    All underlying physical data deleted ⚠️
```

> **Engineering principle:** Never delete a production DLT pipeline unless you explicitly want to wipe all its data. This is not like deleting a job — it deletes the data too.

---

## The Checkpoint — Why Incremental Processing Works

For every Streaming Table, DLT maintains a **checkpoint folder**:

```
databricks_internal/
    └── <pipeline-id>/
          └── orders_bronze/
                ├── _delta_log/        ← the actual data
                └── _checkpoints/      ← the bookmark folder
                      └── offset: 7,500,000
```

**First run:**
1. Reads all rows from `orders_raw` (7.5M rows)
2. Writes to internal Delta table
3. Saves checkpoint: "processed up to offset 7,500,000"

**Second run (10,000 new rows added):**
1. Reads checkpoint: "I'm at 7,500,000"
2. Reads only rows 7,500,001 → 7,510,000 (10,000 new rows)
3. Appends to internal table
4. Updates checkpoint: "now at 7,510,000"

**This is why streaming tables are efficient** — the work grows with new data, not total data.

---

## ✅ Quick Quiz #6 — DLT Internals

**Q1:** A junior engineer on your team deletes the DLT pipeline from the UI to "clean up." What data is now gone?
<details><summary>Answer</summary>ALL datasets created by that pipeline — every Bronze, Silver, Gold table, and all underlying data in `databricks_internal/<pipeline-id>/`.</details>

**Q2:** What is the purpose of the checkpoint folder in a Streaming Table?
<details><summary>Answer</summary>It tracks the offset (position) up to which source data has been processed, so the next run reads only new data (incremental processing).</details>

**Q3:** If `orders_bronze` already processed 7.5M rows, and the pipeline re-runs with no new data, how many rows does it read?
<details><summary>Answer</summary>0 — the checkpoint shows it's already at the latest offset, so there's nothing new to read.</details>

---

---

# 📖 PHASE 7 — Incremental Processing + Modifying Pipelines 🔄

## Adding a New Column — The Declarative Power

In a traditional pipeline, adding a column to an existing table requires:
```sql
ALTER TABLE orders_aggregated_gold ADD COLUMN sum_total_price DECIMAL(18,2);
-- Then rewrite your ETL logic
-- Then re-run and pray it works
```

In DLT:
```python
# Just add the line in your function. That's it.
.agg(
    count("order_key").alias("count_orders"),
    sum("total_price").alias("sum_total_price")   # ← add this line
)
```

DLT detects the new column → evolves the schema → re-runs aggregation → done. No `ALTER TABLE`. No migration scripts. No downtime.

---

## Renaming a Table

```python
# Change this:
@dlt.table(name="joined_silver")

# To this:
@dlt.table(name="orders_silver")
```

DLT:
1. Removes `dev.etl.joined_silver`
2. Creates `dev.etl.orders_silver`
3. Updates all downstream references

No `DROP TABLE`. No `CREATE TABLE`. No manual data migration.

---

## Failure Recovery — DLT vs Traditional

If your pipeline breaks halfway through:

```
Traditional:
    Task 1 (Bronze) ✅ completed
    Task 2 (Silver) ❌ failed
    → You figure out what ran, what didn't, manually re-run Silver+Gold

DLT:
    orders_bronze ✅ (Streaming Table — already checkpointed, reads 0 new rows on re-run)
    customer_bronze ✅ (Materialized View — reruns full batch, cheap)
    orders_silver ❌ (failed — DLT reruns this + everything downstream)
    orders_aggregated_gold ❌ (didn't run — DLT reruns this)
```

DLT knows the dependency graph. It re-runs only what's needed, and streaming tables are essentially free to re-run (0 new rows = instant).

---

# 📖 PHASE 8 — Data Lineage (Unity Catalog) 🔍

## What Is Lineage? (First Principles)

**The Question Lineage Answers:** "Where did this data come from, and who uses it?"

**Why it matters in production:**
- A data quality issue appears in a Gold table → you need to trace which source row caused it
- A regulatory audit asks you to prove where `customer_id` originated
- You're renaming a column in `orders_raw` → you need to know what downstream tables will break

Without lineage tracking, answering these questions means reading through thousands of lines of pipeline code.

---

## Table-Level Lineage

Unity Catalog automatically tracks the full upstream → downstream graph:

```
orders_aggregated_gold
    ← orders_silver
        ← join_view
            ← orders_bronze     ← orders_raw (original source)
            ← customer_bronze   ← customer_raw (original source)
```

One click in the Unity Catalog UI reveals the entire transformation chain.

---

## Column-Level Lineage

Even more powerful — trace **a single column** from Gold back to its source:

```
orders_aggregated_gold.count_orders
    ← orders_silver.order_key (COUNT applied here)
        ← join_view.order_key
            ← orders_bronze.order_key
                ← orders_raw.order_key   ← original source column
```

**Real use case:** "Our `count_orders` metric is off by 5%. Where's the bug?"
- Column lineage shows every transformation it passed through
- You check each step and find the Silver join had a filter that dropped valid rows

---

## ✅ Quick Quiz #7 — Lineage

**Q1:** A business analyst says "the revenue numbers in the Gold table look wrong." How does column lineage help you debug this?
<details><summary>Answer</summary>Column lineage traces `sum_total_price` backward through every transformation — you can see exactly which step (Bronze read, Silver join, Gold aggregation) introduced the error.</details>

**Q2:** You want to rename the column `order_key` in `orders_raw`. Before you do it, how does lineage help?
<details><summary>Answer</summary>Lineage shows every downstream table and notebook that references `order_key` — you know the exact blast radius before making the change.</details>

---

---

# 🗺️ Master Concept Connection Map — Full Picture

```
Medallion Architecture
    ├── Bronze → Raw ingestion (Streaming Tables in DLT)
    ├── Silver → Cleaned/joined (Materialized Views + DLT Views)
    └── Gold → Aggregated (Materialized Views in DLT)

DLT (Delta Live Tables)
    ├── is → Declarative ETL framework (you define WHAT, DLT handles HOW)
    ├── requires → Premium plan + Job compute cluster
    ├── dataset types
    │     ├── Streaming Table → incremental, readStream, has checkpoint
    │     ├── Materialized View → batch, recomputed, stored
    │     └── View → intermediate, NOT stored, @dlt.view
    ├── internally stores → databricks_internal/<pipeline-id>/
    ├── incremental tracking → checkpoint (same mechanism as Autoloader)
    ├── schema evolution → automatic (add column in code = done)
    ├── Pipeline ID → ties all datasets together (delete pipeline = delete data ⚠️)
    └── connects to → Unity Catalog lineage (table + column level)
```

---

---

# 📝 Active Recall Prompts — Spaced Repetition

### 🔁 Review Tomorrow (Day 1)
- *"What are the 3 DLT dataset types? For each: Is it stored? What read method? What decorator? When do you use it?"*
- *"What is the difference between Development mode and Production mode? When would you use each?"*
- *"Explain the Medallion Architecture to a non-technical person using a filing room analogy."*

### 🔁 Review in 3 Days
- *"Walk me through what happens when a DLT pipeline runs for the second time after 10,000 new rows were added to orders_raw. What does each dataset type do?"*
- *"You add a new column to a Gold materialized view. What does DLT do automatically? What would you need to do manually in a traditional pipeline?"*
- *"A teammate deletes the DLT pipeline to 'clean up the workspace.' What just happened?"*

### 🔁 Review in 7 Days
- *"Design a DLT pipeline from scratch: IoT sensors write JSON files to ADLS every minute. You need raw storage, cleaned + joined with device metadata, and hourly aggregated summaries. Define the dataset type, decorator, read method, and Medallion layer for each table. Write the skeleton code."*
- *"A data quality issue is found in your gold aggregation. Using column lineage, describe step-by-step how you'd trace it back to the source."*
- *"Compare DLT to a traditional Workflow-based pipeline. Give 5 specific scenarios where DLT wins. Give 1 scenario where traditional Workflows might still be preferred."*

---

# 🚀 What's Coming Next

Based on the transcripts, you're being set up for:

| Topic | Why It Matters |
|-------|---------------|
| **DLT + Autoloader** | Combining file ingestion (ADLS → DLT Bronze) with the declarative framework |
| **Change Data Capture (CDC)** | Handling inserts + updates + deletes flowing through your pipeline (not just appends) |
| **DLT Data Quality (Expectations)** | Defining rules like "order_key must never be null" — DLT quarantines or blocks bad rows |

---
