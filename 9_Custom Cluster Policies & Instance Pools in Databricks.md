# 📘 Custom Cluster Policies & Instance Pools in Databricks

## 🗺️ Roadmap for This Session

```
PHASE 1 — Why Policies and Pools exist (the problem)
PHASE 2 — Custom Cluster Policies (deep dive)
PHASE 3 — Policy JSON: how it actually works
PHASE 4 — Enforcing Policies on Existing Clusters
PHASE 5 — Instance Pools (the cold-start problem)
PHASE 6 — Warm vs Cold Pools
PHASE 7 — Combining Policies + Pools (enterprise pattern)
```

---

# 🟢 PHASE 1 — Why Policies and Pools Exist

## Two Separate Problems Being Solved

These are **two completely independent features**. Don't conflate them.

```
POLICIES → solve a GOVERNANCE problem
    "Engineers are creating clusters that are too expensive,
     use wrong runtime versions, or never auto-terminate"

POOLS → solve a PERFORMANCE problem
    "Job clusters take 3-5 minutes to start because Azure
     needs time to provision fresh VMs every time"
```

They solve different problems but are often **used together** in enterprise environments.

---

## The Policy Problem: Real Scenario

```
You have 30 data engineers. No policies.

Engineer A: creates 50-worker GPU cluster, forgets about it
            → runs idle for 3 days = $4,000 wasted

Engineer B: uses DBR 12.0 (old, deprecated)
            → incompatible with UC features, breaks pipelines

Engineer C: disables auto-termination
            → cluster runs over the weekend = $800 wasted

Engineer D: uses wrong VM type for the workload
            → job takes 4 hours instead of 40 minutes

Total monthly waste: tens of thousands of dollars
Plus: inconsistent environments = "works on my cluster" bugs
```

**Policies are the admin's way of saying: "here are the rules, you cannot break them."**

---

## The Pool Problem: Real Scenario

```
Scheduled job triggers at 6:00 AM:
    6:00:00 → Databricks starts creating job cluster
    6:00:00 → Azure begins VM provisioning request
    6:02:30 → VMs ready
    6:03:00 → DBR installed and initialized
    6:03:30 → Spark context started
    6:03:30 → Job ACTUALLY starts running
    
    Cold start penalty: ~3.5 minutes
    
For a job that runs 4 minutes of actual work:
    Total wall-clock time: 7.5 minutes
    Useful work: 4 minutes
    Overhead: 3.5 minutes (47% of total time!)
    
For SLA-critical jobs ("results must be ready by 6:05 AM"):
    ❌ Job isn't even started by 6:05 AM
```

**Pools pre-provision VMs so they're ready before the job asks for them.**

---

# 🟡 PHASE 2 — Custom Cluster Policies

## What a Policy Actually Is

A policy is a **JSON document** that defines rules for cluster configuration. Each rule can be one of three types:

```
FIXED   → "this setting MUST be this value, user cannot change it"
FORBIDDEN → "this setting cannot be used at all"
ALLOWED (enum) → "user can pick from only these specific options"
DEFAULT → "pre-fill this value but user can change it"
```

When a user creates a cluster with a policy applied:
- Fixed fields → greyed out in UI, cannot be changed
- Forbidden fields → hidden entirely from UI
- Enum fields → shown as dropdown with only allowed options
- Default fields → pre-filled but editable

---

## How to Create a Custom Policy

```
In Databricks UI:
    Admin Console → Cluster Policies → Create Policy
    
    Best practice: don't start from scratch.
    Clone an existing policy (e.g., "Shared Compute")
    then modify its JSON.
    
    Why clone? Existing policies have correct JSON structure.
    Starting from scratch risks syntax errors.
```

---

# 🟡 PHASE 3 — Policy JSON: How It Actually Works

## Full Annotated Example

```json
{
  "autotermination_minutes": {
    "type": "fixed",
    "value": 10
  },
  "num_workers": {
    "type": "fixed",
    "value": 1
  },
  "autoscale.min_workers": {
    "type": "forbidden"
  },
  "autoscale.max_workers": {
    "type": "forbidden"
  },
  "spark_version": {
    "type": "fixed",
    "value": "15.4.x-scala2.12"
  },
  "node_type_id": {
    "type": "enum",
    "values": ["Standard_DS3_v2", "Standard_DS4_v2"],
    "defaultValue": "Standard_DS4_v2"
  }
}
```

Let's read each rule:

```
"autotermination_minutes": fixed → 10
    Every cluster using this policy ALWAYS auto-terminates at 10 min idle
    User cannot change this
    → Solves "forgot to terminate" problem ✅

"num_workers": fixed → 1
    Exactly 1 worker, always
    → Controls cost for dev clusters ✅

"autoscale.min_workers": forbidden
"autoscale.max_workers": forbidden
    Autoscaling is disabled — the autoscale fields won't even appear
    → Consistent, predictable cluster size ✅

"spark_version": fixed → "15.4.x-scala2.12"
    All clusters must use DBR 15.4 LTS
    User cannot pick a different runtime
    → Standardized environment across all engineers ✅

"node_type_id": enum → ["DS3_v2", "DS4_v2"], default: DS4_v2
    User can CHOOSE between DS3 or DS4
    But cannot pick anything else (no GPU, no high-memory)
    → Controlled cost, user still has some flexibility ✅
```

---

## What the User Sees vs What Admin Sees

```
Admin (creating policy):
    Full JSON editor, all fields available
    Defines rules once, applies to all users

User (creating cluster with this policy):
    Policy dropdown → selects "Engineering Dev Policy"
    
    UI immediately changes:
        Runtime: [15.4 LTS] ← greyed out, cannot change
        Workers: [1] ← greyed out
        Auto-terminate: [10 min] ← greyed out
        Node type: [DS3_v2 ▼ DS4_v2] ← only these two in dropdown
        Autoscale: [hidden entirely]
        
    User can still name the cluster, pick tags, etc.
    The governance rules are silently enforced ✅
```

---

### 🧠 Quick Check #1

> **Q1:** What's the difference between `"type": "fixed"` and `"type": "forbidden"` in policy JSON?
>
> *`fixed` means the setting exists but is locked to a specific value — the user sees it but can't change it. `forbidden` means the setting doesn't appear in the UI at all — it's completely hidden and unavailable.*

> **Q2:** An engineer tries to create a cluster with 10 workers under a policy that has `"num_workers": {"type": "fixed", "value": 1}`. What happens?
>
> *The UI won't allow it. The worker count field is greyed out at 1. The engineer simply cannot create a 10-worker cluster under this policy.*

---

# 🟠 PHASE 4 — Enforcing Policies on EXISTING Clusters

## The Compliance Problem

Policies are great for new clusters. But what about clusters that were created before the policy existed, or clusters where the policy has been updated?

```
Scenario:
    Policy was: spark_version fixed to "14.3"
    You update policy: spark_version fixed to "15.4"
    
    Old clusters still running on 14.3:
        → They are now "Non-compliant" with the current policy
        → Databricks flags them in the UI
```

---

## The "Fix All" Feature

```
In Cluster Policies UI:
    Non-compliant clusters appear with a warning indicator
    Admin clicks "Fix All" (or "Fix" per cluster)
    
    Databricks:
        1. Reads current policy definition
        2. Identifies what needs to change on each cluster
        3. Updates cluster configurations to match
        4. Clusters are now compliant ✅

Result: org-wide enforcement in one click
        No need to hunt down each engineer's cluster manually
```

**This is critical for:**
- Security patches (force-update to a runtime with a fixed CVE)
- Feature rollouts (all clusters must use new DBR for new feature)
- Cost governance (add auto-termination to all existing clusters)

---

# 🔴 PHASE 5 — Instance Pools: Solving Cold Start

## The VM Provisioning Problem (Deep Dive)

When Databricks creates a job cluster without a pool:

```
Step 1: Request sent to Azure: "give me 4 DS4_v2 VMs"
Step 2: Azure allocates VMs from its capacity pool
        (this takes 1-3 minutes — Azure is provisioning hardware)
Step 3: VMs boot up (OS starts, networking configured)
Step 4: Databricks agent installs on each VM
Step 5: Databricks Runtime (DBR) loads
Step 6: Spark context initializes
Step 7: Job can finally start

Total: 3-5 minutes of overhead before a single line of code runs
```

## What a Pool Does

```
WITHOUT POOL:
    Job triggers → request VMs from Azure → wait 3-5 min → job starts

WITH POOL:
    Admin pre-creates pool: "keep 2 DS4_v2 VMs ready at all times"
    
    Azure provisions 2 VMs NOW (not when job needs them)
    These VMs sit idle, already booted, DBR already loaded
    
    Job triggers → borrow VMs from pool → job starts in seconds ✅
    
    After job finishes:
        VMs returned to pool
        Pool "refills" back to minimum idle count
        Ready for the next job
```

---

## Pool Configuration Parameters

```
MIN IDLE INSTANCES
    VMs that are ALWAYS running, even when no job is using them
    These are your "warm" VMs
    Example: 2 → 2 VMs always provisioned and waiting
    Cost: you pay for these even when idle

MAX CAPACITY
    Maximum total VMs the pool can ever have
    (idle + in-use combined)
    Example: 10 → pool can handle up to 10 simultaneous VMs
    If all 10 are in use and another job needs one → it waits

IDLE AUTO-TERMINATION
    How long an idle VM waits before being terminated
    (applies to VMs above the minimum idle count)
    Example: 10 min → if a job finishes and returns a VM to pool,
    that VM waits 10 min for another job before being shut down
    Smart: reuse VMs if another job comes quickly

NODE TYPE
    Which Azure VM family (DS3_v2, DS4_v2, etc.)
    All VMs in a pool must be the same type

DATABRICKS RUNTIME
    Pre-load a specific DBR on pool VMs
    → Even faster startup (DBR already installed)
```

---

### Example Pool Configuration

```
Name:                    engineering-job-pool
Min Idle Instances:      2          ← always 2 warm VMs ready
Max Capacity:            10         ← can scale up to 10 if needed
Idle Auto-Termination:   10 min     ← extra VMs wait 10 min before shutdown
Node Type:               Standard_DS4_v2
Runtime:                 15.4 LTS   ← pre-loaded, even faster start
```

```
Timeline with this pool:
    8:00 AM → Pool has 2 idle DS4_v2 VMs sitting ready
    
    8:01 AM → Job A triggers, needs 2 workers
               → Borrows both idle VMs instantly ✅ (sub-second)
               → Pool: 0 idle, 2 in-use
               → Azure starts provisioning 2 more to refill to min=2
    
    8:01:30 → Job B triggers, needs 1 worker
               → Pool still refilling, borrows 1 from the new ones
               → Pool: 0 idle, 3 in-use (2 from A + 1 from B)
    
    8:15 AM → Job A finishes, returns 2 VMs to pool
               → Pool: 2 idle (waiting 10 min before shutdown)
    
    8:16 AM → Job C triggers → instantly borrows from the waiting VMs ✅
```

---

# 🟢 PHASE 6 — Warm vs Cold Pools

## The Spectrum

```
FULLY WARM POOL (Min Idle > 0)
────────────────────────────────
Min Idle: 2 (or more)
VMs always running: YES
Job startup time: near-instant (seconds)
Cost: pay for idle VMs 24/7
Best for: SLA-critical jobs, real-time pipelines, dashboards

COLD POOL (Min Idle = 0)
─────────────────────────
Min Idle: 0
VMs always running: NO
Job startup time: still faster than no pool (VMs from pool are
                  pre-configured, Azure provisions faster for
                  pool-registered VM types)
Cost: only pay when VMs are actually in use
Best for: batch jobs with flexible SLAs

NO POOL AT ALL
───────────────
Full cold start every time
Slowest startup (3-5 min)
No idle cost
Best for: infrequent jobs, dev clusters, cost-only optimization
```

---

## Decision Guide

```
Is your job SLA-critical? (must start within seconds)
    YES → Warm Pool (Min Idle ≥ 1)
    
Is your job scheduled batch with flexible SLA? (10-15 min window ok)
    YES → Cold Pool or No Pool (save idle VM cost)

Do you run many short jobs in rapid succession?
    YES → Warm Pool + high Idle Auto-Termination
          (VMs returned from one job quickly reused by next)

Is this a one-off or infrequent job?
    YES → No Pool (overhead of maintaining pool isn't worth it)
```

---

### 🧠 Quick Check #2

> **Q1:** Your pool has Min Idle = 2, Max Capacity = 10, Idle Auto-Termination = 10 min. 5 jobs start simultaneously, each needing 2 VMs. What happens?
>
> *2 jobs get instant VMs from the 2 idle slots. The pool requests 8 more from Azure (to serve remaining 3 jobs = 6 VMs needed, plus refill min idle = 2). Total in-use would be 10 — hitting max capacity. Any additional job requests would queue.*

> **Q2:** What's the cost trade-off of Min Idle = 5 vs Min Idle = 0?
>
> *Min Idle = 5: 5 VMs running 24/7 even if no jobs run — instant startup but continuous idle cost. Min Idle = 0: no idle cost but no warm VMs — jobs take longer to start.*

---

# 🟣 PHASE 7 — Combining Policies + Pools (Enterprise Pattern)

## The Power Combo

Policies and Pools are **complementary**:

```
Policy says: "all job clusters must use DS4_v2, DBR 15.4"
Pool provides: pre-warmed DS4_v2 VMs with DBR 15.4 pre-loaded

Result:
    ✅ Governance (policy enforces config standards)
    ✅ Performance (pool eliminates cold start)
    ✅ Cost control (policy enforces auto-termination)
```

You can even **reference a pool inside a policy**:

```json
{
  "instance_pool_id": {
    "type": "fixed",
    "value": "your-pool-id-here"
  },
  "spark_version": {
    "type": "fixed",
    "value": "15.4.x-scala2.12"
  },
  "autotermination_minutes": {
    "type": "fixed",
    "value": 30
  }
}
```

This means: **every cluster created with this policy automatically uses the pool**. Engineers don't even need to know the pool exists — governance and performance handled in one step.

---

## Full Enterprise Cluster Architecture

```
ADMIN SETS UP:
    ├── Pool: "prod-job-pool"
    │     Min Idle: 3, Max: 20, DS4_v2, DBR 15.4 LTS
    │
    └── Policy: "prod-job-policy"
          ├── pool: fixed → prod-job-pool
          ├── runtime: fixed → 15.4 LTS
          ├── auto-terminate: fixed → 10 min
          └── node type: forbidden (pool handles this)

ENGINEER CREATES JOB:
    Selects policy: "prod-job-policy"
    All config is pre-determined ✅
    Cluster borrows from warm pool ✅
    Job runs fast, terminates clean ✅
    Cost controlled, compliant ✅
```

---

## Policy vs Pool — The Key Distinction

| | Cluster Policy | Instance Pool |
|---|---|---|
| **Solves** | Governance + cost control | Startup latency |
| **What it controls** | Configuration rules (runtime, size, termination) | VM availability |
| **Enforced by** | Admins | Admins |
| **User impact** | Restricted UI options | Faster job start |
| **Cost impact** | Prevents misuse (saves money) | Idle VMs cost money |
| **Tool type** | Compliance tool | Performance tool |

---

## 🗺️ Concept Connection Map

```
Custom Cluster Policy
    ├── defined as → JSON with fixed/forbidden/enum rules
    ├── applied to → new cluster creation (restricts UI)
    ├── enforced on → existing clusters via "Fix All" (compliance)
    ├── can reference → Instance Pool (lock cluster to pool)
    └── connects to → previous session's predefined policies

Instance Pool
    ├── solves → cold start latency (3-5 min VM provisioning)
    ├── warm pool → Min Idle > 0 (VMs always ready, higher cost)
    ├── cold pool → Min Idle = 0 (no idle cost, slower than warm)
    ├── used by → job compute clusters (draw workers from pool)
    └── combined with → policies for governed + fast clusters

Policy + Pool together
    └── enterprise pattern → governance + performance in one setup
```

---

## 📝 Active Recall Prompts

**Day 1:**
> *"What are the 3 rule types in a policy JSON (`fixed`, `forbidden`, `enum`)? Give a real example of when you'd use each one."*
>
> *"Explain the cold-start problem in Databricks. How does a warm pool solve it?"*

**Day 3:**
> *"Your company updated the DBR version in the policy from 14.3 to 15.4. 12 existing clusters are now non-compliant. What do you do and what happens?"*
>
> *"Min Idle = 0 vs Min Idle = 3 on a pool — walk through the cost and startup time trade-off for each."*

**Day 7:**
> *"Design an enterprise cluster setup for: 20 engineers doing daily dev work + 5 production pipelines running every hour with 2-minute SLA. What policy and pool config for each use case? Write the JSON skeleton for the production policy."*

---
