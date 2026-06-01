# wb-docker: архитектура и решения

Дополнение к [README](../README.md) и к Google-doc «Перепаковка Docker» —
собрано в одно место «почему именно так». README отвечает на «что и как»,
Google Doc — на «как сделать новую перепаковку», этот документ — на «почему».

## Контекст и цели

Изначально Docker на WB-контроллерах ставился мета-пакетом `wb-docker`,
который через apt-зависимости тянул `docker.io` из Debian. На bullseye это
`docker.io 20.10.5` (2021 года) — отстающая версия без нового compose-плагина
и значимых апдейтов. Плюс: разные релизы Debian кладут разные `docker.io` —
поведенческий контракт у пользователей разъезжается.

**Цель в одну фразу:** пользователь набирает `apt install docker-ce`,
получает одинаковую версию Docker вне зависимости от того, какой релиз WB
и какой Debian, и состояние переживает `apt purge` и переустановку.

## Что в архитектуре сделано

Берём официальные `.deb` Docker Inc. с `download.docker.com`. У `docker-ce`
поднимаем `Version` суффиксом `+wb1xx` (см. README, «Версионирование»). Три
соседа (`docker-ce-cli`, `containerd.io`, `docker-compose-plugin`) идут в WB
apt-репо побайтово upstream — они нужны рядом только чтобы apt разрешил
строгие `Depends:` `docker-ce` из одного источника.

Внутрь `docker-ce.deb` встраивается:

- **overlay**: шаблон `daemon.json` в `/usr/share/wb-docker/daemon.json`
  (WB-дефолты: `data-root: /mnt/data/docker/lib`, log-rotation 10MB×3).
- **postinst-сниппет** (`repack/postinst-snippet.sh`), инжектится после
  первого `set -e` в `DEBIAN/postinst` пакета. На `apt install/configure`
  он:
  - создаёт раскладку `/mnt/data/{etc/docker, var/lib/containerd, docker/lib}`;
  - мигрирует данные старого community-installer'а
    (`/mnt/data/.docker` → `/mnt/data/docker/lib`), включая правку `data-root`
    в существующем `daemon.json`;
  - заменяет `/etc/docker` и `/var/lib/containerd` симлинками на `/mnt/data`
    (с переносом любого содержимого);
  - сеет `daemon.json` из шаблона, **если своего нет** (никогда не
    перезатирает);
  - на релизах wb-2304+ и `unstable.latest` пинит `iptables-legacy` через
    `update-alternatives` (требование вики WB для Docker NAT).
- **дополнение `Depends`**: `docker-compose-plugin (>= …)`, чтобы одна
  команда `apt install docker-ce` тянула и compose.

## Принципиальные решения

### Почему не отдельный пакет `wb-docker`

Был соблазн оставить старый `wb-docker` как отдельный пакет, теперь
зависящий от нашего `docker-ce` вместо `docker.io`. Отказались по двум
причинам. Первая — отдельный пакет добавляет лишний шаг в UX
(`apt install wb-docker` вместо `apt install docker-ce`). Вторая —
содержимое `wb-docker` это де-факто пара конфигурационных файлов, никакого
собственного кода. Положить эти файлы внутрь `docker-ce` проще, чем
поддерживать отдельную единицу версионирования.

### Почему именно четыре пакета

Это структура от Docker Inc. `docker-ce` — демон, `docker-ce-cli` — клиент,
`containerd.io` — рантайм (отдельный CNCF-проект), `docker-compose-plugin` —
cli-плагин. Слияние их в один потребовало бы менять upstream control-файлы
(Conflicts, Breaks) и создало бы конфликты с любыми пакетами, ожидающими
каноничное разделение. Минимальный самодостаточный набор — именно четыре.

### Почему compose отдельным пакетом, а не внутри `docker-ce`

`docker compose` — это subcommand основного docker CLI, но физически бинарь
живёт в `/usr/libexec/docker/cli-plugins/docker-compose` как cli-плагин.
Docker Inc. сознательно сделал compose опциональным — на CI-агенте или в
minimal-контейнере он не нужен. Запихнуть compose в `docker-ce` было бы
отклонением от upstream-конвенции.

### Почему версионный суффикс `+wb1xx`, а не `-wb1xx`

dpkg парсит `+wb100` как часть debian-revision:
`upstream-version = 29.5.2`, `debian-revision = 1~debian.11~bullseye+wb100`.
С дефисом `-wb100` debian-revision «всасывалась» бы в upstream-version —
формально работает, но искажает семантику сравнения версий между нашими
сборками и прямыми сборками Docker Inc. По правилам dpkg `+wb100`
сортируется выше отсутствия суффикса, и наша сборка выигрывает apt-resolve
у upstream-`.deb` и у Debian'овского `docker.io`.

### Почему `1xx`, а не инкремент с нуля

Зарезервированный диапазон даёт возможность позже ввести параллельные
ветки (`+wb2xx` experimental, `+wb9xx` hotfix) без коллизий с основной
линейкой.

## Тонкости и edge cases

### Повторная установка той же версии

Если итеративно правишь overlay и пересобираешь `.deb` под тем же `+wb1xx` —
apt видит «уже установлено, та же версия» и не переустанавливает. Либо
инкрементируй счётчик, либо ставь через `apt-get install --reinstall` /
`dpkg -i` напрямую.

### Состояние на `/mnt/data` намеренно переживает purge

Данные, конфиги и `daemon.json` живут на `/mnt/data` и должны переживать
`apt purge`, переустановку и прошивку. Поэтому в пакете **нет postrm/prerm
с откатом**. Симлинки `/etc/docker` и `/var/lib/containerd` после purge
остаются указывать в `/mnt/data` и безвредны без пакета — переустановка их
пересоздаёт. Полная очистка — явное действие оператора (см. README,
раздел «Удалить»).

### Миграция со старого community-installer

Если на контроллере стоял
[`wb-docker-manager.sh`](https://github.com/wirenboard/wb-community/blob/main/scripts/docker-install/wb-docker-manager.sh),
его data-root был `/mnt/data/.docker`. Наш overlay использует
`/mnt/data/docker/lib`. Перенос делает postinst-сниппет (блок про
`COMMUNITY_LEGACY_DOCKER_DATA`):

1. Если в существующем `daemon.json` data-root указывает на
   `/mnt/data/.docker` — патчит на `/mnt/data/docker/lib` (иначе dockerd
   запустится со старым путём и проигнорирует перенесённые данные).
2. Если новая директория пуста — переносит содержимое старой, удаляет
   пустую `.docker`.
3. Если новая директория уже непуста — оставляет старую на месте,
   логирует, чтобы оператор разобрался вручную.

### Источник `docker.com` в apt-sources

Если на контроллере прописан `/etc/apt/sources.list.d/docker.list` —
`apt install docker-ce` может вытянуть upstream-версию вместо нашей
`+wb1xx`. Решение: убрать `docker.list` и `apt update`. На штатном
WB-образе этого источника быть не должно — мы публикуемся в WB apt repo.
Замечен также `experimental.docker-meta` (deb.wirenboard.com) на тестовых
wb8 — следует отключить перед установкой WB-репака.

### Что в этом PR (postinst-only)

Текущий релиз — это **postinst-only** подход: вся WB-логика отрабатывает
на `apt install/configure`. Этого достаточно для пользователя, который
установил Docker один раз и больше не трогает FIT-обновления прошивки.

Случай «после FIT-обновления rootfs стёрт, симлинки потерялись» в этом PR
не покрывается — для него нужен отдельный механизм восстановления на
каждой загрузке (вариант: oneshot systemd-сервис `Before=docker.service`).
Это отдельный поток работ.

## Открытые вопросы

- **Jenkins-pipeline.** Сейчас сборка ручная. Нужен `Jenkinsfile`, который
  крутит `repack/repack-docker-ce.sh` и публикует через
  `pipelines/upload-deb`.
- **Trixie.** Когда появятся trixie-контроллеры, прогнать
  `SUITE=trixie ARCH=… bash repack/repack-docker-ce.sh` и проверить,
  что патч `Depends` и инъекция overlay'а не сломались на изменённой
  структуре upstream-`.deb`. Параллельно — проверить, что Docker Inc.
  публикует `.deb` для trixie на `download.docker.com`.
- **FIT-survival.** Восстановление WB-overlay после FIT-обновления rootfs —
  отдельный поток (см. ветку `feature/INT-1084-fit-survival`).
- **Откат версии.** Документировать процедуру: `apt downgrade` / `dpkg -i`
  конкретной предыдущей версии.

## Ссылки

- WB wiki по Docker: <https://wiki.wirenboard.com/wiki/Docker>
- Community installer:
  <https://github.com/wirenboard/wb-community/blob/main/scripts/docker-install/wb-docker-manager.sh>
- WB apt repo: <https://deb.wirenboard.com>
- WB Jenkins: <https://jenkins.wirenboard.com>
