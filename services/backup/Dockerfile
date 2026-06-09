# =============================================================================
# platform-backup — pg_dump → MinIO via mc, fired by crond
#
# Base: postgres:16-alpine. Matches platform-postgres / platform-keycloak-postgres
# server major so pg_dump version mismatch can't bite us. Adds the MinIO mc
# client and a cron entry that fires backup.sh nightly.
# =============================================================================
ARG POSTGRES_VERSION=16
ARG MC_TAG=RELEASE.2024-11-21T17-21-54Z

# --- mc binary (copy from upstream image) ----------------------------------
FROM minio/mc:${MC_TAG} AS mc

# --- runtime ---------------------------------------------------------------
FROM postgres:${POSTGRES_VERSION}-alpine

RUN apk add --no-cache bash tini ca-certificates tzdata

# mc client for streaming dumps to MinIO without local disk.
COPY --from=mc /usr/bin/mc /usr/local/bin/mc

WORKDIR /opt/backup
COPY backup.sh /opt/backup/backup.sh
COPY entrypoint.sh /opt/backup/entrypoint.sh
COPY crontab /etc/crontabs/root
RUN chmod +x /opt/backup/backup.sh /opt/backup/entrypoint.sh

# Run as root so crond + mc + pg_dump all have access. The container has no
# inbound network surface and is firewalled to the platform network.
ENTRYPOINT ["/sbin/tini", "--", "/opt/backup/entrypoint.sh"]
