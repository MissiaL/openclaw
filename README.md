# OpenClaw Setup Script

Скрипт автоматической настройки сервера Ubuntu для запуска [OpenClaw](https://docs.openclaw.ai/) бота.

## Запуск

```bash
sudo bash setup_openclaw_ubuntu.sh
```

Требуется запуск от root. Скрипт идемпотентен -- при повторном запуске пропускает уже выполненные шаги.

## Что делает скрипт

### Подготовка сервера

- Обновляет систему и устанавливает базовые пакеты (`curl`, `git`, `jq`, `htop`, `mc` и др.)
- Включает репозитории `universe`, `multiverse`, `restricted`
- Создает пользователя `openclaw` с sudo без пароля, генерирует пароль и сохраняет в `/root/openclaw_credentials.txt`
- Настраивает файрвол (UFW) -- разрешает только SSH
- Включает fail2ban для защиты от брутфорса
- Настраивает swap 2 GB с `vm.swappiness=10`

### Установка софта

- **Homebrew** + GCC (через brew)
- **Google Chrome** (только amd64) -- нужен для browser-инструментов OpenClaw
- **Claude CLI** -- CLI Anthropic для работы с Claude
- **OpenClaw** -- устанавливается через официальный скрипт с `--no-onboard`

### Настройка OpenClaw

После установки скрипт запускает `openclaw setup` и применяет конфигурацию в `~/.openclaw/openclaw.json`:

| Секция | Параметр | Значение | Описание |
|--------|----------|----------|----------|
| `agents.defaults` | `elevatedDefault` | `"full"` | Полный доступ к host-операциям без ограничений |
| `agents.defaults` | `sandbox.mode` | `"off"` | Песочница отключена -- агенты выполняются напрямую на хосте |
| `browser` | `enabled` | `true` | Включает инструмент браузерной автоматизации |
| `browser` | `executablePath` | `/usr/bin/google-chrome-stable` | Путь к Chrome для автоматизации |
| `browser` | `headless` | `true` | Браузер работает без UI (серверный режим) |
| `browser` | `noSandbox` | `true` | Отключает sandbox-изоляцию Chrome (требуется в контейнерах) |
| `session` | `dmScope` | `"per-channel-peer"` | Изоляция сессий по каналу и собеседнику (рекомендуется для мультипользовательских сценариев) |
| `session` | `reset.mode` | `"idle"` | Автосброс сессии по неактивности |
| `session` | `reset.idleMinutes` | `240` | Сброс после 4 часов простоя |
| `update` | `channel` | `"stable"` | Канал обновлений -- стабильные релизы |
| `update` | `auto.enabled` | `true` | Автоматические обновления включены |
| `update` | `auto.stableDelayHours` | `6` | Задержка перед установкой нового стабильного релиза |
| `update` | `auto.stableJitterHours` | `12` | Случайный разброс времени обновления (чтобы серверы обновлялись не одновременно) |
| `update` | `auto.betaCheckIntervalHours` | `1` | Интервал проверки бета-обновлений |
| `tools` | `profile` | `"full"` | Полный набор инструментов для агентов |

### Exec Approvals

Скрипт создает `~/.openclaw/exec-approvals.json` с полностью разрешительной политикой выполнения команд:

| Параметр | Значение | Описание |
|----------|----------|----------|
| `security` | `"full"` | Разрешить выполнение любых команд на хосте |
| `ask` | `"off"` | Не запрашивать подтверждение у пользователя |
| `askFallback` | `"full"` | Если UI недоступен -- разрешить всё |
| `autoAllowSkills` | `true` | Автоматически разрешать команды, используемые в навыках |

### Валидация

После настройки запускается `openclaw doctor --yes --repair --non-interactive` для автоматического обнаружения и исправления проблем конфигурации.

## Результат

По завершении скрипт выводит:
- IP сервера
- Логин и пароль пользователя `openclaw`
- Размер swap
- Версию Claude CLI
- SSH-команду для подключения

Также создается маркер `/root/.openclaw_setup_done` для интеграции с cloud-init.
