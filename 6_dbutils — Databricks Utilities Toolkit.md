# 📘 dbutils — Databricks Utilities Toolkit

## 🗺️ Roadmap for This Session

```
PHASE 1 — What is dbutils and why it exists
PHASE 2 — dbutils.fs (file system operations)
PHASE 3 — File system paths (the confusion zone)
PHASE 4 — dbutils.widgets (parameterizing notebooks)
PHASE 5 — dbutils.secrets (overview)
PHASE 6 — dbutils.notebook (modular workflows)
```

---

# 🟢 PHASE 1 — What is dbutils and Why It Exists

## The Problem First

Databricks notebooks run code (Python/SQL/Scala/R). But code alone can't easily:

```
- Navigate and manage files across ADLS, DBFS, local disk
- Accept dynamic inputs without hardcoding values
- Securely use passwords/tokens without exposing them in code
- Call other notebooks as reusable modules
```

You could write raw Python (`os`, `boto3`, `azure-storage-blob`) to do some of this — but it would be verbose, inconsistent, and not Databricks-aware.

**dbutils = Databricks' built-in Swiss Army knife** for these exact tasks. It knows about your cluster, your storage, your UC setup — already configured, no boilerplate.

---

## What dbutils Is NOT

```
❌ Not available in SQL notebooks
❌ Not available in R notebooks (partially)
✅ Available in: Python, Scala notebooks
✅ Available in: Python cells within mixed notebooks (%python magic)
```

This matters. If you try `dbutils.fs.ls()` in a pure SQL notebook, it won't work.

---

## Self-Discovery: The Help System

```python
# See ALL available utilities
dbutils.help()

# See all commands within a specific utility
dbutils.fs.help()
dbutils.widgets.help()
dbutils.secrets.help()
dbutils.notebook.help()
```

**This is the most important habit to build.** Don't memorize every command — know how to discover them. The help output shows command names, parameters, and descriptions inline.

---

# 🟢 PHASE 2 — dbutils.fs: File System Operations

## The 4 Core Commands

```python
dbutils.fs.ls(path)           # List contents of a directory
dbutils.fs.head(path)         # Preview first N bytes of a file
dbutils.fs.cp(source, dest)   # Copy a file from one location to another
dbutils.fs.mkdirs(path)       # Create a directory (and any parent dirs)
```

There are more (`mv`, `rm`, `mount`) but these 4 cover 90% of daily use.

---

## `dbutils.fs.ls` — List Directory

```python
# List root of DBFS
dbutils.fs.ls("dbfs:/")

# List a specific volume
dbutils.fs.ls("/Volumes/dev/bronze/managedvolume/files")

# List local cluster disk
dbutils.fs.ls("file:/")

# Prettier output — wrap with display()
display(dbutils.fs.ls("/Volumes/dev/bronze/managedvolume"))
```

`display()` renders the result as a table in the notebook UI instead of a raw Python list. Always prefer it when exploring interactively.

---

## `dbutils.fs.head` — Preview a File

```python
# Show first 65536 bytes (default) of a file
dbutils.fs.head("/Volumes/dev/bronze/managedvolume/files/EMP.csv")

# Show first N bytes
dbutils.fs.head("/Volumes/dev/bronze/managedvolume/files/EMP.csv", 500)
```

**Use case:** Quick sanity check — is this file readable? Does it look like the right format? Don't load the whole file just to check the first 5 rows.

---

## `dbutils.fs.mkdirs` — Create Directories

```python
# Create a nested folder structure inside a volume
# (creates all parent folders automatically if they don't exist)
dbutils.fs.mkdirs("/Volumes/dev/bronze/managedvolume/input/csv")
```

Equivalent to `mkdir -p` in Linux. You don't need to create `/input` first — mkdirs handles the whole chain.

---

## `dbutils.fs.cp` — Copy Files

```python
# Copy between any two supported file systems
dbutils.fs.cp(source_path, destination_path)

# Copy entire directory recursively
dbutils.fs.cp(source_path, destination_path, recurse=True)
```

---

# 🟠 PHASE 3 — File System Paths (The Confusion Zone)

This is where most people get stuck. Let's fix it permanently.

## The 4 File Systems You'll Encounter

```
1. DBFS        prefix: "dbfs:/"   or no prefix (default)
2. ADLS Gen2   prefix: "abfss://"
3. Volume      prefix: "/Volumes/" (UC-managed, no extra prefix needed)
4. Local disk  prefix: "file:/"
```

---

## What Each One Is

```
DBFS (dbfs:/)
    The legacy Databricks virtual file system
    Still exists, still used for some internal Databricks paths
    Being phased out in favor of Volumes + ADLS
    Default when you don't specify a prefix

ADLS (abfss://)
    The actual Azure cloud storage
    Full path: abfss://container@storageaccount.dfs.core.windows.net/path
    Used when directly referencing storage outside of UC

Volumes (/Volumes/)
    UC-governed path — the modern way
    Abstracts away the actual ADLS path
    You use /Volumes/catalog/schema/volume/... always

Local disk (file:/)
    The cluster driver node's actual hard drive
    Temporary — disappears when cluster is terminated
    Use for: files downloaded with wget, temporary scratch space
```

---

## The Practical Path Decision Tree

```
Where is the file?

Is it a UC-governed volume?
    YES → use /Volumes/catalog/schema/volume/...

Is it in ADLS directly (not via UC)?
    YES → use abfss://container@account.dfs.core.windows.net/...

Is it a file you just downloaded with wget / created locally?
    YES → use file:/home/path/... or file:/databricks/driver/...

Is it a legacy DBFS path?
    YES → use dbfs:/... or just /...
```

---

## The Copy Patterns You'll Actually Use

```python
# Pattern 1: wget → volume (most common for ingestion demos)
# Step 1: wget downloads to cluster local disk
%sh wget https://example.com/data.csv -O /tmp/data.csv

# Step 2: copy from local to volume
dbutils.fs.cp("file:/tmp/data.csv", "/Volumes/dev/bronze/myvol/files/data.csv")

# Pattern 2: volume → volume (reorganizing)
dbutils.fs.cp(
    "/Volumes/dev/bronze/raw/data.csv",
    "/Volumes/dev/silver/processed/data.csv"
)

# Pattern 3: ADLS → volume (pulling from raw storage into UC)
dbutils.fs.cp(
    "abfss://raw@mystorage.dfs.core.windows.net/landing/data.csv",
    "/Volumes/dev/bronze/myvol/files/data.csv"
)
```

---

### 🧠 Quick Check #1

> **Q1:** You run `wget https://example.com/file.csv`. What path do you use to reference this file in `dbutils.fs.cp`?
>
> *`"file:/tmp/file.csv"` or wherever wget put it on the local disk. The `file:/` prefix tells dbutils this is the cluster's local filesystem, not DBFS or a volume.*

> **Q2:** What does `dbutils.fs.mkdirs` do if the parent folder doesn't exist yet?
>
> *It creates the entire path including all missing parent directories — like `mkdir -p` in Linux.*

> **Q3:** You want to browse your volume's contents nicely in a notebook. What's better — plain `dbutils.fs.ls()` or `display(dbutils.fs.ls())`? Why?
>
> *`display()` renders a formatted table in the notebook UI. Plain `ls()` returns a raw Python list — harder to read when exploring interactively.*

---

# 🟡 PHASE 4 — dbutils.widgets: Parameterizing Notebooks

## The Problem Widgets Solve

```python
# Hardcoded notebook — bad practice
customer_id = "10000"   # ← you have to edit code to change this
SELECT * FROM sales WHERE custID = 10000  # ← hardcoded in query

Problems:
    ❌ Different runs require code edits
    ❌ Can't pass different values from orchestration tools (ADF, Airflow)
    ❌ Not reusable across environments (dev vs prod)
```

**Widgets turn hardcoded values into dynamic inputs.**

---

## Widget Types

```
Text      → free-form text input box (most common)
Dropdown  → pick one value from a fixed list
Combobox  → dropdown but also allows typing custom values
Multiselect → pick multiple values from a list
```

---

## Creating and Using a Text Widget

```python
# Create a text widget
dbutils.widgets.text(
    name="input_custID",       # internal name (used to retrieve value)
    defaultValue="10000",      # what shows by default
    label="Customer ID"        # what the user sees as the label
)

# Read the current value of the widget
customer_id = dbutils.widgets.get("input_custID")
print(f"Running for customer: {customer_id}")

# Remove a specific widget
dbutils.widgets.remove("input_custID")

# Remove all widgets
dbutils.widgets.removeAll()
```

After creating a widget, **a text box appears in the notebook toolbar** at the top. Changing the value in that box and pressing Enter automatically reruns dependent cells.

---

## Using Widgets in SQL Queries

The syntax depends on your Databricks Runtime (DBR) version:

```sql
-- DBR 15.1 and BELOW (older syntax):
SELECT * FROM dev.bronze.sales
WHERE custID = ${input_custID}

-- DBR ABOVE 15.1 (newer syntax):
SELECT * FROM dev.bronze.sales
WHERE custID = :input_custID
```

```
How this works:
    Widget has value "10000"
    SQL query runs as: WHERE custID = 10000
    Change widget to "20000" → query reruns as: WHERE custID = 20000
    
    No code changes needed — just change the widget value
```

---

## Real-World Use Cases for Widgets

```
1. Environment switching
   dbutils.widgets.dropdown("env", "dev", ["dev", "staging", "prod"])
   catalog = dbutils.widgets.get("env")
   → Same notebook works across all environments

2. Date range filtering
   dbutils.widgets.text("start_date", "2024-01-01", "Start Date")
   dbutils.widgets.text("end_date", "2024-12-31", "End Date")
   → Analyst changes dates without touching code

3. ADF/Airflow pipeline parameter passing
   → Orchestration tool passes widget values when calling notebook
   → Notebook runs with those values dynamically
```

---

### 🧠 Quick Check #2

> **Q1:** What's the difference between `name` and `label` in `dbutils.widgets.text()`?
>
> *`name` is the internal key used in code to retrieve the value (`dbutils.widgets.get("name")`). `label` is what the user sees displayed next to the input box in the UI.*

> **Q2:** You're on DBR 16.0 and write `WHERE id = ${myWidget}` in a SQL cell. Will it work?
>
> *No. DBR above 15.1 uses `:myWidget` syntax, not `${myWidget}`. Use `WHERE id = :myWidget` instead.*

---

# 🟢 PHASE 5 — dbutils.secrets: Secure Credential Management

## The Problem

```python
# ❌ Never do this — credentials hardcoded in notebook
storage_key = "xK9mP2qR8..."
service_principal_secret = "abc123xyz..."

# This notebook is now a security liability:
# - Visible to anyone with notebook access
# - Stored in version control
# - Logged in execution history
```

**Secrets = a secure vault** for storing sensitive values outside your code.

---

## How It Works (Conceptual)

```
Secret Scope (the vault)
    ├── Can be Databricks-managed
    └── Can be backed by Azure Key Vault (enterprise standard)

Inside a scope, you store secrets as key-value pairs:
    "storage_account_key" → "xK9mP2qR8..."  (stored encrypted)
    "service_principal_id" → "abc123..."      (stored encrypted)

In your notebook:
    key = dbutils.secrets.get(scope="myscope", key="storage_account_key")
    → Returns the value at runtime
    → Value is NEVER printed/displayed — Databricks redacts it with [REDACTED]
```

```python
# How you use it in code
storage_key = dbutils.secrets.get(scope="prod-secrets", key="adls-key")
# storage_key now holds the actual value in memory
# but it NEVER appears in notebook output — shown as [REDACTED]

# List available scopes
dbutils.secrets.listScopes()

# List keys within a scope (not values — just key names)
dbutils.secrets.list("prod-secrets")
```

The video defers deep coverage to a later session — the important thing now is to understand **why** secrets exist and **never hardcode credentials** in notebooks.

---

# 🟢 PHASE 6 — dbutils.notebook: Modular Workflows

## The Problem

As your data platform grows, you'll have dozens of notebooks:
- `ingest_sales.py`
- `ingest_customers.py`
- `transform_silver.py`
- `load_gold.py`

Running them manually one by one doesn't scale. And copy-pasting shared logic into every notebook violates the engineering principle of DRY (Don't Repeat Yourself).

**dbutils.notebook lets notebooks call other notebooks** — like functions calling other functions.

---

## The Two Key Commands

```python
# Run another notebook and wait for it to finish
dbutils.notebook.run(
    path="/path/to/notebook",        # notebook location
    timeout_seconds=300,             # fail if takes longer than 5 min
    arguments={"env": "prod",        # pass parameters (like widget values)
                "date": "2024-01-01"}
)

# Exit the current notebook with a return value
dbutils.notebook.exit("SUCCESS")
dbutils.notebook.exit("FAILED: missing input file")
```

---

## What This Enables

```
master_pipeline notebook:
    │
    ├── dbutils.notebook.run("ingest_sales", arguments={"env": "prod"})
    ├── dbutils.notebook.run("ingest_customers", arguments={"env": "prod"})
    └── dbutils.notebook.run("transform_silver", arguments={"env": "prod"})

Each child notebook:
    ├── Reads arguments via dbutils.widgets.get()
    ├── Does its job
    └── dbutils.notebook.exit("SUCCESS")
```

This is a simple form of **workflow orchestration** — though in production you'd typically use Databricks Workflows or ADF for this.

---

## Full dbutils Summary

```
dbutils
    │
    ├── .fs          → file/directory operations
    │     ├── .ls()      list contents
    │     ├── .head()    preview file
    │     ├── .cp()      copy files
    │     └── .mkdirs()  create directories
    │
    ├── .widgets     → dynamic notebook parameters
    │     ├── .text()      create text input
    │     ├── .dropdown()  create dropdown
    │     ├── .get()       read current value
    │     └── .remove()    clean up widgets
    │
    ├── .secrets     → secure credential management
    │     ├── .get()         retrieve a secret value
    │     ├── .list()        list keys in a scope
    │     └── .listScopes()  list all available scopes
    │
    └── .notebook    → modular workflow management
          ├── .run()   execute another notebook
          └── .exit()  terminate with return value
```

---

## 🗺️ Concept Connection Map

```
dbutils.fs
    ├── connects to → Volumes (/Volumes/ path)
    ├── connects to → DBFS (legacy, dbfs:/ path)
    ├── connects to → ADLS (abfss:// path)
    └── confusion point → "file:/" prefix for local cluster disk

dbutils.widgets
    ├── solves → hardcoded values in notebooks
    ├── enables → same notebook across dev/staging/prod
    └── connects to → ADF/Airflow (pass args as widget values)

dbutils.secrets
    ├── solves → hardcoded credentials security risk
    ├── backed by → Azure Key Vault (enterprise) or Databricks
    └── rule → never hardcode credentials, always use secrets

dbutils.notebook
    ├── enables → modular pipeline design
    ├── connects to → widgets (.run() passes args, child reads via .get())
    └── alternative to → Databricks Workflows for simple orchestration
```

---

## 📝 Active Recall Prompts

**Day 1:**
> *"List the 4 file system prefixes in Databricks and when you'd use each one. No notes."*
>
> *"Walk through the full flow: download a CSV with wget → copy to a UC volume → read it with SQL."*

**Day 3:**
> *"What problem do widgets solve? Create a widget in your head for switching between dev/prod environments. Write the code."*
>
> *"Why should you never hardcode a storage account key in a notebook? What do you use instead?"*

**Day 7:**
> *"Design a modular pipeline using 3 notebooks: ingest, transform, load. How do you orchestrate them? How do you pass the environment (dev/prod) to each? Write the skeleton code using dbutils."*

---
