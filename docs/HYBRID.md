# Hybrid: cloud-init + ansible-pull

Two-stage VPS bootstrap: cloud-init минимум (user + SSH + ansible), затем ansible-pull тянет полную конфигурацию из git и применяет на хосте локально.

## Зачем гибрид

| Подход | Плюс | Минус |
|---|---|---|
| Чистый cloud-init | Zero-touch при создании VPS | Не идемпотентен, dash vs bash bugs, debug сложный |
| Чистый ansible | Идемпотентность, диффы, vault | Нужен SSH-доступ до запуска (т.е. user уже должен быть) |
| **Hybrid** | cloud-init фиксит SSH, ansible-pull делает всё остальное | Нужен git-репо для pull |

Hybrid решает главную боль: «cloud-init упал в середине — нет SSH». Cloud-init ВСЕГДА доводит user+SSH до конца (короткий шаг), а потом передаёт control ansible.

## Поток

```
┌─────────────────────────────────────────────────────────────────┐
│ 1. VPS-провайдер создаёт VM, передаёт user-data в cloud-init    │
└────────────────────────────────────────────┬────────────────────┘
                                             ▼
┌─────────────────────────────────────────────────────────────────┐
│ 2. cloud-init:                                                  │
│    ✓ создаёт user @@NEW_USER@@ + SSH key                        │
│    ✓ disable_root + ssh_pwauth=false                            │
│    ✓ apt install ansible + git                                  │
│    ✓ git clone @@REPO_URL@@ → /opt/vps-ansible                  │
│    ✓ ansible-pull site-baseline.yml -c local                    │
└────────────────────────────────────────────┬────────────────────┘
                                             ▼
┌─────────────────────────────────────────────────────────────────┐
│ 3. ansible-pull (на самом VPS под root через cloud-init):       │
│    ✓ sshd hardening + port change                               │
│    ✓ firewall (UFW + кастомный port)                            │
│    ✓ sysctl + swap + logrotate                                  │
│    ✓ fail2ban progressive bans                                  │
│    ✓ docker + daemon.json                                       │
│    ✓ unattended-upgrades                                        │
└────────────────────────────────────────────┬────────────────────┘
                                             ▼
┌─────────────────────────────────────────────────────────────────┐
│ 4. VPS готов. ssh @@NEW_USER@@@<ip> -p @@SSH_PORT@@             │
└─────────────────────────────────────────────────────────────────┘
```

## Setup (one-time)

### Шаг 1: push vps-ansible в публичный git

ansible-pull нужен git-репо. Простейший вариант — public GitHub:

```bash
cd /path/to/vps-ansible
git add -A
git commit -m "initial commit"
gh repo create vps-ansible --public --source=. --push
# или: вручную создать репо, добавить remote, push
```

**Production**: используйте private репо + deploy key. См. § "Private repo" ниже.

### Шаг 2: настройте `inventory/group_vars/all/main.yml`

```yaml
new_user: alice
ssh_port: 2244
timezone: Europe/Moscow
ssh_public_key: "ssh-ed25519 AAAA... your-key"
```

Commit + push.

### Шаг 3: сгенерируйте cloud-init user-data

```bash
export REPO_URL=https://github.com/youruser/vps-ansible.git
export NEW_USER=alice
export SSH_PORT=2244
export HOSTNAME=prod-1
# SSH_PUBKEY автоопределяется из ~/.ssh/id_ed25519.pub

bash cloud-init/generate.sh > /tmp/vps-init.yml
```

### Шаг 4: создайте VPS у провайдера

В форме создания VPS найдите поле "User Data" / "Cloud Init" / "Пользовательские данные". Вставьте содержимое `/tmp/vps-init.yml`.

Через ~5-10 минут (зависит от скорости apt + Galaxy) VPS готов:

```bash
ssh alice@<vps-public-ip> -p 2244
```

## Verification

После создания, под user (через SSH):

```bash
# 1. cloud-init статус
cloud-init status --long
# → expected: "status: done"

# 2. Bootstrap лог
cat /var/log/vps-bootstrap.log

# 3. ansible-pull результат
sudo cat /var/log/cloud-init-output.log | grep -A 5 "PLAY RECAP"

# 4. Sanity checks
sudo systemctl status ssh fail2ban docker unattended-upgrades
sudo ufw status verbose
sudo fail2ban-client status sshd
sudo sshd -T | grep -i "permitroot\|allowusers\|maxauth"
```

## Fallback: ansible-pull упал

cloud-init гарантирует user+SSH ВСЕГДА. Если ansible-pull свалился (network drop, syntax error в playbook, что угодно) — у вас всё равно есть рабочий SSH-доступ.

### Diagnose

```bash
ssh alice@<vps-public-ip>  # root@:22 уже disabled, заходим под user
cat /var/log/vps-bootstrap.log
sudo cat /var/log/cloud-init-output.log | tail -50
```

### Recover из локали (без передеплоя VPS)

```bash
# Откройте inventory/hosts.yml и добавьте host в vps:
nano inventory/hosts.yml
#   vps:
#     hosts:
#       recovered:
#         ansible_host: <vps-public-ip>
#         ansible_port: 22         # ! пока port ещё default
#         ansible_user: alice      # cloud-init user уже создан

# Запустите baseline:
ansible-playbook site-baseline.yml --limit recovered

# После того как ssh_hardening поменял порт, обновите hosts.yml:
#   ansible_port: 2244
```

### Recover ON-VPS (вручную)

```bash
# На VPS под user
cd /opt/vps-ansible
sudo ansible-pull -U $(git remote get-url origin) -d /opt/vps-ansible \
    -i "localhost," -c local site-baseline.yml
```

## Periodic re-apply (drift detection)

ansible-pull можно запускать по cron — тогда конфиг-drift автоматически фиксится:

```bash
# На VPS под root
crontab -e
# Каждые 6 часов: pull свежий repo + apply baseline
0 */6 * * * cd /opt/vps-ansible && /usr/bin/ansible-pull \
    -U https://github.com/youruser/vps-ansible.git \
    -d /opt/vps-ansible -i "localhost," -c local site-baseline.yml \
    >> /var/log/ansible-pull.log 2>&1
```

Альтернативно — `systemd timer`, который умеет лучше jitter и dependency.

## Private repo

Public-репо удобен для bootstrap. Если нужен private:

### Вариант A: GitHub deploy key

1. Сгенерируйте key pair специально для bootstrap (read-only):
   ```bash
   ssh-keygen -t ed25519 -f /tmp/vps-bootstrap -N ""
   ```
2. Pubkey → GitHub repo Settings → Deploy keys (read-only).
3. В cloud-init `write_files` добавьте `/root/.ssh/id_ed25519` (private key) + ssh config для github.com.
4. В `runcmd` git clone через SSH вместо HTTPS.

**Минус**: private key в metadata cloud-init = security risk если metadata API доступен (AWS IMDSv1 etc.). Используйте IMDSv2 или provider-side encrypted metadata.

### Вариант B: token

1. GitHub PAT (fine-grained, read repo content only) → env переменная в cloud-init.
2. `git clone https://x-access-token:$TOKEN@github.com/youruser/vps-ansible.git`

**Минус**: token в metadata — same risk.

### Вариант C: gitlab/codeberg/self-hosted

Любой git remote с поддержкой deploy keys. Принцип тот же.

## Multi-host workflow

Один cloud-init template + один git repo обслуживают любое число VPS:

```bash
# Для каждой новой VPS — генерация cloud-init с её параметрами
HOSTNAME=prod-2 SSH_PORT=2244 bash cloud-init/generate.sh > /tmp/prod-2.yml
# вставка в форму создания VPS
```

Все VPS pull тот же repo → одинаковая конфигурация.

Кастомизация per-host — через `host_vars/` в репо:

```yaml
# inventory/host_vars/prod-2.yml
new_user: prod_admin
firewall_allow_http: false   # этот host только internal
```

Запускайте ansible-pull с `--limit` или используйте inventory с group-based settings.

## Когда НЕ использовать hybrid

- VPS-провайдер не поддерживает cloud-init user-data (редко, но бывает) → только Вариант B (manual ansible)
- Нет публичного интернета для git → manual ansible через bastion
- Compliance требует voiced human-in-the-loop для каждого изменения → manual ansible с code review
