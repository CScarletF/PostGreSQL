# PostgreSQL HA Cluster — Patroni + etcd via Autobase

## Origin and purpose

This project was initiated as an RnD task: evaluate multi-server PostgreSQL setups for a team whose mandate is maximum capability at minimum cost and complexity, using free and open-source tooling. The deliverable is a reproducible, documented proof-of-concept demonstrating automated failover and synchronous replication.

**Phase 1** (below) covers automated failover and synchronous replication. **Phase 2** (further below) covers HAProxy read/write load balancing — a self-directed extension beyond the original assignment scope, documented separately for portfolio purposes.

---
---

# Phase 1 — Patroni + etcd Failover Cluster

## Architecture

```
┌─────────────────────────────┐     ┌─────────────────────────────┐
│        srv-deploy-eng        │     │            jenkins           │
│        192.168.20.180        │     │        192.168.20.177        │
│                             │     │                             │
│  PostgreSQL 17 (primary)    │◄───►│  PostgreSQL 17 (replica)    │
│  Patroni                    │     │  Patroni                    │
│  Ansible control node       │     │  etcd (single node)         │
└─────────────────────────────┘     └─────────────────────────────┘
```

**Patroni** manages the cluster: it bootstraps PostgreSQL, controls which node is primary, handles failover elections, and enforces replication mode. It does not replicate data itself — PostgreSQL's native streaming replication does that. Patroni's job is to make the right node primary at the right time and prevent split-brain.

**etcd** is the distributed configuration store (DCS). Patroni nodes write a leader key to etcd with a TTL; the node holding that key is the primary. If the primary stops renewing the key (because it crashed or was stopped), the key expires, and the remaining healthy node wins a new election and promotes itself. etcd is what makes failover automatic and split-brain-safe.

**PostgreSQL 17** handles actual data storage and streaming replication between nodes. The replica continuously applies WAL received from the primary.

### Design decisions and tradeoffs

**Single-node etcd on jenkins.** A production etcd cluster requires 3 or 5 nodes for quorum and split-brain protection. With only 2 VMs, a true etcd cluster is not possible. The single etcd instance on jenkins means etcd itself is a single point of failure — if jenkins is lost entirely (not just Patroni, but the OS), the cluster loses its DCS and Patroni cannot perform elections until etcd is restored. This is an accepted limitation for a 2-node PoC; document it when presenting.

etcd was placed on jenkins rather than srv-deploy-eng because srv-deploy-eng runs a Kubernetes control plane whose own etcd permanently occupies ports 2379 and 2380. See [Environmental constraints](#environmental-constraints).

**Synchronous replication, strict mode.** `synchronous_mode: true` and `synchronous_mode_strict: true` are set. Every write on the primary must be acknowledged by at least one synchronous standby before the client receives a commit confirmation. This guarantees zero data loss on failover — the replica is always fully current.

The tradeoff is write availability: with only one replica, that replica is a hard dependency for writes. If the replica is unreachable, writes block indefinitely. Reads continue unaffected. This behavior is demonstrated explicitly in the failover tests and is intentional, not a misconfiguration.

**PostgreSQL 17 (N-1).** The current major release at deployment time was 18. PG17 was chosen as the N-1 version: it has accumulated more point releases and real-world production exposure than 18, which was approximately 9-10 months old. Autobase 2.8.0 fully supports and tests both versions. This is a deliberate stability preference, not a tooling constraint.

**Ansible control node co-located with the primary.** srv-deploy-eng runs both the Ansible control node and the PostgreSQL primary. In a real environment these would be separated. The accepted tradeoff: if srv-deploy-eng is down during a failover test, you cannot run Ansible against the cluster from it. Manual SSH into jenkins is the fallback for post-failover operations.

**No PgBouncer.** PgBouncer is a connection pooler — it solves connection-scaling problems, not HA problems. It is disabled (`pgbouncer_install: false`) to keep Phase 1's deployed surface area matched exactly to what is being tested.

---

## Assumptions and environment

The following assumptions are baked into this deployment. A future engineer reproducing this on different infrastructure should review each one.

**Operating system:** Ubuntu 22.04.5 LTS on both nodes. Autobase supports Ubuntu 20.04, 22.04, and 24.04, and RHEL/Rocky/AlmaLinux 8/9. The apt repository URLs and package paths in this deployment are Ubuntu-specific (`/etc/postgresql/17/main/`, `jammy-pgdg` apt repo).

**Both nodes are active Kubernetes nodes.** The cluster runs a kubeadm-style Kubernetes deployment (Jitsi stack, scaled to zero replicas but not deleted). Kubernetes control plane components remain running throughout. This created two non-obvious deployment issues documented under [Environmental constraints](#environmental-constraints). A clean non-K8s VM would not encounter either issue.

**Network:** Both VMs are on a flat hypervisor-managed LAN (`192.168.20.0/24`), reachable by each other and by the operator's workstation via SSH. No firewall rules were encountered between the nodes. If your environment has inter-node firewalling, the following ports must be open:

| Port | Protocol | Purpose |
|------|----------|---------|
| 5432 | TCP | PostgreSQL client connections and streaming replication |
| 8008 | TCP | Patroni REST API (health checks, cluster state) |
| 2379 | TCP | etcd client |
| 2380 | TCP | etcd peer |

**Hardware (actual, not minimum):**

| Node | RAM | CPU | Disk |
|------|-----|-----|------|
| srv-deploy-eng | 7.75 GB | 2 vCPU | 134 GB |
| jenkins | 11.68 GB | 2 vCPU | 45 GB |

**Ansible control machine:** srv-deploy-eng. Ansible is not installed natively — all playbooks are run via the `autobase/automation:2.8.0` Docker image. Docker must be installed on the control node.

**Python 3:** Required on both managed nodes at `/usr/bin/python3`. Ubuntu 22.04 ships this by default.

**Autobase version:** `autobase/automation:2.8.0` (pinned). Do not substitute `:latest` — the image changes without notice and will silently alter default variable values (e.g. `postgresql_version` defaults to the current major release in each image version).

---

## Prerequisites

Before running the deploy playbook, the following must be in place on both nodes.

### Service account

A dedicated non-root account `ansible_svc` with passwordless sudo and SSH key authentication:

```bash
# On each node
sudo useradd -m -s /bin/bash ansible_svc
sudo passwd -l ansible_svc
sudo visudo -f /etc/sudoers.d/ansible_svc
# Add: ansible_svc ALL=(ALL) NOPASSWD:ALL
sudo chmod 440 /etc/sudoers.d/ansible_svc
```

Password login is locked (`passwd -l`). The account is only reachable via SSH key. Passwordless sudo is intentional — enumerating every privileged command Autobase's playbooks require in advance is impractical. Narrowing sudo to specific commands is a documented hardening step for after initial deployment, not before.

### SSH keypairs

Separate keypairs per node, generated on the control machine:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/ansible_srv_deploy_eng_key -C "ansible_svc@srv-deploy-eng" -N ""
ssh-keygen -t ed25519 -f ~/.ssh/ansible_jenkins_key -C "ansible_svc@jenkins" -N ""
```

Deploy each public key to its matching node's `ansible_svc` account:

```bash
# On each node, as a sudo-capable user
sudo mkdir -p /home/ansible_svc/.ssh
sudo cp ~/.ssh/ansible_<node>_key.pub /home/ansible_svc/.ssh/authorized_keys
sudo chown -R ansible_svc:ansible_svc /home/ansible_svc/.ssh
sudo chmod 700 /home/ansible_svc/.ssh
sudo chmod 600 /home/ansible_svc/.ssh/authorized_keys
```

Verify before proceeding:

```bash
ssh -i ~/.ssh/ansible_srv_deploy_eng_key ansible_svc@192.168.20.180 "sudo whoami"
ssh -i ~/.ssh/ansible_jenkins_key ansible_svc@192.168.20.177 "sudo whoami"
# Both should return: root
```

### Project directory

```bash
mkdir -p ~/autobase-postgresql/group_vars
cd ~/autobase-postgresql
```

---

## Configuration (Phase 1 baseline)

> Superseded in part by Phase 2 — see [Phase 2 configuration](#configuration-1) below for the current `inventory` and `all.yml` as actually deployed. Kept here for historical reference and to show what Phase 1 alone looked like.

### inventory (Phase 1)

```ini
[etcd_cluster]
192.168.20.177

[master]
192.168.20.180 hostname=srv-deploy-eng postgresql_exists=false ansible_ssh_private_key_file=/root/.ssh/ansible_srv_deploy_eng_key

[replica]
192.168.20.177 hostname=jenkins postgresql_exists=false ansible_ssh_private_key_file=/root/.ssh/ansible_jenkins_key bind_address=192.168.20.177

[postgres_cluster:children]
master
replica

[all:vars]
ansible_connection=ssh
ansible_ssh_port=22
ansible_ssh_user=ansible_svc
ansible_python_interpreter=/usr/bin/python3
ansible_become=true
ansible_become_method=sudo
```

`ansible_ssh_private_key_file` paths use `/root/.ssh/` because the Docker container bind-mounts `$HOME/.ssh` to `/root/.ssh` inside the container. The paths must reflect the container's filesystem, not the host's.

`bind_address=192.168.20.177` on the replica is required. See [Environmental constraints](#environmental-constraints) for why.

etcd is placed on jenkins (`192.168.20.177`) rather than srv-deploy-eng. See [Environmental constraints](#environmental-constraints).

### group_vars/all.yml (Phase 1)

```yaml
---
# Autobase / Patroni cluster configuration
# Deployed via autobase/automation:2.8.0 (Docker-wrapped Ansible)
# See: https://github.com/autobase-tech/autobase/blob/main/automation/roles/common/defaults/main.yml
# for the full list of overridable defaults. Only variables relevant to this
# project's scope are set or commented on below.

# --- Cluster identity ---
patroni_cluster_name: "postgres_cluster_template"
# Propagates into etcd_cluster_name (etcd-<name>) and pgbackrest_stanza (<name>).

# --- PostgreSQL version ---
postgresql_version: 17
# Default in 2.8.0 is 18. Pinned to 17 deliberately: N-1 major version,
# more point-release maturity than 18 (~9-10mo old) while still current
# and fully supported/tested by Autobase.

# --- Memory tuning (host-level, not stored in DCS) ---
# Default auto-calculates shared_buffers as 25% of total system RAM, which
# assumes Postgres has the host to itself. srv-deploy-eng also runs a full
# Kubernetes control plane + Longhorn/MetalLB DaemonSets, and strict memory
# overcommit (vm.overcommit_memory=2, set by Autobase's sysctl role) counts
# ALL committed memory cluster-wide against a hard ceiling. The 25%-of-RAM
# default (~1.9GB) exceeded available overcommit headroom (~1.06GB) on this
# shared host, causing Patroni/initdb to fail with "could not map anonymous
# shared memory: Cannot allocate memory". Overridden below to a value that
# fits comfortably within actual available headroom on this specific box.
local_postgresql_parameters:
  - { option: "shared_buffers", value: "512MB" }
  - { option: "effective_cache_size", value: "1536MB" }

# --- Replication mode ---
synchronous_mode: true
synchronous_mode_strict: true
# strict=true blocks ALL writes to master if no sync replica is reachable —
# zero-data-loss guarantee, chosen deliberately. With only 1 replica in this
# 2-node setup, that replica becomes a single point of failure for WRITE
# availability (reads still work). This is an intentional PoC finding to be
# demonstrated separately from primary-failover testing, not a bug.

# synchronous_node_count: 1  # (default) number of standbys required to ack
#   a sync write. NOTE: this is a ratio against *healthy* replicas, not a
#   raw node count — adding a 3rd node later does NOT fix the above SPOF
#   unless this value is reconsidered relative to total replica count.

# --- Load balancing (Phase 2, not used in this deployment) ---
with_haproxy_load_balancing: false
# Phase 1 = plain replication + failover only. HAProxy read/write load
# balancing is a planned Phase 2 RnD addition, deliberately out of scope
# here and to be documented separately when enabled.

# --- Connection pooling (not used in this deployment) ---
pgbouncer_install: false
# Defaults to true upstream. Disabled here because PgBouncer solves a
# connection-scaling problem (many short-lived client connections), which
# is unrelated to what Phase 1 is testing (Patroni/etcd failover behavior).
# Revisit if/when Phase 2 introduces realistic client-traffic simulation
# through HAProxy.

# --- Backup/restore (not used in this deployment) ---
# pgbackrest_install: false  # (default) pgBackRest backup/restore tooling.
#   Out of scope for this PoC — no backup strategy is being tested here.
# wal_g_install: false       # (default) WAL-G as an alternative backup tool.

# --- Monitoring (installed by default, left as-is) ---
# netdata_install: true  # (default) lightweight monitoring dashboard,
#   reachable at http://<node>:19999 after deploy. Left at default since
#   it's useful for observing the cluster during failover tests, at
#   negligible resource cost on this VM.
```

---

## Deployment

Verify connectivity before the full deploy:

```bash
cd ~/autobase-postgresql
docker run --rm -it \
  -e ANSIBLE_SSH_ARGS="-F none" \
  -e ANSIBLE_INVENTORY=/project/inventory \
  -v $PWD:/project \
  -v $HOME/.ssh:/root/.ssh \
  autobase/automation:2.8.0 \
  ansible all -m ping
```

Both nodes should return `pong`. Then run the full deploy:

```bash
docker run --rm -it \
  -e ANSIBLE_SSH_ARGS="-F none" \
  -e ANSIBLE_INVENTORY=/project/inventory \
  -v $PWD:/project \
  -v $HOME/.ssh:/root/.ssh \
  autobase/automation:2.8.0 \
  ansible-playbook deploy_pgcluster.yml 2>&1 | tee deploy_run.log
```

The deploy takes approximately 10-15 minutes. On completion, Ansible prints cluster connection info including the auto-generated superuser password. Save the log — the password is only printed once.

### Teardown

If you need to start over:

```bash
docker run --rm -it \
  -e ANSIBLE_SSH_ARGS="-F none" \
  -e ANSIBLE_INVENTORY=/project/inventory \
  -v $PWD:/project \
  -v $HOME/.ssh:/root/.ssh \
  autobase/automation:2.8.0 \
  ansible-playbook remove_cluster.yml -e remove_postgres=true -e remove_etcd=true
```

`remove_cluster.yml` does not fully clean up all installed components. After running it, manually verify and remove on both nodes:

```bash
sudo systemctl stop pgbouncer 2>/dev/null; sudo systemctl disable pgbouncer 2>/dev/null
sudo rm -rf /etc/pgbouncer /var/log/pgbouncer
sudo rm -rf /var/lib/postgresql/
sudo rm -rf /etc/tls /etc/patroni/tls
```

---

## Verification

After a successful deploy, confirm the cluster is healthy before proceeding to testing.

```bash
# Cluster state — both members present, lag 0, sync standby streaming
sudo patronictl -c /etc/patroni/patroni.yml list

# Confirm sync_state = sync (not async)
sudo -u postgres psql -c "SELECT client_addr, state, sync_state FROM pg_stat_replication;"

# Write on primary, read on replica
sudo -u postgres psql -c "CREATE TABLE healthcheck (id serial, ts timestamptz default now());"
sudo -u postgres psql -c "INSERT INTO healthcheck DEFAULT VALUES;"
ssh -i ~/.ssh/ansible_jenkins_key ansible_svc@192.168.20.177 \
  "sudo -u postgres psql -c 'SELECT * FROM healthcheck;'"

# Replica rejects writes
ssh -i ~/.ssh/ansible_jenkins_key ansible_svc@192.168.20.177 \
  "sudo -u postgres psql -c 'INSERT INTO healthcheck DEFAULT VALUES;'"
# Expected: ERROR: cannot execute INSERT in a read-only transaction
```

---

## Failover tests (Phase 1)

### Scenario B — Kill the replica, observe write hang

This demonstrates the write-availability tradeoff of strict synchronous replication with a single replica.

**Before:** both members present, lag 0, `sync_state = sync`.

```bash
# Stop the replica
ssh -i ~/.ssh/ansible_jenkins_key ansible_svc@192.168.20.177 "sudo systemctl stop patroni"

# Attempt a write on the primary — this will hang indefinitely
sudo -u postgres psql -c "INSERT INTO healthcheck DEFAULT VALUES;"

# While the write hangs, reads still succeed
sudo -u postgres psql -c "SELECT count(*) FROM healthcheck;"

# Patroni still shows primary as Leader — this is a replication-layer block,
# not a Patroni-layer failure
sudo patronictl -c /etc/patroni/patroni.yml list

# etcd leader key unchanged — primary still holds it
ssh -i ~/.ssh/ansible_jenkins_key ansible_svc@192.168.20.177 \
  "sudo ETCDCTL_API=3 etcdctl \
  --endpoints=https://192.168.20.177:2379 \
  --cacert=/etc/etcd/tls/ca.crt \
  --cert=/etc/etcd/tls/server.crt \
  --key=/etc/etcd/tls/server.key \
  get /service/postgres_cluster_template/leader"

# Restart the replica — the blocked INSERT completes within seconds
ssh -i ~/.ssh/ansible_jenkins_key ansible_svc@192.168.20.177 "sudo systemctl start patroni"
```

**Finding:** `synchronous_mode_strict: true` with a single replica makes that replica a hard write dependency. The primary remains healthy and readable; only writes are blocked. This is the intended behavior of a zero-data-loss configuration, not a failure mode. Adding a second replica does not resolve this unless `synchronous_node_count` is kept at 1 relative to the total replica count — the guarantee is about the ratio of required acknowledgements to healthy replicas, not raw node count.

---

### Scenario A — Kill the primary, observe automatic promotion

This demonstrates Patroni's automated failover via etcd leader election.

**Before:** Capture baseline state.

```bash
sudo patronictl -c /etc/patroni/patroni.yml list
sudo -u postgres psql -c "SELECT timeline_id FROM pg_control_checkpoint();"
# timeline_id = 1

curl -sk https://192.168.20.180:8008/primary | python3 -m json.tool
# "role": "primary", "timeline": 1, "replication": [{"sync_state": "sync"}]

curl -sk https://192.168.20.177:8008/replica | python3 -m json.tool
# "role": "replica", "sync_standby": true, "timeline": 1

ssh -i ~/.ssh/ansible_jenkins_key ansible_svc@192.168.20.177 \
  "sudo ETCDCTL_API=3 etcdctl \
  --endpoints=https://192.168.20.177:2379 \
  --cacert=/etc/etcd/tls/ca.crt \
  --cert=/etc/etcd/tls/server.crt \
  --key=/etc/etcd/tls/server.key \
  get /service/postgres_cluster_template/leader"
# Returns: srv-deploy-eng
```

Kill the primary:

```bash
sudo systemctl stop patroni
```

Within Patroni's TTL window (default 30 seconds), jenkins detects the expired leader key, wins the election, and promotes itself. Monitor from jenkins:

```bash
sudo patronictl -c /etc/patroni/patroni.yml list
# jenkins: Leader, running, TL 2
# srv-deploy-eng: Replica, stopped
```

**Post-failover state:**

```bash
# etcd leader key flipped
ssh -i ~/.ssh/ansible_jenkins_key ansible_svc@192.168.20.177 \
  "sudo ETCDCTL_API=3 etcdctl \
  --endpoints=https://192.168.20.177:2379 \
  --cacert=/etc/etcd/tls/ca.crt \
  --cert=/etc/etcd/tls/server.crt \
  --key=/etc/etcd/tls/server.key \
  get /service/postgres_cluster_template/leader"
# Returns: jenkins

# REST API reflects new roles
curl -sk https://192.168.20.177:8008/primary | python3 -m json.tool
# "role": "primary", "timeline": 2

curl -sk https://192.168.20.180:8008/primary 2>/dev/null || echo "srv-deploy-eng no longer primary"

# Timeline incremented — confirms a genuine failover, not a restart
ssh -i ~/.ssh/ansible_jenkins_key ansible_svc@192.168.20.177 \
  "sudo -u postgres psql -c 'SELECT timeline_id FROM pg_control_checkpoint();'"
# timeline_id = 2
```

**Finding — strict sync applies immediately to the promoted primary.** With no replica connected, writes block on the new primary for the same reason as Scenario B. Write availability is not restored until a sync standby reconnects.

Rejoin the old primary as a replica:

```bash
sudo systemctl start patroni
# Patroni detects it is behind TL 2, runs pg_rewind automatically,
# and rejoins as Sync Standby under jenkins. No manual intervention required.

sudo patronictl -c /etc/patroni/patroni.yml list
# jenkins: Leader, TL 2
# srv-deploy-eng: Sync Standby, TL 2, lag 0
```

Writes resume immediately once srv-deploy-eng reconnects as a sync standby.

**Note on role assignment after failover.** After failover and recovery, the original primary rejoins as a replica under the promoted node. Role assignment is dynamic — Patroni assigns roles based on who holds the etcd leader lock, not on static configuration. If the original primary restarts after a failover, it will not reclaim the primary role automatically; it rejoins as a replica. Operators should not assume a specific node is always primary after a restart.

---

## Environmental constraints encountered

These are non-obvious issues specific to this environment. A future engineer on clean, dedicated VMs will not encounter them. They are documented here because the diagnostic process and resolution are themselves RnD findings.

### etcd port collision with Kubernetes control plane etcd

Both nodes run Kubernetes. The kubeadm-managed K8s control plane etcd is a static pod that binds to the host network on ports 2379 and 2380, including the node's LAN IP — not just loopback as might be assumed. Autobase's default behavior places etcd on the `[master]` node (srv-deploy-eng), which would collide with the K8s etcd already occupying those ports.

**Resolution:** Move Autobase's etcd to jenkins by placing `192.168.20.177` in the `[etcd_cluster]` group instead of `192.168.20.180`. jenkins does not run a K8s control plane etcd, so the ports are free. The single-node etcd tradeoff (see [Architecture](#architecture)) applies regardless of which node hosts it.

To confirm which process owns a port before deployment:
```bash
sudo ss -tlnp | grep -E '2379|2380'
sudo cat /proc/<pid>/cmdline | tr '\0' ' '
# Look for /etc/kubernetes/pki/etcd/ in the cert paths — that's K8s's etcd, not Autobase's
```

### Flannel CNI IP detection on multi-interface Kubernetes nodes

Autobase's `bind_address` role auto-detects the node's primary IP for use in TLS certificate SANs, pg_hba.conf replication rules, and Patroni connection addresses. On jenkins, this detection picked up `10.244.1.0` — a Flannel CNI virtual interface — instead of the actual LAN IP `192.168.20.177`. This caused pg_hba.conf on the primary to generate a replication rule for `10.244.1.0/32` instead of `192.168.20.177/32`, blocking `pg_basebackup` with:

```
FATAL: no pg_hba.conf entry for replication connection from host "192.168.20.177", user "replicator", SSL encryption
```

**Resolution:** Pin `bind_address` explicitly in the inventory for any node with multiple network interfaces:

```ini
192.168.20.177 ... bind_address=192.168.20.177
```

This overrides auto-detection entirely and flows through to all generated configs: TLS SANs, pg_hba.conf, patroni.yml connection addresses, etcd advertise URLs.

### Shared memory exhaustion under strict overcommit on a shared host

Autobase's sysctl role sets `vm.overcommit_memory=2` (strict accounting) on all managed nodes. PostgreSQL's default `shared_buffers` auto-calculates as 25% of total system RAM. On srv-deploy-eng (7.75 GB RAM), that is approximately 1.9 GB. However, strict overcommit accounting counts all committed memory system-wide against a ceiling of `swap + (RAM × overcommit_ratio)`. With the Kubernetes control plane already consuming ~6.8 GB of committed memory, the available headroom under the strict limit was approximately 1.06 GB — well below Postgres's 2.47 GB shared memory request. Patroni's bootstrap failed with:

```
FATAL: could not map anonymous shared memory: Cannot allocate memory
```

**Resolution:** Override `shared_buffers` in `group_vars/all.yml` to a fixed value that fits within actual available headroom:

```yaml
local_postgresql_parameters:
  - { option: "shared_buffers", value: "512MB" }
  - { option: "effective_cache_size", value: "1536MB" }
```

On a dedicated (non-K8s) host, the default auto-calculation is appropriate and this override is not needed. Adjust the value based on `CommitLimit - Committed_AS` from `/proc/meminfo` on the target host.

---

## Known gaps (Phase 1)

**Netdata on jenkins partially configured.** During deployment, the Netdata configuration task on jenkins failed with `[Errno 12] Cannot allocate memory` on the Ansible controller side (a fork/exec failure in the Docker container, not on jenkins itself). Netdata was installed but may not be fully configured. The dashboard at `http://192.168.20.177:19999` should be checked post-deploy. This did not affect cluster functionality.

**remove_cluster.yml incomplete teardown.** The teardown playbook does not remove all installed components. PgBouncer service artifacts, PostgreSQL data directories under `/var/lib/postgresql/`, and TLS certificate directories (`/etc/tls`, `/etc/patroni/tls`) require manual cleanup between redeploy attempts. See [Teardown](#teardown) for the full procedure.

**No backup strategy.** pgBackRest and WAL-G are both disabled. This is a PoC — there is no backup, point-in-time recovery, or archiving. Do not use this configuration for anything other than testing.

**No Ansible Vault.** Secrets (the auto-generated PostgreSQL superuser password) appear in plaintext in the Ansible log. Vault integration is the correct next step before committing logs to version control. The inventory itself contains no secrets — SSH key paths only.

**Swap not disabled.** kubeadm requires swap disabled on all nodes. Both hosts currently have swap enabled (4GB, lightly used). Flagged as an outstanding correctness issue — not yet remediated as of Phase 2.

---
---

# Phase 2 — HAProxy Load Balancing

## Scope

Phase 2 adds HAProxy read/write load balancing on top of the Phase 1 cluster — a self-directed extension beyond the original assignment (PostgreSQL HA/failover), scoped and documented separately for portfolio purposes.

Deliverable: HAProxy running on both nodes, routing client traffic to the correct backend (primary vs. replica) based on live Patroni role state, with no manual reconfiguration required when roles change. **Implemented and verified** — see [Verification performed](#verification-performed-phase-2) below.

## Architecture (Phase 2)

**Deployment model: Option C — co-located, PoC-grade.**
HAProxy runs on the same two hosts as PostgreSQL/Patroni (`srv-deploy-eng`, `jenkins`), rather than on dedicated balancer nodes. This is a deliberate tradeoff for a resource-constrained lab environment, not a production pattern — see [Limitations (Phase 2)](#known-limitations-phase-2).

```
                     ┌─────────────────────┐
                     │   Client / App       │
                     └──────────┬───────────┘
                                 │
                 picks either IP (no VIP yet — Phase 3)
                                 │
          ┌──────────────────────┴──────────────────────┐
          │                                              │
 ┌────────▼─────────┐                          ┌─────────▼────────┐
 │ srv-deploy-eng    │                          │ jenkins           │
 │ 192.168.20.180    │                          │ 192.168.20.177    │
 │                   │                          │                   │
 │ HAProxy           │                          │ HAProxy           │
 │ Patroni + PG 17    │                          │ Patroni + PG 17    │
 │                   │                          │ etcd               │
 └───────────────────┘                          └───────────────────┘
```

Both HAProxy instances query Patroni's REST API (`/primary`, `/replica`, `/sync`, `/async` on port 8008) on **both** cluster members to determine live routing — not just the local node. Health checks, not static config, decide where traffic goes. This reuses the same REST API mechanism observed in the Phase 1 Scenario A failover test.

## Port map

| Port | Listener         | Routes to                                   | Notes |
|------|------------------|------------------------------------------------|-------|
| 5000 | `master`         | Current Patroni primary (read/write)            | Follows failover automatically |
| 5001 | `replicas`       | Any healthy replica (sync or async, round-robin) | Read-only |
| 7001 | `replicas_sync`  | Synchronous standby only                        | Read-only |
| 7002 | `replicas_async` | Async replicas only                             | **Currently empty** — see [Known limitations](#known-limitations-phase-2) |
| 7000 | `stats`          | HAProxy stats page (HTML)                       | No IP restriction — relies on local network trust boundary, not an allowlist |

Health checks use `inter 3s fastinter 1s fall 3 rise 2-4 on-marked-down shutdown-sessions` — a down backend is detected within ~3-9s and existing sessions to it are killed immediately rather than left to drain.

## Configuration

### inventory (Phase 2 — current, supersedes Phase 1 inventory above)

```ini
[etcd_cluster]
192.168.20.177

[master]
192.168.20.180 hostname=srv-deploy-eng postgresql_exists=false ansible_ssh_private_key_file=/root/.ssh/ansible_srv_deploy_eng_key bind_address=192.168.20.180
# bind_address added for Phase 2: HAProxy's post-restart handler runs a
# wait_for check against haproxy_listen_port.stats on this address, so it
# needs to be explicit here now rather than left to auto-detection — same
# class of problem bind_address already solves for jenkins below.

[replica]
192.168.20.177 hostname=jenkins postgresql_exists=false ansible_ssh_private_key_file=/root/.ssh/ansible_jenkins_key bind_address=192.168.20.177
# bind_address pinned: resolves Flannel CNI virtual interface IP
# auto-detection picking the wrong address for TLS SANs / pg_hba.conf
# replication rules (Phase 1 finding).

[postgres_cluster:children]
master
replica

# HAProxy deployed on both nodes — joint rollout per Phase 2 architectural
# decision (Option C: co-located with Postgres, PoC-grade, not
# production-grade). Both IPs required so Autobase's haproxy role runs on
# each host.
[balancers]
192.168.20.180
192.168.20.177

[all:vars]
ansible_connection=ssh
ansible_ssh_port=22
ansible_ssh_user=ansible_svc
ansible_python_interpreter=/usr/bin/python3
ansible_become=true
ansible_become_method=sudo
```

### group_vars/all.yml additions (Phase 2)

Appended to the Phase 1 `all.yml` shown above; `with_haproxy_load_balancing` flips from `false` to `true`:

```yaml
# --- Load balancing (Phase 2: HAProxy read/write load balancing) ---
with_haproxy_load_balancing: true
# Enables the haproxy role. Deployed to both nodes as a joint initial
# rollout (see [balancers] in inventory) — not adding a balancer to an
# already-running single-node setup.

# Port assignments for each HAProxy listener.
# stats: web UI showing backend health/traffic (no IP restriction — relying
#   on local network trust boundary rather than a stats-page allowlist).
# master: routes to the current Patroni primary only (read/write). Backed
#   by Patroni's /primary healthcheck.
# replicas: routes to any healthy replica, sync or async (read-only,
#   round-robin).
# replicas_sync: routes only to the synchronous standby (read-only).
#   Backed by Patroni's /sync healthcheck.
# replicas_async: routes only to async replicas, excludes the sync
#   standby (read-only).
haproxy_listen_port:
  stats: 7000
  master: 5000
  replicas: 5001
  replicas_sync: 7001
  replicas_async: 7002

# Connection ceilings — sized for a 2-node PoC, not production load.
# global: total connections HAProxy will accept across all listeners
#   combined.
# master: cap on the read/write listener specifically.
# replica: cap on each replica-facing listener (shared setting across
#   replicas / replicas_sync / replicas_async).
haproxy_maxconn:
  global: 100
  master: 50
  replica: 50

# Idle timeouts before HAProxy drops a connection.
# client: max idle time on the client-facing side of a connection.
# server: max idle time on the Postgres-facing side of a connection.
haproxy_timeout:
  client: 30s
  server: 30s

# add_balancer intentionally left unset: this is a first-time joint rollout
# of HAProxy to both nodes, not adding a balancer to an already-running
# cluster. Setting this true would trigger Autobase's "fetch existing
# haproxy.cfg and copy it to the new node" code path, which doesn't apply
# here.

# cluster_vip intentionally left unset: single floating endpoint via
# Keepalived VIP is a planned Phase 3 addition. Clients currently need to
# pick between the two HAProxy IPs directly.
```

`pgbouncer_install: false` from Phase 1 is unchanged — no connection pooling introduced in Phase 2.

## Deployment (Phase 2)

Applied via Autobase's dedicated `balancers.yml` playbook — **not** `deploy_pgcluster.yml`, which re-walks full PostgreSQL/Patroni provisioning and is the wrong target for adding HAProxy to an already-running cluster:

```bash
docker run --rm -it \
  -e ANSIBLE_SSH_ARGS="-F none" \
  -e ANSIBLE_INVENTORY=/project/inventory \
  -v $PWD:/project \
  -v $HOME/.ssh:/root/.ssh \
  autobase/automation:2.8.0 \
  ansible-playbook /autobase/automation/playbooks/balancers.yml 2>&1 | tee deploy_run_5.log
```

Recommended: dry-run first with `--check --diff`. Note that in check mode, the `confd` role's package download step is skipped (state-changing operations don't execute), which causes a **false-positive failure** on the subsequent extract task (`Source '/tmp/confd-*.tar.gz' does not exist`). This is expected and does not indicate a real problem — confirmed by inspecting `roles/confd/tasks/main.yml`, where the extract step directly follows a `get_url` download that check mode intentionally skips.

`confd` is installed automatically alongside HAProxy when `with_haproxy_load_balancing: true` and `dcs_type: etcd` (the default) — this wasn't an explicit Phase 2 design decision, it's pulled in by Autobase's `balancers.yml` playbook. `confd` watches etcd directly and can rewrite `haproxy.cfg` in response to DCS state changes, as a complement/backstop to HAProxy's own REST-API health checks.

Actual deploy result: `failed=0` on both hosts (`ok=28, changed=19` on jenkins; `ok=30, changed=18` on srv-deploy-eng).

## Verification performed (Phase 2)

1. **Service status** — `systemctl status haproxy` active on both nodes.
2. **Stats page reachable** — `curl http://<node-ip>:7000/` returns the HAProxy stats HTML on both nodes.
3. **Correct routing, end to end**:
   ```
   psql -h 192.168.20.180 -p 5000 -U postgres -c "SELECT pg_is_in_recovery();"
   → f   (primary — correct)

   psql -h 192.168.20.180 -p 5001 -U postgres -c "SELECT pg_is_in_recovery();"
   → t   (replica — correct)
   ```
   Confirmed against srv-deploy-eng's HAProxy instance while jenkins held the Leader role — i.e., the query was answered by whichever physical node Patroni currently designates as primary, not by whichever node happened to receive the connection. This is the core Phase 2 claim, verified.

Credentials used for this test came from `/var/lib/postgresql/.pgpass` — this is Patroni's internal replication/health-check credential, not necessarily an appropriate credential for real client applications. A separate application-facing role should be provisioned before this cluster is used for anything beyond PoC testing.

Failover-specific testing (does HAProxy routing follow a live `switchover`, not just static role state) is planned but not yet executed — see the separate `failover-tests-phase2.md` test plan.

## Known limitations (Phase 2)

- **`replicas_async` pool is currently empty.** With only one replica (configured as the synchronous standby), there are no async replicas to route to. HAProxy logs `proxy 'replicas_async' has no server available!` at startup — this is expected given current topology, not a misconfiguration. Resolves naturally once the cluster scales to 3-4 replicas (see Phase 3 notes below).
- **No single floating endpoint.** Clients must currently pick between `192.168.20.180` and `192.168.20.177` directly for HAProxy access — no VIP exists yet. Deferred to Phase 3 (Keepalived).
- **Stats page has no access restriction.** Deliberate tradeoff — relies on local network trust rather than an IP allowlist. Not appropriate outside a trusted lab network.
- **Co-located deployment (Option C).** HAProxy shares hosts with PostgreSQL/Patroni/etcd/Kubernetes. A production deployment would run load balancers on dedicated hosts, separate from both the database nodes and any deploy tooling.

## Known issue: intermittent Docker container-creation failures on srv-deploy-eng

Encountered during Phase 2 tooling work, unrelated to the HAProxy deployment itself.

**Symptom:** `docker run` against `autobase/automation:2.8.0` intermittently fails with shifting error signatures across separate attempts:
- Overlay mount ENOSPC
- `config.json` write ENOSPC
- Go runtime `pthread_create failed: Resource temporarily unavailable` (client-side crash)
- `runc create failed: ... procReady not received`

All observed despite verified-clean disk (60-70% used), inodes (13-17% used), memory (5+GB available), swap (near-idle), and process/thread limits at time of failure.

**Suspected root cause (not fully confirmed):** kernel keyring exhaustion (`/proc/sys/kernel/keys/root_maxkeys`). containerd/runc allocate a keyring per container session. Under sustained high container churn — this host runs 280+ concurrent containerd tasks via kubeadm — the per-scope ceiling can be reached, surfacing as `ENOSPC` unrelated to actual disk state. Keyrings are kernel-resident and are **not** released by restarting `dockerd` or `containerd` individually — only a full host reboot clears them. This matches observed behavior: the failure recurred after ~4 days of uptime, was cleared twice by a full reboot, and was **not** cleared by either a `docker` or `containerd` service restart attempted first.

To confirm on next occurrence:
```bash
cat /proc/sys/kernel/keys/root_maxkeys
cat /proc/keys | wc -l
```
If the second value is near the first, this confirms the theory, and the correct fix is raising `root_maxkeys` via sysctl rather than rebooting reactively each time.

**Architectural takeaway:** this is a tooling/host-sharing issue, not a Patroni/PostgreSQL HA issue — the Patroni cluster remained healthy and uninterrupted through every occurrence, including the reboots themselves. Running Docker-wrapped Ansible on a live Kubernetes node creates kernel resource contention between two independent container runtimes (Docker, and Kubernetes' own containerd) sharing one host. A production deployment pipeline should run Ansible from a dedicated, non-cluster-member host to avoid this class of failure entirely.

---

## Future Plans (Phase 3)

- Keepalived VIP for single-endpoint client routing (`cluster_vip`, already wired into `balancers.yml`, currently gated off)
- Scale to 3-4 replicas with a 1-2 minimum synchronous replica requirement — will populate the currently-empty `replicas_async` pool and requires deciding `synchronous_node_count` explicitly (this is a ratio against healthy replicas, not a raw node count, and does not self-resolve just by adding nodes)
- Swap disable on both hosts (kubeadm requirement, outstanding since Phase 1)
- Execute the drafted failover test plan (`failover-tests-phase2.md`) to confirm HAProxy follows a live `patronictl switchover`, not just static role state