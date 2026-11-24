# AI-DNS (Linux)

Bash-порт ядра AI-DNS для Linux с **systemd-resolved**: подбор рабочего smart DNS для ChatGPT / Claude / Gemini и точный откат.

Windows-версия в корне репозитория не затрагивается.

## Требования

- bash 4+, `sudo`
- `dig` (bind-utils / dnsutils), `curl`, `python3`
- `systemd-resolved` и файл `/etc/systemd/resolved.conf`
- права root для Enable / Disable / Update (Status — без root)

```bash
# Debian/Ubuntu
sudo apt install dnsutils curl python3

# Fedora/RHEL
sudo dnf install bind-utils curl python3
```

## Запуск

```bash
cd linux
chmod +x ai-dns.sh ai-dns-*.sh

sudo ./ai-dns-enable.sh              # подобрать и применить DNS
sudo ./ai-dns-enable.sh --test-only  # только проверка, без изменений
sudo ./ai-dns-enable.sh --dry-run --trace
./ai-dns-status.sh                   # состояние и проверка сервисов
sudo ./ai-dns-disable.sh             # откат
sudo ./ai-dns-update.sh              # полный откат + подбор с нуля
```

Или через общий вход:

```bash
sudo ./ai-dns.sh --action Enable --test-only
sudo ./ai-dns.sh --action Disable --full
./ai-dns.sh --action Status --language ru
```

## Что меняется в системе

| Настройка | Enable | Disable |
|---|---|---|
| `/etc/systemd/resolved.conf` | блок `# AIDNS-begin` … `# AIDNS-end`: `DNS=`, `FallbackDNS=`, `Domains=~.`, `DNSOverTLS=no`, `DNSSEC=no` (активные одноименные ключи вне блока убираются) | восстановление из `/var/lib/aidns/resolved.conf.bak` или удаление блока |
| `/etc/hosts` | конфликтующие записи комментируются `# AIDNS-disabled:` | раскомментируются (`--full` удаляет) |
| IPv6 (sysctl) | при `system.disableIpv6` — `net.ipv6.conf.all.disable_ipv6=1` | возврат, если выключал AI-DNS (или `--enable-ipv6`) |
| `/var/lib/aidns` | backup, state, cache, logs | удаляется |

Перед первым изменением копируется исходный `resolved.conf`. Повторный Enable копию не перезаписывает.

Per-domain routing (аналог Windows NRPT) **не поддерживается**: основной сервер должен открывать все **Required** сервисы; secondary только запасной в `DNS=`.

## Настройки

Файл [`settings.json`](settings.json) рядом со скриптами. Disable/Update его не трогают.

| Поле | Смысл |
|---|---|
| `modes` | `Required` / `Preferred` / `Off` для встроенных сервисов |
| `customServices` | свои домены (`id`, `name`, `domain`, `mode`) |
| `customResolvers` | свои IPv4 smart DNS |
| `blockedProviders` / `blockedAddresses` | исключения |
| `pinnedProvider` | id провайдера, предпочитаемый как primary |
| `flags` | значения по умолчанию для `--test-only`, `--dry-run`, … |
| `system.disableIpv6` / `system.hosts` | что Enable может менять |
| `language` | `Auto`, `en`, `ru` |

Каталог провайдеров — общий с Windows: [`../src/providers.json`](../src/providers.json), плюс удалённые ленты (кэш 6 ч в `/var/lib/aidns/cache`).

## Коды завершения

| Код | Значение |
|---|---|
| 0 | успех |
| 1 | ошибка |
| 2 | нет серверов для обязательных сервисов, ничего не изменено |
| 3 | завершено с замечаниями |

## TODO

- **Settings TUI** — интерактивное меню настроек как `AI-DNS-Settings.bat` на Windows (стрелки, режимы сервисов, свои домены). Пока правьте `settings.json` вручную.
