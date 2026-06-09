# =============================================================================
# platform-alertmanager — prom/alertmanager + envsubst.
#
# Alertmanager does NOT expand env vars in its config file at parse time
# (open issue: prometheus/alertmanager#3108). We work around it with a tiny
# entrypoint shim that envsubsts the template into the real config path
# before exec'ing alertmanager. SMTP and webhook secrets stay in env;
# the rendered config sits in a tmpfs only the running container sees.
# =============================================================================
FROM prom/alertmanager:v0.27.0

# alertmanager is /bin/alertmanager (Go binary) inside this image; alpine
# is the base, so apk works.
USER root
RUN apk add --no-cache gettext

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# We bind-mount the template to /etc/alertmanager/alertmanager.yml.tmpl;
# entrypoint renders to /etc/alertmanager/alertmanager.yml then execs
# /bin/alertmanager with the original args.
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["--config.file=/etc/alertmanager/alertmanager.yml", "--storage.path=/alertmanager"]
