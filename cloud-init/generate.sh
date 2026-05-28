#!/usr/bin/env bash
# Генерирует cloud-init user-data из template, подставляя реальные значения.
#
# Usage:
#   bash cloud-init/generate.sh > /tmp/vps-cloud-init.yml
#   # → скопируйте /tmp/vps-cloud-init.yml в форму VPS-провайдера
#     ("User Data" / "Cloud Init" / "Пользовательские данные")
#
# Override через env:
#   NEW_USER=alice SSH_PUBKEY_FILE=~/.ssh/work.pub bash cloud-init/generate.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE="${ROOT}/cloud-init/bootstrap.yml.template"

# ── Параметры (env overrides) ───────────────────────────────────────────
NEW_USER="${NEW_USER:-adnako}"
SSH_PORT="${SSH_PORT:-2244}"
HOSTNAME="${HOSTNAME:-vps-staging}"
TIMEZONE="${TIMEZONE:-Europe/Moscow}"
REPO_URL="${REPO_URL:-https://github.com/CHANGE_ME/vps-ansible.git}"

# SSH pubkey: env > file > default discovery
if [ -z "${SSH_PUBKEY:-}" ]; then
    for candidate in "${SSH_PUBKEY_FILE:-}" ~/.ssh/id_ed25519.pub ~/.ssh/id_rsa.pub; do
        if [ -n "$candidate" ] && [ -f "$candidate" ]; then
            SSH_PUBKEY="$(cat "$candidate")"
            break
        fi
    done
fi

if [ -z "${SSH_PUBKEY:-}" ]; then
    echo "✗ SSH_PUBKEY не задан, не найден ни ~/.ssh/id_ed25519.pub ни ~/.ssh/id_rsa.pub" >&2
    echo "  Варианты:" >&2
    echo "    export SSH_PUBKEY=\"ssh-ed25519 AAAA...\"" >&2
    echo "    export SSH_PUBKEY_FILE=\"~/.ssh/my_key.pub\"" >&2
    echo "    ssh-keygen -t ed25519  # создать новый ключ" >&2
    exit 1
fi

# REPO_URL обязателен — без него cloud-init не сможет ansible-pull
if [ "${REPO_URL}" = "https://github.com/CHANGE_ME/vps-ansible.git" ]; then
    echo "⚠ REPO_URL не задан. Установите env REPO_URL до запуска:" >&2
    echo "    export REPO_URL=https://github.com/youruser/vps-ansible.git" >&2
    echo "" >&2
    echo "Если хотите cloud-init БЕЗ ansible-pull (только user+SSH+packages)," >&2
    echo "удалите блок 'Clone + ansible-pull' из output руками." >&2
fi

# Escape slashes in keys для безопасного sed
escape() { printf '%s' "$1" | sed 's|\\|\\\\|g; s|&|\\&|g; s|/|\\/|g'; }

sed \
    -e "s|@@NEW_USER@@|$(escape "$NEW_USER")|g" \
    -e "s|@@SSH_PORT@@|$(escape "$SSH_PORT")|g" \
    -e "s|@@HOSTNAME@@|$(escape "$HOSTNAME")|g" \
    -e "s|@@TIMEZONE@@|$(escape "$TIMEZONE")|g" \
    -e "s|@@SSH_PUBKEY@@|$(escape "$SSH_PUBKEY")|g" \
    -e "s|@@REPO_URL@@|$(escape "$REPO_URL")|g" \
    -e "s|__TIMESTAMP__|$(date -u +%Y-%m-%dT%H:%M:%SZ)|g" \
    "$TEMPLATE"
