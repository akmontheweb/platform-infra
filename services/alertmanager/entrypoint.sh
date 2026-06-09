#!/usr/bin/env sh
# Render alertmanager.yml.tmpl → alertmanager.yml via envsubst, then exec
# the upstream alertmanager binary with whatever args compose passed.
set -e

TMPL=/etc/alertmanager/alertmanager.yml.tmpl
OUT=/etc/alertmanager/alertmanager.yml

if [ ! -f "${TMPL}" ]; then
  echo "entrypoint: ${TMPL} missing; nothing to render" >&2
  exit 1
fi

# Whitelist only the vars we actually want to substitute. envsubst
# without an explicit list would gobble any ${...} including alertmanager's
# own template syntax inside annotations.
VARS='${SMTP_HOST} ${SMTP_PORT} ${SMTP_USER} ${SMTP_PASSWORD} ${SMTP_FROM} ${ALERTS_TO_EMAIL} ${ALERTS_SMS_WEBHOOK_URL}'

envsubst "${VARS}" < "${TMPL}" > "${OUT}"
chmod 0640 "${OUT}"

exec /bin/alertmanager "$@"
