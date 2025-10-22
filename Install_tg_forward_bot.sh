#!/usr/bin/env bash
set -euo pipefail

# ========== VPN Shop Bot Installer (Ubuntu/Debian) ==========
# Usage:
#   sudo bash -c "$(curl -fsSL https://YOUR_RAW_URL/install_vpn_shop_bot.sh)" @ install
#   sudo bash install_vpn_shop_bot.sh @ install
#   sudo bash install_vpn_shop_bot.sh @ uninstall
# ============================================================

NAME="vpn-shop-bot"
BASE_DIR="/opt/$NAME"
VENV_DIR="$BASE_DIR/.venv"
SERVICE_FILE="/etc/systemd/system/$NAME.service"

ensure_root() { [[ $EUID -eq 0 ]] || { echo "❌ Run as root (use sudo)."; exit 1; }; }

prompt_nonempty() {
  local v
  while true; do
    read -r -p "$1" v || true
    v="${v%"${v##*[![:space:]]}"}"
    [[ -n "$v" ]] && { echo "$v"; return 0; }
    echo "⚠️ مقدار نمی‌تواند خالی باشد."
  done
}

prompt_token() {
  local t
  while true; do
    t="$(prompt_nonempty '🔑 Telegram BOT_TOKEN (از BotFather): ')"
    [[ "$t" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]] && { echo "$t"; return 0; }
    echo "⚠️ فرمت توکن اشتباه است. نمونه: 123456789:ABC_def..."
  done
}

prompt_admin_id() {
  local a
  while true; do
    a="$(prompt_nonempty '👤 ADMIN_ID (آیدی عددی ادمین): ')"
    [[ "$a" =~ ^-?[0-9]+$ ]] && { echo "$a"; return 0; }
    echo "⚠️ فقط عدد مجاز است."
  done
}

install_system_deps() {
  apt-get update -y
  apt-get install -y python3 python3-venv python3-pip curl
}

write_requirements() {
  cat > "$BASE_DIR/requirements.txt" <<'REQ'
python-telegram-bot==20.7
PyYAML>=6.0
aiohttp>=3.9
REQ
}

write_config_yaml() {
  local token="$1" admin_id="$2"
  cat > "$BASE_DIR/config.yaml" <<YAML
telegram:
  bot_token: "$token"
  admin_ids: [$admin_id]

shop:
  currency: "تومان"
  trial:
    data_gb: 1
    days: 1
    once_per_user: true
  reseller:
    default_discount_percent: 15

# ⚠️ برای اتصال واقعی به پنل‌ها، این بخش را با اطلاعات صحیح پر کنید.
# اگر خالی بماند، خرید/تست به‌صورت راهنما پیام می‌دهد.
panels: []

# نمونه پلن‌ها (می‌توانید ویرایش/حذف کنید)
plans:
  - sku: "sample-10-30"
    title: "نمونه 10GB / 30 روز"
    price: 100000
    panel: "SET_ME"       # نام یکی از panels بالا
    data_gb: 10
    days: 30
YAML
}

write_db_py() {
  cat > "$BASE_DIR/db.py" <<'PY'
import sqlite3
from contextlib import closing

SCHEMA = """
PRAGMA journal_mode=WAL;
CREATE TABLE IF NOT EXISTS users(
  tg_id INTEGER PRIMARY KEY,
  username TEXT,
  balance INTEGER DEFAULT 0,
  role TEXT DEFAULT 'user',
  created_at INTEGER
);
CREATE TABLE IF NOT EXISTS vouchers(
  code TEXT PRIMARY KEY,
  amount INTEGER NOT NULL,
  used_by INTEGER,
  used_at INTEGER
);
CREATE TABLE IF NOT EXISTS orders(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  tg_id INTEGER,
  sku TEXT,
  panel TEXT,
  data_gb INTEGER,
  days INTEGER,
  price INTEGER,
  status TEXT,
  config_text TEXT,
  created_at INTEGER
);
"""

def connect(db_path="shop.db"):
  con = sqlite3.connect(db_path, check_same_thread=False)
  con.row_factory = sqlite3.Row
  with closing(con.cursor()) as cur:
    cur.executescript(SCHEMA)
    con.commit()
  return con

def get_user(con, tg_id):
  cur = con.execute("SELECT * FROM users WHERE tg_id=?", (tg_id,))
  r = cur.fetchone()
  if r: return r
  con.execute("INSERT OR IGNORE INTO users(tg_id, created_at) VALUES(?, strftime('%s','now'))", (tg_id,))
  con.commit()
  return get_user(con, tg_id)

def add_balance(con, tg_id, amount):
  con.execute("UPDATE users SET balance=COALESCE(balance,0)+? WHERE tg_id=?", (amount, tg_id))
  con.commit()

def use_voucher(con, tg_id, code):
  cur = con.execute("SELECT * FROM vouchers WHERE code=? AND used_by IS NULL", (code,))
  v = cur.fetchone()
  if not v: return None
  con.execute("UPDATE vouchers SET used_by=?, used_at=strftime('%s','now') WHERE code=?", (tg_id, code))
  add_balance(con, tg_id, v["amount"])
  return v["amount"]

def create_order(con, tg_id, plan, price):
  con.execute("""INSERT INTO orders(tg_id, sku, panel, data_gb, days, price, status, created_at)
                 VALUES (?,?,?,?,?,?, 'created', strftime('%s','now'))""",
                 (tg_id, plan["sku"], plan["panel"], plan["data_gb"], plan["days"], price))
  con.commit()
  return con.execute("SELECT * FROM orders WHERE id=last_insert_rowid()").fetchone()

def set_order_result(con, order_id, status, config_text=None):
  con.execute("UPDATE orders SET status=?, config_text=? WHERE id=?", (status, config_text, order_id))
  con.commit()
PY
}

write_panel_adapters() {
  cat > "$BASE_DIR/panel_adapters.py" <<'PY'
import aiohttp

class BaseAdapter:
  def __init__(self, spec):
    self.name = spec["name"]
    self.base_url = spec["base_url"].rstrip("/")
    self.key = spec["api_key"]
    self.verify_ssl = spec.get("verify_ssl", True)
    self.ep = spec.get("endpoints", {})
    self.map = spec.get("mapping", {})

  def _url(self, key, **kw):
    return self.base_url + self.ep.get(key, "").format(**kw)

  async def _req(self, method, url, json=None, params=None, headers=None):
    h = {"Authorization": f"Bearer {self.key}", "Content-Type":"application/json"}
    if headers: h.update(headers)
    async with aiohttp.ClientSession() as s:
      async with s.request(method, url, json=json, params=params, ssl=self.verify_ssl, headers=h) as r:
        txt = await r.text()
        if r.status >= 400:
          raise RuntimeError(f"{r.status} {txt}")
        ct = r.headers.get("Content-Type","")
        return await r.json() if "application/json" in ct else txt

  async def create_user(self, username, data_gb, days): raise NotImplementedError
  async def create_trial(self, username, data_gb, days): raise NotImplementedError

class MarzbanAdapter(BaseAdapter):
  async def create_user(self, username, data_gb, days):
    url = self._url("create_user")
    payload = {
      "username": username,
      "data_limit": int(data_gb) * 1024**3,
      "expire": f"{int(days)}d",
      "proxies": [{"type": self.map.get("flow","vless")}]
    }
    res = await self._req("POST", url, json=payload)
    return res.get("subscription_url") or res.get("subscription") or str(res)

  async def create_trial(self, username, data_gb, days):
    return await self.create_user(username, data_gb, days)

class SenayiAdapter(BaseAdapter):
  async def create_user(self, username, data_gb, days):
    url = self._url("create_user")
    payload = {"username": username, "traffic": f"{data_gb}GB", "days": int(days)}
    res = await self._req("POST", url, json=payload)
    return res.get("subscription_url") or res.get("config") or str(res)

  async def create_trial(self, username, data_gb, days):
    url = self._url("create_trial")
    payload = {"username": username, "traffic": f"{data_gb}GB", "days": int(days), "trial": True}
    res = await self._req("POST", url, json=payload)
    return res.get("subscription_url") or str(res)

class MarzneshinAdapter(BaseAdapter):
  async def create_user(self, username, data_gb, days):
    url = self._url("create_user")
    payload = {"username": username, "data": int(data_gb), "days": int(days)}
    res = await self._req("POST", url, json=payload)
    return res.get("subscription_url") or str(res)

  async def create_trial(self, username, data_gb, days):
    url = self._url("create_trial")
    payload = {"username": username, "data": int(data_gb), "days": int(days), "trial": True}
    res = await self._req("POST", url, json=payload)
    return res.get("subscription_url") or str(res)

def build_adapter(spec):
  t = spec["type"].lower()
  if t == "marzban": return MarzbanAdapter(spec)
  if t == "senayi": return SenayiAdapter(spec)
  if t == "marzneshin": return MarzneshinAdapter(spec)
  raise ValueError(f"unknown panel type: {t}")
PY
}

write_bot_py() {
  cat > "$BASE_DIR/bot.py" <<'PY'
# -*- coding: utf-8 -*-
import os, yaml, math, re
from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup, ReplyKeyboardMarkup, KeyboardButton
from telegram.ext import Application, CommandHandler, MessageHandler, CallbackQueryHandler, ContextTypes, filters
from db import connect, get_user, add_balance, use_voucher, create_order, set_order_result
from panel_adapters import build_adapter

with open("config.yaml","r",encoding="utf-8") as f:
  CFG = yaml.safe_load(f)

BOT_TOKEN = CFG["telegram"]["bot_token"]
ADMINS = set(CFG["telegram"]["admin_ids"])
CURRENCY = CFG["shop"]["currency"]
TRIAL = CFG["shop"]["trial"]
RESELLER_DEFAULT = CFG["shop"]["reseller"]["default_discount_percent"]
PLANS = {p["sku"]: p for p in CFG.get("plans", [])}
PANELS = {p["name"]: build_adapter(p) for p in CFG.get("panels", [])}

con = connect("shop.db")

def is_admin(uid:int)->bool: return uid in ADMINS
def price_after_discount(price, disc): return math.ceil(price * (100 - disc)/100)

def main_menu(is_reseller=False):
  rows = [
    [KeyboardButton("🧾 حساب کاربری"), KeyboardButton("💳 افزایش موجودی")],
    [KeyboardButton("🛒 خرید کانفیگ"), KeyboardButton("🎁 دریافت تست")],
    [KeyboardButton("🤝 دریافت نمایندگی")]
  ]
  return ReplyKeyboardMarkup(rows, resize_keyboard=True)

async def cmd_start(update:Update, context:ContextTypes.DEFAULT_TYPE):
  u = get_user(con, update.effective_user.id)
  role = u["role"] or "user"
  await update.message.reply_text("خوش آمدید 👋 از منوی زیر استفاده کنید.", reply_markup=main_menu(role=="reseller"))

async def on_text(update:Update, context:ContextTypes.DEFAULT_TYPE):
  text = (update.message.text or "").strip()
  uid = update.effective_user.id
  u = get_user(con, uid)
  role = u["role"] or "user"

  if text == "🧾 حساب کاربری":
    return await update.message.reply_text(f"شناسه: {uid}\nموجودی: {u['balance']} {CURRENCY}", reply_markup=main_menu(role=="reseller"))

  if text == "💳 افزایش موجودی":
    context.user_data["await_voucher"]=True
    return await update.message.reply_text("کد شارژ/ووچر را ارسال کنید (مثال: ABC-123-XYZ).")

  if text == "🛒 خرید کانفیگ":
    if not PLANS or not PANELS:
      return await update.message.reply_text("⚠️ هنوز هیچ پلن/پنلی در config.yaml تنظیم نشده.")
    rows=[[InlineKeyboardButton(f"{p['title']} — {p['price']} {CURRENCY}", callback_data=f"buy:{p['sku']}")] for p in PLANS.values()]
    return await update.message.reply_text("پلن مورد نظر را انتخاب کنید:", reply_markup=InlineKeyboardMarkup(rows))

  if text == "🎁 دریافت تست":
    if not PANELS:
      return await update.message.reply_text("⚠️ هیچ پنلی تنظیم نشده است.")
    kb = InlineKeyboardMarkup([[InlineKeyboardButton("تایید دریافت تست", callback_data="trial:confirm")]])
    return await update.message.reply_text("یک کانفیگ تست ساخته می‌شود. تایید می‌کنید؟", reply_markup=kb)

  if text == "🤝 دریافت نمایندگی":
    if role=="reseller":
      return await update.message.reply_text("شما هم‌اکنون نماینده هستید.")
    for a in ADMINS:
      try: await context.bot.send_message(a, f"درخواست نمایندگی از کاربر {uid}")
      except Exception: pass
    return await update.message.reply_text("درخواست شما برای ادمین ارسال شد.")

  if context.user_data.pop("await_voucher", False):
    amount = use_voucher(con, uid, text.strip())
    if amount:
      return await update.message.reply_text(f"✅ {amount} {CURRENCY} به موجودی افزوده شد.")
    else:
      return await update.message.reply_text("❌ کد نامعتبر یا استفاده شده است.")

async def cb_buy(update:Update, context:ContextTypes.DEFAULT_TYPE):
  q=update.callback_query; await q.answer()
  sku=q.data.split(":")[1]
  plan=PLANS.get(sku)
  if not plan: return await q.edit_message_text("پلن یافت نشد.")
  u=get_user(con, update.effective_user.id)
  role=u["role"] or "user"
  price=plan["price"] if role!="reseller" else price_after_discount(plan["price"], RESELLER_DEFAULT)
  if (u["balance"] or 0) < price:
    return await q.edit_message_text(f"❌ موجودی کافی نیست. قیمت: {price} {CURRENCY}")
  if plan["panel"] not in PANELS:
    return await q.edit_message_text("⚠️ پنل مربوط به این پلن در config.yaml تعریف نشده.")
  order=create_order(con, u["tg_id"], plan, price)
  con.execute("UPDATE users SET balance=balance-? WHERE tg_id=?", (price, u["tg_id"])); con.commit()
  adapter=PANELS[plan["panel"]]
  username=f"{plan['panel']}_{u['tg_id']}_{order['id']}"
  try:
    cfg=await adapter.create_user(username=username, data_gb=plan["data_gb"], days=plan["days"])
    set_order_result(con, order["id"], "delivered", cfg)
    await q.edit_message_text("✅ خرید موفق. کانفیگ شما:\n\n"+str(cfg))
  except Exception as e:
    set_order_result(con, order["id"], "failed", str(e))
    add_balance(con, u["tg_id"], price)
    await q.edit_message_text("❌ ساخت کانفیگ ناموفق بود: "+str(e))

async def cb_trial(update:Update, context:ContextTypes.DEFAULT_TYPE):
  q=update.callback_query; await q.answer()
  if not PANELS:
    return await q.edit_message_text("⚠️ هیچ پنلی تنظیم نشده است.")
  panel_name=list(PANELS.keys())[0]
  adapter=PANELS[panel_name]
  plan={"sku":"_TRIAL_","panel":panel_name,"data_gb":TRIAL["data_gb"],"days":TRIAL["days"]}
  order=create_order(con, update.effective_user.id, plan, 0)
  username=f"trial_{update.effective_user.id}_{order['id']}"
  try:
    cfg=await adapter.create_trial(username=username, data_gb=plan["data_gb"], days=plan["days"])
    set_order_result(con, order["id"], "delivered", cfg)
    await q.edit_message_text("🎁 تست شما:\n\n"+str(cfg))
  except Exception as e:
    set_order_result(con, order["id"], "failed", str(e))
    await q.edit_message_text("❌ ساخت تست ناموفق بود: "+str(e))

def build_app():
  app=Application.builder().token(BOT_TOKEN).build()
  app.add_handler(CommandHandler("start", cmd_start))
  app.add_handler(CommandHandler("admin", lambda u,c: u.message.reply_text("پنل مدیریت—فعلاً از ووچر/نمایندگی متنی استفاده کنید.")))
  app.add_handler(CallbackQueryHandler(cb_buy, pattern=r"^buy:.+"))
  app.add_handler(CallbackQueryHandler(cb_trial, pattern=r"^trial:confirm$"))
  app.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, on_text))
  return app

def main():
  print("✅ VPN shop bot running…")
  build_app().run_polling(close_loop=False)

if __name__=="__main__":
  main()
PY
}

write_service() {
  cat > "$SERVICE_FILE" <<SERVICE
[Unit]
Description=VPN Shop Bot ($NAME)
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$BASE_DIR
ExecStart=$VENV_DIR/bin/python $BASE_DIR/bot.py
Restart=on-failure
RestartSec=5
StandardOutput=append:$BASE_DIR/bot.log
StandardError=append:$BASE_DIR/bot.err

[Install]
WantedBy=multi-user.target
SERVICE
  systemctl daemon-reload
  systemctl enable "$NAME"
}

cmd_install() {
  ensure_root
  install_system_deps
  mkdir -p "$BASE_DIR"
  write_requirements
  local token admin
  token="$(prompt_token)"
  admin="$(prompt_admin_id)"
  write_config_yaml "$token" "$admin"
  write_db_py
  write_panel_adapters
  write_bot_py
  python3 -m venv "$VENV_DIR"
  # shellcheck disable=SC1091
  . "$VENV_DIR/bin/activate"
  pip install --upgrade pip
  pip install -r "$BASE_DIR/requirements.txt"
  write_service
  systemctl restart "$NAME"
  systemctl status "$NAME" --no-pager -l || true
  echo
  echo "🎉 نصب شد. مسیر: $BASE_DIR"
  echo "📄 تنظیمات: $BASE_DIR/config.yaml  (برای اتصال به پنل‌ها پر کنید)"
  echo "📝 لاگ‌ها:  $BASE_DIR/bot.log  و  $BASE_DIR/bot.err"
}

cmd_uninstall() {
  ensure_root
  systemctl stop "$NAME" 2>/dev/null || true
  systemctl disable "$NAME" 2>/dev/null || true
  rm -f "$SERVICE_FILE"
  systemctl daemon-reload
  rm -rf "$BASE_DIR"
  echo "✔️ حذف شد."
}

SUB="${1:-}"
[[ "$SUB" == "@" ]] && { shift; SUB="${1:-}"; }
case "$SUB" in
  install)   cmd_install ;;
  uninstall) cmd_uninstall ;;
  *) echo "Usage: $0 @ {install|uninstall}"; exit 1 ;;
esac
