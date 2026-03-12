# 📘 Delta Tables — Cloning, Views & Catalog Utilities

## 🗺️ Roadmap for This Session

```
PHASE 1 — Catalog Utilities (navigating what exists)
PHASE 2 — IF NOT EXISTS (safe, idempotent table creation)
PHASE 3 — Views: Temporary vs Permanent
PHASE 4 — Copying Tables: 3 ways (CTAS, Deep Clone, Shallow Clone)
PHASE 5 — Full Comparison + When to Use What
```

---

# 🟢 PHASE 1 — Catalog Utilities: Navigating What Exists

## The Problem First

You're working in a large Databricks environment. There are multiple catalogs, dozens of schemas, hundreds of tables. You need to:
- See what catalogs exist
- See what schemas are inside a catalog
- See what tables are inside a schema
- Check if a specific table exists before doing something

These are **navigation/inspection commands** — they don't create or modify anything.

---

## The Commands

```sql
-- List all catalogs in your Unity Catalog metastore
SHOW CATALOGS;

-- List all schemas inside a specific catalog
SHOW SCHEMAS IN dev;

-- List all tables inside a specific catalog + schema
SHOW TABLES IN dev.bronze;

-- Filter results using LIKE (wildcard = *)
SHOW CATALOGS LIKE 'dev*';       -- all catalogs starting with "dev"
SHOW TABLES IN dev.bronze LIKE 'raw*';  -- tables starting with "raw"
```

---

## Checking if a Table Exists Programmatically

Sometimes in a pipeline/script, you need to **branch logic** based on whether a table exists.
SQL doesn't have an IF statement for this — but PySpark does:

```python
# Returns True or False
spark.catalog.tableExists("dev.bronze.raw_sale")

# Practical use:
if spark.catalog.tableExists("dev.bronze.raw_sale"):
    print("Table exists, skip creation")
else:
    print("Table missing, create it")
```

**Why does this matter?**
In production pipelines, blindly running `CREATE TABLE` on an existing table throws an error and breaks your pipeline. This check prevents that.

---

### 🧠 Quick Check #1
> **Q:** What's the difference between `SHOW TABLES` and `spark.catalog.tableExists()`?
>
> *`SHOW TABLES` lists all tables in a schema — a human-readable display. `tableExists()` checks one specific table and returns True/False — used for programmatic logic in code.*

---

# 🟢 PHASE 2 — IF NOT EXISTS: Safe, Idempotent Creation

## What is Idempotency?

**Idempotent** = running something multiple times produces the same result as running it once. No errors, no duplicates.

This is a **critical engineering principle** in pipelines. Your code should be safe to re-run.

```sql
-- ❌ Dangerous — fails if table already exists
CREATE TABLE dev.bronze.raw_sale (id INT, amount DOUBLE);

-- ✅ Safe — does nothing if table already exists, creates if it doesn't
CREATE TABLE IF NOT EXISTS dev.bronze.raw_sale (id INT, amount DOUBLE);
```

```
First run:   Table doesn't exist → creates it ✅
Second run:  Table exists → does nothing, no error ✅
Tenth run:   Table exists → does nothing, no error ✅
```

Same applies to schemas:
```sql
CREATE SCHEMA IF NOT EXISTS dev.bronze;
```

**Rule of thumb:** In any production code, always use `IF NOT EXISTS` when creating tables or schemas.

---

# 🟡 PHASE 3 — Views: Temporary vs Permanent

## What is a View? (First Principles)

A **view** is a saved SQL query that looks and behaves like a table — but **stores no data**.

```
Real table:   stores data physically in ADLS as Parquet files
View:         stores a SQL query definition only
              when you SELECT from a view → it runs the underlying query live
```

**Analogy:** A view is like a shortcut on your desktop. The shortcut isn't the file — it just points to it. Delete the shortcut, the file is still there.

---

## Temporary Views

```sql
CREATE TEMPORARY VIEW vw_high_value_sales AS
SELECT * FROM dev.bronze.raw_sale
WHERE amount > 1000;
```

| Property | Temporary View |
|---|---|
| **Scope** | Current session only |
| **Stored in Unity Catalog?** | ❌ No |
| **Survives cluster restart?** | ❌ No |
| **Physical data copied?** | ❌ No |
| **Use case** | Intermediate transformation within a notebook run |

When your cluster shuts down or session ends → temporary view is gone. No trace anywhere.

---

## Permanent Views

```sql
CREATE VIEW dev.bronze.vw_high_value_sales AS
SELECT * FROM dev.bronze.raw_sale
WHERE amount > 1000;
```

| Property | Permanent View |
|---|---|
| **Scope** | Lives in UC catalog.schema |
| **Stored in Unity Catalog?** | ✅ Yes (metadata/query definition) |
| **Survives cluster restart?** | ✅ Yes |
| **Physical data copied?** | ❌ No |
| **Use case** | Shared, reusable query layer for teams/dashboards |

---

## Replacing a View

```sql
-- If view already exists → update its definition
-- If view doesn't exist → create it
CREATE OR REPLACE VIEW dev.bronze.vw_high_value_sales AS
SELECT * FROM dev.bronze.raw_sale
WHERE amount > 5000;  -- changed the filter
```

This is the view equivalent of `IF NOT EXISTS` — safe to re-run.

---

## Key Insight: Views Don't Copy Data

```
Table: dev.bronze.raw_sale  →  100GB of Parquet in ADLS

View: dev.bronze.vw_high_value_sales
    → stores: "SELECT * FROM dev.bronze.raw_sale WHERE amount > 1000"
    → storage cost: nearly zero (just a text query definition)
    → when queried: runs live against the 100GB table
```

**Implication:** If the underlying table changes, the view reflects those changes automatically — it always runs fresh.

---

### 🧠 Quick Check #2

> **Q1:** You create a temporary view in your notebook, then restart your cluster. Is the view still there?
>
> *No. Temporary views are session-bound. Cluster restart = session ends = view gone.*

> **Q2:** Does creating a permanent view double your storage cost?
>
> *No. Views store only a query definition — no data is copied or stored physically.*

> **Q3:** You update the underlying table. Does your view reflect the new data?
>
> *Yes — the view runs the query live every time it's queried, so it always reads the current state of the table.*

---

# 🟠 PHASE 4 — Copying Tables: 3 Ways

## Why Would You Copy a Table?

Common real-world reasons:
- Create a **dev/test copy** to experiment without touching production data
- **Archive** a version of data before a transformation
- **Migrate** a table to a new catalog/schema
- Give another team their own copy to work with

There are 3 ways to do this in Databricks. They are **not interchangeable** — each has trade-offs.

---

## Method 1: CTAS (Create Table As Select)

```sql
CREATE TABLE dev.bronze.raw_sale_copy
AS SELECT * FROM dev.bronze.raw_sale;
```

**What happens:**
```
Source table: dev.bronze.raw_sale
    ↓ runs SELECT *
    ↓ takes the result
    ↓ writes it as new Parquet files to a new ADLS location
New table: dev.bronze.raw_sale_copy  →  new independent physical copy
```

**The Problem with CTAS:**

CTAS only copies the **data rows**. It does not fully copy the **table's metadata definition**.

```
What gets lost:
  ❌ Column nullability constraints (e.g., NOT NULL)
  ❌ Partition information
  ❌ Table properties
  ❌ Delta-specific metadata

What you get:
  ✅ All the data rows
  ✅ Column names and data types (basic schema)
  ✅ New independent physical copy
```

Think of CTAS like **copy-pasting raw text** from a Word document into Notepad — you get the words, but lose all the formatting.

---

## Method 2: Deep Clone

```sql
CREATE TABLE dev.bronze.raw_sale_deep_copy
DEEP CLONE dev.bronze.raw_sale;
```

**What happens:**
```
Source table: dev.bronze.raw_sale
    ↓ copies ALL metadata (constraints, partitions, properties)
    ↓ copies ALL data files physically to new ADLS location
New table: dev.bronze.raw_sale_deep_copy  →  exact replica, independent
```

**Deep Clone = full photocopy of both the document AND its formatting.**

```
What you get:
  ✅ All data rows
  ✅ Full metadata (nullability, partitions, table properties)
  ✅ New independent physical copy in ADLS
  ✅ Delta table history (version log)
  ✅ Changes to original don't affect the clone
```

**Deep Clone is the safest copy method.** If you need an exact replica, use this, not CTAS.

---

## Method 3: Shallow Clone

```sql
CREATE TABLE dev.bronze.raw_sale_shallow_copy
SHALLOW CLONE dev.bronze.raw_sale;
```

**What happens:**
```
Source table: dev.bronze.raw_sale  (data files in ADLS: /path/to/files/)
    ↓ copies ONLY metadata
    ↓ does NOT copy data files
Shallow clone: dev.bronze.raw_sale_shallow_copy
    → has its own metadata
    → points to the ORIGINAL table's data files in ADLS
    → no new data files written
```

**Shallow Clone = a shortcut that looks like a full copy.**

---

## Shallow Clone — The Details That Matter

```
Source table at time of clone: Version 5 (100 rows)

Shallow clone created → points to source Version 5

Source table later updated to Version 6 (200 rows)
    → Shallow clone still sees Version 5 data (100 rows) ✅
    → It's pinned to the version at time of cloning

You insert new rows into the shallow clone directly:
    → Clone writes its OWN new data files ✅
    → It becomes partially independent
```

**The VACUUM risk:**

```
VACUUM = a Delta maintenance command that 
         permanently deletes old data files 
         (files not part of the current table version)

If source table runs VACUUM and deletes Version 5 files:
    → Shallow clone breaks ❌ (it was pointing to those deleted files)
```

This is the **critical weakness** of shallow clones. If someone vacuums the source, your shallow clone can lose data.

---

## The Three Methods — Side by Side

```
SOURCE TABLE
    ├─── CTAS ──────────────→ New table, new files, PARTIAL metadata copy
    │                          Independent ✅  |  Metadata risk ⚠️
    │
    ├─── DEEP CLONE ────────→ New table, new files, FULL metadata copy
    │                          Independent ✅  |  Exact replica ✅
    │
    └─── SHALLOW CLONE ─────→ New table, NO new files, points to source
                               Storage efficient ✅  |  VACUUM risk ⚠️
```

---

## Full Comparison Table

| Feature | CTAS | Deep Clone | Shallow Clone |
|---|---|---|---|
| **Copies data files?** | ✅ Yes | ✅ Yes | ❌ No |
| **Copies metadata fully?** | ⚠️ Partial | ✅ Full | ✅ Full |
| **New ADLS storage used?** | ✅ Yes | ✅ Yes | ❌ Minimal |
| **Independent from source?** | ✅ Yes | ✅ Yes | ⚠️ Partially |
| **VACUUM risk?** | ❌ None | ❌ None | ⚠️ Yes |
| **Best for** | Quick data copy | Exact production replica | Fast test copy, low storage |

---

## When to Use Which

```
Use CTAS when:
  ✅ You need a quick data copy and don't care about metadata precision
  ✅ You're transforming data while copying (SELECT with filters/joins)
  ⚠️  Not for exact production replicas

Use DEEP CLONE when:
  ✅ You need an exact replica of a production table
  ✅ Metadata (partitions, constraints) must be preserved
  ✅ Migrating a table to a new catalog/schema
  ✅ Creating a backup before a risky transformation

Use SHALLOW CLONE when:
  ✅ You want a fast, storage-efficient copy for testing/dev
  ✅ You're okay with pointing to existing data files
  ⚠️  Ensure source table won't be vacuumed while you use it
```

---

### 🧠 Final Quiz

> **Q1:** You need to migrate a table from `dev` catalog to `prod` catalog and preserve all partition info and constraints. Which method?
>
> *Deep Clone — it's the only method that guarantees full metadata preservation.*

> **Q2:** Your shallow clone broke after someone ran maintenance on the source table. What likely happened?
>
> *VACUUM was run on the source table, deleting old data files that the shallow clone was still referencing.*

> **Q3:** Does a view consume ADLS storage?
>
> *No — a view stores only a query definition (text), not data. The data stays in the underlying table.*

> **Q4:** You have a notebook that creates a table at the start. It runs in a daily pipeline. What clause should you add?
>
> *`IF NOT EXISTS` — so on day 2 onward, it doesn't fail trying to create an already-existing table.*

---

## 🗺️ Concept Connection Map

```
CTAS
    ├── contrasts with → Deep Clone (metadata loss risk)
    ├── contrasts with → Shallow Clone (always writes new files)
    └── similar to → regular INSERT but as table creation

Deep Clone
    ├── preferred over → CTAS (when metadata matters)
    ├── independent from → source table (no shared files)
    └── use for → production backups, migrations

Shallow Clone
    ├── depends on → source table's data files
    ├── risk: → VACUUM on source breaks the clone
    └── efficient for → dev/test environments

Views
    ├── temporary → session-scoped, no UC storage
    ├── permanent → UC-stored, survives restarts
    └── both → zero data storage cost, live query on source
```

---

## 📝 Active Recall Prompts

**Day 1:**
> *"Without notes: what are the 3 ways to copy a table in Databricks and the key trade-off of each?"*

**Day 3:**
> *"What is the VACUUM risk with shallow clone? Draw what happens step by step."*
>
> *"What's the difference between a temporary and permanent view? When would you use each in a real pipeline?"*

**Day 7:**
> *"You're building a daily ETL pipeline. List 3 places where `IF NOT EXISTS` would protect you. Explain why for each."*
>
> *"Your team asks for a copy of a 500GB production table for testing. Which clone method and why?"*

---
