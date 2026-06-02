FROM quay.io/keycloak/keycloak:26.1

# Build optimised image with PostgreSQL baked in and token-exchange enabled.
# NO realm is imported at build time — realms are managed by Terraform.
RUN /opt/keycloak/bin/kc.sh build --db=postgres --features=token-exchange --health-enabled=true

ENTRYPOINT ["/opt/keycloak/bin/kc.sh"]
CMD ["start", "--optimized"]
