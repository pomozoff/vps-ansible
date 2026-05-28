# vps-ansible

Hybrid VPS provisioner для Ubuntu 24.04. Bootstrap через cloud-init или ansible — на выбор. Idempotent baseline через ansible-pull (на VPS) или ansible-playbook (с локалки).

## Что внутри

### Core baseline (всегда применяется)

| Role | Что делает | Tag |
|------|-----------|-----|
| `base_user` | Non-root user, SSH-key, sudo NOPASSWD, locked password, home 0750 | `user`, `bootstrap` |
| `ssh_hardening` | Socket-override port, drop-in config (AllowUsers, MaxAuthTries 3, ClientAlive, no X11/agent/TCP forward), banner | `ssh`, `bootstrap`, `baseline` |
| `firewall` | UFW: SSH + 80 + 443/tcp + 443/udp (QUIC), logging low | `firewall`, `bootstrap`, `baseline` |
| `packages` | apt upgrade, timezone, minimal extras | `packages`, `baseline` |
| `sysctl` | Kernel/network hardening (SYN cookies, rp_filter, dmesg_restrict, ptrace_scope, fs.protected_*) | `sysctl`, `security` |
| `swap` | 2GB swapfile + swappiness=10 | `swap` |
| `logrotate` | journald 500M cap, apt history rotation | `logrotate` |
| `unattended_upgrades` | Auto security updates + auto-reboot 03:00 | `updates`, `security` |
| `docker` | Docker CE + compose, arch-detect, daemon.json log-rotation + live-restore | `docker` |

### IDS / ban manager (выбираем ОДИН — toggle в group_vars)

| Role | Toggle | Описание |
|------|--------|----------|
| `fail2ban` | `use_fail2ban: true` (default) | Progressive bans (1h → 1d → 1w) через nftables |
| `crowdsec` | `use_crowdsec: true` (mutually exclusive) | Modern alternative, shared CTI feed |

### Production-grade opt-ins (default: false)

| Role | Toggle | Cost | Назначение |
|------|--------|------|-----------|
| `login_defs` | `use_login_defs_hardening: true` (default) | 0 | UMASK 027, PASS_MAX_DAYS 90, SHA-512 100000 rounds |
| `auditd` | `use_auditd` | ~5 MB RAM | Security audit trail (PCI / SOC2-ready) |
| `aide` | `use_aide` | ~10 MB RAM + 5-15 min init | File-integrity monitoring, weekly cron diff |
| `apparmor` | `use_apparmor` | 0 | Enforce existing profiles |
| `tmp_hardening` | `use_tmp_hardening` | 0 | /tmp noexec,nosuid,nodev (⚠ может ломать debconf) |
| `node_exporter` | `use_node_exporter` | ~15 MB RAM | Prometheus metrics on 127.0.0.1:9100 |

### Optional dev-comfort (отдельный playbook)

| Role | Описание |
|------|----------|
| `dev_comfort` | btop, direnv, ripgrep, fd-find, bat, tree |
| `neovim` | Pinned upstream appimage, arch-detect |
| `zsh` | zsh4humans + p10k |

Запускайте: `ansible-playbook site-dev-comfort.yml` или `--tags dev`.

## Quick start

### Prerequisites

```bash
pip install ansible
ansible-galaxy collection install -r requirements.yml
```

### Вариант A: Hybrid (cloud-init → ansible-pull автоматически)

См. [docs/HYBRID.md](docs/HYBRID.md). TL;DR:

```bash
export REPO_URL=https://github.com/youruser/vps-ansible.git
bash cloud-init/generate.sh > /tmp/vps-init.yml
# → вставьте /tmp/vps-init.yml в форму "User Data" VPS-провайдера
```

cloud-init на свежем VPS: создаёт user + SSH, ставит ansible, делает `ansible-pull` baseline. ~5-10 минут.

### Вариант B: Manual ansible (классика)

```bash
# 1. Создайте VPS вручную (Ubuntu 24.04, root@:22, любой SSH key cloud-init)
# 2. Раскомментируйте в inventory/hosts.yml:
nano inventory/hosts.yml
#    fresh-vps:
#      ansible_host: 1.2.3.4
#      ansible_user: root
#      ansible_port: 22
# 3. Bootstrap (один раз):
ansible-playbook site-bootstrap.yml
# 4. Переместите host из vps_bootstrap в vps в hosts.yml
# 5. Baseline (idempotent, повторять регулярно):
ansible-playbook site-baseline.yml
```

### Вариант C: Fallback (cloud-init завис/упал)

Если cloud-init bootstrap сделал user+SSH, но ansible-pull сломался — просто запустите ansible с локалки:

```bash
# inventory/hosts.yml уже знает про host (вы добавили IP заранее)
ansible-playbook site-baseline.yml --limit your-host
```

## Tags

```bash
# Только security
ansible-playbook site-baseline.yml --tags security
# Без docker
ansible-playbook site-baseline.yml --skip-tags docker
# Только fail2ban + sysctl
ansible-playbook site-baseline.yml --tags fail2ban,sysctl
# Dev-comfort (zsh, neovim, btop) — отдельный playbook
ansible-playbook site-dev-comfort.yml
```

## Структура

```
vps-ansible/
├── ansible.cfg              # Connection settings, fact caching
├── requirements.yml         # collections (community.general, ansible.posix)
├── site.yml                 # Umbrella: bootstrap + baseline
├── site-bootstrap.yml       # ONE-SHOT: user + ssh + firewall
├── site-baseline.yml        # IDEMPOTENT: packages + security + docker
├── site-dev-comfort.yml     # OPTIONAL: zsh, neovim
├── inventory/
│   ├── hosts.yml            # vps_bootstrap (root) + vps groups
│   └── group_vars/
│       ├── all/main.yml     # User, SSH port, swap, fail2ban tunings
│       └── vps/main.yml     # Post-bootstrap connection
├── roles/
│   ├── base_user/
│   ├── ssh_hardening/
│   ├── firewall/
│   ├── packages/
│   ├── sysctl/              # NEW: kernel + network hardening
│   ├── swap/                # NEW: 2GB swap
│   ├── logrotate/           # NEW: journald + apt log limits
│   ├── unattended_upgrades/
│   ├── fail2ban/            # NEW: progressive bans
│   ├── docker/              # split from packages
│   ├── dev_comfort/         # NEW: opt-in tools
│   ├── neovim/              # split from packages, arch-detect
│   └── zsh/                 # opt-in, не в baseline
├── cloud-init/
│   ├── bootstrap.yml.template
│   └── generate.sh
└── docs/
    └── HYBRID.md            # Cloud-init handoff to ansible-pull
```

## Vault (для production)

SSH pubkey + любые secrets вынесите в vault:

```bash
# Encrypt SSH key
ansible-vault encrypt_string 'ssh-ed25519 AAAA...' --name 'ssh_public_key' \
    >> inventory/group_vars/vps/secret.yml

# Создайте vault password file (chmod 600, в .gitignore!)
echo "your-strong-password" > .vault_pass
chmod 600 .vault_pass

# Раскомментируйте в ansible.cfg:
# vault_password_file = .vault_pass

# Дальше playbook'и подхватят автоматически
ansible-playbook site-baseline.yml
```

## После первого bootstrap

SSH меняется на **`{{ ssh_port }}`** (default 2244), root login и пароли disabled, AllowUsers ограничивает SSH твоим user.

```bash
ssh adnako@your_server_ip -p 2244
```

Обновите inventory:

```yaml
vps:
  hosts:
    production:
      ansible_host: 1.2.3.4
```

(ansible_user, ansible_port подтянутся из `group_vars/vps/main.yml`)

## Validation

```bash
# Syntax check
ansible-playbook site.yml --syntax-check
ansible-playbook site-baseline.yml --syntax-check

# Lint (если установлен)
ansible-lint

# Dry-run
ansible-playbook site-baseline.yml --check --diff
```

### Molecule (idempotency test)

```bash
pip install molecule molecule-plugins[docker] ansible-lint
cd /path/to/vps-ansible
molecule test     # spawn Ubuntu 24.04 container → converge → idempotence → verify → destroy
```

Подробнее: `molecule/default/molecule.yml`.

## Что НЕ делает (intentionally)

- **Не ставит deployment-specific compose stacks** (это application-level, разные проекты)
- **Не настраивает TLS-сертификаты** (Caddy/nginx + Let's Encrypt — на уровне app stack)
- **Не ставит monitoring agents** (node_exporter, etc.) — добавишь отдельной role когда нужен Grafana
- **Не настраивает backups** — backup strategy зависит от приложения

## Troubleshooting

| Симптом | Где смотреть |
|---|---|
| cloud-init не запустил ansible-pull | `cat /var/log/vps-bootstrap.log` + `cloud-init status --long` |
| `ansible-playbook` падает на gather_facts | проверьте `inventory/hosts.yml`, ansible_python_interpreter |
| После bootstrap не могу зайти по SSH | проверьте порт `nmap -p 2244 <ip>` + AllowUsers соответствует `new_user` |
| fail2ban забанил мой IP | `sudo fail2ban-client set sshd unbanip <ip>` |
| Docker repo 404 | ансible-architecture != arm64/x86_64 — обновите docker role mapping |
