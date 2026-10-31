# Сценарии

Рецепты для типовых сетей. Везде предполагается hub, созданный через `wg-network init hub` (см. [Быстрый старт](getting-started.md)), и сеть по умолчанию `10.50.0.0/24`. Добавь `--dry-run` к любой изменяющей команде, чтобы сначала увидеть её план.

- [Серверы, которым нужен только hub](#серверы-которым-нужен-только-hub)
- [Маршрутизация между peer](#маршрутизация-между-peer)
- [Site-to-site: локальная сеть за peer](#site-to-site-локальная-сеть-за-peer)
- [Exit node: интернет через hub](#exit-node-интернет-через-hub)
- [Ноутбуки и телефоны](#ноутбуки-и-телефоны)
- [IPv6 dual-stack](#ipv6-dual-stack)
- [Несколько сетей на одном сервере](#несколько-сетей-на-одном-сервере)
- [Hub с DNS-именем и меняющимся IP](#hub-с-dns-именем-и-меняющимся-ip)
- [Перенос hub на другой IP или порт](#перенос-hub-на-другой-ip-или-порт)
- [Переустановленный peer (новый ключ)](#переустановленный-peer-новый-ключ)
- [Ротация preshared key](#ротация-preshared-key)
- [Замена упавшего hub](#замена-упавшего-hub)
- [Временно отключить peer](#временно-отключить-peer)
- [Подготовить изменения и применить позже](#подготовить-изменения-и-применить-позже)
- [Автоматизация: Ansible, CI, скрипты](#автоматизация-ansible-ci-скрипты)
- [Миграция с wg-network.sh](#миграция-с-wg-networksh)

## Серверы, которым нужен только hub

Режим по умолчанию и самый безопасный: каждый peer видит только hub (например, мониторинг, бэкапы или база данных на hub).

```bash
sudo wg-network init hub --endpoint vpn.example.com          # на hub
sudo wg-network deploy app1 root@app1.example.com --install  # на hub, для каждого сервера
```

Каждый peer получает только маршрут `10.50.0.1/32`. Peer не достучатся друг до друга, даже если попробуют: hub не маршрутизирует.

## Маршрутизация между peer

```bash
sudo wg-network set --forward on
```

Интерфейс hub перезапускается под таймером отката, добавляются:

- `net.ipv4.conf.wg0.forwarding=1` (только для интерфейса туннеля, а не глобальный `ip_forward`);
- правило iptables `FORWARD -i wg0 -o wg0 -j ACCEPT` с комментарием `wg-network`;
- TCP MSS clamping для маршрутизируемого трафика.

Peer, приглашённые **после** этого, сразу получают маршрут на всю сеть (`10.50.0.0/24`). Существующие peer сохраняют прежний маршрут; на каждом, кому нужна вся сеть:

```bash
sudo wg-network peer set hub --routes 10.50.0.0/24
```

На peer это горячее изменение, его туннель не прерывается.

Снова изолировать peer: `sudo wg-network set --forward off`. Правила снимаются при перезапуске интерфейса.

## Site-to-site: локальная сеть за peer

За шлюзом офиса `office` находится сеть `192.168.10.0/24`, и серверам в VPN нужен к ней доступ.

На hub:

```bash
sudo wg-network set --forward on                              # если сеть офиса нужна и другим peer
sudo wg-network invite office --routes 192.168.10.0/24
```

`--routes` говорит, какие сети находятся за этим peer. Hub добавляет их в AllowedIPs peer и направляет в туннель. wg-network отклоняет маршруты, пересекающиеся с сетью hub, с другими peer или с локальными маршрутами hub (`--force` — только если пересечение намеренное).

На шлюзе офиса выполни напечатанный `join`. Затем настрой сторону LAN шлюза сам, это уже вне VPN:

- включи форвардинг на шлюзе: `sysctl -w net.ipv4.ip_forward=1` (и сохрани это в `/etc/sysctl.d`);
- либо добавь маршрут на роутере офиса: `10.50.0.0/24 via <адрес шлюза в LAN>`,
- либо маскируй трафик VPN на шлюзе: `iptables -t nat -A POSTROUTING -s 10.50.0.0/24 -o <lan-if> -j MASQUERADE`.

Чтобы шлюз видел весь VPN, а не только hub, ему нужен маршрут на сеть: `sudo wg-network peer set hub --routes 10.50.0.0/24` на шлюзе (или пригласи его после `--forward on`).

Добавить ещё одну сеть позже, на hub: `sudo wg-network peer set office --routes 192.168.10.0/24,192.168.20.0/24`.

## Exit node: интернет через hub

Клиенты отправляют весь трафик через hub и выходят в интернет с его адресом.

```bash
sudo wg-network set --nat eth0                     # интерфейс hub, смотрящий в интернет
sudo wg-network peer add phone --generate --full-tunnel --dns 1.1.1.1 --qr
```

`--nat` добавляет MASQUERADE для сети туннеля на `eth0`, правила FORWARD в обе стороны (обратный трафик — только для установленных соединений), форвардинг на `wg0` и `eth0` и MSS clamping. `--full-tunnel` даёт клиенту `AllowedIPs = 0.0.0.0/0` (и `::/0` при IPv6).

Чтобы весь трафик через hub отправлял сервер, пригласи его с `--full-tunnel`:

```bash
sudo wg-network invite egress1 --full-tunnel
```

На этом сервере предохранитель проверит, не перехватит ли новый маршрут по умолчанию твою SSH-сессию. Если ты подключён из интернета, изменение будет **заблокировано**: ты потерял бы доступ. Сначала подключись через VPN или прими риск с `--force` (таймер подтверждения всё равно защищает).

`doctor` на hub следит за заполнением conntrack: на exit node с большим числом клиентов может закончиться `nf_conntrack_max`.

## Ноутбуки и телефоны

```bash
sudo wg-network peer add laptop --generate --output /root/laptop.conf
sudo wg-network peer add phone --generate --qr
```

- Ключи генерируются на hub, приватный ключ там не хранится. Если конфиг потерян, удали peer и добавь заново.
- Preshared key добавляется по умолчанию.
- Клиент получает `PersistentKeepalive = 25`, чтобы оставаться доступным за NAT.
- Без `--full-tunnel` клиент отправляет в туннель только трафик VPN: адрес hub или всю сеть, если hub маршрутизирует.

## IPv6 dual-stack

```bash
sudo wg-network init hub --endpoint vpn.example.com --address6 auto
```

`auto` выбирает случайный ULA /64, как рекомендует RFC 4193 (`fdXX:XXXX:XXXX::/64`); можно указать свой префикс (`--address6 fd00:50::/64`, длина 48–96). Hub получает `::1`. IPv6-адрес каждого peer выводится из номера хоста в IPv4: `10.50.0.7` становится `fdXX:XXXX:XXXX::7`. Токены содержат оба адреса.

**Форвардинг** IPv6 в Linux глобальный, и его включение отключает приём router advertisement на внешнем интерфейсе (если на нём не `accept_ra=2`). Поэтому wg-network его не включает; `doctor` предупреждает, когда он нужен для маршрутизации dual-stack. Включи сам, когда уверен:

```bash
sysctl -w net.ipv6.conf.eth0.accept_ra=2     # продолжать принимать RA на uplink, если ты на них полагаешься
sysctl -w net.ipv6.conf.all.forwarding=1
```

## Несколько сетей на одном сервере

Каждая сеть — интерфейс со своим состоянием. Дай каждой сети своё имя интерфейса, диапазон адресов и порт:

```bash
sudo wg-network -i wg1 init hub --endpoint vpn.example.com:51821 --port 51821 --address 10.60.0.1/24
sudo wg-network -i wg1 invite db1
```

Если управляемых интерфейсов больше одного, `-i` обязателен (кроме случая, когда среди них есть `DEFAULT_INTERFACE`). `wg-network interfaces` показывает их список. Сервер может быть hub в одной сети и peer в другой; предохранители не дадут сетям пересечься.

## Hub с DNS-именем и меняющимся IP

Используй DNS-имя как endpoint: `init hub --endpoint vpn.example.com`. Сам WireGuard резолвит имя один раз, поэтому после смены IP peer остались бы на старом адресе. `wg-network-reresolve.timer` на каждом peer проверяет раз в минуту: если hub не отвечает дольше `RERESOLVE_AFTER` секунд (по умолчанию 135), имя резолвится заново, и туннель восстанавливается сам.

## Перенос hub на другой IP или порт

Новый IP при том же DNS-имени: на peer ничего делать не нужно, таймер повторного резолва идёт за именем.

Новый IP без DNS: на каждом peer (горячее изменение, туннель восстанавливается сразу):

```bash
sudo wg-network peer set hub --endpoint 198.51.100.20:51820
```

Обнови endpoint hub для будущих приглашений: `sudo wg-network set --endpoint 198.51.100.20`.

Новый порт: смени его на hub, затем на каждом peer:

```bash
sudo wg-network set --port 51900 --endpoint vpn.example.com:51900   # на hub, для подтверждения введи имя интерфейса
sudo wg-network peer set hub --endpoint vpn.example.com:51900       # на каждом peer
```

Новый порт открывается в UFW; старое правило остаётся, пока ты его не уберёшь (`ufw delete allow 51820/udp`).

## Переустановленный peer (новый ключ)

Сервер переустановлен, и у него новый ключ. На нём: `sudo wg-network join` с новым токеном из `invite` или `init peer`. На hub замени ключ в существующей записи (адрес и маршруты сохраняются):

```bash
sudo wg-network peer set worker1 --key 'NEW_PUBLIC_KEY='
```

## Ротация preshared key

Hub генерирует новый ключ и печатает его в stdout, peer берёт его из stdin. Pipe между двумя SSH-сессиями не оставляет ключ ни в файлах, ни в командных строках:

```bash
ssh hub sudo wg-network peer set worker1 --rotate-psk --yes \
  | ssh worker1 sudo wg-network peer set hub --psk-file - --yes
```

Оба шага — горячие изменения. Пока второй шаг не применён, peer не сможет пройти новый handshake; текущая сессия продолжает работать до двух минут (WireGuard меняет сессионные ключи каждые 120 с), поэтому выполняй оба шага вместе. `--psk-file FILE` читает ключ из файла.

Для ноутбука или телефона (ключи сгенерированы через `--generate`) удали peer и добавь заново, чтобы получить новый конфиг.

## Замена упавшего hub

Подготовь заранее на hub и храни архив зашифрованным вне сервера:

```bash
sudo wg-network backup | gpg -c > hub-wg0.backup.gpg
```

На сервере-замене:

```bash
curl -fsSL https://raw.githubusercontent.com/Ange1oc/devops_template/main/ubuntu/wg/install.sh | sudo bash
gpg -d hub-wg0.backup.gpg | sudo wg-network restore -
```

Архив проверяется (только файлы состояния, никаких ссылок и устройств) и валидируется до того, как что-либо записано. Новый hub получает тот же ключ, адреса и peer. Направь DNS-имя на новый сервер (или смени endpoint на peer) — peer переподключатся сами. Открой UDP-порт в облачном firewall, если он есть.

## Временно отключить peer

```bash
sudo wg-network peer disable worker1     # горячо, остальные туннели работают
sudo wg-network peer enable worker1      # переподключается сразу по последнему известному адресу
```

## Подготовить изменения и применить позже

Подготовь несколько изменений и примени их вместе, например в окно обслуживания:

```bash
sudo wg-network --no-apply peer add db1 --key ...
sudo wg-network --no-apply set --mtu 1380
sudo wg-network plan --diff           # что и как изменится (код 10 — есть что применить)
sudo wg-network apply                 # одно применение, одно подтверждение
```

Чтобы по умолчанию всё только готовилось, задай `AUTO_APPLY=never` в `/etc/default/wg-network`.

## Автоматизация: Ansible, CI, скрипты

Полезные свойства:

- без терминала ничего не применяется, если не указан `--yes` или `--apply`;
- в stdout только данные, сообщения — в stderr;
- [коды выхода](commands.md#коды-выхода) стабильны; `plan` возвращает 10, если есть что применить, `doctor` — 0/1/2;
- `--json` есть у `invite`, `join`, `peer add`, `peer list`, `status`;
- токены передаются через stdin.

Полное подключение с управляющей машины, которая видит оба сервера:

```bash
TOKEN=$(ssh hub sudo wg-network invite worker1 --json | jq -r .token)
KEY=$(printf '%s\n' "$TOKEN" | ssh worker1 sudo wg-network join - --yes --json | jq -r .public_key)
ssh hub sudo wg-network peer add worker1 --key "$KEY" --yes --wait 20 --json
```

Или просто `ssh hub sudo wg-network deploy worker1 root@worker1 --yes`.

`--yes` подтверждает изменения автоматически после пост-проверок. Если изменение может сломать доступ самой управляющей машины, требуй подтверждение из нового подключения:

```bash
ssh server sudo wg-network set --mtu 1380 --yes --wait-confirm --confirm-timeout 60
ssh server sudo wg-network confirm
```

Если второе подключение не удалось, изменение откатится через 60 секунд.

Идемпотентность: `init` на управляемом интерфейсе возвращает 3 (отказ), `peer add` для существующего имени — 3. Проверяй заранее через `wg-network status --json` или `peer show NAME` (код 1, если peer нет).

## Миграция с wg-network.sh

Установи wg-network на сервер со старым скриптом и выполни любую команду, например `sudo wg-network status`. Состояние перенесётся автоматически (см. [Как это устроено](concepts.md#миграция-с-прежних-версий)): ключи, адреса и peer сохраняются, а работающий интерфейс не перезапускается, если смысл его конфига совпадает. Проверь результат: `sudo wg-network plan`; код 0 означает, что перенесённое состояние совпадает с тем, что работает.
