# Alerting Runbook

**Stack:** Prometheus (rules + scrape) → Alertmanager (routing) → Resend SMTP (email) + optional Twilio webhook (SMS).

**Coverage:** 9 alert rules across 6 services (api, streams, db, redis, minio, host) + 1 placeholder for backup-stale (Week 3 follow-up).

**Routing:** `severity=critical` → email + SMS webhook (if configured); `severity=warning` → email only. Critical inhibits its own warning duplicate via `inhibit_rules`. Group by `(alertname, cluster, service)` so a 10-alert burst arrives as one notification.

---

## 1. What's running

| Service | Image | Purpose |
|---|---|---|
| `platform-prometheus` | `prom/prometheus:v2.52.0` | Scrapes targets, evaluates `infra/prometheus/rules/*.yml`, fires to alertmanager |
| `platform-alertmanager` | `platform-alertmanager:latest` (built from `services/alertmanager/`) | Routes + dedupes + notifies. envsubst shim renders SMTP creds into the config |
| `postgres-exporter-platform` | `prometheuscommunity/postgres-exporter:v0.15.0` | Exposes `pg_stat_*` for platform-postgres |
| `postgres-exporter-keycloak` | same | for platform-keycloak-postgres |
| `redis-exporter` | `oliver006/redis_exporter:v1.61.0` | Exposes `redis_*` + per-stream length / group lag |
| `cadvisor` | `gcr.io/cadvisor/cadvisor:v0.49.1` | Per-container CPU/memory/OOM/fs metrics — needs docker socket |
| `platform-otel-collector` | already running | Cue API metrics ship here via OTLP → exposed on `:8889` for Prometheus |
| `platform-grafana` | already running | Renders `infra/grafana/dashboards/*.json` (now properly mounted) |

The OTel collector is the existing path for Cue API metrics; nothing changes there.

---

## 2. The 9 alert rules (and what each one means)

All rules live in `infra/prometheus/rules/alerts.yml`. Labels: `severity` (`critical` | `warning`) and `service` (`api` | `streams` | `db` | `redis` | `minio` | `host`).

| Alert | Severity | Threshold | What it means |
|---|---|---|---|
| `APIHighErrorRate` | critical | 5xx rate > 2% for 5m | Real users seeing failures; check OTel traces and `make logs-api` |
| `DLQNonEmpty` | warning | any DLQ has ≥ 1 message for 5m | An agent failed past `MAX_RETRIES=3`. Replay/discard via `/admin/dlq/*` |
| `StreamConsumerLagHigh` | warning | PEL > 100 for 10m | Workers slow but moving; check the specific consumer group |
| `StreamConsumerLagCritical` | critical | PEL > 1000 for 5m | Pipeline backpressure; agent crash loop or LiteLLM saturation likely |
| `PostgresHighConnections` | warning | > 80% of max_connections for 5m | Pool sizing or query leak; investigate `pg_stat_activity` |
| `PostgresConnectionsCritical` | critical | > 95% of max_connections for 1m | New connections imminent-fail |
| `PostgresDiskHigh` | warning | container fs usage > 85% for 10m | Watch for WAL fill due to failing `archive_command` |
| `PostgresDiskCritical` | critical | > 95% for 2m | If this hits 100%, writes halt |
| `MinIOLowFreeSpace` | warning | free < 15% for 15m | Backups land here; expand or trim retention |
| `RedisMemoryHigh` | warning | used / max > 85% for 10m | Set if `maxmemory` configured |
| `RedisContainerMemoryHigh` | warning | container fs > 85% of cgroup for 10m | Fallback when `maxmemory` unset |
| `ContainerOOMKilled` | critical | any container OOM event in last 5m | Raise memory limit or fix the leak |
| `WALArchiveFailing` | critical | `pg_stat_archiver_failed_count` increased in last 10m | Fix MinIO FIRST; **do NOT restart postgres** until `archived_count` catches up. See `BACKUP_RUNBOOK.md` §7 |
| `WALArchiveStale` | warning | `pg_stat_archiver_last_archive_age > 5m` for 5m | archive_command silently broken even if failed_count is 0 |

### Placeholder: backup-stale

The "alert if last successful pg_dump > 25h" rule is defined in `alerts.yml` but the rule group is empty. It needs a metric source — proposed approaches:

1. `backup.sh` sets a Redis key `platform:backup:last_success` to the unix timestamp; configure `redis_exporter` `REDIS_EXPORTER_CHECK_KEYS=platform:backup:last_success`; alert on `time() - redis_key_value{key=~".*last_success"} > 25*3600`.
2. Add a Prometheus pushgateway and have `backup.sh` push a counter.

Option 1 is lighter — added in a Week 3 follow-up.

---

## 3. Operator tasks

### Check what's firing right now

```bash
make alerts-status     # /api/v1/alerts JSON from Prometheus
```

Or open the Prometheus UI at `http://<host>:9091/alerts` and the Alertmanager UI at `http://<host>:9094`.

### Inspect rule definitions live

```bash
make alerts-rules      # all rule groups + current thresholds
```

### Reload rules after editing `alerts.yml`

```bash
make alerts-reload     # hits prometheus /-/reload — no restart needed
```

### Reload Alertmanager after editing the template

```bash
make alerts-am-reload  # restarts the container so envsubst re-runs
```

### Silence a noisy alert for an hour

```bash
make alerts-silence ALERT=APIHighErrorRate
```

Silences are visible in the Alertmanager UI and can be extended/deleted there.

### Fire a synthetic test alert

```bash
make alerts-test
```

POSTs a `TestAlert` directly into Alertmanager's API. If routing works end-to-end you should get an email within 30s. Useful right after rotating SMTP creds.

---

## 4. SMS routing (Twilio bridge)

SMS is optional. Email-only is enough for zero-user scale; turn on SMS once you have on-call rotation.

The Alertmanager `page` receiver POSTs a JSON alert payload to `ALERTS_SMS_WEBHOOK_URL`. There are two reasonable bridges:

### Option A: extend platform-mcp (preferred — already does SMS via Twilio)

Add an `/alerts/sms` endpoint to `services/mcp/app/` that accepts the Alertmanager webhook payload, formats a short message ("[CRITICAL] {alertname} on {cluster}: {summary}"), and calls Twilio. Skeleton:

```python
@router.post("/alerts/sms")
async def alerts_sms(payload: dict):
    for alert in payload.get("alerts", []):
        msg = f"[{alert['labels']['severity'].upper()}] {alert['labels']['alertname']}: {alert['annotations']['summary']}"
        await send_sms(to=settings.ONCALL_PHONE, body=msg[:160])
    return {"ok": True}
```

Then set `ALERTS_SMS_WEBHOOK_URL=http://platform-mcp:8080/alerts/sms` in `.env.production` and re-encrypt.

### Option B: tiny sidecar

A 20-line Python/Go service that does only the Twilio bridge. Simpler to reason about but yet-another-service. Useful if MCP becomes user-data sensitive and you want to keep ops out.

The runbook's job is to flag both — actual implementation is the operator's call. Leave `ALERTS_SMS_WEBHOOK_URL=` blank in `.env` to disable SMS gracefully.

---

## 5. Dashboards

Three JSONs in `infra/grafana/dashboards/` are provisioned automatically (every 30s reload, see `infra/grafana/provisioning/dashboards/dashboards.yaml`):

| File | UID | Covers |
|---|---|---|
| `api-health.json` | `cue-api-health` | req rate, 5xx rate, p50/p95/p99 latency, in-flight, firing alerts |
| `stream-pipeline.json` | `cue-stream-pipeline` | total DLQ, per-stream length, per-group PEL, totals |
| `db-redis-health.json` | `cue-db-redis-health` | PG conn / max, WAL archived vs failed, db size, redis mem + ops, MinIO disk free |

Open at `http://<host>:3002` (or whatever `PLATFORM_GRAFANA_PORT` is). Default admin password is in `PLATFORM_GRAFANA_ADMIN_PASSWORD`.

---

## 6. What's NOT covered yet

- **Backup-stale alert.** Placeholder rule group; needs a `last_success` metric source (Redis key + `REDIS_EXPORTER_CHECK_KEYS` is the lightest path).
- **OTel metric naming verification.** Rules assume `http_server_duration_*` for FastAPI HTTP metrics. If the OTel collector renames these (e.g. `http_server_request_duration_seconds_*`), the `APIHighErrorRate` rule needs adjustment. **Do this verification on first deploy: `curl http://platform-otel-collector:8889/metrics | grep http_server`.** If the metric name differs, edit `alerts.yml` and `api-health.json`, then `make alerts-reload`.
- **External uptime monitor.** Internal alerts can't tell you the host is unreachable. Deferred to post-launch per plan §7.
- **PagerDuty / Opsgenie.** Plan §5 explicitly skips these at current scale — email + SMS is enough.
- **Inhibit on backup window.** During the 02:00 / 03:00 UTC backup hour, IO load can produce false-positive latency/connection spikes. If you see this pattern in the first week, add `time_intervals` + a route mute_time during the window.

---

## 7. Pre-launch verification checklist

Don't ship without ticking these:

- [ ] All exporters healthy: `make alerts-rules` shows non-empty rule groups; `http://<host>:9091/targets` is all green.
- [ ] OTel metric names verified (see §6 above) — `APIHighErrorRate` rule references real metric names.
- [ ] `make alerts-test` delivered an email to the address in `ALERTS_TO_EMAIL`.
- [ ] If SMS configured: `make alerts-test` with `severity=critical` payload delivered an SMS.
- [ ] All 3 dashboards render in Grafana with non-empty data: `cue-api-health`, `cue-stream-pipeline`, `cue-db-redis-health`.
- [ ] Synthetic disk-fill test: fill the postgres volume to > 85% and confirm `PostgresDiskHigh` fires within 10m (use a scratch container; don't actually fill prod).
- [ ] Synthetic WAL-fail test: temporarily set `WALG_S3_PREFIX=s3://nonexistent-bucket/` on platform-postgres and confirm `WALArchiveFailing` fires within 10m, then restore the prefix. (See `BACKUP_RUNBOOK.md` §7 for the mitigation playbook.)
- [ ] Operator knows the silence procedure: `make alerts-silence ALERT=<name>`.
