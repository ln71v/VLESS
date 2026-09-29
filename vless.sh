#!/bin/bash
# VLESS + Reality (голый Xray): установка и управление через меню.
# https://github.com/ln71v/VLESS
# Запуск:  bash <(curl -Ls https://raw.githubusercontent.com/ln71v/VLESS/main/vless.sh)

REPO_RAW="https://raw.githubusercontent.com/ln71v/VLESS/main"
CFG=/usr/local/etc/xray/config.json
META=/usr/local/etc/xray/vless-meta.env
BOT_DIR=/opt/vless-bot
BOT_ENV=/etc/vless-bot.env
BOT_UNIT=/etc/systemd/system/vless-bot.service

G='\033[1;32m'; R='\033[1;31m'; Y='\033[1;33m'; C='\033[1;36m'; N='\033[0m'
ok()   { echo -e "${G}✔ $*${N}"; }
err()  { echo -e "${R}✘ $*${N}"; }
warn() { echo -e "${Y}! $*${N}"; }
info() { echo -e "${C}$*${N}"; }
pause() { echo; read -rp "Enter — вернуться в меню " _; }
ask()  { local q="$1" def="$2" a; read -rp "$q [$def]: " a; echo "${a:-$def}"; }
yes_no() { local a; read -rp "$1 (да/нет): " a; [[ "$a" =~ ^(да|д|yes|y)$ ]]; }

# чтение с клавиатуры, даже если скрипт пришёл через pipe
[ -t 0 ] || exec </dev/tty

[ "$(id -u)" = 0 ] || { err "Запускай от root"; exit 1; }

# ---------- служебное ----------
deps() {
    local miss=()
    for p in curl openssl python3 qrencode; do command -v "$p" >/dev/null || miss+=("$p"); done
    if [ ${#miss[@]} -gt 0 ]; then
        info "Ставлю: ${miss[*]}"
        apt-get update -qq >/dev/null && apt-get install -y -qq curl openssl python3 qrencode >/dev/null \
            || { err "Не смогла поставить пакеты"; exit 1; }
    fi
}

installed() { [ -x /usr/local/bin/xray ] && [ -f "$CFG" ] && grep -q '"reality"' "$CFG"; }

need_installed() { installed || { err "Xray ещё не установлен. Пункт 1 в меню."; pause; return 1; }; }

server_ip() { curl -s4 --max-time 10 https://ifconfig.me || curl -s4 --max-time 10 https://api.ipify.org; }

port_owner() { ss -tlnpH "sport = :$1" 2>/dev/null | grep -o 'users:(("[^"]*' | head -1 | cut -d'"' -f2; }

load_meta() { [ -f "$META" ] && . "$META"; SERVER_NAME=${SERVER_NAME:-VPN}; SERVER_IP=${SERVER_IP:-$(server_ip)}; }

pubkey() {
    local priv
    priv=$(python3 -c "import json;c=json.load(open('$CFG'));print([i for i in c['inbounds'] if i.get('protocol')=='vless'][0]['streamSettings']['realitySettings']['privateKey'])")
    xray x25519 -i "$priv" | awk '/Password|Public/{print $NF}' | head -1
}

# python-помощник для работы с конфигом Xray
cfgpy() {
    python3 - "$CFG" "$@" <<'PY'
import json, re, sys, uuid, urllib.parse
cfg_path, cmd, *a = sys.argv[1:]
cfg = json.load(open(cfg_path))
ib = [i for i in cfg["inbounds"] if i.get("protocol") == "vless"][0]
cl = ib["settings"]["clients"]

def save():
    json.dump(cfg, open(cfg_path + ".new.json", "w"), indent=2, ensure_ascii=False)

if cmd == "list":
    for c in cl:
        print(c.get("email", "?"))
elif cmd == "count":
    print(len(cl))
elif cmd == "port":
    print(ib["port"])
elif cmd == "sni":
    print(ib["streamSettings"]["realitySettings"]["serverNames"][0])
elif cmd == "add":
    name = re.sub(r"\s+", "_", a[0].strip())[:32]
    if not re.fullmatch(r"[\w.-]+", name):
        sys.exit("BADNAME")
    if any(c.get("email", "").lower() == name.lower() for c in cl):
        sys.exit("EXISTS")
    cl.append({"id": str(uuid.uuid4()), "flow": "xtls-rprx-vision", "email": name})
    save()
    print(name)
elif cmd == "del":
    new = [c for c in cl if c.get("email") != a[0]]
    if len(new) == len(cl):
        sys.exit("NOTFOUND")
    ib["settings"]["clients"] = new
    save()
elif cmd == "link":
    name, ip, pbk, label = a
    c = next((c for c in cl if c.get("email") == name), None)
    if not c:
        sys.exit("NOTFOUND")
    rs = ib["streamSettings"]["realitySettings"]
    q = {"encryption": "none", "flow": c.get("flow", "xtls-rprx-vision"), "security": "reality",
         "sni": rs["serverNames"][0], "fp": "chrome", "pbk": pbk, "sid": rs["shortIds"][0], "type": "tcp"}
    print(f"vless://{c['id']}@{ip}:{ib['port']}?{urllib.parse.urlencode(q)}#"
          + urllib.parse.quote(f"{label}-{name}"))
PY
}

# проверить новый конфиг и применить
apply_cfg() {
    if xray run -test -config "$CFG.new.json" >/dev/null 2>&1; then
        cp "$CFG" "$CFG.bak"; mv "$CFG.new.json" "$CFG"
        systemctl restart xray; sleep 1
        systemctl is-active -q xray && return 0
        err "Xray не запустился, откатываю"; cp "$CFG.bak" "$CFG"; systemctl restart xray; return 1
    fi
    rm -f "$CFG.new.json"; err "Конфиг не прошёл проверку, ничего не изменила"; return 1
}

show_key() {
    local name="$1" link
    load_meta
    link=$(cfgpy link "$name" "$SERVER_IP" "$(pubkey)" "$SERVER_NAME") || { err "Нет такого пользователя"; return 1; }
    echo; info "🔑 $name"; echo
    qrencode -t ansiutf8 -m 1 "$link"
    echo; echo "$link"; echo
    info "Отсканируй QR в приложении или скопируй ссылку выше."
}

pick_user() {   # выводит выбранное имя в stdout
    local users i=1 n
    mapfile -t users < <(cfgpy list)
    [ ${#users[@]} -eq 0 ] && { err "Пользователей нет" >&2; return 1; }
    for u in "${users[@]}"; do echo "  $i) $u" >&2; i=$((i+1)); done
    read -rp "Номер: " n
    [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le ${#users[@]} ] || { err "Нет такого номера" >&2; return 1; }
    echo "${users[$((n-1))]}"
}

# ---------- пункты меню ----------
install_xray() {
    deps
    if installed; then
        warn "Xray уже стоит. Переустановка создаст НОВЫЕ ключи — все старые ссылки перестанут работать."
        yes_no "Переустановить?" || return
    fi

    local def_port=443
    [ -n "$(port_owner 443)" ] && [ "$(port_owner 443)" != xray ] && def_port=2083
    [ "$def_port" = 2083 ] && warn "Порт 443 занят программой $(port_owner 443), предлагаю 2083"
    local port sni name user
    while :; do
        port=$(ask "Порт" "$def_port")
        [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || { err "Порт — число 1–65535"; continue; }
        local own; own=$(port_owner "$port")
        [ -z "$own" ] || [ "$own" = xray ] && break
        err "Порт $port занят программой $own, выбери другой"
    done
    sni=$(ask "Сайт для маскировки" "www.yahoo.com")
    name=$(ask "Название сервера (видно в приложении)" "$(hostname)")
    user=$(ask "Имя первого пользователя" "me")

    info "Ставлю Xray..."
    bash -c "$(curl -sL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null 2>&1
    command -v xray >/dev/null || { err "Xray не установился (нет доступа к GitHub?)"; pause; return; }

    local uid keys priv pbk sid ip
    uid=$(xray uuid); keys=$(xray x25519)
    priv=$(echo "$keys" | awk '/PrivateKey/{print $NF}')
    sid=$(openssl rand -hex 8); ip=$(server_ip)

    [ -f "$CFG" ] && cp "$CFG" "$CFG.old"
    python3 - "$CFG.new.json" "$port" "$uid" "$user" "$sni" "$priv" "$sid" <<'PY'
import json, sys
out, port, uid, user, sni, priv, sid = sys.argv[1:]
cfg = {
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "listen": "0.0.0.0", "port": int(port), "protocol": "vless",
    "settings": {"clients": [{"id": uid, "flow": "xtls-rprx-vision", "email": user}], "decryption": "none"},
    "streamSettings": {"network": "tcp", "security": "reality",
      "realitySettings": {"dest": f"{sni}:443", "serverNames": [sni], "privateKey": priv, "shortIds": [sid]}},
    "sniffing": {"enabled": True, "destOverride": ["http", "tls", "quic"]}
  }],
  "outbounds": [{"protocol": "freedom", "tag": "direct"}, {"protocol": "blackhole", "tag": "block"}]
}
json.dump(cfg, open(out, "w"), indent=2, ensure_ascii=False)
PY
    [ -f "$CFG" ] || echo '{}' > "$CFG"
    printf 'SERVER_NAME=%q\nSERVER_IP=%q\n' "$name" "$ip" > "$META"
    systemctl enable xray >/dev/null 2>&1
    apply_cfg || { pause; return; }

    if ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow "$port"/tcp >/dev/null && ok "Порт $port открыт в файрволе"
    fi
    ok "Xray работает на порту $port"
    show_key "$user"
    pause
}

list_users() {
    need_installed || return
    info "Пользователи:"
    local name; name=$(pick_user) || { pause; return; }
    show_key "$name"; pause
}

add_user() {
    need_installed || return
    local name res
    read -rp "Имя нового пользователя (например Марина): " name
    [ -z "$name" ] && return
    res=$(cfgpy add "$name" 2>&1)
    case "$res" in
        *BADNAME*) err "Имя: буквы, цифры, точка, дефис"; pause; return ;;
        *EXISTS*)  err "Такой уже есть"; pause; return ;;
    esac
    apply_cfg && { ok "Добавлен $res"; show_key "$res"; }
    pause
}

del_user() {
    need_installed || return
    info "Кого удалить:"
    local name; name=$(pick_user) || { pause; return; }
    [ "$(cfgpy count)" = 1 ] && warn "Это последний пользователь, сервер останется без ключей."
    yes_no "Удалить $name? Его ключ перестанет работать." || return
    cfgpy del "$name" && apply_cfg && ok "$name удалён"
    pause
}

install_bot() {
    need_installed || return
    deps
    apt-get install -y -qq python3-requests >/dev/null || { err "Не поставился python3-requests"; pause; return; }
    load_meta
    local token admin
    if [ -f "$BOT_ENV" ]; then . "$BOT_ENV"; token=$BOT_TOKEN; admin=$ADMIN_ID; fi
    info "Токен бота — у @BotFather (/newbot). Твой ID — у @userinfobot."
    token=$(ask "Токен бота" "${token:-}")
    admin=$(ask "Твой Telegram ID" "${admin:-}")
    [[ "$token" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]] || { err "Токен выглядит неправильно"; pause; return; }
    [[ "$admin" =~ ^[0-9]+$ ]] || { err "ID — это число"; pause; return; }
    curl -s --max-time 10 "https://api.telegram.org/bot$token/getMe" | grep -q '"ok":true' \
        || { err "Telegram не принял токен"; pause; return; }

    mkdir -p "$BOT_DIR"
    curl -fsSL "$REPO_RAW/bot/bot.py" -o "$BOT_DIR/bot.py" \
        && curl -fsSL "$REPO_RAW/bot/vless-bot.service" -o "$BOT_UNIT" \
        || { err "Не скачала бота с GitHub"; pause; return; }
    python3 -m py_compile "$BOT_DIR/bot.py" || { err "Файл бота битый"; pause; return; }

    printf 'BOT_TOKEN=%s\nADMIN_ID=%s\nSERVER_NAME=%s\nSERVER_IP=%s\n' "$token" "$admin" "$SERVER_NAME" "$SERVER_IP" > "$BOT_ENV"
    chmod 600 "$BOT_ENV"
    systemctl daemon-reload
    systemctl enable -q vless-bot; systemctl restart vless-bot; sleep 2
    if systemctl is-active -q vless-bot; then
        ok "Бот работает. Открой его в Telegram и нажми /start"
    else
        err "Бот не запустился:"; journalctl -u vless-bot -n 15 --no-pager
    fi
    pause
}

status() {
    load_meta
    echo
    if installed; then
        ok "Xray: $(systemctl is-active xray), $(xray version | head -1 | cut -d' ' -f1-2)"
        echo "   Сервер: $SERVER_NAME ($SERVER_IP), порт $(cfgpy port), маскировка $(cfgpy sni)"
        echo "   Пользователей: $(cfgpy count)"
    else
        err "Xray не установлен"
    fi
    if [ -f "$BOT_UNIT" ]; then
        systemctl is-active -q vless-bot && ok "Бот: работает" || err "Бот: $(systemctl is-active vless-bot)"
    else
        echo "   Бот: не установлен"
    fi
    pause
}

update_xray() {
    need_installed || return
    info "Обновляю Xray (ключи и пользователи сохранятся)..."
    bash -c "$(curl -sL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null 2>&1
    systemctl restart xray; sleep 1
    systemctl is-active -q xray && ok "$(xray version | head -1 | cut -d' ' -f1-2)" || err "Xray не запустился"
    [ -f "$BOT_UNIT" ] && curl -fsSL "$REPO_RAW/bot/bot.py" -o "$BOT_DIR/bot.py" \
        && systemctl restart vless-bot && ok "Бот обновлён"
    pause
}

uninstall() {
    echo "  1) Удалить только бота"
    echo "  2) Удалить всё (Xray, ключи, бота)"
    echo "  0) Назад"
    local c; read -rp "Выбор: " c
    case "$c" in
        1|2)
            systemctl disable --now vless-bot >/dev/null 2>&1
            rm -rf "$BOT_DIR" "$BOT_UNIT" "$BOT_ENV"; systemctl daemon-reload
            ok "Бот удалён"
            if [ "$c" = 2 ]; then
                yes_no "Точно удалить Xray и все ключи?" || { pause; return; }
                bash -c "$(curl -sL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove --purge >/dev/null 2>&1
                rm -f "$META"
                ok "Xray удалён"
            fi ;;
    esac
    pause
}

# ---------- меню ----------
while :; do
    clear
    echo -e "${C}══════ VLESS + Reality ══════${N}"
    if installed; then
        load_meta
        echo -e "  Сервер: ${G}$SERVER_NAME${N}  $SERVER_IP:$(cfgpy port)  пользователей: $(cfgpy count)"
    else
        echo -e "  ${Y}Xray не установлен${N}"
    fi
    echo
    echo "  1) Установить Xray (VLESS + Reality)"
    echo "  2) Показать ключ пользователя (QR + ссылка)"
    echo "  3) Добавить пользователя"
    echo "  4) Удалить пользователя"
    echo "  5) Установить Telegram-бота"
    echo "  6) Статус"
    echo "  7) Обновить Xray и бота"
    echo "  8) Удаление"
    echo "  0) Выход"
    echo
    read -rp "Выбор: " choice
    case "$choice" in
        1) install_xray ;;
        2) list_users ;;
        3) add_user ;;
        4) del_user ;;
        5) install_bot ;;
        6) status ;;
        7) update_xray ;;
        8) uninstall ;;
        0) exit 0 ;;
    esac
done
