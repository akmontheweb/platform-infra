# Secrets Runbook — platform-infra

**Owner:** Platform team
**Last reviewed:** 2026-06-09 (initial SOPS+age rollout)

This runbook covers how secrets are stored, rotated, and recovered for the
platform-infra stack. The pattern is **SOPS + age (file-based, git-friendly)**
per the locked decision in `cue/PRODUCTION_LAUNCH_PLAN.md` §7.

---

## 1. Layout

```
platform-infra/
├── .sops.yaml                  ← committed. Maps file paths to age recipients.
├── .env.development            ← gitignored. Dev cleartext (decrypted at deploy time).
├── .env.development.enc        ← committed. SOPS-encrypted dev source of truth.
├── .env.production             ← gitignored. Prod cleartext (decrypted at deploy time).
├── .env.production.enc         ← committed. SOPS-encrypted prod source of truth.
├── .env                        ← gitignored. Symlink to .env.development OR
│                                  .env.production, managed by scripts/deploy.sh
│                                  based on DEPLOY_ENV.
├── .env.example                ← committed. Template only — no real secrets.
├── keys/
│   └── prod-age.txt            ← gitignored. Age private key (used for both
│                                  dev and prod — single shared recipient).
└── scripts/
    └── setup-sops.sh           ← install / keygen / encrypt / decrypt / verify
```

The encrypted file's **keys** stay in cleartext (so reviewers can see structure
in diffs); only **values** are encrypted. SOPS supports `dotenv` natively.

---

## 2. First-time setup

On a workstation that will hold the age key:

```bash
cd platform-infra
bash scripts/setup-sops.sh install                       # → ~/.local/bin/{sops,age,age-keygen}
bash scripts/setup-sops.sh keygen                        # writes keys/prod-age.txt + updates .sops.yaml
bash scripts/setup-sops.sh encrypt .env.development      # → .env.development.enc
bash scripts/setup-sops.sh encrypt .env.production       # → .env.production.enc

# Commit the encrypted files and the public-key edit, then back up the private key.
git add .sops.yaml .env.development.enc .env.production.enc
git commit -m "chore(secrets): encrypt env files with SOPS+age"
```

**Back up `keys/prod-age.txt` IMMEDIATELY to at least two locations:**

- 1Password / Bitwarden vault entry "platform-infra prod-age key"
- Hardware token (YubiKey + PGP) OR printed QR in a fireproof safe

> Lose this key, lose the ability to decrypt every production secret. There is
> no recovery path — you would have to rotate every secret and re-encrypt with a
> new age key.

---

## 3. Third-party API keys — rotation required

The following keys were **not** rotated in this sprint because they live at a
third-party provider and must be rotated there first. Once rotated, paste the
new values into `.env.production` (after `decrypt`) and re-encrypt.

| Key                  | Provider | Where to rotate                                                   |
| -------------------- | -------- | ----------------------------------------------------------------- |
| `OPENAI_API_KEY`     | OpenAI   | https://platform.openai.com/api-keys                              |
| `ANTHROPIC_API_KEY`  | Anthropic | https://console.anthropic.com/settings/keys                       |
| `GEMINI_API_KEY`     | Google   | https://aistudio.google.com/apikey                                |
| `TWILIO_AUTH_TOKEN`  | Twilio   | https://console.twilio.com → Account → Auth Tokens (rotate primary) |
| `SMTP_PASSWORD`      | Resend   | https://resend.com/api-keys → revoke old + create new             |
| `TAVILY_API_KEY`     | Tavily   | https://app.tavily.com/home                                       |

After rotating each:

```bash
bash scripts/setup-sops.sh decrypt .env.production.enc        # → .env.production
# Edit .env.production with the new value(s)
bash scripts/setup-sops.sh encrypt .env.production            # → .env.production.enc
shred -u .env.production         # or: rm and clear shell history
git add .env.production.enc && git commit -m "chore(secrets): rotate <provider> key"
```

---

## 4. Routine rotation cadence

| Secret class                                                                 | Cadence              | Trigger        |
| ---------------------------------------------------------------------------- | -------------------- | -------------- |
| Platform-internal (PG, Keycloak DB+admin, MinIO, Grafana, MCP_API_KEY, LITELLM_MASTER_KEY, REDIS, Caddy obs) | Every 6 months       | Calendar       |
| Third-party API keys (OpenAI, Twilio, Resend, Tavily, Anthropic)             | Every 6 months OR on incident | Calendar or alert |
| `keys/prod-age.txt`                                                           | Only on suspected compromise | Incident      |

Rotation order matters — rotate `PLATFORM_PG_SUPERPASSWORD` last in the batch
because `LITELLM_DATABASE_URL` embeds it. The compose ALWAYS reads both
together, so update them in the same edit.

After rotating `PLATFORM_REDIS_PASSWORD`, also update Cue's `REDIS_URL` in
`cue/.env` and `cue/cue-core/.env` and run `make sync-env` in the Cue repo.

After rotating `LITELLM_MASTER_KEY`, all per-project virtual keys are invalidated.
Re-run `terraform apply` to regenerate them.

---

## 5. Terraform state — S3 backend on platform MinIO

Production state is stored in MinIO at `s3://platform-tfstate/terraform.tfstate`.
The bucket is created once via the bootstrap below, and access is gated by a
service account whose credentials live in `.env.production` as
`TF_BACKEND_ACCESS_KEY` + `TF_BACKEND_SECRET_KEY`.

**Bootstrap (one-time, on a workstation):**

```bash
# Boot the stack with MinIO up
make up

# Create the state bucket and the limited-scope service account
docker exec -i platform-minio mc alias set local http://localhost:9000 \
    "$PLATFORM_MINIO_ROOT_USER" "$PLATFORM_MINIO_ROOT_PASSWORD"
docker exec -i platform-minio mc mb local/platform-tfstate
docker exec -i platform-minio mc admin user add local \
    "$TF_BACKEND_ACCESS_KEY" "$TF_BACKEND_SECRET_KEY"
docker exec -i platform-minio mc admin policy attach local readwrite \
    --user "$TF_BACKEND_ACCESS_KEY"

# Versioning is critical — keeps prior state if the active object is corrupted
docker exec -i platform-minio mc version enable local/platform-tfstate

# Initialise Terraform against the new backend
cd terraform
terraform init -migrate-state \
    -backend-config="access_key=$TF_BACKEND_ACCESS_KEY" \
    -backend-config="secret_key=$TF_BACKEND_SECRET_KEY"
```

The S3 backend config lives in `terraform/backend.tf` (committed; no secrets).
Credentials are passed at `terraform init` time via `-backend-config=` flags.

**Locking:** Terraform 1.11+ supports native lockfile-based locking via the S3
backend (`use_lockfile = true`). The config in `backend.tf` enables this.

**Caveat:** state lives on the same Hetzner host as the application. Protects
against `terraform apply` races and accidental local-state edits, not host
failure. See `PRODUCTION_LAUNCH_PLAN.md` §4 for the same-host trade-off.

---

## 6. CI verification

Add this to every PR check in the CI workflow (Week 2 task):

```bash
bash platform-infra/scripts/setup-sops.sh verify
```

It fails the build if any `.env*` file is tracked in cleartext (only `.enc`
and `.example` variants are allowed). This prevents the "oops I committed
.env" failure mode.

---

## 7. Restore — lost cleartext, encrypted file intact

```bash
# Get the age private key back from 1Password into keys/prod-age.txt
chmod 0600 keys/prod-age.txt
bash scripts/setup-sops.sh decrypt .env.production.enc      # → .env.production
bash scripts/setup-sops.sh decrypt .env.development.enc     # → .env.development
```

## 8. Restore — lost age private key

This is the irrecoverable case. The encrypted file becomes useless. Recovery
requires:

1. Rotate **every** secret at its source (platform-internal random values + all
   third-party providers).
2. `bash scripts/setup-sops.sh keygen` to generate a fresh age key.
3. Reconstruct `.env.production` from the new values.
4. `bash scripts/setup-sops.sh encrypt`.
5. Force-push the new `.env.production.enc` and `.sops.yaml`.
6. Distribute the new private key per §2.

This is why §2 says **two independent backups**.

---

## 9. Decision record

- **2026-06-09:** SOPS+age (file-based, git-friendly) chosen over Vault / Doppler / 1Password Connect. File-based fits a single-team / single-host posture; revisit when team or environment count grows. See `cue/PRODUCTION_LAUNCH_PLAN.md` §7.
