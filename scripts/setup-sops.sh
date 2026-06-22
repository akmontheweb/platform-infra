#!/usr/bin/env bash
# =============================================================================
# scripts/setup-sops.sh — Bootstrap, encrypt, and decrypt platform-infra secrets
# =============================================================================
# Subcommands:
#   install   — verify (or download) sops + age binaries to ~/.local/bin
#   keygen    — generate the production age keypair under keys/prod-age.txt
#                 and wire its public key into .sops.yaml
#   encrypt   — sops-encrypt <file> → <file>.enc
#                 Defaults to .env.production. For dev:
#                   bash setup-sops.sh encrypt .env.development
#   decrypt   — sops-decrypt <file>.enc → <file>
#                 Defaults to .env.production.enc. For dev:
#                   bash setup-sops.sh decrypt .env.development.enc
#   verify    — fail if any tracked .env* is unencrypted (CI gate)
#
# See SECRETS_RUNBOOK.md for the full procedure.
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

SOPS_VERSION="${SOPS_VERSION:-v3.9.4}"
AGE_VERSION="${AGE_VERSION:-v1.2.0}"
KEYS_DIR="${REPO_ROOT}/keys"
PROD_KEY_FILE="${KEYS_DIR}/prod-age.txt"

cmd="${1:-help}"

ensure_bin_in_path() {
    case ":$PATH:" in
        *:"$HOME/.local/bin":*) ;;
        *) echo "warning: ~/.local/bin not in PATH — add it to your shell rc" >&2 ;;
    esac
}

install_tools() {
    mkdir -p "$HOME/.local/bin"
    ensure_bin_in_path

    if ! command -v sops >/dev/null 2>&1; then
        echo "Installing sops $SOPS_VERSION → ~/.local/bin/sops"
        curl -sSL -o "$HOME/.local/bin/sops" \
            "https://github.com/getsops/sops/releases/download/${SOPS_VERSION}/sops-${SOPS_VERSION}.linux.amd64"
        chmod +x "$HOME/.local/bin/sops"
    fi
    sops --version | head -1

    if ! command -v age >/dev/null 2>&1; then
        echo "Installing age $AGE_VERSION → ~/.local/bin/age"
        tmp="$(mktemp -d)"
        curl -sSL -o "$tmp/age.tgz" \
            "https://github.com/FiloSottile/age/releases/download/${AGE_VERSION}/age-${AGE_VERSION}-linux-amd64.tar.gz"
        tar -xzf "$tmp/age.tgz" -C "$tmp"
        install -m 0755 "$tmp/age/age" "$HOME/.local/bin/age"
        install -m 0755 "$tmp/age/age-keygen" "$HOME/.local/bin/age-keygen"
        rm -rf "$tmp"
    fi
    age --version
}

keygen() {
    mkdir -p "$KEYS_DIR"
    chmod 0700 "$KEYS_DIR"
    if [[ -f "$PROD_KEY_FILE" ]]; then
        echo "error: $PROD_KEY_FILE already exists — refusing to overwrite" >&2
        exit 1
    fi
    age-keygen -o "$PROD_KEY_FILE" 2>&1
    chmod 0600 "$PROD_KEY_FILE"

    pubkey="$(grep '# public key:' "$PROD_KEY_FILE" | sed 's/^# public key: //')"
    if [[ -z "$pubkey" ]]; then
        echo "error: could not extract public key from $PROD_KEY_FILE" >&2
        exit 1
    fi
    echo "Generated production age key:"
    echo "  private: $PROD_KEY_FILE  (gitignored — back up to 1Password / hardware token)"
    echo "  public:  $pubkey"

    sed -i.bak "s|REPLACE_WITH_PROD_AGE_PUBLIC_KEY|$pubkey|g" .sops.yaml
    rm -f .sops.yaml.bak
    echo "Wrote public key into .sops.yaml"
}

encrypt_file() {
    local plain="$1"
    local enc="${plain}.enc"
    if [[ ! -f "$plain" ]]; then
        echo "error: $plain not found" >&2
        exit 1
    fi
    if grep -q "REPLACE_WITH_PROD_AGE_PUBLIC_KEY" .sops.yaml; then
        echo "error: .sops.yaml still has placeholder — run \`$0 keygen\` first" >&2
        exit 1
    fi
    sops --encrypt --input-type dotenv --output-type dotenv "$plain" > "$enc"
    echo "Encrypted $plain → $enc"
}

decrypt_file() {
    local enc="$1"
    local plain="${enc%.enc}"
    if [[ ! -f "$enc" ]]; then
        echo "error: $enc not found" >&2
        exit 1
    fi
    export SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-$PROD_KEY_FILE}"
    if [[ ! -f "$SOPS_AGE_KEY_FILE" ]]; then
        echo "error: age private key not found at $SOPS_AGE_KEY_FILE" >&2
        echo "       Restore it from 1Password and place it at keys/prod-age.txt" >&2
        exit 1
    fi
    sops --decrypt --input-type dotenv --output-type dotenv "$enc" > "$plain"
    chmod 0600 "$plain"
    echo "Decrypted $enc → $plain (mode 0600)"
}

verify_no_cleartext() {
    # CI gate: any tracked .env* file must end in .enc (encrypted).
    local bad
    bad="$(git ls-files | grep -E '(^|/)\.env(\..+)?$' | grep -vE '\.(enc|example)$' || true)"
    if [[ -n "$bad" ]]; then
        echo "error: the following dotenv files are tracked in cleartext:" >&2
        echo "$bad" >&2
        exit 1
    fi
    echo "OK — no cleartext dotenv files tracked."
}

case "$cmd" in
    install)  install_tools ;;
    keygen)   keygen ;;
    encrypt)  encrypt_file "${2:-.env.production}" ;;
    decrypt)  decrypt_file "${2:-.env.production.enc}" ;;
    verify)   verify_no_cleartext ;;
    help|*)
        sed -n '2,15p' "$0"
        exit 0
        ;;
esac
