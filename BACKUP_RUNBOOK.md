# Backup Runbook

**Scope:** logical Postgres backups for the three platform DBs (`cue`, `litellm`, `keycloak`), streamed nightly to platform-infra MinIO.

**RPO** under this design: **24 hours** (between nightly snapshots), assuming the latest snapshot is recoverable.
**RTO** for a single-DB cold restore: **5–15 minutes** depending on dump size (see drill numbers below once you run one).

**Caveat:** MinIO runs on the same Hetzner host as Postgres. This protects against logical errors (`DROP TABLE`, bad migration, accidental delete) but **not host failure**. If the disk goes, both Postgres and the backups go. Same-host was the accepted Week 2 trade-off (see `PRODUCTION_LAUNCH_PLAN.md` §7); revisit an off-host mirror (Backblaze B2 ~$5/mo/TB) once first user data is on file.

---

## 1. What's running

`docker-compose.yml` service `platform-backup` (image built from `services/backup/`):

| Item | Value |
|---|---|
| Schedule | `0 3 * * *` UTC (03:00 UTC nightly) |
| Trigger | crond inside the container, fires `backup.sh` |
| Source | `platform-postgres` (DBs: `cue`, `litellm`) + `platform-keycloak-postgres` (DB: `keycloak`) |
| Destination | `s3://platform-backups/postgres/{server}/{db}/{ts}.dump` on `platform-minio:9000` |
| Format | `pg_dump --format=custom --compress=9 --no-owner --no-acl` (restorable with `pg_restore`) |
| Transport | `mc pipe` — no local disk I/O on the backup container |
| Retention | 7 days — enforced by MinIO bucket lifecycle (`mc ilm rule add --expire-days 7 --prefix postgres/`) |
| Boot behavior | Runs one backup at container start (`BACKUP_RUN_ON_START=true`) so a fresh stack has something to restore |

Override via env: `BACKUP_BUCKET`, `BACKUP_RETENTION_DAYS`, `BACKUP_RUN_ON_START`.

---

## 2. Common operator tasks

### Trigger an on-demand backup

```bash
make backup-now
```

Useful before a risky migration or right after a manual data fix.

### List what's currently backed up

```bash
make backup-list
```

Shows every object in `platform-backups/postgres/`. Names sort lexicographically, so `tail` gives the newest.

### Inspect the most recent cron run

```bash
make backup-logs
```

A successful run ends with `all backups OK (3 dumps to s3://platform-backups/)`. A partial failure exits non-zero — investigate the `FAIL` line for the failing DB.

### Run a restore drill (read-only — does NOT touch production)

```bash
make restore-drill DB=cue        # or DB=litellm, DB=keycloak
```

Pulls the latest dump, spins up a scratch `postgres:16-alpine` on the platform network, restores into it, runs `count(*)` probes on a small set of canonical tables, and tears down. Run this **at least once before launch** and time it.

Expected output on success ends with `OK — restore drill for {db} passed`.

---

## 3. Actually-restore-production procedure (the real thing)

This is the runbook for "the cue DB is corrupted, restore from last night's dump".

### Pre-flight (safety)

1. **Take the API offline first** so no new writes happen while you're restoring.
   ```bash
   # In the Cue repo on the Hetzner host:
   cd /opt/Cue && docker compose stop api ai-orchestrator
   ```
2. **Snapshot the current (corrupted) DB before destroying it** — never roll forward without a fallback.
   ```bash
   docker compose exec platform-backup bash -c '
     PGPASSWORD="$PLATFORM_PG_SUPERPASSWORD" pg_dump \
       -h platform-postgres -U "$PLATFORM_PG_SUPERUSER" -d cue \
       --format=custom --compress=9 \
       | mc pipe platform/platform-backups/postgres/pre-restore-snapshots/cue-$(date -u +%Y-%m-%dT%H-%M-%SZ).dump
   '
   ```

### Restore

3. **Identify the dump you want.** Default is "latest":
   ```bash
   make backup-list | tail -20
   ```

4. **Drop and recreate the target DB.** `pg_restore` into a dirty DB merges, which is almost never what you want.
   ```bash
   docker compose exec platform-postgres bash -c '
     psql -U "$POSTGRES_USER" -d postgres -c "DROP DATABASE cue;" &&
     psql -U "$POSTGRES_USER" -d postgres -c "CREATE DATABASE cue;"
   '
   ```

5. **Stream the dump from MinIO into pg_restore.**
   ```bash
   SNAP="postgres/platform-postgres/cue/2026-06-09T03-00-00Z.dump"  # adjust
   docker compose exec -T platform-backup mc cat "platform/platform-backups/${SNAP}" \
     | docker compose exec -T platform-postgres pg_restore \
         -U "$PLATFORM_PG_SUPERUSER" -d cue --no-owner --no-acl -j 4 -v
   ```

6. **Sanity-check the restore.**
   ```bash
   docker compose exec platform-postgres psql -U "$PLATFORM_PG_SUPERUSER" -d cue \
     -c "SELECT count(*) FROM users; SELECT count(*) FROM tasks; SELECT max(created_at) FROM audit_logs;"
   ```

7. **Bring Cue back up.**
   ```bash
   cd /opt/Cue && docker compose start api ai-orchestrator
   ```

8. **Tell the team what the data window is** — anything written between the snapshot time (step 3) and now is gone. Audit-log it.

### Restoring keycloak or litellm

Same procedure, just substitute the server (`platform-keycloak-postgres` for keycloak) and the DB name. Keycloak has its own DB on its own server — don't confuse the two.

---

## 4. Failure modes & how you'd notice

| Symptom | What's actually wrong | Fix |
|---|---|---|
| `make backup-logs` shows `MinIO alias 'platform' not reachable` | platform-minio is down OR `PLATFORM_MINIO_ROOT_*` env didn't make it in | `docker compose restart platform-minio platform-backup`; check `.env.production` has both root vars |
| `FAIL platform-postgres/cue` | pg_dump can't connect — wrong superuser password (post-rotation) | Confirm `PLATFORM_PG_SUPERPASSWORD` matches what the DB has; restart `platform-backup` so entrypoint re-exports |
| `mc ilm rule add` failed silently and dumps from 30 days ago still exist | Lifecycle rule didn't stick at first boot | `docker compose exec platform-backup mc ilm rule add --expire-days 7 --prefix postgres/ platform/platform-backups` |
| Restore drill says `MISSING` for a probe table | Schema drifted; the canonical probes in `restore-drill.sh` no longer match the live schema | Update the `probes=(...)` array for that DB; don't ignore — a probe miss can mask a partial restore |
| Backup container restart-loops | `entrypoint.sh` env guard tripped on a missing var | `docker compose logs platform-backup` will show which `:?required` fired |

---

## 5. WAL archiving + PITR (the second layer)

**RPO under WAL:** ~60 seconds on idle clusters (`archive_timeout=60s`), sub-second under write load (each transaction commit flushes WAL).
**RTO for PITR:** ~3–10 minutes depending on how much WAL has to replay since the last base backup.

### What's running

Both `platform-postgres` and `platform-keycloak-postgres` are built from `services/postgres/Dockerfile` — `pgvector/pgvector:pg16` extended with the `wal-g` binary, a cron daemon, and a custom entrypoint that snapshots wal-g env into `/etc/wal-g.env` (cron strips env).

| Item | Value |
|---|---|
| Continuous WAL push | `archive_command='wal-g wal-push %p'` (compose `command:` arg) |
| WAL flush cadence | `archive_timeout=60s` — every minute on idle, every commit under load |
| Base backups | Weekly: Sunday 02:00 UTC, fired by cron in each PG container (`services/postgres/wal-g.cron` → `base-backup.sh`) |
| Base backup retention | Last 4 full backups (`wal-g delete retain FULL 4 --confirm`). wal-g auto-trims orphaned WAL older than the oldest retained base. |
| MinIO prefixes | `s3://platform-backups/wal-g/platform-postgres/` and `…/platform-keycloak-postgres/` — kept separate from `postgres/` (logical dumps) so the two retention systems don't interfere |
| Restore command | `restore_command='wal-g wal-fetch %f %p'` — used during recovery |

The wal-g and logical-dump systems are **complementary**, not redundant:
- Logical dumps are easy to inspect, partially restore (one table), and grep for sensitive data leaks.
- WAL gives PITR — the ability to roll forward to a precise moment, which logical dumps can't.

### On-demand base backup (before a risky migration)

```bash
make wal-base-backup                # platform-postgres
make wal-base-backup-keycloak       # platform-keycloak-postgres
```

Each invokes `docker compose exec <pg-container> /opt/wal-g/base-backup.sh`. Tail `make wal-logs` to watch progress.

### Inspect WAL archiver health

```bash
make wal-status
```

Runs `SELECT * FROM pg_stat_archiver;` against both PG servers. Key signals:
- `archived_count` rising = archive_command is working.
- `failed_count > 0` = archive_command is failing — **this WILL fill the disk** if not fixed. WAL piles up locally because Postgres won't recycle archived segments. Investigate `last_failed_wal` / `last_failed_time`.
- `last_archived_time` more than 5 min stale on a write-active cluster = something is wrong.

### Run the WAL/PITR drill

```bash
make wal-restore-drill                                  # platform-postgres, recover to LATEST
make wal-restore-drill CLUSTER=keycloak                 # platform-keycloak-postgres
make wal-restore-drill CLUSTER=postgres PITR="2026-06-09 12:00:00 UTC"
```

This spins up a scratch container with an empty data dir, `wal-g backup-fetch LATEST` into PGDATA, writes `recovery.signal` + `restore_command`, starts postgres in recovery mode, waits for `pg_is_in_recovery() = f`, then runs canonical row-count probes. Expected output ends with `OK — WAL/PITR drill for {cluster} passed`.

### Actually-restore-production with PITR

This is the runbook for "an admin ran `DELETE FROM tasks` at 11:34 AM and we need to roll the cue DB back to 11:33".

1. **Stop writers.** API and ai-orchestrator must be down or paused so no new WAL is generated against the cluster you're about to roll back.
2. **Identify the PITR target.** `2026-06-09 11:33:00 UTC` — be precise; the granularity is finer than a second but rounding to the minute is usually safe.
3. **Decide where to roll back to.** Two options:
   - **In-place restore over the existing data dir.** Risky — if recovery fails partway, you may not be able to roll back further. Take a manual `pg_dump` snapshot first.
   - **Side-by-side restore in a new container, then swap.** Safer. Bring up `platform-postgres-restored` from the same image, point it at the same MinIO bucket, recover, validate, then re-point clients.
4. **Stop the live container** (only if doing in-place):
   ```bash
   docker compose stop platform-postgres
   ```
5. **Wipe its data dir** (only if doing in-place — destructive!):
   ```bash
   docker run --rm -v platform-infra_platform_postgres_data:/data alpine sh -c 'rm -rf /data/*'
   ```
6. **Bring it back up with the recovery configuration applied at first boot.** Easiest: temporarily edit `docker-compose.yml` to add a `recovery_target_time` arg, or use `scripts/wal-restore-drill.sh` as a template for a one-shot restore container.
7. **Once `pg_is_in_recovery() = f`, run sanity-check queries**, then point clients back. Anything written between the PITR target and now is gone.

If you don't have a runbook step memorized for this, **run the drill first** in a non-production cluster. `make wal-restore-drill` is exactly this minus the swap.

---

## 6. What's NOT covered yet (next iteration)

- **Off-host mirror.** Same-host MinIO doesn't survive host failure. Accepted trade-off for Week 2; revisit once user data is on file.
- **Backup monitoring.** No alert if cron didn't run, if a base backup is overdue, or if `pg_stat_archiver.failed_count > 0`. Coming in Week 3 alerting.
- **Encrypted backups at rest beyond MinIO's disk encryption.** Both `pg_dump` output and wal-g segments are plaintext to anyone with MinIO root creds. If that becomes a concern, wal-g supports `WALG_LIBSODIUM_KEY` for transparent encryption — easy add later.
- **Dedicated MinIO service account for backups.** Currently using `PLATFORM_MINIO_ROOT_*`. A least-privilege SA scoped to `platform-backups/*` would be cleaner; defer until a multi-tenant access model becomes necessary.

---

## 7. Failure modes specific to WAL

| Symptom | What's actually wrong | Fix |
|---|---|---|
| `pg_stat_archiver.failed_count` climbing | archive_command can't reach MinIO (network, creds, bucket gone) | Check `wal-g wal-push` manually inside the container; fix MinIO; **don't restart postgres yet** — un-archived WAL on disk is your only copy of recent commits. Re-trigger by `SELECT pg_switch_wal();` once MinIO is back. |
| Disk filling on the Postgres volume | archive_command has been failing long enough that WAL accumulated | Same: fix the archive target first; then `pg_switch_wal()` to push the backlog; only after `failed_count` stops rising and `archived_count` catches up should you restart anything. |
| `wal-g backup-push` failed mid-run | Usually MinIO timed out or a large file errored | wal-g is idempotent — re-run. It picks up where it left off. |
| Base backups exist but PITR drill says "no base backup found" | `WALG_S3_PREFIX` mismatch between live cluster and drill | Verify both point at `s3://platform-backups/wal-g/<server>/`. The drill script inherits env from the live container — if it can't, it'll log "could not read wal-g env" and exit. |
| Recovery hangs in the drill | restore_command is failing — usually because the scratch container can't reach MinIO | `docker logs wal-drill-...` will show the wal-g wal-fetch error. Confirm the platform-infra_default network is up and credentials are inherited. |

---

## 8. Pre-launch verification checklist

Don't ship without ticking these:

**Logical dumps:**
- [ ] First nightly cron has fired (check `make backup-logs` the morning after deploy).
- [ ] `make backup-list` shows three dumps from the same night.
- [ ] `make restore-drill DB=cue` exits 0; record the wall-clock time as your measured RTO.
- [ ] `make restore-drill DB=keycloak` exits 0.
- [ ] `make restore-drill DB=litellm` exits 0.
- [ ] Confirmed lifecycle rule active: `docker compose exec platform-backup mc ilm rule list platform/platform-backups`.

**WAL / PITR:**
- [ ] `make wal-status` shows `archived_count > 0` and `failed_count = 0` on both PG servers.
- [ ] At least one base backup landed: `docker compose exec platform-postgres su postgres -c 'wal-g backup-list'` returns a row.
- [ ] `make wal-restore-drill` (default: platform-postgres) exits 0.
- [ ] `make wal-restore-drill CLUSTER=keycloak` exits 0.
- [ ] Disk-fill mitigation rehearsed mentally: if archive_command starts failing, the on-call knows to `SELECT pg_switch_wal();` AFTER fixing MinIO, not restart postgres.
