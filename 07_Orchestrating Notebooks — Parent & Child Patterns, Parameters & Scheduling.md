# 📘 Orchestrating Notebooks — Parent/Child Patterns, Parameters & Scheduling

## 🗺️ Roadmap for This Session

```
PHASE 1 — The Problem: Why orchestration exists
PHASE 2 — The Parent-Child Notebook Pattern
PHASE 3 — Building the Child Notebook (full anatomy)
PHASE 4 — Building the Parent Notebook (calling + capturing output)
PHASE 5 — Scheduling: Automating the whole thing
PHASE 6 — The bigger picture: where this fits in real pipelines
```

---

# 🟢 PHASE 1 — The Problem: Why Orchestration Exists

## The Naive Approach (and Why It Breaks)

Imagine you're processing employee data for 10 departments: Sales, HR, Finance, IT, Operations...

```
Naive approach — one monolithic notebook:
─────────────────────────────────────────
# Read all data
df = spark.read.csv(...)

# Sales
df_sales = df.filter(df.department == "SALES")
df_sales.write.format("delta").save(...)

# HR
df_hr = df.filter(df.department == "HR")
df_hr.write.format("delta").save(...)

# Finance... IT... Operations...
# × 10 departments
```

Problems:
```
❌ Adding a new department = editing the notebook code
❌ One failure breaks ALL departments in one run
❌ Can't run Sales and HR in parallel
❌ Can't rerun just one department without touching others
❌ Not reusable — logic is duplicated for each department
❌ Impossible to schedule separately per department
```

**Orchestration = breaking this into modular, parameterized, reusable units.**

---

## The Engineering Principle at Play

This is **the same reason functions exist in programming**:

```python
# Bad: copy-paste logic
sales_total = sales_price * sales_qty
hr_total = hr_price * hr_qty

# Good: reusable function
def calculate_total(price, qty):
    return price * qty

sales_total = calculate_total(sales_price, sales_qty)
hr_total = calculate_total(hr_price, hr_qty)
```

**Parent-child notebooks are functions, but for entire data pipelines.**

```
Child notebook  = the reusable function (logic lives here)
Parent notebook = the caller (passes different parameters each time)
Parameter       = what changes between calls (department name)
```

---

# 🟢 PHASE 2 — The Parent-Child Notebook Pattern

## The Architecture

```
PARENT NOTEBOOK (run_employee_data)
    │
    ├── dbutils.notebook.run("child", 600, {"department": "SALES"})
    │       └── child runs → filters SALES → writes dev.bronze.d_sales → exits with count=51
    │
    ├── dbutils.notebook.run("child", 600, {"department": "HR"})
    │       └── child runs → filters HR → writes dev.bronze.d_hr → exits with count=34
    │
    └── dbutils.notebook.run("child", 600, {"department": "FINANCE"})
            └── child runs → filters FINANCE → writes dev.bronze.d_finance → exits with count=89
```

**Key insight:** The child notebook code never changes. Only the parameter changes.

---

## Information Flow: Two Directions

```
PARENT → CHILD: parameters (department name)
    via: dbutils.notebook.run(arguments={"department": "SALES"})
    read in child via: dbutils.widgets.get("department")

CHILD → PARENT: return value (record count)
    via: dbutils.notebook.exit(str(count))
    captured in parent via: result = dbutils.notebook.run(...)
```

This bidirectional communication is what makes notebook orchestration powerful.

---

# 🟡 PHASE 3 — Building the Child Notebook (Full Anatomy)

Let's walk through every section of the child notebook and understand **why** each part exists.

---

## Step 1: Create the Input Widget

```python
# Create a text widget to accept the department parameter
dbutils.widgets.text(
    name="department",      # key used to retrieve value
    defaultValue="",        # blank by default (parent will always provide it)
    label="Department name" # human-readable label in UI
)

# Read the widget value into a Python variable
dpd = dbutils.widgets.get("department")
print(f"Running for department: {dpd}")
```

**Why blank default?**
When the parent calls this notebook, it always provides the value. The blank default is just a safeguard. If someone runs this manually via UI, they must type a value.

---

## Step 2: Read the Source Data

```python
# Preview raw file first (sanity check)
dbutils.fs.head("/Volumes/dev/bronze/rawfiles/employees.csv")

# Load full dataset
df = spark.read.csv(
    "/Volumes/dev/bronze/rawfiles/employees.csv",
    header=True         # treat first row as column names
)

display(df)
```

---

## Step 3: Filter Based on the Parameter

```python
# Filter by department (case-insensitive) AND only active employees
df_filtered = df.filter(
    (df.department.upper() == dpd.upper()) &  # case-insensitive match
    (df.active_record == "1")                  # only active employees
)

display(df_filtered)
```

**Why `.upper()` on both sides?**
```
Widget input: "sales"    → upper() → "SALES"
Data value:  "Sales"     → upper() → "SALES"
Match: ✅

Without upper():
"sales" == "Sales" → False ❌ (missed records due to case mismatch)
```

This is **defensive programming** — don't assume input casing.

---

## Step 4: Conditional Write to Delta Table

```python
# Count filtered records
count = df_filtered.count()

# Only write if there's actual data
if count > 0:
    # Dynamic table name based on department parameter
    table_name = f"dev.bronze.d_{dpd.lower()}"
    
    df_filtered.write \
        .format("delta") \
        .mode("overwrite") \         # overwrite on re-runs (idempotent)
        .saveAsTable(table_name)
    
    print(f"✅ Written {count} records to {table_name}")
else:
    print(f"⚠️ No records found for department: {dpd}")
```

**Why `overwrite` mode?**
```
This notebook is designed to run repeatedly (scheduled daily).
If the table already exists from yesterday's run:
    overwrite → replace with today's fresh data ✅
    append    → duplicate rows accumulate ❌
    error     → pipeline breaks on second run ❌
```

**Why conditional write?**
```
If department="UNKNOWNDEPT" is passed by mistake:
    count = 0
    Skip write — don't create an empty Delta table ✅
    Print a warning so the issue is visible ✅
```

---

## Step 5: Verify the Write

```python
# Read back from the table we just wrote — confirms it worked
display(spark.table(f"dev.bronze.d_{dpd.lower()}"))
```

This is a **self-validation pattern** — write, then immediately read back to confirm. Essential in production pipelines to catch silent failures.

---

## Step 6: Exit with Return Value

```python
# Send the record count back to the parent notebook
dbutils.notebook.exit(str(count))
```

**Why `str(count)`?**
`notebook.exit()` only accepts strings. Convert int → string here, convert back in parent if needed.

**Why return count?**
The parent notebook can use this to:
- Log how many records were processed
- Trigger alerts if count is unexpectedly 0
- Build audit/monitoring tables

---

## Full Child Notebook — All Together

```python
# ── STEP 1: Widget ──────────────────────────────────────
dbutils.widgets.text("department", "", "Department name")
dpd = dbutils.widgets.get("department")

# ── STEP 2: Load Data ───────────────────────────────────
df = spark.read.csv(
    "/Volumes/dev/bronze/rawfiles/employees.csv",
    header=True
)

# ── STEP 3: Filter ──────────────────────────────────────
df_filtered = df.filter(
    (df.department.upper() == dpd.upper()) &
    (df.active_record == "1")
)

# ── STEP 4: Conditional Write ───────────────────────────
count = df_filtered.count()

if count > 0:
    table_name = f"dev.bronze.d_{dpd.lower()}"
    df_filtered.write.format("delta").mode("overwrite").saveAsTable(table_name)
    print(f"✅ {count} records written to {table_name}")
else:
    print(f"⚠️ No data for department: {dpd}")

# ── STEP 5: Verify ──────────────────────────────────────
if count > 0:
    display(spark.table(f"dev.bronze.d_{dpd.lower()}"))

# ── STEP 6: Return to Parent ────────────────────────────
dbutils.notebook.exit(str(count))
```

---

### 🧠 Quick Check #1

> **Q1:** Why do we use `.upper()` on both sides of the department filter?
>
> *Case-insensitive matching — widget might receive "sales", data might store "SALES" or "Sales". Uppercasing both sides ensures they always match regardless of casing.*

> **Q2:** The child notebook runs and `count = 0`. What happens?
>
> *The `if count > 0` block is skipped — no Delta table is written. The notebook exits with `"0"`. No error is thrown, but the parent receives `"0"` as the return value.*

> **Q3:** Why is `overwrite` mode chosen over `append`?
>
> *This notebook runs on a schedule (e.g., daily). Overwrite replaces yesterday's data with today's fresh filtered result. Append would keep accumulating duplicate rows on every run.*

---

# 🟡 PHASE 4 — Building the Parent Notebook

## The Parent's Job

The parent does three things:
1. Call the child with specific parameters
2. Capture the return value
3. Optionally loop over multiple departments

---

## Basic Parent: Single Department Call

```python
# Run the child notebook for SALES department
# Returns the exit value from dbutils.notebook.exit()
result = dbutils.notebook.run(
    path="WR_employee_data",   # child notebook name (same folder)
                               # use full path if in different folder:
                               # "/Users/you@company/pipelines/WR_employee_data"
    timeout_seconds=600,       # fail if child takes longer than 10 minutes
    arguments={"department": "SALES"}  # passed to child as widget value
)

print(f"Records processed: {result}")  # prints "51"
```

---

## The Timeout Parameter — Why It Matters

```
timeout_seconds=600 means:
    If child notebook hasn't finished in 10 minutes → force fail
    
Without timeout:
    A hung notebook (infinite loop, deadlock, stuck Spark job)
    runs forever → blocks your pipeline indefinitely → never alerts

With timeout:
    Hung notebook → fails at 10 min → parent gets an error
    → you get alerted → you investigate ✅

In production: always set a reasonable timeout.
```

---

## Practical Parent: Multiple Departments

```python
departments = ["SALES", "HR", "FINANCE", "IT", "OPERATIONS"]

results = {}

for dept in departments:
    count = dbutils.notebook.run(
        path="WR_employee_data",
        timeout_seconds=600,
        arguments={"department": dept}
    )
    results[dept] = int(count)
    print(f"{dept}: {count} records")

print("\n── Final Summary ──")
for dept, count in results.items():
    print(f"  {dept}: {count}")
```

```
Output:
  SALES: 51
  HR: 34
  FINANCE: 89
  IT: 12
  OPERATIONS: 200

── Final Summary ──
  SALES: 51
  HR: 34
  ...
```

**This is the power of the pattern** — one parent notebook processes all departments. Add a new department? Just add it to the list. Zero code changes in the child.

---

## Full Path Usage

```python
# If notebooks are in the same folder → just the name
dbutils.notebook.run("WR_employee_data", 600, {"department": "SALES"})

# If notebooks are in different folders → full workspace path
dbutils.notebook.run(
    "/Users/engineer@company.com/pipelines/WR_employee_data",
    600,
    {"department": "SALES"}
)

# Best practice for team environments: use relative paths from a repo root
# /Repos/main/my_project/pipelines/WR_employee_data
```

---

### 🧠 Quick Check #2

> **Q1:** `dbutils.notebook.run()` runs the child. What does it return?
>
> *Whatever string was passed to `dbutils.notebook.exit()` in the child. In our case, the string representation of the record count.*

> **Q2:** What happens if the child notebook takes 15 minutes but `timeout_seconds=600`?
>
> *The parent forcefully terminates the child notebook at 10 minutes and raises a `TimeoutError`. The pipeline fails and can trigger alerts.*

> **Q3:** You have 20 departments. Do you need 20 separate child notebooks?
>
> *No. One child notebook + a loop in the parent. The same child runs 20 times with 20 different parameter values.*

---

# 🟠 PHASE 5 — Scheduling: Automating the Whole Thing

## What Scheduling Means

Right now, you run the parent notebook manually. In production, you need it to run automatically — every day at 6 AM, every hour, every Monday, etc.

Databricks has a built-in job scheduler.

---

## How to Schedule via UI

```
In the notebook UI (top right):
    → Click "Schedule" button
    → Fill in:
        Job name:    "daily_employee_dept_pipeline"
        Schedule:    Daily at 06:00 AM UTC
        Cluster:     New job cluster (recommended) OR existing cluster
        Parameters:  department = SALES  (widget default)
        Notifications: your.email@company.com on failure
```

---

## New Job Cluster vs Existing Cluster

```
Existing all-purpose cluster:
    ✅ Already running, starts immediately
    ❌ Shared — other jobs can affect your job's resources
    ❌ You pay for idle time even when not running jobs
    ❌ Not isolated — one job's memory leak can affect another

New job cluster (recommended for scheduled jobs):
    ✅ Spins up fresh for THIS job only
    ✅ Terminates after job finishes → you only pay for run time
    ✅ Fully isolated
    ❌ Startup time (~2-5 minutes to spin up)
```

**Rule of thumb:** Interactive exploration → all-purpose cluster. Scheduled production jobs → job cluster.

---

## Cron Syntax (Advanced Scheduling)

The UI has simple daily/weekly options. For custom schedules, use **cron syntax**:

```
Cron format: minute  hour  day-of-month  month  day-of-week

Examples:
0 6 * * *        → Every day at 6:00 AM
0 */4 * * *      → Every 4 hours
0 8 * * 1        → Every Monday at 8:00 AM
30 9 1 * *       → 1st of every month at 9:30 AM
0 6 * * 1-5      → Weekdays only at 6:00 AM
```

---

## Notifications

```
Configure alerts for:
    ✅ Job start      → "pipeline started, expect results in 20 min"
    ✅ Job success    → "daily load completed, X records processed"
    ✅ Job failure    → "ALERT: pipeline failed, investigate immediately"

In production: failure alerts are non-negotiable.
Without them: job silently fails, bad data sits unnoticed for days.
```

---

# 🔴 PHASE 6 — The Bigger Picture

## Where This Pattern Fits in Real Data Pipelines

```
Real production pipeline (daily):

06:00 AM  → Scheduler triggers: run_employee_data (parent)
                │
                ├── child("SALES")   → writes dev.bronze.d_sales
                ├── child("HR")      → writes dev.bronze.d_hr
                ├── child("FINANCE") → writes dev.bronze.d_finance
                └── child("IT")      → writes dev.bronze.d_it
                
06:15 AM  → Scheduler triggers: transform_silver (next pipeline stage)
                │
                └── reads from dev.bronze.d_* tables
                    transforms, writes to dev.silver.*
                    
07:00 AM  → Dashboards refresh from dev.silver.*
            Analysts see fresh data ✅
```

This is the **Bronze → Silver → Gold** medallion architecture you'll study in depth soon. What you're building here is the **Bronze layer ingestion** pattern.

---

## The Design Principles You Just Applied

```
1. DRY (Don't Repeat Yourself)
   One child notebook instead of 10 department-specific notebooks

2. Idempotency
   overwrite mode → safe to re-run anytime, same result

3. Separation of Concerns
   Child: knows HOW to process one department
   Parent: knows WHICH departments to process and WHEN

4. Observability
   exit() returns count → parent can log/alert on unexpected values
   Print statements → visible in job logs
   Notifications → immediate failure alerts

5. Defensive Programming
   case-insensitive filter
   conditional write (skip if no data)
   timeout on notebook.run()
```

---

## 🗺️ Concept Connection Map

```
Parent-Child Notebooks
    ├── child receives params via → dbutils.widgets (text widget)
    ├── parent passes params via → dbutils.notebook.run(arguments={})
    ├── child returns value via → dbutils.notebook.exit(str(value))
    ├── parent captures return via → result = dbutils.notebook.run(...)
    └── scales to N departments → loop in parent, single child reused

Scheduling
    ├── triggers → parent notebook automatically
    ├── job cluster → isolated, cost-efficient for scheduled jobs
    ├── cron syntax → fine-grained schedule control
    └── notifications → observability for production pipelines

This pattern connects to:
    ├── Medallion architecture (Bronze ingestion layer)
    ├── ADF/Airflow (more advanced orchestration tools)
    └── Databricks Workflows (next evolution of this pattern)
```

---

## 📝 Active Recall Prompts

**Day 1:**
> *"Explain the parent-child notebook pattern from memory. What flows from parent → child? What flows child → parent? What commands handle each direction?"*

**Day 3:**
> *"You have a sales pipeline that processes data for 15 regions. Design the parent-child architecture. What does the child do? What does the parent do? How do you scale it?"*
>
> *"Why use a job cluster instead of an all-purpose cluster for scheduled jobs?"*

**Day 7:**
> *"A scheduled pipeline runs daily at 6 AM. On day 5 it silently writes 0 records — no error, no alert. What design decisions would have caught this? Fix the pipeline."*

---
