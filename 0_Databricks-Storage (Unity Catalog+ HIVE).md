# 🧱 Databricks Storage — From Zero to Unity Catalog

## 🗺️ Your Learning Roadmap

```
PHASE 1 — The WHY (Foundation)
  └─ What problem are we solving? Why does storage even matter?

PHASE 2 — The OLD World (Hive + DBFS)
  └─ What existed before, and why it broke at scale

PHASE 3 — Azure Storage Basics (ADLS)
  └─ Where data actually lives physically

PHASE 4 — Managed vs External Tables
  └─ The most critical distinction you'll ever learn

PHASE 5 — Unity Catalog (The New World)
  └─ The 3-level hierarchy: Metastore → Catalog → Schema → Table

PHASE 6 — External Locations & Schemas
  └─ Exactly what your video was teaching
```

---

# 🟢 PHASE 1 — The WHY: Why Does Storage Management Even Matter?

## The Core Problem

Imagine you're a company with **100 data engineers**, all writing data to different places on different cloud storage accounts, with no rules, no governance, no idea who owns what.

- Engineer A drops a table → it goes *somewhere*
- Engineer B deletes a database → *actual files are gone forever*
- Manager asks "who can access customer data?" → *nobody knows*

**This is the real problem.** Databricks' entire storage story is about solving:

| Problem | Solution It Led To |
|---|---|
| Where does data actually live? | DBFS → ADLS |
| Who governs access? | Hive Metastore → Unity Catalog |
| Managed vs chaos? | Managed vs External Tables |
| Multi-team isolation? | Catalogs + Schemas |

---

# 🟢 PHASE 2 — The OLD World: Hive Metastore + DBFS

## What is a Metastore? (First Principles)

Think of a **metastore** as a **phone book for your data**.

Your actual data (CSV, Parquet files) lives in storage. But your SQL engine needs to know:
- *"Where is the `sales` table physically stored?"*
- *"What columns does it have?"*
- *"What's its data type?"*

The **metastore stores this metadata** — it's a catalog/directory of your tables, not the data itself.

```
Metastore (the phone book)
    "sales table" → located at /mnt/datalake/sales/
    "customers table" → located at /mnt/datalake/customers/
    
Actual Storage (the city)
    /mnt/datalake/sales/       ← real Parquet files here
    /mnt/datalake/customers/   ← real Parquet files here
```

## What is Hive Metastore?

**Apache Hive** was originally a data warehouse built on top of Hadoop (2008). It introduced the concept of querying files with SQL. Its metastore became the *de facto standard* — even Spark adopted it.

**Hive Metastore = the old phone book**. It worked, but had serious problems:

| Limitation | Why It Hurts |
|---|---|
| **Workspace-scoped** | Each Databricks workspace had its own metastore. Team A couldn't see Team B's tables |
| **No fine-grained access control** | You either had access to everything or nothing |
| **No data lineage** | No tracking of where data came from or where it went |
| **No column-level security** | You couldn't hide just the SSN column from certain users |

---

## What is DBFS? (Databricks File System)

**DBFS = Databricks File System**

When Databricks launched, they needed a place to store data. They created DBFS — a **virtual file system** that sits on top of cloud storage.

```
You write to:    /dbfs/user/data/sales.parquet
Actually goes to: Azure Blob Storage → wasbs://container@account.blob.core.windows.net/...
```

It was a convenience layer. The problem?

```
❌ DBFS is workspace-local
❌ One workspace = one DBFS root
❌ No governance, no access control
❌ Data tied to a single workspace — if workspace is gone, data confusion ensues
❌ Not enterprise-ready
```

**DBFS was a crutch.** Good for learning, bad for production at scale.

---

### 🧠 Quick Check #1
> **Q:** What is the difference between a metastore and actual data storage?
> 
> *Answer: Metastore = metadata/phone book (WHERE is the table, WHAT are its columns). Storage = the actual data files (Parquet, CSV, Delta). They are separate.*

---

# 🟢 PHASE 3 — Azure Storage: Where Data Actually Lives

## Azure Data Lake Storage Gen2 (ADLS Gen2)

This is the **physical hard drive** of your data platform. Everything eventually lands here.

```
ADLS Gen2 Structure:
─────────────────────────────
Storage Account: mycompany_datalake
    └── Container: raw
        └── sales/
            └── 2024/
                └── data.parquet   ← ACTUAL DATA FILE
    └── Container: curated
        └── customers/
```

**Why ADLS over regular Blob Storage?**
- Built for big data (hierarchical namespace)
- Finer access control (ACLs at folder level)
- Works natively with Spark/Databricks

**Key mental model:**

```
Azure ADLS = your physical warehouse building
Containers  = floors of the warehouse  
Folders     = shelves on each floor
Files       = boxes on the shelves
```

Databricks **reads from and writes to** ADLS. That's it. Databricks itself stores no data — it's a compute engine that points at ADLS.

---

# 🟡 PHASE 4 — The Most Important Concept: Managed vs External Tables

This is where **90% of confusion lives**. Let's kill it permanently.

## The Core Analogy

Imagine you rent a storage unit (like a U-Haul facility).

| | Managed Table | External Table |
|---|---|---|
| **Analogy** | Storage unit OWNS your stuff. You check it in, they manage it. | You own the stuff. Storage unit just knows it's there. |
| **Who controls the file?** | Databricks/Unity Catalog | You (the engineer) |
| **DROP TABLE behavior** | **Deletes the actual files** ⚠️ | **Only removes metadata**, files stay safe ✅ |
| **Where files live** | UC-managed location (auto-assigned) | You specify the path |
| **Use case** | UC-governed internal tables | Sharing data across systems, existing data |

---

## Managed Tables — Deep Dive

```sql
CREATE TABLE dev.bronze.raw_sale (
  id INT,
  amount DOUBLE
);
-- You didn't specify LOCATION
-- Unity Catalog decides WHERE the files go
-- It stores them under its managed path
-- When you DROP TABLE → FILES ARE DELETED TOO
```

**Why would you use managed tables?**
- You want Unity Catalog to handle everything
- You don't care about the physical path
- Full lifecycle managed for you

**The storage path looks like:**
```
abfss://container@storage.dfs.core.windows.net/
  └── <metastore-id>/
      └── <catalog-id>/
          └── <schema-id>/
              └── <table-id>/     ← NOT the table name! It's a UUID
                  └── part-00000.parquet
```

> ⚠️ **Notice**: Unity Catalog uses **IDs (UUIDs), not names** for folder structure. This is intentional — if you rename a table, the path doesn't break.

---

## External Tables — Deep Dive

```sql
CREATE TABLE dev.bronze.raw_sale
LOCATION 'abfss://raw@mystorage.dfs.core.windows.net/sales/'
-- YOU specified where the files are
-- UC just registers this location in its phone book
-- When you DROP TABLE → only the metadata is deleted
-- Files in ADLS remain untouched ✅
```

**Why use external tables?**
- Data already exists in ADLS from another system
- You want the files to survive even if the table is dropped
- Sharing data between Databricks and other tools (Synapse, ADF, etc.)

---

### Visual Summary

```
MANAGED TABLE                        EXTERNAL TABLE
─────────────────                    ──────────────────
CREATE TABLE foo (...)               CREATE TABLE foo (...)
                                     LOCATION 'abfss://...'
        │                                    │
        ▼                                    ▼
UC picks storage path              YOU control storage path
        │                                    │
   DROP TABLE                           DROP TABLE
        │                                    │
        ▼                                    ▼
  ❌ FILES DELETED                   ✅ FILES REMAIN
  (metadata + data gone)             (only metadata removed)
```

---

### 🧠 Quick Check #2
> **Q1:** Your teammate runs `DROP TABLE production.sales.transactions`. Should you be worried?
>
> *It depends — if it's a **managed table**, the actual Parquet files in ADLS are deleted permanently. If it's **external**, only the metadata is removed and files are safe.*

> **Q2:** You're ingesting data from an external IoT system that writes files to ADLS directly. Should you use managed or external tables?
>
> *External — because the files already exist at a known path and are managed by another system.*

---

# 🟡 PHASE 5 — Unity Catalog: The New Governance Layer

## Why Unity Catalog Was Created

Hive Metastore had one fatal flaw: **it was workspace-scoped**.

```
OLD WORLD (Hive):
  Workspace A → its own Hive Metastore
  Workspace B → its own Hive Metastore
  
  Team A can't see Team B's tables. 
  No central governance. 
  No audit logs.
```

Unity Catalog solves this with a **single metastore across all workspaces**:

```
NEW WORLD (Unity Catalog):
  Account-level Unity Catalog Metastore
       ├── Workspace A connects here
       ├── Workspace B connects here  
       └── Workspace C connects here
       
  All workspaces share the same catalog/tables/permissions
```

---

## The 3-Level Namespace (The Most Important Mental Model)

```
catalog.schema.table

   dev.bronze.raw_sale
    │     │      │
    │     │      └── Table: raw_sale
    │     └───────── Schema (like a folder/database): bronze
    └─────────────── Catalog (like a project/environment): dev
```

| Level | What It Represents | Real-World Analogy |
|---|---|---|
| **Catalog** | Environment or domain (dev/prod, finance/marketing) | A filing cabinet |
| **Schema** | A logical grouping of tables | A drawer in the cabinet |
| **Table** | Actual data | A folder inside the drawer |

---

## The Hierarchy of Storage Control

This is **exactly what your video teaches**. Unity Catalog lets you define where managed table data is stored at **3 different levels**:

```
Level 1: METASTORE (account-wide default)
    "By default, store all data in this ADLS path"
    
Level 2: CATALOG (override for a specific catalog)
    "For the dev_ext catalog, store data HERE instead"
    
Level 3: SCHEMA (override for a specific schema)
    "For the bronze_ext schema, store data HERE specifically"
    
Note: TABLE level → not for managed tables (only external tables)
```

**The most specific level wins:**
```
Schema location defined? → Use schema location
No schema location, but catalog location defined? → Use catalog location
No catalog location? → Use metastore default location
```

---

# 🟠 PHASE 6 — Your Video, Now Fully Explained

## What the Video Was Actually Showing

The instructor created **3 schemas** to demonstrate how storage location inheritance works:

### Case 1: `dev.bronze` (No external location anywhere)
```sql
CREATE SCHEMA dev.bronze;
CREATE TABLE dev.bronze.raw_sale (...);
```
```
Storage path: <metastore-default-location>/<metastore-id>/<catalog-id>/<table-id>/
              ↑ Falls back to the metastore's default ADLS path
```

### Case 2: `dev_ext.bronze` (External location at CATALOG level)
```sql
-- dev_ext catalog was created with MANAGED LOCATION pointing to ADLS
CREATE SCHEMA dev_ext.bronze;
CREATE TABLE dev_ext.bronze.raw_sale (...);
```
```
Storage path: <catalog-external-location>/<catalog-id>/<table-id>/
              ↑ Uses the catalog's ADLS path, NOT the default metastore path
```

### Case 3: `dev_ext.bronze_ext` (External location at SCHEMA level)
```sql
CREATE SCHEMA dev_ext.bronze_ext
  MANAGED LOCATION 'abfss://schemas@mystorage.dfs.core.windows.net/bronze_ext/';

CREATE TABLE dev_ext.bronze_ext.raw_sale (...);
```
```
Storage path: <schema-external-location>/<schema-id>/<table-id>/
              ↑ Uses the schema's OWN ADLS path — most specific, wins
```

---

## What is an External Location?

An **External Location** in Unity Catalog is a **registered, trusted ADLS path**.

You can't just point a schema to *any* random ADLS path — UC needs to know it's allowed to use it. So you:

1. Create a **Storage Credential** (service principal / managed identity that has access to ADLS)
2. Create an **External Location** using that credential (registers a specific ADLS path as trusted in UC)
3. Now schemas/tables can use that path

```
Storage Credential = the KEY to the ADLS building
External Location  = registering a specific room/floor you're allowed to enter
Schema/Table       = actually going into that room and storing files there
```

---

## The Full Picture — Everything Connected

```
Azure ADLS Gen2 (Physical Storage)
    └── storage account: mycompany
        ├── /catalog/   ← external location for catalog level
        └── /schema/    ← external location for schema level

Unity Catalog (Governance Layer)
    └── Metastore (account-wide)
        ├── Storage Credential (auth to ADLS)
        ├── External Location: /catalog/ path  
        ├── External Location: /schema/ path   
        └── Catalog: dev_ext
            ├── Managed Location → /catalog/
            ├── Schema: bronze (inherits catalog location)
            │   └── Table: raw_sale → stored in /catalog/<ids>/
            └── Schema: bronze_ext (own location)
                └── Table: raw_sale → stored in /schema/<ids>/
```

---

## 🔑 Why Table IDs, Not Table Names?

The video showed that ADLS folders use UUIDs, not table names. Here's why:

```
❌ If UC used table names for folders:
   Rename table "sales" to "sales_v2" → folder path breaks → data lost!

✅ UC uses table IDs (UUIDs):
   Rename table "sales" to "sales_v2" → UUID stays the same → data still there!
   
   /abfss/.../3f8a9b2c-4d1e-.../ ← this never changes, even if you rename
```

---

### 🧠 Final Quiz — All Phases

**Q1:** You have a managed table in `dev_ext.bronze_ext`. Your schema has an external location defined. Where is the data stored?
> *At the schema's external location path in ADLS — the most specific level wins.*

**Q2:** What happens if you `DROP SCHEMA dev.bronze CASCADE`?
> *For managed tables inside, the actual Parquet files are deleted from ADLS. For external tables, files remain.*

**Q3:** Why does Unity Catalog use UUIDs for folder names instead of table names?
> *So that renaming tables/schemas doesn't break the physical file path — decouples the logical name from physical location.*

**Q4:** What's the difference between a Storage Credential and an External Location?
> *Storage Credential = the authentication (keys/identity to access Azure). External Location = a specific ADLS path registered in UC using that credential.*

---

## 📝 Active Recall Prompts (Spaced Repetition)

**Review tomorrow (Day 1):**
> "Explain managed vs external tables without notes — specifically what happens on DROP TABLE for each"

**Review in 3 days:**
> "What problem does Unity Catalog solve that Hive Metastore couldn't? Draw the storage hierarchy from metastore to table."

**Review in 7 days:**
> "You're designing a new Databricks environment. When would you define an external location at schema level vs catalog level? What's your reasoning?"

---

## 🗺️ Concept Connection Map

```
Unity Catalog (Governance)
    ├── connects to → Azure ADLS Gen2 (via External Locations)
    ├── replaces → Hive Metastore + DBFS
    ├── prerequisite for → External Tables, Managed Tables
    └── contrasts with → Hive Metastore (workspace-scoped, no governance)

Managed Tables
    ├── connects to → External Locations (schema/catalog level storage)
    ├── contrasts with → External Tables (lifecycle ownership differs)
    └── prerequisite for → DROP/UNDROP behavior (next video topic)

External Location
    ├── requires → Storage Credential (auth layer)
    ├── connects to → Schema MANAGED LOCATION
    └── prerequisite for → External Tables (table-level path control)
```

---

| Aspect | Managed Table | External Table |
|------|------|------|
| Who picks the ADLS path? | Unity Catalog (auto-assigned) | You (explicitly defined) |
| Who manages the files? | Unity Catalog | You |
| Governed by Unity Catalog? | ✅ Yes | ✅ Yes |
| Stored in ADLS? | ✅ Yes | ✅ Yes |

## ✅ The Correct Mental Model

- **ADLS** = where all data lives, always, for both table types.  
- **Unity Catalog** = governs both table types. Always.  
- **Managed vs External** = only answers the question: **"who owns the file lifecycle?"**
