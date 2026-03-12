# 📘 Managed vs External Tables — Unity Catalog vs Legacy Hive + UNDROP

## 🗺️ Roadmap for This Session

```
PHASE 1 — Quick Recap & Bridge (what you already know)
PHASE 2 — The Legacy Hive Metastore behavior (the OLD, dangerous world)
PHASE 3 — Unity Catalog behavior (the NEW, safer world)
PHASE 4 — DROP behavior: exactly what happens to your files
PHASE 5 — UNDROP: the safety net feature
PHASE 6 — Full comparison table + when to use what
```

---

# 🟢 PHASE 1 — Bridge From Last Session

You now know:
- ADLS = physical storage, always
- Unity Catalog = governs everything
- Managed = UC picks the path, owns the lifecycle
- External = you pick the path, you own the lifecycle

**This session answers one new question:**

> *"What actually happens to your data files when you DELETE a table?"*

And the answer is **completely different** depending on:
1. Whether you're on **Legacy Hive** or **Unity Catalog**
2. Whether it's a **managed** or **external** table

---

# 🟢 PHASE 2 — Legacy Hive Metastore: The Dangerous Old World

## How DROP TABLE worked in Hive

```
Legacy Hive Metastore
─────────────────────
DROP TABLE managed_table
    │
    ├── Metadata deleted ✅
    └── Physical files in storage → DELETED IMMEDIATELY ❌☠️

DROP TABLE external_table
    │
    ├── Metadata deleted ✅
    └── Physical files → SAFE, untouched ✅
```

**Managed table in Hive = instant death for your data.**

No grace period. No recovery. No undo.
One wrong `DROP TABLE` → data is permanently gone.

This was a massive operational risk in production systems.

---

### 🧠 Quick Check #1
> **Q:** In legacy Hive, a junior engineer accidentally drops a managed table in production. What happens?
>
> *Metadata gone + actual data files deleted immediately. No recovery possible. Incident.*

---

# 🟡 PHASE 3 — Unity Catalog: The Safer New World

Unity Catalog changes the DROP behavior for **managed tables** specifically.

```
Unity Catalog
─────────────────────
DROP TABLE managed_table
    │
    ├── Metadata deleted immediately ✅
    └── Physical files in ADLS → NOT deleted immediately
                                 Kept for 7–30 days 🕐
                                 Then permanently deleted

DROP TABLE external_table
    │
    ├── Metadata deleted immediately ✅
    └── Physical files in ADLS → NEVER deleted by UC ✅
                                 They stay forever until YOU delete them
```

**Key shift:** UC gives you a **grace window** on managed tables. Your data survives the DROP for a period — long enough to recover from mistakes.

---

## Why doesn't UC delete external table files?

Because **it never owned them.**

External table = you told UC *"hey, those files over there — register them as a table."*
UC only added a metadata entry. It never took custody of the files.
So when you drop it, UC removes what it added (metadata). It doesn't touch what was already yours.

---

# 🟡 PHASE 4 — The DROP Behavior: Full Breakdown

## The Complete Matrix

| Scenario | Metadata after DROP | Files after DROP | Recoverable? |
|---|---|---|---|
| **Hive — Managed** | Gone immediately | Gone immediately ☠️ | ❌ No |
| **Hive — External** | Gone immediately | Safe ✅ | Partial (files exist, metadata gone) |
| **UC — Managed** | Gone immediately | Kept 7–30 days 🕐 | ✅ Yes (within window) |
| **UC — External** | Gone immediately | Safe forever ✅ | ✅ Yes (files never touched) |

---

## What "metadata deleted immediately" means

When you DROP any table, the first thing that dies is the **entry in Unity Catalog's registry** — the phone book entry.

```
Before DROP:
  UC registry: "raw_sale → lives at abfss://.../3f8a9b2c..."
  ADLS: files exist at that path

After DROP (all cases):
  UC registry: entry removed ← happens instantly
  ADLS: depends on table type + system (Hive vs UC)
```

So immediately after DROP — even in UC — if you run `SELECT * FROM bronze.raw_sale`, you get an error. The table is "gone" from SQL's perspective.

But the **files may still be physically sitting in ADLS**, which is what UNDROP exploits.

---

# 🟠 PHASE 5 — UNDROP: The Safety Net

## What UNDROP Actually Does

UNDROP does **not** restore files. The files were never deleted (within the window).

What UNDROP does is **restore the metadata entry** back into Unity Catalog's registry.

```
DROP TABLE → removes metadata, files stay (7–30 day window)
UNDROP TABLE → puts metadata back, points to the still-existing files

Result: table is back, as if nothing happened
```

---

## The 7-Day Retention Window

```
Day 0:  DROP TABLE executed → metadata gone, files in ADLS still intact
Day 1:  UNDROP still works ✅
Day 3:  UNDROP still works ✅
Day 7:  UNDROP still works ✅
Day 8+: Files start getting cleaned up → UNDROP may fail ❌
```

This window is **7 days by default**, can extend to 30 days depending on configuration.

---

## UNDROP Syntax

```sql
-- Option 1: by table name (if name is still unique/known)
UNDROP TABLE dev.bronze.raw_sale;

-- Option 2: by table ID (safer — name might be reused)
UNDROP TABLE <table_id>;

-- How do you find the table_id of a dropped table?
SHOW TABLES DROPPED IN dev.bronze;
-- Returns a list of recently dropped tables with their IDs and drop timestamps
```

---

## Why table ID matters for UNDROP

```
Scenario:
  DROP TABLE dev.bronze.raw_sale       ← dropped
  CREATE TABLE dev.bronze.raw_sale     ← new table, same name
  UNDROP TABLE dev.bronze.raw_sale     ← which one?? Ambiguous ⚠️

Safer:
  UNDROP TABLE <specific-table-id>     ← unambiguous, exact table
```

---

## Does UNDROP work for External Tables too?

**Yes.** Because:
- Files were never deleted (they're in your ADLS external path, UC doesn't touch them)
- UC just needs to restore the metadata entry
- UNDROP within 7 days → table comes back

Even after 7 days, for external tables, files still exist in ADLS. You'd just need to re-register the table manually (recreate the metadata pointing to the existing files).

---

### 🧠 Quick Check #2

> **Q1:** UNDROP restores files from a backup. True or False?
>
> *False. UNDROP only restores metadata. The files were never deleted — they were just "unregistered" when the table was dropped.*

> **Q2:** You dropped a managed table 10 days ago and just realized it. Can you UNDROP?
>
> *Likely not — you're outside the 7-day retention window. Files may have been cleaned up already.*

> **Q3:** You dropped an external table 20 days ago. Can you recover?
>
> *Yes — files are still in ADLS (UC never deletes external files). You can't UNDROP (beyond 7 days for metadata), but you can manually recreate the table pointing to the existing ADLS path.*

---

# 🔴 PHASE 6 — The Full Picture: Everything Side by Side

## Hive vs Unity Catalog

| Behavior | Hive Metastore | Unity Catalog |
|---|---|---|
| Managed table DROP | Files deleted instantly ☠️ | Files kept 7–30 days |
| External table DROP | Files safe | Files safe |
| Recovery after DROP | ❌ Impossible | ✅ UNDROP within 7 days |
| Column-level security | ❌ No | ✅ Yes |
| Cross-workspace sharing | ❌ No | ✅ Yes |
| Audit logs | ❌ No | ✅ Yes |

---

## When to Actually Use Each Table Type

```
Use MANAGED when:
  ✅ Data is created and owned entirely within Databricks
  ✅ You want UC to handle storage path, cleanup, lifecycle
  ✅ You don't need other systems (Synapse, ADF) to read the same files
  ✅ Simpler = better for your use case

Use EXTERNAL when:
  ✅ Files already exist in ADLS from another system (ADF pipeline, IoT, etc.)
  ✅ Multiple tools need to read the same files (not just Databricks)
  ✅ You need files to survive even if the table is dropped
  ✅ You want full control over the physical file location
```

---

## 🗺️ Concept Connection Map

```
DROP TABLE behavior
    ├── depends on → Managed vs External distinction
    ├── depends on → Hive Metastore vs Unity Catalog
    └── connects to → UNDROP (recovery mechanism)

UNDROP
    ├── requires → Unity Catalog (not available in Hive)
    ├── works because → files not immediately deleted (managed tables)
    ├── relies on → 7-day metadata retention window
    └── safer via → table ID rather than table name

External Tables
    ├── files safe after DROP → always (UC never owns them)
    ├── recoverable after 7 days → yes, by recreating metadata
    └── contrasts with → Managed tables (UC owns lifecycle)
```

---

## 📝 Active Recall Prompts

**Day 1:**
> *"What is the exact sequence of events when you DROP a managed table in Unity Catalog? Be specific about metadata vs files."*

**Day 3:**
> *"Your colleague says 'UNDROP restored the files from backup.' What's wrong with that statement?"*
>
> *"An external table was dropped 15 days ago. Walk me through exactly how you'd recover it."*

**Day 7:**
> *"Compare Hive vs Unity Catalog DROP behavior across all 4 scenarios (managed/external × Hive/UC) without looking at notes."*

---
