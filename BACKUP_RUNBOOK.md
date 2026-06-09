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

## 5. What's NOT covered yet (next iteration)

- **WAL archiving / PITR.** Logical dumps give 24h RPO at best. For finer-grained recovery (point-in-time, sub-hour RPO) we need `wal-g` or `pgBackRest` archiving WAL segments continuously to MinIO. The plan calls for this — deferred to a follow-up commit so the dump cron lands first.
- **Off-host mirror.** Same-host MinIO doesn't survive host failure. Accepted trade-off for Week 2; revisit once user data is on file.
- **Backup monitoring.** No alert if cron didn't run, or if the last dump is older than 25 hours. Coming in Week 3 alerting.
- **Encrypted backups at rest beyond MinIO's disk encryption.** `pg_dump` output is currently plaintext custom-format — anyone with MinIO root creds can read it. If that becomes a concern, pipe through `age` before `mc pipe`.
- **Dedicated MinIO service account for backups.** Currently using `PLATFORM_MINIO_ROOT_*`. A least-privilege SA scoped to `platform-backups/*` would be cleaner; defer until a multi-tenant access model becomes necessary.

---

## 6. Pre-launch verification checklist

Don't ship without ticking these:

- [ ] First nightly cron has fired (check `make backup-logs` the morning after deploy).
- [ ] `make backup-list` shows three dumps from the same night.
- [ ] `make restore-drill DB=cue` exits 0; record the wall-clock time as your measured RTO.
- [ ] `make restore-drill DB=keycloak` exits 0.
- [ ] `make restore-drill DB=litellm` exits 0.
- [ ] Confirmed lifecycle rule active: `docker compose exec platform-backup mc ilm rule list platform/platform-backups`.
