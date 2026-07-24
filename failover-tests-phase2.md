# Phase 2 Failover Test Plan

Purpose: prove HAProxy's routing decisions follow Patroni's live role state
automatically — no manual HAProxy reconfiguration when the primary changes.
This is the strongest demonstration of Phase 2's actual value: static
config would break on failover, and this test shows it doesn't.

Run these in order. Record actual output under each step — this doc is a
plan, not a report; fill in results as you go (or copy into a versioned log
per your existing convention: `failover_test_run_1.log`, etc.).

---

## Pre-flight

Confirm starting state before triggering anything.

```bash
sudo patronictl -c /etc/patroni/patroni.yml list
```
Record: which node is Leader, which is Sync Standby, timeline number.

```bash
psql -h 192.168.20.180 -p 5000 -U postgres -c "SELECT pg_is_in_recovery();"
psql -h 192.168.20.180 -p 5001 -U postgres -c "SELECT pg_is_in_recovery();"
```
Expected: 5000 → `f`, 5001 → `t`. Confirms baseline routing is correct
before the test begins.

```bash
curl -s "http://192.168.20.180:7000/;csv" | grep -E "^(master|replicas),"
```
(Stats page CSV export — gives a clean machine-readable snapshot of which
backends HAProxy currently considers UP for each listener. Useful as a
before/after diff.)

---

## Test 1 — Planned switchover (`patronictl switchover`)

Clean, graceful role change. This is the easy case — Patroni orchestrates
it, both nodes cooperate.

```bash
sudo patronictl -c /etc/patroni/patroni.yml switchover
```
Follow the interactive prompts: specify the current leader as the node to
switch away from, and let Patroni pick the target (or specify explicitly).
Confirm when prompted.

**Immediately after** (within a few seconds — this is testing HAProxy's
health-check reaction time, not just eventual consistency):

```bash
sudo patronictl -c /etc/patroni/patroni.yml list
```
Confirm the Leader role actually moved.

```bash
psql -h 192.168.20.180 -p 5000 -U postgres -c "SELECT pg_is_in_recovery();"
```
Expected: still `f` — but now answered by the **new** primary. This is the
actual proof: the query succeeds and returns "not in recovery" without any
change to the connection string, because HAProxy re-routed automatically.

```bash
psql -h 192.168.20.180 -p 5001 -U postgres -c "SELECT pg_is_in_recovery();"
```
Expected: still `t` — the old primary (now demoted to replica) or the
existing standby, whichever Patroni assigns.

**Timing measurement** — worth capturing for the write-up: how long
between the switchover completing (per `patronictl list`) and HAProxy
correctly reflecting it (per the psql check)? HAProxy's `inter 3s fastinter
1s fall 3 rise 2-4` settings predict detection within roughly 3-9 seconds.
Loop the psql check every second for ~15s after switchover to measure this
empirically rather than assuming the spec numbers hold in practice:

```bash
for i in $(seq 1 15); do
  echo "t+${i}s: $(psql -h 192.168.20.180 -p 5000 -U postgres -tAc 'SELECT pg_is_in_recovery();' 2>&1)"
  sleep 1
done
```

**Check the strict-sync interaction** (Phase 1 documented finding — this
is where it matters in practice): immediately after switchover, is the new
primary accepting writes, or blocked waiting for a sync standby to catch
up/reconnect?
```bash
psql -h 192.168.20.180 -p 5000 -U postgres -c "CREATE TABLE IF NOT EXISTS failover_test (id serial, ts timestamptz default now());"
psql -h 192.168.20.180 -p 5000 -U postgres -c "INSERT INTO failover_test DEFAULT VALUES RETURNING *;"
```
If this hangs rather than returning immediately, that's the strict-sync
behavior from Phase 1 manifesting through HAProxy — worth timing and
documenting as expected, not a bug.

---

## Test 2 — Unplanned failure (kill the primary's Patroni process)

Rougher case: no graceful handoff, simulates an actual crash.

**Identify current primary first:**
```bash
sudo patronictl -c /etc/patroni/patroni.yml list
```

**On the current primary node**, stop Patroni abruptly (not `switchover` —
actually kill it):
```bash
sudo systemctl stop patroni
```

**From the other node** (or any client), poll until Patroni promotes the
standby:
```bash
for i in $(seq 1 30); do
  echo "t+${i}s:"
  sudo patronictl -c /etc/patroni/patroni.yml list 2>&1
  sleep 2
done
```
Record how long promotion actually takes — this depends on your DCS TTL
settings from Phase 1, not HAProxy, but it's the floor for how fast
HAProxy *can* react (it can't route to a new primary before Patroni
designates one).

**Confirm HAProxy follows once promotion completes:**
```bash
psql -h 192.168.20.180 -p 5000 -U postgres -c "SELECT pg_is_in_recovery();"
```
Expected: `f`, answered by the newly-promoted node.

**Recovery — bring the old primary back:**
```bash
sudo systemctl start patroni
```
Confirm it rejoins as a replica (Phase 1 finding: it does not automatically
reclaim primary):
```bash
sudo patronictl -c /etc/patroni/patroni.yml list
```

**Confirm HAProxy picks it back up as a valid replica target:**
```bash
psql -h 192.168.20.180 -p 5001 -U postgres -c "SELECT pg_is_in_recovery();"
```

---

## Test 3 — HAProxy node failure (not Patroni)

Different failure class: what happens if one of the two HAProxy instances
itself goes down, rather than a Postgres node? Confirms clients aren't
dependent on a specific HAProxy instance staying up — relevant given
there's no VIP yet (Phase 3), so this also documents the current gap.

```bash
sudo systemctl stop haproxy   # on jenkins, for example
```

Confirm the *other* node's HAProxy still routes correctly:
```bash
psql -h 192.168.20.180 -p 5000 -U postgres -c "SELECT pg_is_in_recovery();"
```
Expected: still works — because you connected to `192.168.20.180`
specifically, not jenkins's now-dead HAProxy.

Then confirm the actual gap this reveals:
```bash
psql -h 192.168.20.177 -p 5000 -U postgres -c "SELECT pg_is_in_recovery();"
```
Expected: connection refused/times out — proving that without a VIP,
losing one HAProxy instance means any client hardcoded to that specific IP
loses access, even though the cluster itself is healthy. **This is the
concrete justification for Phase 3's Keepalived work**, not just a
nice-to-have — worth stating exactly that in the writeup.

Restart it:
```bash
sudo systemctl start haproxy
```

---

## Cleanup

```bash
psql -h 192.168.20.180 -p 5000 -U postgres -c "DROP TABLE IF EXISTS failover_test;"
```

Confirm final state matches a healthy baseline:
```bash
sudo patronictl -c /etc/patroni/patroni.yml list
```

---

## What to capture in the writeup

- Actual switchover-to-HAProxy-reroute latency (measured, not assumed from
  config)
- Whether strict sync mode blocked writes post-switchover, and for how
  long
- Actual promotion latency in the unplanned-failure case
- Confirmation that a downed HAProxy instance doesn't affect the other —
  and the explicit gap this exposes (no VIP) as the Phase 3 justification
- Any deviation from expected `patronictl list` role states at each step