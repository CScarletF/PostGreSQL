# PostgreSQL HA Cluster — Patroni + etcd via Autobase

## Origin and purpose

This project was initiated as an RnD task: evaluate multi-server PostgreSQL setups for a team whose mandate is maximum capability at minimum cost and complexity, using free and open-source tooling. The deliverable is a reproducible, documented proof-of-concept demonstrating automated failover and synchronous replication.

**Phase 1** (below) covers automated failover and synchronous replication. **Phase 2** (further below) covers HAProxy read/write load balancing — a self-directed extension beyond the original assignment scope, documented separately for portfolio purposes. **Phase 3** covers a Keepalived VIP for single-endpoint client routing, plus a later addendum generalizing the `webapp_postgres` provisioning role.

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

**Ansible control machine:** srv-deploy-eng. Ansible is not installed natively for Autobase-provided playbooks — those are run via the `autobase/automation:2.8.0` Docker image. Docker must be installed on the control node. (Native `ansible-playbook` is also installed and used for custom, non-Autobase roles — see Phase 3.)

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

`ansible_ssh_private_key_file` paths use `/root/.ssh/` because the Docker container bind-mounts `$HOME/.ssh` to `/root/.ssh` inside the container. The paths must reflect the container's filesystem, not the host's. **Native (non-Docker) runs of custom playbooks require these same keys to also exist under `/root/.ssh/` on the host itself — see Phase 3 for why and how.**

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
#   reachable at http://<node>:19999 after deploy. NOTE: NOT negligible —
#   confirmed ~1.1GB real committed memory on srv-deploy-eng under strict
#   overcommit (vm.overcommit_memory=2), contributing to an sshd fork
#   failure during swap-disable work (see Phase 3). Check headroom before
#   assuming this is free.
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

**Note (Phase 3 addendum):** this pinning is correct and necessary for Postgres/Patroni's own identity, but does *not* automatically extend correctly to HAProxy — see Phase 3's `bind_address` note below for a case where the same variable, reused for a different purpose, caused a real bug.

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

**Swap — resolved on both hosts as of Phase 3.** kubeadm requires swap disabled on all nodes. Originally flagged as outstanding in Phase 1/2; disabled and confirmed persistent (fstab commented out) on both srv-deploy-eng and jenkins during Phase 3 work. See Phase 3's swap/overcommit notes below for the process and a live incident encountered along the way.

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
                 picks either IP, or the Phase 3 VIP (192.168.20.190)
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
# each host. Also reused as the target group for Phase 3's Keepalived and
# haproxy_vip_bind roles.
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
# Keepalived VIP was a planned Phase 3 addition at the time this section
# was written. As of Phase 3, the VIP (192.168.20.190) is implemented and
# verified working — see Phase 3 below. This variable itself remains
# unset because Phase 3's VIP was implemented via a standalone Keepalived
# role rather than Autobase's built-in cluster_vip mechanism; kept here
# unchanged as an accurate historical record of the Phase 2 state.

# --- VIP (Phase 3: Keepalived) ---
keepalived_vip: 192.168.20.190
keepalived_interface: ens18
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

## Failover Test Plan (Phase 2) — Status: NOT YET EXECUTED

Purpose: prove HAProxy's routing decisions follow Patroni's live role state
automatically — no manual HAProxy reconfiguration when the primary changes.
This is the strongest demonstration of Phase 2's actual value: static
config would break on failover, and this test is designed to show it
doesn't.

This section was drafted as a test plan and has **not yet been run**. Run
the steps in order and record actual output under each step — this is a
plan, not a report; fill in results as you go (or copy into a versioned
log per this project's existing convention: `failover_test_run_1.log`,
etc.).

### Pre-flight

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

### Test 1 — Planned switchover (`patronictl switchover`)

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

### Test 2 — Unplanned failure (kill the primary's Patroni process)

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

### Test 3 — HAProxy node failure (not Patroni)

Different failure class: what happens if one of the two HAProxy instances
itself goes down, rather than a Postgres node? Confirms clients aren't
dependent on a specific HAProxy instance staying up.

**Note (Phase 3 addendum):** this test predates Phase 3's VIP. As
originally drafted, it documents the gap that Phase 3 was built to close.
It's still worth running as-is against the individual node IPs first
(to reconfirm the gap existed before Phase 3), and then repeating step 2
against the VIP (`192.168.20.190`) instead of `192.168.20.177` directly,
to confirm Phase 3 actually closes it.

```bash
sudo systemctl stop haproxy   # on jenkins, for example
```

Confirm the *other* node's HAProxy still routes correctly:
```bash
psql -h 192.168.20.180 -p 5000 -U postgres -c "SELECT pg_is_in_recovery();"
```
Expected: still works — because you connected to `192.168.20.180`
specifically, not jenkins's now-dead HAProxy.

Then confirm the gap this reveals (pre-Phase-3 behavior):
```bash
psql -h 192.168.20.177 -p 5000 -U postgres -c "SELECT pg_is_in_recovery();"
```
Expected: connection refused/times out — proving that without a VIP,
losing one HAProxy instance means any client hardcoded to that specific IP
loses access, even though the cluster itself is healthy. **This was the
concrete justification for Phase 3's Keepalived work.**

Then, with Phase 3 in place, repeat against the VIP instead:
```bash
psql -h 192.168.20.190 -p 5000 -U postgres -c "SELECT pg_is_in_recovery();"
```
Expected (post-Phase-3): still works, regardless of which underlying node
is down, as long as the other node's HAProxy + Keepalived are healthy —
this is the actual claim Phase 3 makes and should be confirmed here rather
than assumed from Phase 3's own steady-state verification alone.

Restart it:
```bash
sudo systemctl start haproxy
```

### Cleanup

```bash
psql -h 192.168.20.180 -p 5000 -U postgres -c "DROP TABLE IF EXISTS failover_test;"
```

Confirm final state matches a healthy baseline:
```bash
sudo patronictl -c /etc/patroni/patroni.yml list
```

### What to capture in the writeup

- Actual switchover-to-HAProxy-reroute latency (measured, not assumed from
  config)
- Whether strict sync mode blocked writes post-switchover, and for how
  long
- Actual promotion latency in the unplanned-failure case
- Confirmation that a downed HAProxy instance doesn't affect the other,
  both pre- and post-Phase-3 (via individual IPs vs. via the VIP)
- Any deviation from expected `patronictl list` role states at each step

## Known limitations (Phase 2)

- **`replicas_async` pool is currently empty.** With only one replica (configured as the synchronous standby), there are no async replicas to route to. HAProxy logs `proxy 'replicas_async' has no server available!` at startup — this is expected given current topology, not a misconfiguration. Resolves naturally once the cluster scales to 3-4 replicas (RnD-only exploration — see Phase 3's production-framing note).
- **No single floating endpoint — resolved in Phase 3.** Clients previously had to pick between `192.168.20.180` and `192.168.20.177` directly. As of Phase 3, `192.168.20.190` (Keepalived VIP) provides a single stable endpoint. See Phase 3 below.
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

## Future Plans (as of end of Phase 2)

- ~~Keepalived VIP for single-endpoint client routing~~ — **done, see Phase 3 below**
- Scale to 3-4 replicas with a 1-2 minimum synchronous replica requirement — will populate the currently-empty `replicas_async` pool and requires deciding `synchronous_node_count` explicitly (this is a ratio against healthy replicas, not a raw node count, and does not self-resolve just by adding nodes). **RnD-only exploration — not the same as the 2-node production recommendation noted in Phase 3.**
- ~~Swap disable on both hosts~~ — **done, see Phase 3 below**
- Execute the drafted failover test plan above (still not yet executed as of Phase 3) to confirm HAProxy follows a live `patronictl switchover`, not just static role state — and, per the Phase 3 addendum to Test 3, to confirm the VIP actually closes the single-HAProxy-instance gap under a live failure, not just at steady state.

---
---

# Phase 3 — Keepalived VIP for Single-Endpoint Client Routing

**Keepalived** provides a single floating virtual IP (VIP) across the two
HAProxy instances deployed in Phase 2, so clients connect to one stable
address instead of choosing between the two nodes' real IPs directly.

VIP: `192.168.20.190`
Preferred node: `jenkins` (higher priority, preempt enabled — see below)

**Production relevance note:** this VIP work is directly relevant to
planned 2-node hospital-partner production deployments (one writer, one
reader), not just an internal RnD exercise. The separate "scale to 3-4
replicas" exploration noted in Phase 2's Future Plans is RnD-only and
should not be conflated with the 2-node production recommendation.

## Architecture decisions

**Unicast, not multicast VRRP.** This is a Proxmox-managed hypervisor
network; multicast VRRP is unreliable on virtualized/hypervisor networks
due to switch/vswitch multicast snooping issues, risking a split-brain VIP
if advertisements silently fail to propagate. Configured with explicit
`unicast_src_ip` / `unicast_peer` per node instead of the default
multicast group.

**Preempt, not nopreempt.** jenkins (priority 150) reclaims the VIP
automatically when it recovers after a failover to srv-deploy-eng
(priority 100). Deliberate tradeoff: this causes a brief *second*
failover event on jenkins' recovery (traffic moves back from
srv-deploy-eng to jenkins) rather than leaving the VIP wherever it landed
until that node also fails. Chosen for predictability — the VIP's
location always reflects the preferred node's health rather than failover
history.

**Failover trigger is HAProxy health, not Patroni role.** The
`chk_haproxy` vrrp_script checks local HAProxy's systemd status and stats
port reachability — it does not check Patroni's primary/replica state.
HAProxy already abstracts Patroni role away (routing writes to whichever
node is primary via its own health checks), so the VIP only needs to
track "is there a healthy HAProxy to route through here."

## Swap disable and overcommit override

kubeadm requires swap disabled on all nodes — flagged as outstanding since
Phase 1. Resolved on both hosts during Phase 3 work.

**srv-deploy-eng:** required overriding Autobase's own
`vm.overcommit_memory=2` (set in `/etc/sysctl.d/autobase.sysctl.conf`) via
a new `/etc/sysctl.d/zz-local-overrides.conf` setting
`vm.overcommit_memory=1`. Filename prefix matters — `sysctl.d` loads in
strict lexical order, and `zz-` must sort after `autobase.sysctl.conf`
(starts with `a`) to actually take effect; a first attempt using `99-`
failed silently because digits sort before letters in ASCII.

**Live incident during this fix (srv-deploy-eng):** strict overcommit +
no swap left insufficient headroom, causing `sshd` to fail forking new
connections (`error: fork: Cannot allocate memory`) and reject all new SSH
sessions instantly. No processes were OOM-killed (confirmed via
`dmesg`/`journalctl` — `sshd` just couldn't fork, wasn't killed by the
kernel), and Patroni/PostgreSQL were unaffected throughout (confirmed
healthy via `patronictl list`, zero replication lag, the entire time).
Recovered via the Proxmox console (out-of-band, bypasses SSH/network
entirely) — log in as the regular OS user, not `ansible_svc` (password
login is deliberately locked on that account).

**Contributing factor:** `netdata` and a long-unhealthy `cadvisor` Docker
container were consuming ~1.1GB of real committed memory on
srv-deploy-eng — well beyond the "negligible cost" assumption noted in
Phase 1's `group_vars/all.yml` comment (since corrected there). Stopping
these before running `swapoff` avoided repeating the crisis.

**jenkins:** swap disabled (fstab entry commented out) and confirmed via
`swapon --show` returning empty. Given jenkins' larger RAM allocation
(11.68GB vs. srv-deploy-eng's 7.75GB), the same overcommit override was
not required there, but headroom (`Committed_AS` vs `CommitLimit` in
`/proc/meminfo`) should still be periodically confirmed rather than
assumed safe indefinitely.

**Recommendation for repeating this elsewhere:** check for and stop any
`netdata`/unhealthy `cadvisor` containers, and check `Committed_AS` vs
`CommitLimit` headroom, *before* running `swapoff -a` — not after.

**Longer-term consideration (not yet done):** increasing srv-deploy-eng's
RAM allocation in Proxmox (7.8GB is tight for co-hosting K8s control plane
+ Patroni + PostgreSQL + Docker-tooling simultaneously) would allow strict
overcommit (`2`) to be restored safely, rather than relying on the
heuristic-overcommit (`1`) workaround — which trades "safe allocation
refusal" for "OOM-kill risk under real load" on a control-plane node.

## Known issues / non-obvious dependencies

**HAProxy `bind_address` had to be patched separately from Postgres.**
`bind_address` is pinned per-node in `inventory` (e.g. `192.168.20.180`)
to resolve Flannel CNI virtual interface auto-detection breaking
Postgres/Patroni TLS SANs and `pg_hba.conf` rules (see Phase 1). Autobase's
HAProxy role reuses that same variable for every `bind` line in
`haproxy.cfg` — but HAProxy has no TLS-SAN or `pg_hba` identity concern
the way Postgres does. Pinning HAProxy to a single real IP silently broke
VIP-routed traffic: packets addressed to the VIP never matched a socket
bound only to the node's own address, so the VIP could move correctly
between nodes while nothing was actually listening on it.

Fixed via a new role, `roles/haproxy_vip_bind/`, run as a separate
post-deploy playbook (`haproxy-vip-bind.yml`) that rewrites all five
HAProxy listener binds (`stats`, `master`, `replicas`, `replicas_sync`,
`replicas_async`) from `bind_address` to `0.0.0.0`, validated against
HAProxy's own config checker before the file is overwritten.

**CRITICAL — not set-and-forget.** Any future re-run of the Autobase
playbook (`autobase/automation:2.8.0`) re-renders `haproxy.cfg` from its
own internal template using the pinned `bind_address` again, silently
reverting this patch with no warning. `haproxy-vip-bind.yml` MUST be
re-run after any Autobase playbook run that touches HAProxy config. Not
currently automated/chained — a manual step.

**`host_vars/` files are named by inventory IP, not hostname.** Ansible's
`host_vars/<name>.yml` auto-load only matches the literal inventory host
identifier — in this project's `inventory`, that's the IP
(`192.168.20.177`, `192.168.20.180`), not the `hostname=` custom variable
set alongside it. Files must be named `host_vars/192.168.20.177.yml` and
`host_vars/192.168.20.180.yml`, not `host_vars/jenkins.yml` /
`host_vars/srv-deploy-eng.yml` — the latter silently fails to load with
no error, leaving all `keepalived_*` variables undefined.

**Native (non-Docker) `ansible-playbook` runs require SSH keys symlinked
into `/root/.ssh/`.** `inventory` hardcodes
`ansible_ssh_private_key_file=/root/.ssh/ansible_<node>_key` for both
hosts. Phase 1/2 only ever worked because the `autobase/automation:2.8.0`
Docker wrapper mounts the real keys (which live under
`/home/srv-deploy-eng/.ssh/`) into the container's `/root/.ssh/`
automatically. Native playbook runs — required for `keepalived.yml`,
`haproxy-vip-bind.yml`, and (as of the addendum below) `webapp_postgres.yml`
— need the real keys symlinked manually:

```bash
sudo mkdir -p /root/.ssh
sudo ln -s /home/srv-deploy-eng/.ssh/ansible_srv_deploy_eng_key /root/.ssh/ansible_srv_deploy_eng_key
sudo ln -s /home/srv-deploy-eng/.ssh/ansible_jenkins_key /root/.ssh/ansible_jenkins_key
sudo chmod 700 /root/.ssh
```

Because `/root/.ssh/` is only readable by root, `ansible-playbook` must
also be invoked with `sudo` for any play that connects over SSH using
these keys — running as a non-root user gets a misleading `no such
identity: ... Permission denied` even though the symlink and target both
exist and are correctly named. See the addendum below for where this bit
in practice.

**Kubernetes RBAC — `system:node` ClusterRoleBinding found with no
subjects.** Unrelated to Keepalived itself, but discovered and fixed
during Phase 3 work: jenkins was missing from `kubectl get nodes` despite
a healthy, correctly-authenticating kubelet. Root cause: the
`system:node` ClusterRoleBinding had no subjects bound (should bind the
`system:nodes` group) — the same failure class as an earlier
`kubeadm:cluster-admins` binding issue. Without a subject, no node can
self-register or update status via that binding. Fixed via:

```bash
kubectl patch clusterrolebinding system:node --type='json' \
  -p='[{"op":"add","path":"/subjects","value":[{"kind":"Group","name":"system:nodes","apiGroup":"rbac.authorization.k8s.io"}]}]'
```

Root cause of why either binding lost its subjects was not determined for
either occurrence — worth a postmortem note if it recurs a third time.
Confirmed via `kubectl get clusterrolebinding -o custom-columns=...` that
no other bindings are currently in the same empty-subjects state.

## Deployment

Two separate playbooks, run natively (not through the Docker wrapper —
neither role is part of the pinned Autobase image):

```bash
sudo ansible-playbook keepalived.yml -i inventory
sudo ansible-playbook haproxy-vip-bind.yml -i inventory
```

Recommended: dry-run first with `--check --diff` for both.

## Verification (confirmed working)

- `chk_haproxy` succeeds on both nodes (checked against `bind_address`,
  not `127.0.0.1` — HAProxy does not bind to loopback)
- VIP correctly held by jenkins at rest (`ip addr show ens18` shows
  `192.168.20.190` as a secondary address); correctly migrated to
  srv-deploy-eng when jenkins' keepalived service was stopped and back to
  jenkins on restart (preempt)
- `keepalived` starts cleanly on both nodes with no `Unknown keyword` or
  `SECURITY VIOLATION` warnings (`enable_script_security` set correctly
  in `global_defs`)
- All five HAProxy listeners reachable through the VIP:
  - `stats` (`curl` → `200`)
  - `replicas` / `replicas_sync` / `replicas_async` (`nc -zv` TCP connect
    succeeds on all three)
  - `master` — end-to-end proof via `psql -h 192.168.20.190 -p 5000 -U
    postgres -d postgres -c "SELECT pg_is_in_recovery();"` returning `f`,
    confirming write traffic actually reaches the current primary through
    the VIP, not just that the port is open

## Not yet tested

- Actual failover behavior under a live HAProxy or Postgres node failure
  induced deliberately (VIP migration has only been confirmed via
  stopping/restarting the keepalived service directly, not via a full
  simulated node failure)
- Interaction with the Phase 2 failover test plan (above) — Test 3's
  Phase 3 addendum (repeating the HAProxy-instance-down scenario against
  the VIP) has not yet been executed
- Behavior during a live `patronictl switchover` combined with VIP
  routing simultaneously

## On the horizon

- Execute the Phase 2 failover test plan in full, including the Phase 3
  addendum to Test 3
- Confirm/repeat srv-deploy-eng's overcommit headroom check on jenkins
  periodically rather than treating it as permanently settled
- Consider increasing srv-deploy-eng's Proxmox RAM allocation to restore
  strict overcommit (`vm.overcommit_memory=2`) safely

---
---

# Phase 3 addendum — Generalizing `webapp_postgres` for multi-module apps

## Origin

`webapp_postgres` was originally written for a single consumer: the
`app-framework` repo's `equipment` module, and only ever provisioned one
hardcoded table (`webapp_postgres_table_name: equipment`). As
app-framework grew a second consumer app (a store PoS build on the same
framework) with its own modules (`product`, `sale`, `sale_item`, plus
`assignment` from the original app), every new module required manually
repeating the same three steps by hand: apply that module's `schema.sql`
as the Postgres superuser, `GRANT` `webapp_app` scoped privileges on the
new table, `GRANT USAGE` on its `id` sequence. This toil scales linearly
with module count and was flagged as worth fixing once the second/third
manual round confirmed the pattern.

## What changed

`webapp_postgres_table_name` (a single hardcoded table name) is gone.
The role now discovers **every** `modules/<name>/schema.sql` under a
configured `webapp_postgres_modules_dir`, the same directory-scan
principle app-framework's own `app.py` and `setup.py` already use for
backend registration and schema sync — adding a module to the app
requires no change to this role, the same way it requires no change to
`app.py`.

For each discovered module (skipping `_template`, matched by folder name
the same way `app.py`/`scaffold.py` skip it):
1. Read the table name out of that module's `table.json` (not
   hand-repeated in Ansible — `table.json` is already the single source
   of truth for that value, per app-framework's own README).
2. Apply `schema.sql` only if the table doesn't already exist (same
   idempotency guarantee the original single-table version had).
3. `GRANT SELECT, INSERT, UPDATE, DELETE` to `webapp_app` on the table.
4. `GRANT USAGE, SELECT` to `webapp_app` on `<table>_id_seq`.

`webapp_postgres.yml`'s `hosts:`/`connection:` also changed, and this is
the part most likely to trip up a future re-run — see below.

## Why the play now targets `jenkins` over SSH instead of `localhost`

The original role assumed the Ansible control node and the app-framework
checkout (`modules/`) lived on the same machine — true for the
single-table `equipment` case, since `webapp_postgres.yml` originally ran
with `hosts: localhost, connection: local`. That assumption doesn't hold
here: the Ansible control node is `srv-deploy-eng`, but the app-framework
checkout (and the running app itself) is on `jenkins`, per `inventory`.
`hosts: localhost` always meant "wherever `ansible-playbook` is invoked
from," which is `srv-deploy-eng` — not where `modules/` lives.

Fixed by pointing `webapp_postgres.yml` at `jenkins` (`192.168.20.177`)
directly, matching how `host_vars/` files are already keyed by IP rather
than hostname elsewhere in this project (see the `host_vars/` note
above). This has one real consequence: `ansible.builtin.find` (module,
runs on the target host) was already fine, but the two `table.json`/
`schema.sql` file reads had to change from `lookup('file', ...)` to
`slurp` + `b64decode` — `lookup()` plugins always execute on the
controller regardless of a play's `hosts:`, so they silently read from
the wrong machine once the target stopped being `localhost`. `slurp` is
a proper module and runs on whichever host the play targets, which is
what's actually needed here.

## Prerequisites (in addition to Phase 1's `ansible_svc`/SSH-key setup)

- **`python3-psycopg2` on `jenkins`.** The `community.postgresql.*`
  tasks now execute on `jenkins`, not the controller, so the Python
  driver needs to be installed there:
  ```bash
  ssh -i ~/.ssh/ansible_jenkins_key ansible_svc@192.168.20.177 \
    "python3 -c 'import psycopg2' || sudo apt-get install -y python3-psycopg2"
  ```
- **`ansible_jenkins_key` symlinked into `/root/.ssh/`** — same
  requirement as `keepalived.yml`/`haproxy-vip-bind.yml`, see the
  Phase 3 known-issues note above. If already done for those two
  playbooks, no further action needed.
- **Run with `sudo`.** Because the symlinked key lives under
  `/root/.ssh/`, invoking `ansible-playbook` as a non-root user fails
  with a misleading `no such identity: ... Permission denied` even
  though the key exists and is correctly symlinked — the error is a
  read-permission problem on `/root/.ssh/`, not a missing-file problem.
  Always run this playbook (and the other two native playbooks) with
  `sudo`.

## Running it

```bash
sudo ansible-playbook webapp_postgres.yml -i inventory -e @webapp_postgres_secrets.yml
```

Re-running after every table already exists is a safe no-op — expect
`changed=0` across every module's grant/apply tasks, since the grants
themselves are idempotent and the schema-apply step only fires when a
table is genuinely absent. This was confirmed directly: after manually
applying `product`/`sale`/`sale_item` by hand (before this addendum
existed) and then running the generalized role, the result was
`changed=0` for all five modules (`equipment`, `assignment`, `product`,
`sale`, `sale_item`), proving the automated path reproduces the same end
state the manual `psql -f` + `GRANT` steps had already produced.

## What this doesn't cover

Generating `table_core.py` (app-framework's `sync_tables.py
--module=<name>`) is still a separate step, run against the app's Docker
container — that was never part of this role even for the original
single-table `equipment` case, so it's an unchanged gap, not a new one
introduced by this addendum. A new module still needs both: this role
for schema + grants, and `sync_tables.py` (directly, or via
app-framework's own `setup.py`) for the generated Python table object.

---
---

# Phase 3 addendum 2 — One-command provisioning script

## Origin

Even with the generalized role above, provisioning a fresh clone of this
repo still meant: manually symlinking SSH keys into `/root/.ssh/`,
confirming `python3-psycopg2` on `jenkins`, hand-writing
`webapp_postgres_secrets.yml`, and remembering the exact
`sudo ansible-playbook ... -e @secrets -e webapp_postgres_vip=... ...`
invocation with every override flag. All manual, all steps this README
already documented as prerequisites — worth automating into one script
now that they're well understood, so a fresh clone is genuinely
`git clone` -> fill in one config file -> run one script, no command
memorization needed.

## `scripts/setup.sh` and `scripts/config.env`

`scripts/config.env.example` is the template; copy it to
`scripts/config.env` (gitignored — holds the real superuser password)
and fill in real values: `WEBAPP_SUPERUSER_PASSWORD`, `WEBAPP_VIP`/
`WEBAPP_VIP_PORT`, `WEBAPP_DB_NAME`/`WEBAPP_APP_USER`,
`WEBAPP_MODULES_DIR` (app-framework's `modules/` path AS IT EXISTS ON
`TARGET_HOST`, not on this control node), `TARGET_HOST`,
`INVENTORY_PATH`, and both SSH key paths as they exist on this control
node's real home directory.

`scripts/setup.sh`, run as `sudo` (same reason `ansible-playbook` itself
needs `sudo` here — see the SSH-key note above), then: symlinks both
keys into `/root/.ssh/` if not already present (idempotent — safe to
re-run), checks for `python3-psycopg2` on `TARGET_HOST` via an ad-hoc
`ansible ... -m command` probe and installs it via `apt` if missing,
writes `webapp_postgres_secrets.yml` from the config file's password
(overwriting any previous copy), and runs `webapp_postgres.yml` with
every relevant variable passed as `-e`, sourced from `config.env` rather
than hardcoded in the script itself.

Usage, end to end:
```bash
git clone <this repo> && cd autobase-postgresql
cp scripts/config.env.example scripts/config.env
nano scripts/config.env   # fill in real values
sudo scripts/setup.sh
```

## `.gitignore` additions

```gitignore
webapp_postgres_secrets.yml
.secrets/
scripts/config.env
```

`scripts/config.env.example` (no real secrets, just placeholders) IS
committed — only the filled-in copy is ignored.

---
---

# Phase 3 addendum 3 — Dropping `product.stock_quantity`'s lower-bound CHECK

## Origin

The companion `app-framework` repo added an "override" checkout path (a
cashier confirming physical stock exists despite the system showing
zero or insufficient stock), which requires `product.stock_quantity` to
be allowed to go negative. The column's `CHECK (stock_quantity >= 0)`
constraint unconditionally rejects any UPDATE that would violate it
regardless of what application code decides to permit — so the
constraint itself had to be dropped on the live table before the
application-level override logic could do anything at all. See
app-framework's own README for the full feature; this section covers
only the database-side migration.

## Running it

`drop_stock_check.sql` (committed at this repo's root) looks up the
constraint's actual name dynamically via `pg_constraint` rather than
hardcoding it, since Postgres auto-generates the name and it can vary:

```bash
psql -h 192.168.20.190 -p 5000 -U postgres -d webapp_demo -f drop_stock_check.sql
```

Expect one `NOTICE:  Dropped constraint product_stock_quantity_check`
line and no errors. Safe to re-run — if the constraint is already gone,
it prints a NOTICE saying so instead of erroring.

This is a genuine schema migration against a live table, not something
`webapp_postgres`'s module-discovery role (Phase 3 addendum 1, above)
handles — that role only ever applies a module's `schema.sql` when the
table doesn't exist yet, by design (idempotent create, never an ALTER on
an existing table). Any future schema change to an already-provisioned
table needs its own one-off migration script like this one, run
manually, same as this one was.

**A known trap when writing scripts like this via a shell heredoc**: an
unclosed quote or a mismatched heredoc delimiter can silently swallow
trailing lines into the file being written, producing a file with
garbage appended (a stray shell prompt's own text, an unterminated
`EOF`) that then fails with a confusing SQL syntax error rather than a
shell error. Always `cat` the file back and visually confirm its full
contents end cleanly before running it against a live database.
---
---

# Phase 3 addendum 4 -- Audit columns on the original tables

## Origin

The companion `app-framework` repo added authentication (`app_user`) and
requires every table to record who created and last changed each row:
nullable `created_by` and `updated_by` columns referencing `app_user(id)`.
New tables get them from their `schema.sql`. The six tables that already
existed on the live database (`equipment`, `assignment`, `product`,
`sale`, `sale_item`, `recipe`) need an ALTER, which the `webapp_postgres`
role never performs (it only creates tables that are absent), so this is
a one-off migration of the same category as `drop_stock_check.sql`.

## Running it

```bash
scripts/migrate_audit_columns.sh          # shows the target, asks to confirm
scripts/migrate_audit_columns.sh --yes    # unattended
```

It reads `scripts/config.env` (superuser password, VIP, port, database),
runs `add_audit_columns.sql` as the Postgres superuser through the VIP,
and prints a verification table listing both columns for every migrated
table. No `sudo` is needed; it only requires the `psql` client on
srv-deploy-eng.

Properties:

- Idempotent: columns that already exist are skipped, so re-running after
  success changes nothing.
- A missing table is skipped with a NOTICE; a missing `app_user` aborts
  with a clear error (run `sudo scripts/setup.sh` first).
- Existing rows keep NULL in both columns. They predate authentication and
  have no author; the application treats NULL as "unknown".
- Adding a nullable column without a default is a metadata-only change,
  and the foreign key validates against NULLs, so the locks are brief.
  With `synchronous_mode_strict` the synchronous replica must be healthy
  for the DDL to commit, like any write.

## Order of operations

1. Deploy the app-framework change (the updated `schema.sql` files and
   code). The code is safe before the migration: it only writes the audit
   columns on tables whose generated `table_core.py` lists them.
2. Run `scripts/migrate_audit_columns.sh`.
3. In the app repo, run `python setup.py`: it re-reflects each table into
   `table_core.py` (now including the audit columns) and recreates the
   containers. Commit the regenerated `table_core.py` files.

## Rollback

Dropping the columns discards all attribution recorded since:

```sql
ALTER TABLE <table> DROP COLUMN created_by, DROP COLUMN updated_by;
```

for each of the six tables, then re-run `python setup.py` so the generated
`table_core.py` files stop listing them.

## Fresh-install ordering caveat

Every module's `schema.sql` now references `app_user`, and some already
referenced each other (`assignment` -> `equipment`, `sale_item` -> `sale`
and `product`, `recipe` -> `product`). The `webapp_postgres` role applies
schemas in the order `find` returns them, which is not a dependency order.
Applying to an empty database can therefore fail depending on that order.
Existing deployments are unaffected (every table already exists). Making
the role apply schemas in dependency order is tracked as follow-up work.
