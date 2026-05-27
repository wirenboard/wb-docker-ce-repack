# wb-docker

Downstream-репак Docker от Docker Inc. с WB-суффиксом версии.

Цель — отвязать версию Docker на контроллерах Wiren Board от Debian'овского
`docker.io` (на bullseye это `20.10.5` 2021 года) и от cadence публикаций
Docker Inc. WB сам решает, какую upstream-версию катить пользователям и
когда.

Репак затрагивает только один пакет — `docker-ce`. У него к полю `Version`
дописывается WB-суффикс `+wb1xx` (пример:
`5:29.5.2-1~debian.11~bullseye+wb100`); в следующем PR в этот же пакет
встраивается WB-overlay (data-root на `/mnt/data`, симлинки, daemon.json).
Остальные три — `docker-ce-cli`, `containerd.io`, `docker-compose-plugin` —
кладутся в `artifacts/` как есть с download.docker.com: тот же
upstream-`Version`, побайтово upstream-содержимое, upstream-имя файла.
Они лежат рядом с `docker-ce` в WB-репо только чтобы apt мог разрешить
строгие `Depends:` нашего `docker-ce` из того же источника.

По правилам сравнения версий dpkg `+wb100` сортируется выше как
upstream-`.deb` без суффикса, так и Debian'овского `docker.io`, поэтому
apt при штатном `apt install docker-ce` выбирает наш билд, а зависимая
цепочка тянет ровно те upstream-версии `cli` / `containerd.io` /
`compose-plugin`, под которые собран этот `docker-ce`.

> Этот PR даёт только версионный маркер `+wb100` на `docker-ce` плюс
> зеркало трёх соседних upstream-`.deb`. Сама WB-интеграция (data-root на
> `/mnt/data`, симлинки) приедет следующим PR — там же, внутри `docker-ce`.
> На контроллере поведение Docker'а пока такое же, как при установке
> с `download.docker.com`.

## Структура репозитория

```
repack/
├── repack-docker-ce.sh     — скрипт сборки (download → docker-ce repack + mirror others)
├── src/                    — кэш upstream .deb (gitignored)
├── out/                    — распакованный stage docker-ce (gitignored)
└── artifacts/              — итог: WB docker-ce + три зеркала (gitignored)
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

Скопировать все четыре `.deb` (один WB `docker-ce` + три upstream-зеркала)
нужной архитектуры на контроллер:

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
