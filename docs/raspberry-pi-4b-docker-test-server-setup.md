# Предварительная настройка Docker test-сервера на Raspberry Pi 4B

## 1. Назначение и границы

Это руководство описывает подготовку отдельной среды для разработки и тестирования скриптов управления AdGuard VPN CLI и Telegram-бота. Локальная разработка может выполняться на Raspberry Pi или другом компьютере; тестовый сервер получает только конкретный commit SHA из ветки `test`. Production-каталог `/usr/local/bin/vpngw/` не используется для тестов.

**Критически важно:** Docker на Linux-хосте не гарантирует отсутствие влияния на сеть хоста. Docker Engine создаёт firewall rules для bridge-сетей и может менять параметры IP forwarding/forward policy. На этом Raspberry Pi уже работает VPN-шлюз с policy routing и iptables. Поэтому безопасный рекомендуемый вариант для теста реального VPN-туннеля — отдельный Raspberry Pi 4B/VM или другой отдельный тестовый узел.

На том же Pi допустимы только mock/unit-тесты без host networking, TUN и доступа к host routes/firewall, пока отдельный эксперимент не доказал изоляцию конкретного реального VPN-сценария. Если условие «не затрагивать основную маршрутизацию» является абсолютным, не запускайте реальный VPN-probe на production-шлюзе.

Docker Engine управляет firewall rules; нельзя «решить» это настройкой `iptables: false`: официальная документация предупреждает, что это ломает bridge networking и может открыть доступ к опубликованным портам. Отключение firewall-управления Docker не является рекомендуемой конфигурацией.

## 2. Схема каталогов и данных

Предлагаемая структура тестового хоста:

```text
/srv/vpngw-test/
  incoming/                 # получение исходников/артефакта по конкретному SHA
  releases/<commit-sha>/    # неизменяемая тестовая версия
  config/                   # отдельная тестовая конфигурация без production secrets
  results/<commit-sha>/     # отчёты тестов и диагностические логи
  current -> releases/...   # активная тестовая версия; не production
```

Production-каталог остаётся отдельным:

```text
/usr/local/bin/vpngw/       # только production release после отдельного sign-off
```

Правила:

- Развёртывать только точный commit SHA из `test`, не использовать изменяемый `latest` как идентификатор релиза.
- Не монтировать production `/etc/vpn-gw.conf`, VPN auth state, логи, `/dev/net`, Docker socket или `/usr/local/bin/vpngw` в test container.
- Создать отдельный `vpn-gw-test.conf` с тестовыми путями, dummy Telegram token/chat и тестовыми целями. Не копировать production TG token, account state, VPN credentials или device-code URL.
- Имеющиеся скрипты ожидают конфигурацию `/etc/vpn-gw.conf` и некоторые фиксированные CLI-пути. В тестовом контейнере этот путь может указывать только на отдельный тестовый config; CLI нужно подменять fake executable. Не запускать существующий скрипт с привилегиями host для обхода несовместимости.
- Test container не должен выполнять `iptables`, `ipset`, `ip rule`, менять sysctl, подключать/отключать production VPN или перезапускать production services. Тесты этих вызовов должны использовать mock/fake.

Права каталогов выдавать по принципу минимально необходимых. Не добавлять пользователя разработки в группу `docker` без отдельного решения: доступ к Docker daemon фактически даёт root-уровень управления хостом. Предпочитать `sudo docker ...` ограниченному администраторами доступу.

## 3. Предварительная инвентаризация маршрутизации

До установки или запуска Docker зафиксировать состояние устройства и выбрать maintenance window. Команды ниже только читают состояние; сохранять вывод в root-only каталоге, поскольку правила могут раскрыть детали сети.

```bash
uname -a
cat /etc/os-release
dpkg --print-architecture
ip -4 route show table all
ip -6 route show table all
ip rule show
ip -6 rule show
sysctl net.ipv4.ip_forward
sudo iptables-save
sudo ip6tables-save
sudo nft list ruleset
```

Не все команды могут быть установлены; отсутствие `nft` само по себе не является причиной менять firewall backend. Зафиксировать также текущий основной VPN-интерфейс и проверить, что production tunnel, доступ клиентов, DNS и bypass-routing исправны.

До установки выяснить:

- кто сейчас управляет iptables/nftables и какой backend использует `iptables`;
- включено ли IPv4 forwarding (для текущего шлюза оно ожидаемо включено);
- какие правила/политики стоят в `FORWARD`, какие таблицы и fwmark использует VPN;
- какие Docker/containerd пакеты уже есть и не управляют ли они существующими контейнерами;
- есть ли непересекающийся subnet для тестовой сети. Не назначать CIDR до сравнения со всеми route tables и VPN-сетями.

**Остановиться и не продолжать установку на production Pi**, если нет локальной консоли/резервного доступа, неизвестно как восстановить firewall, Docker уже используется production-процессами или невозможно выделить maintenance window. Подготовить Docker на отдельном test-устройстве.

Актуальный production inventory уже подтвердил Docker Engine/Compose и работающий контейнер Gitea на этом Pi. Это не чистый Docker test host: не переустанавливать/не перезапускать daemon, не менять его `daemon.json`, не выполнять prune/cleanup и не создавать test networks на production host как часть подготовки. Для интеграционного/VPN test использовать отдельный Raspberry Pi/VM; на production узле допустимы только уже согласованные read-only проверки.

## 4. Проверить ОС и архитектуру Raspberry Pi

Для Raspberry Pi 4B рекомендуется 64-bit Raspberry Pi OS / Debian-based OS и `arm64`:

```bash
uname -m
. /etc/os-release
printf 'OS=%s VERSION=%s CODENAME=%s\n' "$ID" "$VERSION_ID" "$VERSION_CODENAME"
dpkg --print-architecture
```

Ожидаемая архитектура для 64-bit ОС: `aarch64` от `uname -m` и `arm64` от `dpkg`. Docker официально публикует Debian Engine packages для `arm64` и `armhf`, но до установки проверить, что конкретный OS codename поддержан и apt repository возвращает кандидаты именно для текущей системы. Не подменять codename наугад. Если установлен 32-bit образ, не менять архитектуру на работающем VPN-шлюзе в рамках этой процедуры; сначала подготовить отдельную тестовую SD-карту/устройство и миграционный план.

Официальный Docker Debian repository следует использовать только для Debian-совместимой системы. Для Ubuntu использовать соответствующий официальный Ubuntu repository. Не запускать convenience install script на production-шлюзе.

## 5. Проверить существующую установку Docker

До установки выполнить:

```bash
command -v docker || true
docker version 2>/dev/null || true
sudo systemctl status docker --no-pager 2>/dev/null || true
dpkg -l | grep -E 'docker|containerd|podman' || true
```

Не удалять `docker.io`, `containerd`, `runc`, образы, сети или volumes автоматически. Если какие-либо пакеты уже установлены, выяснить их назначение и согласовать переход на Docker Engine. Не выполнять `docker system prune`, очистку `/var/lib/docker` или замену runtime на production-сервере.

## 6. Установить Docker Engine из официального apt repository

Для Debian-based Raspberry Pi OS на поддерживаемом codename следовать официальной инструкции Docker для Debian. Это меняет пакеты и запускает daemon, поэтому сначала выполнить раздел 3 и согласовать maintenance window.

1. Установить apt prerequisites и добавить официальный Docker keyring:

```bash
sudo apt update
sudo apt install ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/debian/gpg \
  -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
```

1. Создать `/etc/apt/sources.list.d/docker.sources`, используя codename и architecture, проверенные в разделе 4:

```text
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: <SUPPORTED_DEBIAN_CODENAME>
Components: stable
Architectures: <arm64-or-armhf>
Signed-By: /etc/apt/keyrings/docker.asc
```

Для `Suites` использовать реальный Debian base codename (например, `bookworm` или `trixie`) только если он поддерживается и соответствует установленной ОС. Для `Architectures` использовать вывод `dpkg --print-architecture`.

1. Обновить apt metadata и убедиться, что кандидаты найдены:

```bash
sudo apt update
apt-cache policy docker-ce docker-ce-cli containerd.io docker-compose-plugin
```

Если apt не находит package candidate для текущего codename/architecture, остановиться и подобрать поддерживаемый способ установки по официальной документации; не смешивать пакеты Debian releases.

1. Установить Engine, CLI, containerd, Buildx и Compose plugin:

```bash
sudo apt install docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin
```

Перед подтверждением apt внимательно проверить список действий и версий. После установки проверить daemon, но не запускать реальный VPN-контейнер:

```bash
sudo systemctl status docker --no-pager
sudo docker version
sudo docker compose version
```

Поскольку запуск Docker daemon на router host может изменить forwarding/firewall state, сразу повторить read-only snapshot из раздела 3 и сравнить его с baseline до старта тестовых контейнеров.

## 7. Настроить Docker daemon без ослабления firewall

Основной файл конфигурации Linux daemon: `/etc/docker/daemon.json`. Если файл уже есть, сначала сохранить копию, прочитать текущие параметры и **объединить**, а не перезаписывать конфигурацию.

На router host не выставлять `"iptables": false` или `"ip6tables": false`; не переключать iptables/nftables backend и не задавать `"ip-forward": false`. Это может сломать Docker network или текущую маршрутизацию. Оставить Docker firewall management включённым и не публиковать порты контейнера на host.

У Docker есть опция `ip-forward-no-drop`, предотвращающая изменение default FORWARD policy на DROP при включённом forwarding. Использовать её только для версии Docker, которая поддерживает параметр, и только после сохранения baseline. Для текущего Pi как VPN-router ожидается forwarding traffic; однако этот параметр не изолирует Docker rules от существующих правил. Его эффект и policy routing всё равно надо проверить после рестарта daemon.

Пример конфигурации для обсуждения на staging; не копировать вслепую поверх существующего файла:

```json
{
  "iptables": true,
  "ip-forward-no-drop": true,
  "log-driver": "local",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
```

`iptables: true` оставляет штатное управление Docker firewall включённым. `ip-forward-no-drop: true` предотвращает автоматическую установку Docker default FORWARD policy в DROP, но **не** гарантирует, что Docker bridge rules не повлияют на существующий firewall. Параметр `ip-forward-no-drop` проверить на установленной версии Docker и валидировать перед рестартом. Не применять конфигурацию на production-шлюзе до согласованного окна обслуживания и проверки способа rollback.

Не добавлять параметры `bip`/`default-address-pools`, пока не проверены все host/VPN routes на пересечение. Не публиковать контейнерные порты (`ports:`) и не менять `net.ipv4.ip_forward` ради Docker. Данный пример не является готовым к применению на production без сравнения текущих правил.

### Проверка конфигурации и рестарт daemon

1. Сохранить исходный `/etc/docker/daemon.json`, если он существует; не затирать настройки уже работающих контейнеров.
2. Проверить синтаксис JSON и наличие параметров в установленной версии Docker. Если установленный `dockerd` поддерживает проверку конфигурации, выполнить `sudo dockerd --validate --config-file=/etc/docker/daemon.json`.
3. До рестарта убедиться, что Docker пока не обслуживает production-контейнеры. Рестарт выполнять только в maintenance window с локальным/внеполосным доступом к Pi.
4. Перезапустить daemon по плану обслуживания и немедленно повторить snapshots из раздела 3.
5. Если изменились default route, VPN policy rules/таблицы, необходимые FORWARD rules или пропал клиентский трафик, не продолжать тесты. Остановить только тестовые контейнеры, вернуть предыдущий daemon config и восстановить сеть по заранее проверенному плану. Не выполнять бездумный `iptables-F`, `nft flush ruleset` или массовую очистку Docker.

Docker официально предупреждает, что он создаёт firewall rules для bridge-сетей и что отключение этих правил без собственной эквивалентной конфигурации ломает сетевую безопасность/связность. Поэтому цель на том же шлюзе — минимизировать test traffic и проверить влияние, а не утверждать, что host не изменяется.

## 8. Создать тестовый каталог

Создать директории с ограниченными правами; адаптировать владельца под утверждённого deploy-оператора, не выдавая группе `docker` общий доступ:

```bash
sudo install -d -o root -g root -m 0750 \
  /srv/vpngw-test/incoming \
  /srv/vpngw-test/releases \
  /srv/vpngw-test/config \
  /srv/vpngw-test/results
```

Для каждого принятого кандидата создать `/srv/vpngw-test/releases/<commit-sha>`. Каталог релиза после проверки SHA считать неизменяемым; результаты помещать в отдельный `/srv/vpngw-test/results/<commit-sha>`. `current` может указывать только на активный тестовый релиз. Никогда не создавать test symlink внутрь `/usr/local/bin/vpngw/`.

Создать test config с отдельными временными путями (`MAIN_SH_DIR`, log/state/cache), dummy bot values и безопасными check targets. Конфигурация `vpn-gw.conf` является shell-кодом, так как source-ится скриптами: принимать её только из доверенной ветки/артефакта, защитить от записи обычным пользователям, не строить её из Telegram ввода. В fake-тестах сетевые отправители и AdGuard CLI должны быть подменены mock-исполнителями.

## 9. Docker-профиль для безопасных mock-тестов

Первый рабочий профиль должен запускать только unit/smoke-тесты без внешней сети и без host capabilities. Пример-фрагмент Compose для адаптации (путь `release` и test config должны быть read-only):

```yaml
services:
  vpngw-test:
    image: ${VPNGW_TEST_IMAGE:?set an immutable image tag}
    network_mode: none
    read_only: true
    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true
    tmpfs:
      - /tmp
    volumes:
      - ./release:/opt/vpngw:ro
      - ./config/vpn-gw-test.conf:/etc/vpn-gw.conf:ro
```

В Compose не задавать `privileged`, `network_mode: host`, `pid: host`, Docker socket, реальные `/dev/net/tun`, host filesystem и `ports`. Запускать Compose с уникальным project name, чтобы `down` удалял только тестовые ресурсы. Образ помечать commit SHA и сохранять image digest в test report.

`network_mode: none` нужен для безопасных mock/unit tests, но он не проверяет доступность Telegram/API/VPN. Для тестов HTTP использовать локальные fake services в отдельном изолированном тестовом проекте либо mocks. Не расширять этот профиль до реальной сети на production Pi без отдельной проверки риска.

## 10. Условия для реального VPN/TUN integration test

Реальный tunnel test требует egress к VPN endpoint и TUN/NET_ADMIN внутри отдельного network namespace. Даже если default route контейнера меняется только внутри namespace, transport-пакеты контейнера выходят через host uplink/forwarding и проходят через host Docker/firewall rules. На текущем VPN-шлюзе это может задеть policy routing, конфликтовать с основным AdGuard туннелем или создавать nested VPN.

Поэтому:

- Сначала реализовать fake CLI/API/network tests по разделу 9.
- Реальный test CLI запускать на отдельном test Raspberry Pi/VM с собственным account/config, если нет доказанной изоляции на этом Pi.
- Не передавать test container `/dev/net/tun` и `NET_ADMIN` на production gateway в рамках предварительной установки.
- Если отдельный узел невозможен, открыть отдельную задачу feasibility: описать выбранный network driver, CIDR без пересечений, host firewall rules, VPN endpoint egress и cleanup; сравнить routing/firewall и измерить основной tunnel до/во время/после. Только после review разрешать ограниченный тестовый эксперимент.
- Не заявлять «не влияет на основную маршрутизацию» только на основании того, что у контейнера свой network namespace.

## 11. Проверка после теста и план восстановления

После каждого тестового запуска:

1. Остановить только свой Compose project и убедиться, что его контейнеры/сети удалены.
2. Повторить snapshots `ip route`, `ip rule`, iptables/nftables и `net.ipv4.ip_forward` из раздела 3; сравнить с baseline и ожидаемыми Docker-only различиями.
3. Проверить основной AdGuard VPN: интерфейс, connectivity, фактическую локацию и доступность клиентского трафика/bypass routing.
4. Сохранить commit SHA, image digest, версии Docker/ОС, результаты тестов и различия сетевого состояния в `/srv/vpngw-test/results/<commit-sha>/` без секретов.
5. При любом необъяснимом сетевом различии не принимать тестовый релиз и не запускать production promotion. Применить заранее проверенный restore plan или перенести Docker test на отдельный узел.

Не использовать `docker system prune -a`, не удалять `/var/lib/docker` и не менять production конфиг/iptables ради освобождения ресурсов. Cleanup должен быть ограничен Compose project и его явно созданной сетью/volumes.

## 12. Release handoff

После успешного тестирования передать в PR `test -> main`:

- commit SHA исходников и image digest;
- список тестов и их реальные результаты (не placeholder pass);
- подтверждение, что проверена именно эта версия;
- health status тестового контейнера и основного VPN-шлюза;
- сетевой baseline comparison;
- краткий rollback plan и ответственного за deployment.

После отдельного approval код может быть установлен в production через процедуру из [PR/release процесса](dev-to-test-pr-process.md). Тестовая установка и production rollout должны оставаться независимыми.

## 13. Официальные источники

- [Docker Engine install on Debian](https://docs.docker.com/engine/install/debian/)
- [Docker packet filtering and firewalls](https://docs.docker.com/engine/network/packet-filtering-firewalls/)
- [Docker daemon configuration](https://docs.docker.com/engine/daemon/)
- [Docker Compose](https://docs.docker.com/compose/)

Перед обновлением Docker Engine повторно сверять поддерживаемые OS/архитектуру и параметры daemon с актуальной официальной документацией.
