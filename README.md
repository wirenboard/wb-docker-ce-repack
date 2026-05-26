# wb-docker

Downstream-репак Docker от Docker Inc. с WB-суффиксом версии.

Цель — отвязать версию Docker на контроллерах Wiren Board от Debian'овского
`docker.io` (на bullseye это `20.10.5` 2021 года) и от cadence публикаций
Docker Inc. WB сам решает, какую upstream-версию катить пользователям и
когда. Имена пакетов сохраняются upstream-каноничные (`docker-ce`,
`docker-ce-cli`, `containerd.io`, `docker-compose-plugin`); меняется только
поле `Version` — к нему дописывается WB-суффикс `+wb1xx`. Пример:
`5:29.5.2-1~debian.11~bullseye+wb100`.

По правилам сравнения версий dpkg такой пакет сортируется выше как
upstream-`.deb` без суффикса, так и Debian'овского `docker.io`, поэтому
apt при штатном `apt install docker-ce` выбирает наш билд.

> WB-специфичная интеграция (data-root на `/mnt/data`, симлинки) — отдельная
> фича и приедет следующим PR. Этот PR даёт только перепакованный upstream
> Docker — на контроллере поведение Docker'а такое же, как при установке
> с `download.docker.com`.

## Структура репозитория

```
repack/
├── repack-docker-ce.sh     — скрипт сборки (download → version-bump → rebuild)
├── src/                    — кэш upstream .deb (gitignored)
├── out/                    — распакованные stage-каталоги (gitignored)
└── artifacts/              — собранные .deb (gitignored)
```

## Как собрать

Требуется Linux с `wget`, `dpkg-deb`, `md5sum`, `tar` (на macOS:
`brew install wget dpkg coreutils`).

```bash
# По умолчанию: bullseye / armhf
bash repack/repack-docker-ce.sh

# Явно задать архитектуру:
ARCH=arm64 bash repack/repack-docker-ce.sh
ARCH=armhf bash repack/repack-docker-ce.sh
```

Готовые `.deb` появятся в `repack/artifacts/`.

## Как поставить на контроллер

Скопировать четыре `.deb` (только нужной архитектуры) на контроллер:

```bash
HOST=wirenboard-XXXXXXXX.local
ARCH=arm64                            # arm64 для wb8, armhf для wb6/wb7

scp repack/artifacts/*_${ARCH}.deb root@${HOST}:/tmp/
```

На контроллере поднять локальный apt-репозиторий и поставить одной командой:

```bash
mkdir -p /var/local/wb-repo
mv /tmp/*.deb /var/local/wb-repo/
cd /var/local/wb-repo
apt-ftparchive packages . > Packages && gzip -k -f Packages

cat > /etc/apt/sources.list.d/wb-local.list <<EOF
deb [trusted=yes] file:/var/local/wb-repo ./
EOF

apt-get update
apt-cache policy docker-ce            # candidate должен быть +wb1xx
apt-get install -y docker-ce          # подтянет cli, containerd, compose
```

## Полная документация

Расширенный документ — версионная конвенция `+wb1xx`, мотивация, история
решений — лежит в Google Drive:

[Перепаковка Docker для Wiren Board](https://docs.google.com/document/d/1SS1GXR9tSsovYjIU3ILNvEqS7ZJKOOznjiLtqoGcz34/edit?tab=t.0)

## Ссылки

- WB apt repo: https://deb.wirenboard.com
- WB Jenkins: https://jenkins.wirenboard.com
- Docker upstream debs: https://download.docker.com/linux/debian/
