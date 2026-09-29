#!/usr/bin/env python3
# Бот выдачи VLESS-ключей (голый Xray, VLESS + Reality). Управление кнопками.
import json, os, re, subprocess, time, uuid, urllib.parse
import requests

TOKEN = os.environ["BOT_TOKEN"]
ADMIN = int(os.environ["ADMIN_ID"])
CFG = os.environ.get("XRAY_CONFIG", "/usr/local/etc/xray/config.json")
NAME = os.environ.get("SERVER_NAME", "VPN")
IP = os.environ.get("SERVER_IP", "")
API = f"https://api.telegram.org/bot{TOKEN}"

BTN_ADD = "➕ Добавить"
BTN_LIST = "👥 Пользователи"
MENU = {"keyboard": [[{"text": BTN_ADD}, {"text": BTN_LIST}]], "resize_keyboard": True, "is_persistent": True}
waiting_name = set()


# ---------- Xray ----------
def load():
    with open(CFG) as f:
        return json.load(f)


def save(cfg):
    tmp = CFG + ".tmp.json"
    with open(tmp, "w") as f:
        json.dump(cfg, f, indent=2, ensure_ascii=False)
    r = subprocess.run(["xray", "run", "-test", "-config", tmp], capture_output=True, text=True)
    if r.returncode != 0:
        os.remove(tmp)
        raise RuntimeError("конфиг Xray не прошёл проверку, ничего не изменила")
    subprocess.run(["cp", CFG, CFG + ".botbak"])
    os.replace(tmp, CFG)
    subprocess.run(["systemctl", "restart", "xray"])


def inbound(cfg):
    for ib in cfg["inbounds"]:
        if ib.get("protocol") == "vless":
            return ib
    raise RuntimeError("в конфиге Xray нет VLESS-входа")


def clients(cfg):
    return inbound(cfg)["settings"]["clients"]


def by_id(cfg, short):
    for c in clients(cfg):
        if c["id"].startswith(short):
            return c
    return None


def by_name(cfg, name):
    for c in clients(cfg):
        if c.get("email", "").lower() == name.lower():
            return c
    return None


_pub = {}


def public_key(priv):
    if priv not in _pub:
        out = subprocess.run(["xray", "x25519", "-i", priv], capture_output=True, text=True).stdout
        for line in out.splitlines():
            if "Password" in line or "Public" in line:
                _pub[priv] = line.split(":", 1)[1].strip()
                break
        else:
            raise RuntimeError("не смогла получить публичный ключ")
    return _pub[priv]


def link(cfg, c):
    ib = inbound(cfg)
    rs = ib["streamSettings"]["realitySettings"]
    q = {
        "encryption": "none", "flow": c.get("flow", "xtls-rprx-vision"), "security": "reality",
        "sni": rs["serverNames"][0], "fp": "chrome", "pbk": public_key(rs["privateKey"]),
        "sid": rs["shortIds"][0], "type": "tcp",
    }
    tag = urllib.parse.quote(f"{NAME}-{c['email']}")
    return f"vless://{c['id']}@{IP}:{ib['port']}?{urllib.parse.urlencode(q)}#{tag}"


# ---------- Telegram ----------
def api(method, files=None, **data):
    for k, v in list(data.items()):
        if isinstance(v, (dict, list)):
            data[k] = json.dumps(v, ensure_ascii=False)
    try:
        return requests.post(f"{API}/{method}", data=data, files=files, timeout=30).json()
    except Exception:
        return {}


def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def send(chat, text, kb=None):
    api("sendMessage", chat_id=chat, text=text, parse_mode="HTML", reply_markup=kb or MENU)


def edit(chat, msg, text, kb=None):
    api("editMessageText", chat_id=chat, message_id=msg, text=text, parse_mode="HTML",
        reply_markup=kb or {"inline_keyboard": []})


def ib_btn(text, data):
    return {"text": text, "callback_data": data}


def users_kb(cfg):
    rows = [[ib_btn(f"👤 {c.get('email', '?')}", "u:" + c["id"][:8])] for c in clients(cfg)]
    return {"inline_keyboard": rows}


def user_kb(c):
    s = c["id"][:8]
    return {"inline_keyboard": [
        [ib_btn("🔑 Ключ", "k:" + s), ib_btn("🗑 Удалить", "d:" + s)],
        [ib_btn("⬅ Назад", "back")],
    ]}


def give_key(chat, cfg, c):
    l = link(cfg, c)
    png = subprocess.run(["qrencode", "-o", "-", "-s", "8", "-m", "2", l], capture_output=True).stdout
    api("sendPhoto", files={"photo": ("qr.png", png)}, chat_id=chat,
        caption=f"🔑 {c['email']}\nОтсканируй QR в Hiddify / v2rayNG / Happ\nили скопируй ссылку ниже")
    send(chat, f"<code>{esc(l)}</code>")


# ---------- логика ----------
def on_text(chat, text):
    t = text.strip()
    if t in ("/start", "/menu", "Меню"):
        waiting_name.discard(chat)
        return send(chat, f"Сервер <b>{esc(NAME)}</b>. Выбери действие 👇")
    if t == BTN_ADD:
        waiting_name.add(chat)
        return send(chat, "Как назвать пользователя? Напиши имя, например: <b>Марина</b>",
                    {"inline_keyboard": [[ib_btn("✖ Отмена", "cancel")]]})
    if t == BTN_LIST:
        waiting_name.discard(chat)
        cfg = load()
        if not clients(cfg):
            return send(chat, "Пользователей пока нет. Жми «➕ Добавить».")
        return send(chat, f"Пользователи ({len(clients(cfg))}). Нажми на имя:", users_kb(cfg))
    if chat in waiting_name:
        name = re.sub(r"\s+", "_", t)[:32]
        if not re.fullmatch(r"[\w.-]+", name):
            return send(chat, "Имя: буквы, цифры, точка, дефис. Попробуй ещё раз.",
                        {"inline_keyboard": [[ib_btn("✖ Отмена", "cancel")]]})
        cfg = load()
        if by_name(cfg, name):
            return send(chat, f"<b>{esc(name)}</b> уже есть. Придумай другое имя.",
                        {"inline_keyboard": [[ib_btn("✖ Отмена", "cancel")]]})
        waiting_name.discard(chat)
        c = {"id": str(uuid.uuid4()), "flow": "xtls-rprx-vision", "email": name}
        clients(cfg).append(c)
        save(cfg)
        send(chat, f"✅ Добавлен <b>{esc(name)}</b>. Держи ключ:")
        return give_key(chat, cfg, c)
    send(chat, "Жми кнопки внизу 👇")


def on_button(chat, msg, data):
    if data == "cancel":
        waiting_name.discard(chat)
        return edit(chat, msg, "Отменено.")
    cfg = load()
    if data == "back":
        return edit(chat, msg, f"Пользователи ({len(clients(cfg))}). Нажми на имя:", users_kb(cfg))
    kind, _, short = data.partition(":")
    c = by_id(cfg, short)
    if not c:
        return edit(chat, msg, "Такого пользователя уже нет.", {"inline_keyboard": [[ib_btn("⬅ Назад", "back")]]})
    name = esc(c.get("email", "?"))
    if kind == "u":
        return edit(chat, msg, f"👤 <b>{name}</b>", user_kb(c))
    if kind == "k":
        return give_key(chat, cfg, c)
    if kind == "d":
        return edit(chat, msg, f"Удалить <b>{name}</b>? Его ключ перестанет работать.",
                    {"inline_keyboard": [[ib_btn("🗑 Да, удалить", "y:" + short), ib_btn("Отмена", "u:" + short)]]})
    if kind == "y":
        inbound(cfg)["settings"]["clients"] = [x for x in clients(cfg) if x is not c]
        save(cfg)
        return edit(chat, msg, f"🗑 <b>{name}</b> удалён.", {"inline_keyboard": [[ib_btn("⬅ К списку", "back")]]})


def main():
    global IP
    if not IP:
        IP = requests.get("https://ifconfig.me", timeout=10).text.strip()
    api("setMyCommands", commands=[{"command": "start", "description": "Меню"}])
    off = 0
    while True:
        try:
            r = requests.get(f"{API}/getUpdates", params={"offset": off, "timeout": 50,
                             "allowed_updates": json.dumps(["message", "callback_query"])}, timeout=60).json()
        except Exception:
            time.sleep(5)
            continue
        for u in r.get("result", []):
            off = u["update_id"] + 1
            try:
                if "callback_query" in u:
                    q = u["callback_query"]
                    api("answerCallbackQuery", callback_query_id=q["id"])
                    if q["from"]["id"] == ADMIN and "message" in q:
                        on_button(q["message"]["chat"]["id"], q["message"]["message_id"], q.get("data", ""))
                elif "message" in u:
                    m = u["message"]
                    if m.get("from", {}).get("id") == ADMIN and "text" in m:
                        on_text(m["chat"]["id"], m["text"])
            except Exception as e:
                chat = (u.get("message") or u.get("callback_query", {}).get("message") or {}).get("chat", {}).get("id")
                if chat:
                    send(chat, f"⚠️ Ошибка: {esc(str(e))}")


if __name__ == "__main__":
    main()
