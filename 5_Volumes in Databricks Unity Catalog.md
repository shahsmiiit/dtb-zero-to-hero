# 📘 Volumes in Databricks Unity Catalog

## 🗺️ Roadmap for This Session

```
PHASE 1 — The Problem: What gap do Volumes fill?
PHASE 2 — What exactly is a Volume?
PHASE 3 — Managed vs External Volumes
PHASE 4 — Working with Volumes (creating, reading, writing)
PHASE 5 — DROP behavior (same pattern you already know)
PHASE 6 — Full Unity Catalog object model — everything together
```

---

# 🟢 PHASE 1 — The Problem Volumes Solve

## Everything You've Learned So Far Has One Assumption

Every concept so far — Delta tables, MERGE, Cloning, Managed/External tables — all assume your data is **structured** and lives in a **table with rows and columns**.

But real data engineering doesn't only deal with tables.

```
What about:
    ├── Raw CSV files landing from an external system?
    ├── JSON files from an API?
    ├── ML model artifacts (.pkl, .h5 files)?
    ├── Images, PDFs, audio files?
    ├── Config files, scripts, reference files?
    └── Semi-structured logs that aren't ready to be a table yet?
```

Before Volumes, you had two bad options:

```
Option A: Dump files in ADLS directly
    ✅ Works
    ❌ No Unity Catalog governance
    ❌ No access control via UC permissions
    ❌ No visibility in Catalog Explorer
    ❌ Different path conventions per team

Option B: Force everything into a Delta table
    ❌ Makes no sense for images, model files, raw CSVs
    ❌ Overhead of registering as a table just to store files
```

**Volumes = Unity Catalog's answer to governed file storage for non-table data.**

---

## The Key Distinction to Burn Into Memory

```
TABLES  → store structured data as rows/columns (Delta format)
VOLUMES → store files of ANY type (CSV, JSON, images, models, anything)

Both are:
    ✅ Governed by Unity Catalog
    ✅ Live in the catalog.schema hierarchy
    ✅ Have managed and external variants
    ✅ Subject to UC permissions
```

---

# 🟢 PHASE 2 — What Exactly is a Volume?

## Definition

A **Volume** is a Unity Catalog object that represents a **directory/folder in cloud storage**, governed by UC, accessible via a standardized path.

It is NOT a table. It has no schema, no rows, no columns. It's a **governed folder**.

```
Unity Catalog Hierarchy (complete picture):

Metastore
└── Catalog (dev)
    └── Schema (bronze)
        ├── Tables      ← structured data (Delta)
        ├── Views       ← saved queries
        └── Volumes     ← files of any type ← NEW
```

## The Volume Path Convention

Every volume gets a **standardized access path**:

```
/Volumes/<catalog>/<schema>/<volume>/<optional_subfolder>/<filename>

Example:
/Volumes/dev/bronze/managedvolume/files/EMP.csv
    │       │       │              │     └── file
    │       │       │              └── subfolder you created
    │       │       └── volume name
    │       └── schema
    └── catalog
```

This path works **identically** in:
- SQL queries
- Python (`dbutils.fs`)
- Shell commands (`%sh`)
- Any Databricks notebook cell

---

### 🧠 Quick Check #1
> **Q:** Your colleague says "I'll just store my ML model files in a Delta table." What's wrong with this?
>
> *Delta tables store structured row/column data in Parquet format. ML model files (.pkl, .h5) are binary files — they have no rows or columns. You'd use a Volume for file storage, not a table.*

---

# 🟡 PHASE 3 — Managed vs External Volumes

## You Already Know This Pattern

This is the **exact same managed vs external concept** from tables — applied to volumes.

| | Managed Volume | External Volume |
|---|---|---|
| **Who picks storage path?** | Unity Catalog (auto) | You (explicit ADLS path) |
| **Requires external location?** | ❌ No | ✅ Yes |
| **DROP VOLUME behavior** | Deletes metadata + ALL files ☠️ | Deletes metadata only, files safe ✅ |
| **Governed by UC?** | ✅ Yes | ✅ Yes |
| **Use case** | Temp files, intermediate processing | Raw landing zone, shared files, files other systems also use |

---

## Creating a Managed Volume

```sql
CREATE VOLUME dev.bronze.managedvolume
COMMENT 'This is a managed volume';
-- No LOCATION specified — UC decides where in ADLS this goes
```

```
After creation, UC assigns a path like:
    abfss://container@storage.dfs.core.windows.net/
        <metastore-id>/<catalog-id>/<schema-id>/volumes/managedvolume/
        
You don't need to know this path — you always use:
    /Volumes/dev/bronze/managedvolume/
```

---

## Creating an External Volume

Requires: storage credential + external location (same setup as external tables).

```sql
-- First: external location must already exist in UC (registered ADLS path)
-- Then:
CREATE VOLUME dev.bronze.externalvolume
EXTERNAL LOCATION 'abfss://data@mystorage.dfs.core.windows.net/ADB/EXTvolume'
COMMENT 'This is an external volume';
```

```
Files go to: abfss://data@mystorage.dfs.core.windows.net/ADB/EXTvolume/
Access via:  /Volumes/dev/bronze/externalvolume/
```

---

## Inspecting a Volume

```sql
DESCRIBE VOLUME dev.bronze.managedvolume;

-- Returns:
--   catalog:      dev
--   schema:       bronze
--   name:         managedvolume
--   owner:        you@company.com
--   location:     abfss://...metastore-managed-path...
--   volume_type:  MANAGED
```

---

# 🟡 PHASE 4 — Working With Volumes

## Three Ways to Interact With Volume Files

### Way 1: Shell commands (download/inspect files)

```bash
%sh
# Download a file from the internet to the cluster's local disk
wget https://example.com/EMP.csv

# Check it's there
ls -ltr

# Check your current directory
pwd
```

⚠️ **Important:** `wget` downloads to the **cluster's local disk**, NOT to the volume yet. The next step copies it into the volume.

---

### Way 2: dbutils.fs (move files into/around volumes)

```python
%python

# Create a subfolder inside the volume
dbutils.fs.mkdirs("/Volumes/dev/bronze/managedvolume/files")

# Copy from cluster's local disk → into the volume
# Note: local file paths need "file:/" prefix
dbutils.fs.cp(
    "file:/local/path/EMP.csv",                          # source (local disk)
    "/Volumes/dev/bronze/managedvolume/files/EMP.csv"    # destination (volume)
)

# List contents of a volume folder
dbutils.fs.ls("/Volumes/dev/bronze/managedvolume/files")

# Delete a file from a volume
dbutils.fs.rm("/Volumes/dev/bronze/managedvolume/files/EMP.csv")
```

**Why `file:/` prefix?**
```
Without prefix: Databricks assumes the path is in the distributed file system (ADLS/DBFS)
With "file:/":  Databricks treats it as the cluster driver node's local file system

wget downloaded to local disk → need "file:/" to reference it
Volume path → no prefix needed (UC handles it)
```

---

### Way 3: SQL (read files directly from volumes)

```sql
-- Read a CSV file directly using SQL
SELECT * FROM csv.`/Volumes/dev/bronze/managedvolume/files/EMP.csv`;

-- Read with options (header parsing, delimiter, etc.)
SELECT * FROM read_files(
    '/Volumes/dev/bronze/managedvolume/files/EMP.csv',
    format => 'csv',
    header => true
);
```

⚠️ **Note on the plain SQL version:**
```sql
SELECT * FROM csv.`/Volumes/.../EMP.csv`
-- This reads the file but treats the header row as data
-- First row (column names) appears as a regular row

-- Use read_files() with header => true for proper parsing
```

---

## Typical Volume Workflow in a Real Pipeline

```
Step 1: External system drops raw CSV into ADLS external location
        ↓
Step 2: External Volume registered on that ADLS path
        → file is now accessible via /Volumes/dev/bronze/rawfiles/EMP.csv
        ↓
Step 3: Databricks notebook reads from Volume:
        SELECT * FROM read_files('/Volumes/dev/bronze/rawfiles/EMP.csv', ...)
        ↓
Step 4: Transform data → write to Delta managed table
        → now it's structured, governed, queryable as a table
        ↓
Step 5: Raw file in Volume kept as audit trail (external → never deleted by UC)
```

---

### 🧠 Quick Check #2

> **Q1:** You use `wget` to download a file. Can you immediately reference it with `/Volumes/...`?
>
> *No. `wget` downloads to the cluster's local disk. You must use `dbutils.fs.cp("file:/local/path", "/Volumes/...")` to move it into the volume first.*

> **Q2:** You run `SELECT * FROM csv.\`/Volumes/dev/bronze/myvol/data.csv\`` and the first row shows column names as data. Why?
>
> *The basic `csv.` reader doesn't auto-detect headers. Use `read_files()` with `header => true` to parse the header row correctly.*

---

# 🟠 PHASE 5 — DROP Behavior: Same Pattern, Already Familiar

```
DROP VOLUME dev.bronze.managedvolume;
    → UC metadata removed ✅
    → ALL files in ADLS deleted ☠️
    → No recovery

DROP VOLUME dev.bronze.externalvolume;
    → UC metadata removed ✅
    → Files in ADLS: UNTOUCHED ✅
    → Recreate the external volume → files reappear immediately
```

**This is identical to managed vs external TABLES.** UC only destroys what it owns. External = you own the files = UC never deletes them.

```sql
-- Proof: recreate the external volume after dropping it
CREATE VOLUME dev.bronze.externalvolume
EXTERNAL LOCATION 'abfss://data@mystorage.dfs.core.windows.net/ADB/EXTvolume';

-- Files that were there before are immediately accessible again
-- UC just re-registers the pointer to your ADLS folder
```

---

# 🔴 PHASE 6 — The Complete Unity Catalog Object Model

You now have all the pieces. Here's the full picture:

```
Unity Catalog — Complete Object Model
══════════════════════════════════════

METASTORE (one per Azure region / Databricks account)
    │
    ├── Storage Credential    ← auth to access ADLS (service principal/managed identity)
    ├── External Location     ← registered ADLS paths UC is allowed to use
    │
    └── CATALOG (dev, prod, finance...)
            │
            └── SCHEMA (bronze, silver, gold...)
                    │
                    ├── TABLES (Delta format, rows + columns)
                    │     ├── Managed Table   ← UC owns path + lifecycle
                    │     └── External Table  ← you own path + lifecycle
                    │
                    ├── VIEWS (saved queries, no physical data)
                    │     ├── Temporary View  ← session only
                    │     └── Permanent View  ← persists in UC
                    │
                    └── VOLUMES (files of any type)
                          ├── Managed Volume  ← UC owns path + lifecycle
                          └── External Volume ← you own path + lifecycle
```

---

## The Managed vs External Pattern — Universal Rule

You've now seen this pattern **4 times** (managed tables, external tables, managed volumes, external volumes). It always works the same way:

```
MANAGED  = UC picks path + UC owns lifecycle
           DROP → metadata gone + DATA/FILES GONE ☠️

EXTERNAL = You pick path + You own lifecycle
           DROP → metadata gone + DATA/FILES SAFE ✅
```

This is not a coincidence — it's a deliberate design principle in Unity Catalog. **Once you understand this pattern, you understand half of UC.**

---

## 🗺️ Concept Connection Map

```
Volumes
    ├── fills gap of → file storage (non-table data) in UC
    ├── same hierarchy as → Tables and Views (catalog.schema.volume)
    ├── managed variant → mirrors managed tables (UC owns lifecycle)
    ├── external variant → mirrors external tables (you own lifecycle)
    └── accessed via → /Volumes/<catalog>/<schema>/<volume>/ path

dbutils.fs
    ├── used for → file operations on volumes (mkdirs, cp, ls, rm)
    ├── requires → "file:/" prefix for local cluster disk paths
    └── connects to → Volume path convention (/Volumes/...)

DROP behavior
    ├── managed volume → data deleted (same as managed table)
    └── external volume → data safe (same as external table)
```

---

## 📝 Active Recall Prompts

**Day 1:**
> *"What is the difference between a Table and a Volume in UC? When would you use each?"*
>
> *"You downloaded a file with wget. Walk through every step to get it into a managed volume and then query it with SQL."*

**Day 3:**
> *"Draw the complete Unity Catalog object model from memory — metastore down to tables/views/volumes."*
>
> *"What happens to files when you DROP a managed volume vs external volume? Why?"*

**Day 7:**
> *"Design a data pipeline: raw JSON files land in ADLS every hour. You need to process them into a Delta table. Which UC objects do you use at each stage and why?"*

---
