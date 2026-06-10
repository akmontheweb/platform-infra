# =============================================================================
# platform-postgres — pgvector/postgres:16 + wal-g + cron.
#
# Same image used by both platform-postgres (cue + litellm) and
# platform-keycloak-postgres. archive_command pushes every flushed WAL
# segment to MinIO via wal-g; a weekly cron does a full base backup so
# PITR has a recovery starting point.
#
# wal-g config comes from env (compose-set): WALG_S3_PREFIX, AWS_*,
# AWS_ENDPOINT, AWS_S3_FORCE_PATH_STYLE. archive_command runs in postgres'
# process env so it inherits these. The cron-fired base-backup does NOT
# inherit env, so entrypoint dumps the relevant vars to /etc/wal-g.env
# for the cron job to source.
# =============================================================================
ARG PGVECTOR_TAG=pg16
ARG WALG_VERSION=v3.0.8

FROM pgvector/pgvector:${PGVECTOR_TAG}

ARG WALG_VERSION

# wal-g + cron + ca-certificates (needed for MinIO HTTPS in future).
# Cleaning apt lists keeps the image lean.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        ca-certificates \
        cron \
        curl \
        tini \
 && curl -fsSL -o /tmp/wal-g.tar.gz \
        "https://github.com/wal-g/wal-g/releases/download/${WALG_VERSION}/wal-g-pg-22.04-amd64.tar.gz" \
 && tar -xzf /tmp/wal-g.tar.gz -C /usr/local/bin/ \
 && mv /usr/local/bin/wal-g-pg-22.04-amd64 /usr/local/bin/wal-g \
 && chmod 0755 /usr/local/bin/wal-g \
 && rm /tmp/wal-g.tar.gz \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/*

# Base-backup script — fired by cron as the postgres user.
COPY base-backup.sh /opt/wal-g/base-backup.sh
RUN chmod +x /opt/wal-g/base-backup.sh \
 && touch /var/log/wal-g.log \
 && chown postgres:postgres /var/log/wal-g.log

# Cron schedule: Sunday 02:00 UTC weekly base backup + retention sweep.
# 02:00 lands an hour before the nightly logical pg_dump at 03:00 so the
# two backup mechanisms don't fight for IO.
COPY wal-g.cron /etc/cron.d/wal-g-base-backup
RUN chmod 0644 /etc/cron.d/wal-g-base-backup

# Custom entrypoint: dumps wal-g env to a file for cron, starts crond,
# then hands off to the upstream postgres entrypoint.
COPY entrypoint.sh /usr/local/bin/platform-postgres-entrypoint.sh
RUN chmod +x /usr/local/bin/platform-postgres-entrypoint.sh

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/platform-postgres-entrypoint.sh"]
CMD ["postgres"]
