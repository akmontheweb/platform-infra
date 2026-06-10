# =============================================================================
# platform-alertmanager — prom/alertmanager + busybox-sed env interpolation.
#
# Alertmanager does NOT expand env vars in its config file at parse time
# (open issue: prometheus/alertmanager#3108). We work around it with a tiny
# entrypoint shim that runs sed (busybox-native) over an explicit allowlist
# of vars before exec'ing alertmanager. The allowlist matters because the
# alertmanager template uses {{ ... }} for its own templating and we don't
# want a generic substituter touching those. SMTP and webhook secrets stay
# in env; the rendered config sits in a tmpfs only the running container sees.
#
# Why sed rather than envsubst: prom/alertmanager v0.27 switched from
# alpine to busybox; busybox has no apk, so installing the gettext package
# (which provides envsubst) is no longer possible. sed is already present.
# =============================================================================
FROM prom/alertmanager:v0.27.0

USER root

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# We bind-mount the template to /etc/alertmanager/alertmanager.yml.tmpl;
# entrypoint renders to /etc/alertmanager/alertmanager.yml then execs
# /bin/alertmanager with the original args.
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["--config.file=/etc/alertmanager/alertmanager.yml", "--storage.path=/alertmanager"]
