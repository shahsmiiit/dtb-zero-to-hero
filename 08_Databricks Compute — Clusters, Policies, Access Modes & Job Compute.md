# 📘 Databricks Compute — Clusters, Policies, Access Modes & Job Compute

## 🗺️ Roadmap for This Session

```
PHASE 1 — What is Compute? (First Principles)
PHASE 2 — Anatomy of a Cluster (Driver + Workers)
PHASE 3 — Cluster Configuration (every setting explained)
PHASE 4 — Access Modes & Unity Catalog Integration
PHASE 5 — All-Purpose vs Job Compute
PHASE 6 — Cluster Policies & Permissions
PHASE 7 — Cost Optimization Principles
```

---

# 🟢 PHASE 1 — What is Compute? (First Principles)

## The Fundamental Question

You've been writing SQL and Python in notebooks this whole time. But **what is actually running that code?**

```
Your laptop runs your local Python scripts.
Your phone's CPU runs your apps.

In Databricks:
    Your notebooks run on COMPUTE — a set of machines 
    (physical or virtual) that execute your Spark jobs.
```

Without compute, your notebook is just a text file. Compute is the engine.

---

## Why Cloud Compute (Not Your Laptop)?

```
Your laptop:
    4-8 CPU cores
    16-32 GB RAM
    Can process maybe 1-2 GB of data reasonably
    ❌ Cannot process 10TB of sales data

Cloud compute cluster:
    Hundreds of CPU cores (combined across machines)
    Terabytes of RAM (combined)
    Can process 10TB in minutes
    ✅ Scales to any data size
    ✅ Pay only when you use it
```

**This is the fundamental value proposition of cloud data engineering** — compute on demand, at any scale, pay-per-use.

---

# 🟢 PHASE 2 — Anatomy of a Cluster

## Driver + Workers: The Spark Architecture

Every Databricks cluster running Spark has this structure:
<img width="1024" height="546" alt="image" src="https://github.com/user-attachments/assets/fce112fd-86e9-406e-9e28-cc9677cc71cf" />


```
                    ┌─────────────────┐
                    │   DRIVER NODE   │
                    │                 │
                    │ • Coordinates   │
                    │ • Splits work   │
                    │ • Collects results│
                    │ • Runs your     │
                    │   notebook code │
                    └────────┬────────┘
                             │ distributes tasks
              ┌──────────────┼──────────────┐
              ▼              ▼              ▼
     ┌────────────┐ ┌────────────┐ ┌────────────┐
     │  WORKER 1  │ │  WORKER 2  │ │  WORKER 3  │
     │            │ │            │ │            │
     │ Executes   │ │ Executes   │ │ Executes   │
     │ its chunk  │ │ its chunk  │ │ its chunk  │
     │ of data    │ │ of data    │ │ of data    │
     └────────────┘ └────────────┘ └────────────┘
```

---

## Driver Node — What It Does

```
When you run: df.filter(...).groupBy(...).count()

Driver:
    1. Receives your code
    2. Creates an execution plan ("how to split this work")
    3. Sends task chunks to each worker
    4. Collects results from all workers
    5. Returns the final answer to your notebook

The driver is the "project manager" — it plans, delegates, consolidates.
```

**Important:** The driver runs your actual notebook Python/SQL code. Workers only execute the distributed Spark tasks the driver sends them.

---

## Worker Nodes — What They Do

```
Worker receives a task: "filter rows 1M-2M of this dataset"
Worker:
    1. Reads its chunk of data from ADLS
    2. Applies the filter
    3. Returns filtered rows to driver

Workers are "factory workers" — they execute, they don't think.
More workers = more parallelism = faster on large data.
```

---

## Single-Node Cluster

```
Single-node = Driver only, no workers

The driver both coordinates AND executes.
Like a manager doing all the work themselves.

When to use:
    ✅ Learning / development / small datasets
    ✅ Running lightweight notebooks
    ✅ Cost-sensitive exploratory work
    ❌ Not for large-scale production workloads
```

---

### 🧠 Quick Check #1
> **Q1:** You run a query that processes 500GB of data. Your cluster has 1 driver + 10 workers. Which nodes are actually crunching through the 500GB?
>
> *The worker nodes. The driver plans the work and splits the 500GB into 10 chunks, sends one to each worker. Workers do the actual processing and return results to the driver.*

> **Q2:** What's the downside of a single-node cluster for large workloads?
>
> *No parallelism — one machine does everything. 500GB processed sequentially instead of distributed across many machines. Much slower, may run out of memory.*

---

# 🟡 PHASE 3 — Cluster Configuration: Every Setting Explained

## Databricks Runtime (DBR)

```
DBR = a prepackaged software bundle that includes:
    ├── Apache Spark (specific version)
    ├── Python (specific version)
    ├── Scala
    ├── Delta Lake libraries
    ├── Bug fixes and Databricks-specific optimizations
    └── Optional: ML libraries (for ML runtimes)
```

Think of DBR like an **operating system image** for your cluster. When you spin up a cluster, it boots with this entire stack pre-installed.

```
DBR choices:
    Standard  → general data engineering workloads
    ML        → includes TensorFlow, PyTorch, scikit-learn etc.

Version types:
    Latest    → newest features, less battle-tested
    LTS       → Long-Term Support, stable, bug-patched for longer

✅ Rule: Always use latest LTS for production
   Example: "15.4 LTS (Spark 3.5.0, Scala 2.12)"
```

---

## Photon Acceleration

```
Standard Spark runtime:
    Written in Scala/JVM
    Mature, well-supported
    Baseline performance

Photon runtime:
    Written in C++ by Databricks
    Vectorized execution engine
    10-100x faster for certain operations (SQL queries, scans, aggregations)
    
Cost trade-off:
    Standard: ~6 DBUs/hour
    Photon:   ~8 DBUs/hour  (more expensive)

DBU = Databricks Unit (how Databricks measures and charges compute usage)
```

**When Photon is worth it:**
```
✅ Heavy SQL analytics workloads
✅ Large aggregations and joins
✅ Data ingestion at scale
✅ Interactive queries where speed matters

❌ Not worth it for:
    Small datasets (overhead isn't justified)
    Pure ML workloads (Photon doesn't accelerate ML training)
```

---

## VM Types (Azure Virtual Machines)

Each node in your cluster is an Azure VM. You choose the VM type:

```
General Purpose (e.g., DS4_v2):
    8 cores, 28GB RAM
    Balanced CPU + memory
    ✅ Good default for most workloads

Memory Optimized:
    More RAM relative to CPU
    ✅ For workloads that cache large datasets
    ✅ For heavy joins, aggregations that need RAM

Compute Optimized:
    More CPU relative to RAM
    ✅ For CPU-heavy transformations

Delta Cache Accelerated:
    SSDs on the node for caching Delta data
    ✅ Repeated reads of same data go to local SSD, not ADLS
    ✅ Significantly faster for iterative queries on same tables
```

---

## Autoscaling

```
WITHOUT autoscaling:
    Fixed worker count = 4
    Light job (10GB data) → 4 workers idle most of the time → 💸 wasted
    Heavy job (10TB data) → 4 workers overwhelmed → ⏳ slow

WITH autoscaling:
    Min workers: 2   Max workers: 10
    
    Light job:  cluster runs with 2 workers ✅ (saves cost)
    Heavy job:  cluster scales up to 10 workers ✅ (handles load)
    Job done:   cluster scales back down to 2 ✅ (saves cost)
```

```
How Databricks autoscales:
    Detects task queue is growing → adds workers
    Detects workers are idle → removes workers
    Always stays between min and max bounds
    
You set the bounds, Databricks manages within them.
```

---

## Terminate After Idle Time

```
Scenario without this setting:
    9 AM  → You start cluster for a quick notebook run
    9:15  → You finish and forget to terminate
    5 PM  → Cluster has been running 8 hours, you've been in meetings
    Cost  → 8 hours × cluster hourly rate = 💸💸💸

With terminate after idle = 30 minutes:
    9:15  → You finish
    9:45  → No activity detected for 30 min → cluster auto-terminates
    Cost  → 45 min instead of 8 hours ✅
```

**Set this on every all-purpose cluster. Always.**

---

### 🧠 Quick Check #2

> **Q1:** Your team runs nightly batch jobs processing 5TB. Should you enable Photon? What else matters?
>
> *Likely yes — 5TB SQL processing is exactly where Photon wins. Also consider memory-optimized VMs if doing heavy joins, autoscaling to handle variable data volumes, and job compute (not all-purpose) since it's automated.*

> **Q2:** Autoscaling min=2, max=8. Your job submits 50 parallel tasks. What happens?
>
> *Databricks detects the task queue and scales workers up toward 8 (the max). It can't go beyond 8. Some tasks will queue behind others if 8 workers aren't enough.*

---

# 🟠 PHASE 4 — Access Modes & Unity Catalog

## What Access Mode Controls

Access mode defines **who can use the cluster** and **what security model applies**.

```
Three modes:

1. SINGLE USER
   ─────────────
   Only one specific person can attach to this cluster
   Full Unity Catalog support ✅
   Best isolation ✅
   Use: dedicated cluster for one engineer or job

2. SHARED
   ───────
   Multiple users can attach simultaneously
   Full Unity Catalog support ✅
   Users are isolated from each other (can't see each other's data/vars)
   Use: team cluster for interactive work, cost sharing

3. NO ISOLATION (Legacy)
   ──────────────────────
   Multiple users, NO isolation between them
   NO Unity Catalog support ❌
   Users share the same Spark context — one user can see another's data
   Use: only for legacy Hive Metastore workloads
   Migration path: move to Single User or Shared + UC
```

---

## The Unity Catalog Connection

```
Single User + Shared  →  UC enforces permissions at the cluster level
                          Your Azure AD identity is used
                          Row-level security, column masking all work ✅

No Isolation           →  UC cannot enforce security here
                          Anyone on the cluster can query anything
                          ❌ Not safe for multi-user environments
```

**In modern Databricks (UC era): always use Single User or Shared. Never No Isolation for new work.**

---

# 🟠 PHASE 5 — All-Purpose vs Job Compute

This is the most practically important distinction for your daily work.

## All-Purpose Compute

```
Created: manually by you via UI or API
Lifecycle: persists until YOU terminate it
Used for: interactive notebooks, ad-hoc exploration, development

Timeline:
    You create it → Running ✅
    You run notebooks against it
    You forget to terminate → still running 💸
    You manually stop it → terminated

Cost model: pay for every minute it runs, whether you're using it or not
```

---

## Job Compute

```
Created: automatically by Databricks when a job starts
Lifecycle: created → job runs → job ends → automatically destroyed
Used for: scheduled pipelines, automated workflows

Timeline:
    Schedule triggers at 6 AM
    Databricks spins up a fresh cluster (2-3 min startup)
    Job runs
    Job completes → cluster destroyed immediately
    
Cost model: pay only for the actual job run time ✅
```

```
Key differences:
    All-Purpose: you manage lifecycle, higher risk of idle waste
    Job Compute: Databricks manages lifecycle, cost-optimal

You CANNOT manually create a job compute cluster from the UI.
It only exists when a workflow creates it automatically.
```

---

## Which to Use When

```
Use ALL-PURPOSE when:
    ✅ Writing and testing code interactively
    ✅ Exploring data in notebooks
    ✅ Ad-hoc analysis
    ✅ Development and debugging
    ⚠️ Always set terminate-after-idle

Use JOB COMPUTE when:
    ✅ Scheduled pipelines (daily/hourly ETL)
    ✅ Automated workflows
    ✅ Production jobs that run unattended
    ✅ Any job where you want cost optimization
```

---

## Serverless Compute (Preview)

```
Problem with both above: you still configure VM types, worker counts, etc.
    What if you don't want to think about infrastructure at all?

Serverless:
    You write code → click run
    Databricks provisions compute automatically in the background
    You never see "create cluster", "choose VM type", "set worker count"
    Auto-scales transparently
    You pay only for compute actually used (per-second billing)

Status: Available now for SQL warehouses, expanding to notebooks/jobs
```

---

# 🔴 PHASE 6 — Cluster Policies & Permissions

## What are Policies?

In a large organization, you don't want every engineer creating maximum-spec clusters that cost thousands per hour. **Policies are guardrails.**

```
Without policies:
    Engineer creates: 50 workers × GPU-enabled × no auto-terminate
    Cost: $500/hour, runs all weekend
    You find out Monday morning 💸💸💸

With policies:
    Admin defines: max 8 workers, must auto-terminate after 60 min, no GPU
    Engineers can only create clusters within these bounds
    Cost controlled ✅
```

---

## Predefined Policies

```
PERSONAL COMPUTE
    Single-node, single-user
    Good for: individual development, learning
    Not for: large data processing

SHARED COMPUTE
    Multi-node, shared access, autoscaling
    Good for: team clusters, cost sharing
    UC supported ✅

POWER USER COMPUTE
    Multi-node, autoscaling, flexible access modes
    Good for: senior engineers needing more control

LEGACY SHARED
    Multi-node, no isolation, no UC
    Only for: teams still on Hive Metastore
    Migration target: move off this ASAP
```

---

## Cluster Permissions

Three permission levels, applied to users/groups/service principals:

```
CAN MANAGE
    ✅ Edit cluster config
    ✅ Start / stop
    ✅ Delete cluster
    ✅ Grant permissions to others
    → Give to: cluster owners, admins

CAN RESTART
    ✅ Start / stop cluster
    ❌ Cannot edit configuration
    ❌ Cannot delete
    → Give to: engineers who need to use the cluster
               but shouldn't change its config

CAN ATTACH TO
    ✅ Attach a notebook to the cluster and run it
    ❌ Cannot start/stop
    ❌ Cannot edit
    → Give to: data analysts who just need to run queries
               service accounts running automated jobs
```

---

## Cluster Management Tabs (What They're For)

```
LIBRARIES
    Install Python packages, JARs, wheels on cluster startup
    Example: install a custom library your team built
    Installs automatically whenever cluster starts

EVENT LOG
    History of: cluster started, worker added, worker removed
    Useful for: understanding autoscaling behavior

SPARK UI
    Detailed view of every Spark job that ran
    Shows: DAG visualization, stage timing, task distribution
    Use for: performance debugging ("why is this query slow?")

DRIVER LOGS
    stdout/stderr from your notebook code
    Use for: debugging print statements, error traces

METRICS
    CPU%, memory usage, disk I/O, network
    Use for: understanding if cluster is undersized/oversized
```

---

## Full Cluster Decision Framework

```
QUESTION 1: Interactive or automated?
    Interactive → All-Purpose
    Automated   → Job Compute

QUESTION 2: Single user or team?
    Single user → Single-user access mode
    Team        → Shared access mode

QUESTION 3: Data size?
    Small (<10GB)   → Single-node
    Medium          → Multi-node, 2-4 workers
    Large (>1TB)    → Multi-node, autoscaling, memory-optimized VMs

QUESTION 4: Query-heavy or ML?
    SQL/analytics   → Consider Photon
    ML training     → ML runtime, GPU VMs

QUESTION 5: Cost sensitivity?
    Always:
        ✅ Set terminate-after-idle (all-purpose)
        ✅ Use job compute for production (auto-terminates)
        ✅ Enable autoscaling
        ✅ Tag clusters with owner/project for cost tracking
```

---

## 🗺️ Concept Connection Map

```
Cluster
    ├── consists of → Driver node + Worker nodes
    ├── runs → Databricks Runtime (DBR version)
    ├── optional → Photon acceleration (faster SQL, higher cost)
    ├── sized by → VM type + worker count/autoscaling
    └── governed by → Access Mode + Policies + Permissions

All-Purpose Compute
    ├── for → interactive notebook development
    ├── risk → idle cost if not terminated
    └── mitigated by → terminate-after-idle setting

Job Compute
    ├── for → automated scheduled pipelines
    ├── lifecycle → created + destroyed per job run automatically
    └── connects to → Databricks Workflows (next topics)

Access Modes
    ├── Single User → UC supported, dedicated
    ├── Shared → UC supported, multi-user isolated
    └── No Isolation → legacy only, no UC, avoid for new work

Policies
    ├── enforced by → admins
    ├── protect against → runaway cost, misconfiguration
    └── types → Personal, Shared, Power User, Legacy, Custom
```

---

## 📝 Active Recall Prompts

**Day 1:**
> *"What is the difference between a driver node and a worker node? What does each one do when you run a query?"*
>
> *"All-Purpose vs Job Compute — when do you use each, and what's the key lifecycle difference?"*

**Day 3:**
> *"Your company has 20 data engineers sharing clusters. What access mode do you choose and why? What policy would you apply to control costs?"*
>
> *"What does Photon do? When is it worth the extra cost and when isn't it?"*

**Day 7:**
> *"Design the cluster strategy for this scenario: 5 data engineers doing daily development + a nightly 2TB ETL job + an ML team training models weekly. What cluster type, access mode, VM type, and settings for each use case?"*

---
