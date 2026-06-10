#!/usr/bin/env sh
# Render alertmanager.yml.tmpl → alertmanager.yml via sed over an explicit
# allowlist, then exec the upstream alertmanager binary.
#
# Why allowlist: the alertmanager template uses {{ ... }} for its own
# templating; we only want to substitute the env vars we name. Adding a new
# placeholder to the template means adding a corresponding sed expression
# here.
set -e

TMPL=/etc/alertmanager/alertmanager.yml.tmpl
OUT=/etc/alertmanager/alertmanager.yml

if [ ! -f "${TMPL}" ]; then
  echo "entrypoint: ${TMPL} missing; nothing to render" >&2
  exit 1
fi

# Escape sed metacharacters in the replacement string so secrets containing
# &, /, or backslash don't break the substitution or inject sed commands.
_sed_escape() {
  printf '%s' "$1" | sed -e 's/[\/&]/\\&/g'
}

sed \
  -e "s|\${SMTP_HOST}|$(_sed_escape "${SMTP_HOST}")|g" \
  -e "s|\${SMTP_PORT}|$(_sed_escape "${SMTP_PORT}")|g" \
  -e "s|\${SMTP_USER}|$(_sed_escape "${SMTP_USER}")|g" \
  -e "s|\${SMTP_PASSWORD}|$(_sed_escape "${SMTP_PASSWORD}")|g" \
  -e "s|\${SMTP_FROM}|$(_sed_escape "${SMTP_FROM}")|g" \
  -e "s|\${ALERTS_TO_EMAIL}|$(_sed_escape "${ALERTS_TO_EMAIL}")|g" \
  -e "s|\${ALERTS_SMS_WEBHOOK_URL}|$(_sed_escape "${ALERTS_SMS_WEBHOOK_URL}")|g" \
  "${TMPL}" > "${OUT}"

# Strip the SMS webhook block when ALERTS_SMS_WEBHOOK_URL is empty —
# alertmanager rejects "url: ''" with an unparseable-scheme error otherwise.
if [ -z "${ALERTS_SMS_WEBHOOK_URL}" ]; then
  sed -i '/# SMS_BLOCK_START/,/# SMS_BLOCK_END/d' "${OUT}"
fi

chmod 0640 "${OUT}"

exec /bin/alertmanager "$@"
