# wb-docker

Downstream-репак Docker для контроллеров Wiren Board.

Команда `apt install docker-ce` на WB-контроллере ставит сразу четыре пакета
(`docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-compose-plugin`)
с WB-специфичной интеграцией, спрятанной внутрь `docker-ce`. Все настройки
data-root, симлинков и iptables-backend делаются автоматически на установке.

Версионирование: WB-суффикс `+wb1xx` дописывается только к `docker-ce`
(например, `5:29.5.2-1~debian.11~bullseye+wb100`). Остальные три пакета
кладутся в WB-репо как есть с download.docker.com — побайтово upstream,
тот же `Version`, то же имя файла. Они нужны рядом с `docker-ce` только
чтобы apt разрешал его строгие `Depends:` из одного источника.

## Структура репозитория

```
repack/
├── repack-docker-ce.sh     — главный скрипт сборки
├── postinst-snippet.sh     — WB-setup, инжектится в docker-ce DEBIAN/postinst
├── overlay/                — файлы, инжектящиеся в дерево docker-ce.deb
│   └── usr/share/wb-docker/daemon.json    — шаблон daemon.json
├── src/                    — кэш upstream .deb (gitignored)
├── out/                    — распакованные stage-каталоги (gitignored)
└── artifacts/              — собранные .deb (gitignored)
```

## Быстрый старт

### Собрать пакеты на своей машине

Требуется Linux с `wget`, `dpkg-deb`, `md5sum`, `tar`
(или на macOS — `brew install wget dpkg coreutils`).

```bash
# По умолчанию: bullseye / armhf
bash repack/repack-docker-ce.sh

# Или явно задать архитектуру:
ARCH=arm64 bash repack/repack-docker-ce.sh
ARCH=armhf bash repack/repack-docker-ce.sh
```

Готовые `.deb` появятся в `repack/artifacts/`.

### Поставить на тестовый контроллер

С локальной машины скопировать четыре `.deb` на контроллер:

```bash
HOST=wirenboard-XXXXXXXX.local       # серийник контроллера, 8 символов
ARCH=arm64                            # arm64 для wb8, armhf для wb6/wb7

scp repack/artifacts/*_${ARCH}.deb root@${HOST}:/tmp/
```

На контроллере поднять локальный apt-репозиторий и поставить:

```bash
mkdir -p /var/local/wb-repo
mv /tmp/*.deb /var/local/wb-repo/
cd /var/local/wb-repo
apt-ftparchive packages . > Packages && gzip -k -f Packages

cat > /etc/apt/sources.list.d/wb-local.list <<EOF
deb [trusted=yes] file:/var/local/wb-repo ./
EOF

apt-get update
apt-get install -y docker-ce          # одной командой все четыре пакета
```

Проверить, что всё поднялось:

```bash
docker info 2>&1 | grep 'Docker Root Dir'      # → /mnt/data/docker/lib
docker compose version
docker run --rm hello-world
```

### Удалить

Штатное удаление (с сохранением пользовательских данных на `/mnt/data`):

```bash
apt purge docker-ce && apt autoremove --purge
```

Полное удаление вместе с образами и контейнерами:

```bash
apt purge docker-ce && apt autoremove --purge
rm -rf /mnt/data/docker /mnt/data/.docker /mnt/data/etc/docker \
       /mnt/data/var/lib/containerd
```

## Полная документация

Расширенный документ по архитектуре, всем edge-cases и плану работ лежит
в Google Drive:

[Перепаковка Docker для Wiren Board](https://docs.google.com/document/d/1SS1GXR9tSsovYjIU3ILNvEqS7ZJKOOznjiLtqoGcz34/edit?tab=t.0)


## Ссылки

- Документация по WB Docker: https://wiki.wirenboard.com/wiki/Docker
- Community installer: https://github.com/wirenboard/wb-community/blob/main/scripts/docker-install/wb-docker-manager.sh
- WB apt repo: https://deb.wirenboard.com
- WB Jenkins: https://jenkins.wirenboard.com
