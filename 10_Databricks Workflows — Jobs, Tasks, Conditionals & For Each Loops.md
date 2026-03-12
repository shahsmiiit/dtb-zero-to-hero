# 📘 Databricks Workflows — Jobs, Tasks, Conditionals & For Each Loops

## 🗺️ Roadmap for This Session

```
PHASE 1 — Why Workflows exist (vs dbutils.notebook.run)
PHASE 2 — Core Concepts: Jobs, Tasks, Dependencies
PHASE 3 — Inter-Task Communication (dbutils.jobs.taskValues)
PHASE 4 — Conditional Branching (If/Else Task)
PHASE 5 — For Each Loop Task
PHASE 6 — Repair Run (surgical failure recovery)
PHASE 7 — Full Workflow Design Principles
```

---

# 🟢 PHASE 1 — Why Workflows Exist

## You Already Know `dbutils.notebook.run()` — What's Wrong With It?

In session 19, you built a parent-child notebook pattern. It works. But it has fundamental limitations:

```
dbutils.notebook.run() problems:
    ❌ Sequential only — runs notebooks one after another
       No parallel execution
    
    ❌ No visual monitoring
       You see print statements in a notebook, nothing more
    
    ❌ No conditional branching
       Can't say "run task B only if task A returned X"
    
    ❌ No retry logic
       Task fails → entire parent notebook fails
       Must re-run everything from scratch
    
    ❌ No scheduling with dependency awareness
       Cron schedule is all-or-nothing
    
    ❌ No for-each over dynamic lists
       You write Python loops, not workflow-managed iterations
    
    ❌ No audit history
       No run history, no per-task logs, no timeline view
```

**Databricks Workflows is the production-grade replacement for all of that.**

---

## The Mental Model Shift

```
dbutils.notebook.run()      →    Databricks Workflows
─────────────────────────────────────────────────────
Code-based orchestration    →    UI + configuration-based orchestration
Sequential only             →    Parallel + sequential + conditional
No visibility               →    Full DAG visualization + per-task logs
Manual retry                →    Repair Run (retry only failed tasks)
Notebook → Notebook only    →    Notebooks + SQL + Python + dbt + Spark + more
```

**Think of it this way:**
- `dbutils.notebook.run()` = writing your own orchestration in code
- Databricks Workflows = using a proper orchestration engine (like a lightweight Airflow built into Databricks)

---

# 🟢 PHASE 2 — Core Concepts: Jobs, Tasks, Dependencies

## Definitions

```
JOB
    A named, schedulable pipeline
    Made up of one or more tasks
    Has its own configuration: schedule, cluster, parameters, notifications
    Example: "daily_emp_processing"

TASK
    A single unit of work within a job
    Has a type (notebook, SQL, Python, if-else, for-each, etc.)
    Has dependencies (which tasks must succeed before this one runs)
    Has its own cluster, parameters, retry policy
    Example: "01_get_day", "02_process_data", "03_else_branch"

DAG (Directed Acyclic Graph)
    The execution map of your tasks
    "Task B depends on Task A" = Task B runs AFTER Task A succeeds
    Visual in the Workflows UI as a flowchart
```

---

## Task Types Available

```
NOTEBOOK        → run a Databricks notebook (Python/SQL/Scala/R)
PYTHON SCRIPT   → run a .py file directly
SQL             → run a SQL query or script
DBT             → run a dbt project/model
SPARK SUBMIT    → submit a raw Spark job (JAR)
PIPELINE        → run a Delta Live Tables pipeline
RUN JOB         → trigger another job (job calling a job)
IF/ELSE         → conditional branching based on a value
FOR EACH        → iterate over a list, run nested task per item
```

This is far richer than `dbutils.notebook.run()` which only supported notebooks.

---

## Job-Level vs Task-Level Configuration

```
JOB LEVEL (applies to whole job):
    ├── Job name
    ├── Schedule (when to run)
    ├── Job-level parameters (available to ALL tasks)
    ├── Max concurrent runs (can 2 runs of same job overlap?)
    ├── Job-level notifications (email on job success/failure)
    └── Permissions (who can view/run/manage this job)

TASK LEVEL (per task):
    ├── Task name
    ├── Task type (notebook/SQL/etc.)
    ├── Cluster (job cluster or existing)
    ├── Dependencies (which tasks must complete first)
    ├── Parameters (widget values passed to this task)
    ├── Retry policy (retry 3 times on failure?)
    ├── Timeout (fail if task takes longer than X minutes)
    └── Task-level notifications
```

---

## Advanced Job Settings

```
QUEUE BEHAVIOR
    "What happens if no cluster resources are available when job triggers?"
    
    Option A: Wait up to 48 hours for resources to free up
    Option B: Fail immediately if resources unavailable
    
    Choose based on SLA criticality:
        Non-critical batch → wait (Option A)
        SLA-critical pipeline → fail fast + alert (Option B)

MAX CONCURRENT RUNS
    Can multiple runs of this same job execute simultaneously?
    
    Default: 1 (previous run must finish before next starts)
    Example use of >1: 
        Job triggered per event, multiple events can come at once
        Each needs its own independent run
```

---

### 🧠 Quick Check #1

> **Q1:** What is the difference between a Job and a Task in Databricks Workflows?
>
> *A Job is the entire pipeline — the schedulable unit with a name, schedule, and notifications. A Task is a single step inside the job. A job has one or many tasks. Tasks have dependencies on each other.*

> **Q2:** You have a job that runs every hour. Should Max Concurrent Runs be 1 or higher?
>
> *Depends on runtime. If the job takes 50 minutes and runs every hour, you might want >1 to allow overlap. But if it processes the same data, overlapping runs would conflict → keep it at 1.*

---

# 🟡 PHASE 3 — Inter-Task Communication: dbutils.jobs.taskValues

## The Problem

Tasks are isolated. Task A runs in its own notebook. Task B runs in a separate notebook. They don't share memory.

```
Task A computes: day_of_week = "Sunday"
Task B needs to know: is it Sunday?

How does Task B get that value from Task A?
```

You cannot use Python variables — different notebooks, different Spark contexts. You need a **message passing mechanism** that Databricks Workflows manages.

---

## The Solution: taskValues

```
dbutils.jobs.taskValues.set()   →   "publish a value from this task"
dbutils.jobs.taskValues.get()   →   "read a value published by another task"
```

Databricks stores these values in the job run's state, accessible by any downstream task.

---

## Setting a Value (in the UPSTREAM task)

```python
# Task: 01_set_day
# After computing the day of week...

input_day = "Sunday"   # computed from date logic

# Publish this value to the workflow's shared state
dbutils.jobs.taskValues.set(
    key="input_day",    # the name downstream tasks use to retrieve it
    value=input_day     # the actual value
)

print(f"Day set to: {input_day}")
```

---

## Getting a Value (in the DOWNSTREAM task)

```python
# Task: 03_else_condition
# This task runs when it's NOT Sunday

# Read the value published by task "01_set_day"
day = dbutils.jobs.taskValues.get(
    taskKey="01_set_day",    # which task published it
    key="input_day"          # which key within that task
)

print(f"Not processing today. Day is: {day}")
```

---

## taskValues vs dbutils.notebook.exit()

These solve related but different problems:

```
dbutils.notebook.exit(value)
    → Returns ONE value back to the PARENT notebook that called it
    → Works with dbutils.notebook.run() pattern
    → Single string return value only

dbutils.jobs.taskValues.set(key, value)
    → Publishes named key-value pairs to the JOB'S shared state
    → Available to ANY downstream task in the workflow
    → Multiple key-value pairs supported
    → Works within Databricks Workflows only
```

```
Rule of thumb:
    Using dbutils.notebook.run() pattern → use notebook.exit()
    Using Databricks Workflows → use jobs.taskValues
```

---

## The Full Date Extraction Example

```python
# Task: 01_set_day
# Full code breakdown

# 1. Accept input date as a widget parameter
dbutils.widgets.text("input_date", "", "Input Date")
input_date = dbutils.widgets.get("input_date")
# input_date format: "2024-10-27T13:00:00" (ISO timestamp)

# 2. Fix Spark SQL timestamp parsing for ISO format
spark.conf.set("spark.sql.legacy.timeParserPolicy", "LEGACY")

# 3. Extract day of week using Spark SQL
# "e" pattern in date_format returns day name (Sunday, Monday, etc.)
result = spark.sql(f"""
    SELECT date_format(
        to_timestamp('{input_date}', "yyyy-MM-dd'T'HH:mm:ss"),
        'EEEE'
    ) AS day_of_week
""")

input_day = result.collect()[0]["day_of_week"]
print(f"Day of week: {input_day}")

# 4. Publish to workflow state for downstream tasks
dbutils.jobs.taskValues.set(key="input_day", value=input_day)
```

**Why the `'T'` in the format string?**
```
ISO timestamp: "2024-10-27T13:00:00"
                         ↑ literal T character (not a format code)

Must escape it: "yyyy-MM-dd'T'HH:mm:ss"
                            ↑↑ single quotes tell Spark:
                               "this T is a literal character, not a pattern"
```

---

### 🧠 Quick Check #2

> **Q1:** Task A publishes `taskValues.set(key="record_count", value="500")`. Task C (which depends on Task B which depends on Task A) wants this value. Can it get it?
>
> *Yes. taskValues are stored at the job-run level, not task level. Any downstream task — regardless of how many hops away — can retrieve it using `taskValues.get(taskKey="TaskA", key="record_count")`.*

> **Q2:** What's wrong with this? `dbutils.jobs.taskValues.get(taskKey="01_set_day", key="input_dat")`
>
> *Typo in the key name — `"input_dat"` instead of `"input_day"`. The key must exactly match what was set with `.set(key="input_day", ...)`. This is exactly the error the video hit in production.*

---

# 🟠 PHASE 4 — Conditional Branching: If/Else Task

## What It Is

The If/Else task is a **special task type** — it doesn't run code. It evaluates a condition and routes execution to either a "true" branch or "false" branch.

```
          ┌─────────────┐
          │  01_set_day │
          └──────┬──────┘
                 │
          ┌──────▼──────┐
          │  check_day  │  ← IF/ELSE TASK
          │             │    "is input_day == 'Sunday'?"
          └──────┬──────┘
                 │
        ┌────────┴────────┐
        │                 │
     TRUE              FALSE
        │                 │
┌───────▼──────┐  ┌───────▼──────┐
│ 02_process   │  │ 03_else      │
│ (it's Sunday)│  │ (not Sunday) │
└──────────────┘  └──────────────┘
```

---

## Configuring the If/Else Task

```
Task Name: check_day
Task Type: If/Else Condition
Depends On: 01_set_day (must succeed first)

Condition expression:
    {{tasks.01_set_day.values.input_day}} == "Sunday"
    
    Syntax breakdown:
    {{tasks.<task_name>.values.<key>}}
    → reads the taskValue published by 01_set_day
    → compares it to "Sunday"
    
True branch  → 02_process_data runs
False branch → 03_else_condition runs
```

---

## Configuring Tasks That Depend on If/Else

```
Task: 02_process_data
    Depends on: check_day
    Run if: check_day is TRUE
    
Task: 03_else_condition
    Depends on: check_day
    Run if: check_day is FALSE
```

**The key insight:** Tasks downstream of If/Else declare which branch they belong to. Databricks routes execution accordingly. **Only one branch runs** — the other is skipped entirely.

---

## Why This Matters in Real Pipelines

```
Real use cases for If/Else branching:

1. Day/time-based processing
   "Run heavy aggregations only on weekends when traffic is low"

2. Data quality gates
   "If record count < 1000, skip processing and alert"
   "If source file exists, process it; else log and exit"

3. Environment routing
   "If env == prod, write to prod tables; else write to dev"

4. Incremental vs full load
   "If first run of month, do full reload; else do incremental"
```

---

# 🟠 PHASE 5 — For Each Loop Task

## The Problem It Solves

Before For Each, to process multiple departments you wrote a Python loop in the parent notebook:

```python
# Old way: Python loop in parent notebook
for dept in ["sales", "hr", "finance"]:
    dbutils.notebook.run("process_data", 600, {"department": dept})
```

Problems:
```
❌ Sequential — runs one department at a time
❌ Not visible in Workflows UI as separate task instances
❌ If "hr" fails, you can't repair-run just "hr"
❌ Not natively managed by the workflow engine
```

---

## For Each Task: How It Works

```
For Each Task configuration:
    Input list: ["sales", "office"]    ← the array to iterate over
    Nested task: process_data notebook ← what runs for each item
    
    Databricks then:
        Iteration 1: runs process_data with department="sales"
        Iteration 2: runs process_data with department="office"
        
        Each iteration appears as a separate task instance
        in the workflow run UI ✅
        
        Can run iterations in parallel (configurable) ✅
        
        Individual iteration failure visible + repairable ✅
```

---

## Configuring For Each in the UI

```
Task: for_each_departments
Type: For Each

Inputs:
    Loop variable name: "department"
    Input list:         ["sales", "office"]
    
    (Can also reference a taskValue from upstream task
     for dynamic lists!)

Nested task: process_data
    Parameter: department = {{input.department}}
    (Databricks replaces this with current loop item)
```

---

## Dynamic vs Static Lists in For Each

```
STATIC list (hardcoded):
    ["sales", "office", "hr", "finance"]
    → Good when departments don't change
    → Change list = edit the workflow config

DYNAMIC list (from taskValues):
    Task A queries database: "SELECT DISTINCT dept FROM config_table"
    Publishes list: taskValues.set("dept_list", ["sales", "office", "it"])
    
    For Each reads: {{tasks.TaskA.values.dept_list}}
    → Good for self-updating pipelines
    → New department in config table → automatically processed next run
```

---

### 🧠 Quick Check #3

> **Q1:** For Each with `["sales", "office", "hr"]` — the "office" iteration fails. What happens to "hr"?
>
> *Depends on configuration. By default other iterations continue. You can then use Repair Run to re-run only the "office" iteration without touching "sales" or "hr".*

> **Q2:** What's the advantage of For Each over a Python loop in a notebook?
>
> *For Each is workflow-managed: each iteration is visible as a separate task in the UI, individually retriable via Repair Run, can run in parallel, and is tracked in job run history. A Python loop is invisible to the workflow engine — it's a black box.*

---

# 🔴 PHASE 6 — Repair Run: Surgical Failure Recovery

## The Old Way (Without Repair Run)

```
Job has 5 tasks: A → B → C → D → E
Task D fails.

Old behavior (dbutils.notebook.run() world):
    Entire job fails
    You fix the bug
    Re-run from Task A
    Tasks A, B, C run again (wasted compute + time)
    D runs (fixed)
    E runs
    
    Cost: ran A, B, C unnecessarily
    Time: full pipeline runtime even though only D was broken
```

---

## Repair Run: Run Only What Failed

```
Job has 5 tasks: A → B → C → D → E
Task D fails.

With Repair Run:
    You fix the bug in Task D
    Click "Repair Run" in the Workflows UI
    Databricks:
        ✅ Keeps results of A, B, C (they succeeded)
        ↩️  Re-runs only Task D (and E which depends on D)
        
    Cost: only D and E recompute
    Time: fraction of full pipeline runtime
```

**Why this is important:**
```
In production, Task A might load 500GB of data (10 min, expensive).
Task D is a simple transformation that failed due to a typo.

Without Repair Run: reload 500GB every time you fix a typo ❌
With Repair Run:    fix typo, re-run only D + E ✅
```

---

## When Can You Repair Run?

```
✅ Task failed with an error (bug you can fix)
✅ Task timed out (you can increase timeout then repair)
✅ Cluster issue caused failure (cluster recovered, repair works)

❌ Job run was cancelled entirely
❌ Run is still in progress
❌ Retention period expired (runs have a history retention window)
```

---

## Repair Run in the UI

```
Workflows → Jobs → [Your Job] → Runs tab
    → Find the failed run
    → Click "Repair Run"
    → Choose: Re-run all failed tasks OR re-run specific tasks
    → Confirm
    
The repaired run creates a new sub-run linked to the original
Both are visible in run history for audit purposes
```

---

# 🟣 PHASE 7 — Full Workflow Design Principles

## The Complete Example — Assembled

```
JOB: daily_emp_processing
Schedule: Daily at 6:00 AM
Job Parameter: input_date = {{job.start_time.iso_datetime}}
               (Databricks auto-fills job start time as ISO timestamp)

TASK 1: 01_set_day
    Type: Notebook
    Notebook: get_day.py
    Receives: input_date (from job parameter)
    Publishes: input_day (taskValue)
    Depends on: nothing (first task)

TASK 2: check_day (IF/ELSE)
    Type: If/Else
    Condition: input_day == "Sunday"
    Depends on: 01_set_day

TASK 3: 02_process_data (FOR EACH)
    Type: For Each → nested Notebook
    Runs if: check_day is TRUE
    Loop over: ["sales", "office"]
    Each iteration: runs process_emp_data notebook
                    with department = current item
    Depends on: check_day (true branch)

TASK 4: 03_else_condition
    Type: Notebook
    Notebook: else_condition.py
    Reads: taskValues.get("01_set_day", "input_day")
    Runs if: check_day is FALSE
    Depends on: check_day (false branch)
```

---

## The Design Principles You're Applying

```
1. SEPARATION OF CONCERNS
   Each task does one thing:
   01_set_day:         compute the day
   check_day:          make the decision
   02_process_data:    do the work
   03_else:            handle the skip case

2. DYNAMIC PARAMETERS
   input_date comes from job start time automatically
   No hardcoding of dates anywhere

3. EXPLICIT DEPENDENCIES
   Tasks declare what they need before they can run
   Workflow engine enforces order + handles failures

4. OBSERVABILITY
   Every task has its own status, logs, duration
   Run history with full DAG view
   Per-task notifications possible

5. RECOVERABILITY
   Repair Run means failures are cheap to fix
   No need to rerun the full pipeline for one task's bug
```

---

## Workflows vs dbutils.notebook.run() — Final Comparison

| Capability | dbutils.notebook.run() | Databricks Workflows |
|---|---|---|
| **Task types** | Notebooks only | Notebooks, SQL, Python, dbt, Spark, If/Else, For Each |
| **Execution** | Sequential | Sequential + parallel |
| **Conditional logic** | Python if/else in code | Native If/Else task |
| **Iteration** | Python for loop | Native For Each task |
| **Inter-task values** | notebook.exit() (limited) | taskValues (flexible) |
| **Monitoring** | Print statements | Full UI: DAG, per-task logs, timeline |
| **Failure recovery** | Re-run entire parent | Repair Run (only failed tasks) |
| **Run history** | None | Full history with audit trail |
| **Scheduling** | dbutils + external trigger | Built-in scheduler + cron |
| **Use in production** | ⚠️ Limited, simple cases | ✅ Recommended |

---

## 🗺️ Concept Connection Map

```
Databricks Workflows
    ├── replaces → dbutils.notebook.run() for production orchestration
    ├── consists of → Jobs (scheduled) containing Tasks (execution units)
    ├── inter-task comms → dbutils.jobs.taskValues (set/get)
    ├── conditional flow → If/Else task (routes to true/false branch)
    ├── iteration → For Each task (runs nested task per list item)
    ├── failure recovery → Repair Run (re-run only failed tasks)
    └── connects to → Cluster Policies + Pools (job clusters can use pools)

dbutils.jobs.taskValues
    ├── set() → upstream task publishes a value
    ├── get() → downstream task reads that value
    └── contrasts with → dbutils.notebook.exit() (parent-child pattern only)

For Each Task
    ├── input → static list or dynamic taskValue list
    ├── each iteration → runs nested task with current item
    └── advantage over Python loop → visible in UI, individually repairable
```

---

## 📝 Active Recall Prompts

**Day 1:**
> *"What is the difference between `dbutils.jobs.taskValues.set()` and `dbutils.notebook.exit()`? When do you use each?"*
>
> *"A job with 6 tasks — task 4 fails. You fix the bug. What do you do next, and what tasks rerun?"*

**Day 3:**
> *"Draw the DAG for the video's example workflow from memory. Label each task type, dependency, and which branch runs under which condition."*
>
> *"What problem does For Each solve that a Python loop in a notebook can't?"*

**Day 7:**
> *"Design a workflow that: checks if today is month-end, if yes → runs full reload for 5 tables using For Each, if no → runs incremental load for the same 5 tables. Draw the DAG, name the tasks, identify what taskValues you'd set and get."*

---
