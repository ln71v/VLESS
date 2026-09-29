#!/bin/sh
# Xray на Keenetic (Entware): VLESS-серверы как локальные SOCKS-прокси для Keenetic.
# Каждый сервер получает свой порт (1080, 1081, ...). В Keenetic для каждого
# создаётся «Прокси-подключение» SOCKS5 127.0.0.1:<порт>.
# https://github.com/ln71v/VLESS

DIR=/opt/etc/xray
CFG=$DIR/config.json
LIST=$DIR/servers.list      # строки: порт|имя|ссылка
INIT=/opt/etc/init.d/S24xray
RAW="https://raw.githubusercontent.com/ln71v/VLESS/main/router"

pause() { printf '\nEnter — в меню '; read -r _; }
say()   { printf '%s\n' "$*"; }

mkdir -p "$DIR"; touch "$LIST"

param() {   # param <query> <key>
    printf '%s' "$1" | tr '&' '\n' | sed -n "s/^$2=//p" | head -1 \
        | sed 's/%2F/\//g; s/%2f/\//g; s/%2C/,/g; s/%2c/,/g'
}

outbound() {   # outbound <tag> <link>  -> JSON
    local tag link uuid rest hostport host port q sec typ flow sni fp flowjs pbk sid alpn alpnjs stream
    tag=$1; link=${2#vless://}
    uuid=${link%%@*}; rest=${link#*@}
    hostport=${rest%%\?*}; host=${hostport%:*}; port=${hostport##*:}
    q=${rest#*\?}; q=${q%%#*}
    sec=$(param "$q" security); typ=$(param "$q" type); flow=$(param "$q" flow)
    sni=$(param "$q" sni); fp=$(param "$q" fp); [ -z "$fp" ] && fp=chrome
    [ -z "$typ" ] && typ=tcp
    [ "$typ" = tcp ] || { say "Тип $typ не поддерживается, нужен tcp" >&2; return 1; }
    flowjs=""; [ -n "$flow" ] && flowjs="\"flow\": \"$flow\", "
    case "$sec" in
        reality)
            pbk=$(param "$q" pbk); sid=$(param "$q" sid)
            stream="\"security\": \"reality\", \"realitySettings\": {\"serverName\": \"$sni\", \"fingerprint\": \"$fp\", \"publicKey\": \"$pbk\", \"shortId\": \"$sid\"}" ;;
        tls)
            alpn=$(param "$q" alpn); [ -z "$sni" ] && sni=$host
            alpnjs=""; [ -n "$alpn" ] && alpnjs=", \"alpn\": [\"$(printf '%s' "$alpn" | sed 's/,/", "/g')\"]"
            stream="\"security\": \"tls\", \"tlsSettings\": {\"serverName\": \"$sni\", \"fingerprint\": \"$fp\"$alpnjs}" ;;
        *) say "Шифрование \"$sec\" не поддерживается (нужно reality или tls)" >&2; return 1 ;;
    esac
    printf '    {"tag": "%s", "protocol": "vless", "settings": {"vnext": [{"address": "%s", "port": %s, "users": [{"id": "%s", %s"encryption": "none"}]}]}, "streamSettings": {"network": "tcp", %s}}' \
        "$tag" "$host" "$port" "$uuid" "$flowjs" "$stream"
}

build() {   # собрать config.json из servers.list
    local tmp first p n l
    tmp=$CFG.new.json
    {
        say '{'
        say '  "log": {"loglevel": "warning"},'
        say '  "inbounds": ['
        first=1
        while IFS='|' read -r p n l; do
            [ -z "$p" ] && continue
            [ $first = 1 ] || say ','; first=0
            printf '    {"tag": "in-%s", "listen": "0.0.0.0", "port": %s, "protocol": "socks", "settings": {"auth": "noauth", "udp": true}, "sniffing": {"enabled": true, "destOverride": ["http", "tls"]}}' "$p" "$p"
        done < "$LIST"
        say ''; say '  ],'
        say '  "outbounds": ['
        while IFS='|' read -r p n l; do
            [ -z "$p" ] && continue
            outbound "out-$p" "$l" || return 1
            say ','
        done < "$LIST"
        say '    {"tag": "direct", "protocol": "freedom"}'
        say '  ],'
        say '  "routing": {"rules": ['
        first=1
        while IFS='|' read -r p n l; do
            [ -z "$p" ] && continue
            [ $first = 1 ] || say ','; first=0
            printf '    {"type": "field", "inboundTag": ["in-%s"], "outboundTag": "out-%s"}' "$p" "$p"
        done < "$LIST"
        say ''; say '  ]}'
        say '}'
    } > "$tmp" || return 1
    if xray run -test -config "$tmp" >/dev/null 2>&1; then
        [ -f "$CFG" ] && cp "$CFG" "$CFG.bak"
        mv "$tmp" "$CFG"
        "$INIT" restart >/dev/null 2>&1
        return 0
    fi
    say "Конфиг не прошёл проверку:"; xray run -test -config "$tmp" 2>&1 | tail -3
    rm -f "$tmp"; return 1
}

check() {   # check <port>
    ip=$(curl -s --max-time 15 --socks5-hostname 127.0.0.1:"$1" https://ifconfig.me)
    [ -n "$ip" ] && say "  порт $1 → $ip ✔" || say "  порт $1 → нет связи ✘"
}

install() {
    say "Ставлю xray-core..."
    opkg update >/dev/null 2>&1; opkg install xray-core curl >/dev/null 2>&1
    command -v xray >/dev/null || { say "xray не установился"; return; }
    if [ ! -f "$INIT" ]; then
        curl -fsSL "$RAW/S24xray" -o "$INIT" && chmod +x "$INIT" || { say "Не скачала S24xray"; return; }
    fi
    say "Готово: $(xray version | head -1 | cut -d' ' -f1-2). Теперь добавь сервер (пункт 2)."
}

add() {
    command -v xray >/dev/null || { say "Сначала пункт 1"; return; }
    say "Вставь ссылку vless:// (из бота, приложения или 3x-ui):"
    read -r link
    case "$link" in vless://*) ;; *) say "Это не ссылка vless://"; return ;; esac
    printf 'Имя (например Fremont): '; read -r name; name=$(printf '%s' "$name" | tr -d '|')
    port=1080; while grep -q "^$port|" "$LIST"; do port=$((port+1)); done
    printf 'Порт на роутере [%s]: ' "$port"; read -r p; [ -n "$p" ] && port=$p
    grep -q "^$port|" "$LIST" && { say "Порт $port уже занят"; return; }
    outbound test "$link" >/dev/null || return
    cp "$LIST" "$LIST.bak"
    printf '%s|%s|%s\n' "$port" "${name:-server$port}" "$link" >> "$LIST"
    if build; then
        say "Добавлен ${name} на порт $port. Проверяю..."; sleep 2; check "$port"
        say ""
        say "В Keenetic: Интернет → Прокси-подключения → Добавить:"
        say "  тип SOCKS5, адрес 127.0.0.1:$port, без логина,"
        say "  галка «Использовать для выхода в интернет»,"
        say "  в «Приоритетах подключений» поставь его НИЖЕ основного провайдера."
    else
        mv "$LIST.bak" "$LIST"; say "Ничего не изменила."
    fi
}

list() {
    [ -s "$LIST" ] || { say "Серверов нет"; return; }
    while IFS='|' read -r p n l; do
        [ -z "$p" ] && continue
        h=${l#*@}; h=${h%%\?*}
        say "  $p  $n  ($h)"
    done < "$LIST"
}

del() {
    list; [ -s "$LIST" ] || return
    printf 'Порт сервера для удаления: '; read -r p
    grep -q "^$p|" "$LIST" || { say "Нет такого"; return; }
    cp "$LIST" "$LIST.bak"; grep -v "^$p|" "$LIST.bak" > "$LIST"
    if [ -s "$LIST" ]; then build && say "Удалён. Не забудь удалить подключение 127.0.0.1:$p в Keenetic."
    else "$INIT" stop >/dev/null 2>&1; say "Удалён последний сервер, Xray остановлен."; fi
}

test_all() {
    [ -s "$LIST" ] || { say "Серверов нет"; return; }
    say "Проверяю (до 15 сек на сервер):"
    while IFS='|' read -r p n l; do [ -n "$p" ] && printf '%s:' "$n" && check "$p"; done < "$LIST"
}

while :; do
    say ""
    say "══════ VLESS на Keenetic ══════"
    ps | grep -q '[x]ray run' && say "  Xray: работает" || say "  Xray: остановлен"
    say ""
    say "  1) Установить Xray на роутер"
    say "  2) Добавить сервер (ссылка vless://)"
    say "  3) Список серверов"
    say "  4) Удалить сервер"
    say "  5) Проверить все серверы"
    say "  6) Перезапустить Xray"
    say "  0) Выход"
    printf 'Выбор: '; read -r c
    case "$c" in
        1) install; pause ;;
        2) add; pause ;;
        3) list; pause ;;
        4) del; pause ;;
        5) test_all; pause ;;
        6) "$INIT" restart; pause ;;
        0) exit 0 ;;
    esac
done
