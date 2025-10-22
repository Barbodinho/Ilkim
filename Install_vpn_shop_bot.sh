#!/usr/bin/env bash
set -euo pipefail

# ===================== VPN Shop Bot Installer =====================
# Features:
# - Asks BOT_TOKEN + ADMIN_ID on install
# - Creates full Telegram VPN shop bot with admin panel
# - Panels (Marzban / Senayi / Marzneshin) configurable INSIDE the bot
# - SQLite DB, systemd service, QR code delivery
# Usage:
#   sudo bash -c "$(curl -fsSL https://RAW_URL/install_vpn_shop_bot.sh)" @ install
#   sudo bash install_vpn_shop_bot.sh @ {install|reconfigure|status|logs|uninstall}
# =================================================================

NAME="vpn-shop-bot"
BASE="/opt/$NAME"
VENV="$BASE/.venv"
SVC="/etc/systemd/system/$NAME.service"

ensure_root(){ [[ $EUID -eq 0 ]] || { echo "❌ لطفاً با sudo اجرا کنید."; exit 1; }; }

ask_nonempty(){
  local p v; p="$1"
  while true; do
    read -r -p "$p" v || true
    v="${v%"${v##*[![:space:]]}"}"
    [[ -n "$v" ]] && { echo "$v"; return; }
    echo "⚠️ خالی نباشه."
  done
}
ask_token(){
  local t
  while true; do
    t="$(ask_nonempty '🔑 Telegram BOT_TOKEN: ')"
    [[ "$t" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]] && { echo "$t"; return; }
    echo "⚠️ فرمت توکن اشتباه است."
  done
}
ask_admin(){
  local a
  while true; do
    a="$(ask_nonempty '👤 ADMIN_ID (آیدی عددی): ')"
    [[ "$a" =~ ^-?[0-9]+$ ]] && { echo "$a"; return; }
    echo "⚠️ فقط عدد."
  done
}

sys_deps(){
  apt-get update -y
  apt-get install -y python3 python3-venv python3-pip curl
}

reqs(){
  cat >"$BASE/requirements.txt"<<'REQ'
python-telegram-bot==20.7
PyYAML>=6.0
aiohttp>=3.9
qrcode[pil]>=7.4
Pillow>=10.3
REQ
}

config_yaml(){
  local token="$1" admin="$2"
  cat >"$BASE/config.yaml"<<YAML
telegram:
  bot_token: "$token"
  admin_ids: [$admin]

shop:
  currency: "تومان"
  trial:
    data_gb: 1
    days: 1
    once_per_user: true
  reseller:
    default_discount_percent: 15

# NOTE: از داخل «مدیریت پنل ← اضافه‌کردن پنل» می‌تونی پنل‌ها رو بسازی.
panels: []     # اینجا می‌ماند؛ پنل‌های واقعی در DB ذخیره می‌شود.

plans: []      # محصولات را هم از داخل «اضافه‌کردن/ویرایش محصولات» بساز.
YAML
}

db_py(){
  cat >"$BASE/db.py"<<'PY'
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
  sub_url TEXT,
  created_at INTEGER
);
CREATE TABLE IF NOT EXISTS panels(
  name TEXT PRIMARY KEY,
  type TEXT NOT NULL,                  -- marzban | senayi | marzneshin
  base_url TEXT NOT NULL,
  api_key TEXT NOT NULL,
  verify_ssl INTEGER DEFAULT 1,
  endpoints TEXT,                      -- YAML/JSON (str)
  mapping TEXT                         -- YAML/JSON (str)
);
CREATE TABLE IF NOT EXISTS products(
  sku TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  price INTEGER NOT NULL,
  panel TEXT NOT NULL,
  data_gb INTEGER NOT NULL,
  days INTEGER NOT NULL,
  active INTEGER DEFAULT 1
);
CREATE TABLE IF NOT EXISTS settings(
  key TEXT PRIMARY KEY,
  val TEXT
);
"""

def connect(db_path="shop.db"):
  con = sqlite3.connect(db_path, check_same_thread=False)
  con.row_factory = sqlite3.Row
  with closing(con.cursor()) as cur:
    cur.executescript(SCHEMA)
    con.commit()
  return con

# users
def get_user(con, tg_id):
  r = con.execute("SELECT * FROM users WHERE tg_id=?", (tg_id,)).fetchone()
  if r: return r
  con.execute("INSERT OR IGNORE INTO users(tg_id, created_at) VALUES(?, strftime('%s','now'))", (tg_id,))
  con.commit()
  return con.execute("SELECT * FROM users WHERE tg_id=?", (tg_id,)).fetchone()

def add_balance(con, tg_id, amount):
  con.execute("UPDATE users SET balance=COALESCE(balance,0)+? WHERE tg_id=?", (amount, tg_id)); con.commit()

def dec_balance(con, tg_id, amount):
  con.execute("UPDATE users SET balance=COALESCE(balance,0)-? WHERE tg_id=?", (amount, tg_id)); con.commit()

def use_voucher(con, tg_id, code):
  v = con.execute("SELECT * FROM vouchers WHERE code=? AND used_by IS NULL", (code,)).fetchone()
  if not v: return None
  con.execute("UPDATE vouchers SET used_by=?, used_at=strftime('%s','now') WHERE code=?", (tg_id, code))
  add_balance(con, tg_id, v["amount"])
  return v["amount"]

# orders
def create_order(con, tg_id, plan, price):
  con.execute("""INSERT INTO orders(tg_id, sku, panel, data_gb, days, price, status, created_at)
                 VALUES (?,?,?,?,?,?, 'created', strftime('%s','now'))""",
                 (tg_id, plan["sku"], plan["panel"], plan["data_gb"], plan["days"], price))
  con.commit()
  return con.execute("SELECT * FROM orders WHERE id=last_insert_rowid()").fetchone()

def set_order_result(con, order_id, status, cfg=None, sub=None):
  con.execute("UPDATE orders SET status=?, config_text=?, sub_url=? WHERE id=?",(status, cfg, sub, order_id)); con.commit()

def user_orders(con, tg_id):
  return con.execute("SELECT * FROM orders WHERE tg_id=? ORDER BY id DESC", (tg_id,)).fetchall()

# panels
def list_panels(con): return con.execute("SELECT * FROM panels ORDER BY name").fetchall()
def upsert_panel(con, name, type_, base, key, verify_ssl, endpoints, mapping):
  con.execute("""INSERT INTO panels(name,type,base_url,api_key,verify_ssl,endpoints,mapping)
                 VALUES (?,?,?,?,?,?,?)
                 ON CONFLICT(name) DO UPDATE SET
                 type=excluded.type, base_url=excluded.base_url, api_key=excluded.api_key,
                 verify_ssl=excluded.verify_ssl, endpoints=excluded.endpoints, mapping=excluded.mapping
              """,(name,type_,base,key,1 if verify_ssl else 0,endpoints,mapping)); con.commit()
def delete_panel(con, name): con.execute("DELETE FROM panels WHERE name=?", (name,)); con.commit()

# products
def list_products(con): return con.execute("SELECT * FROM products WHERE active=1 ORDER BY rowid DESC").fetchall()
def get_product(con, sku): return con.execute("SELECT * FROM products WHERE sku=?", (sku,)).fetchone()
def upsert_product(con, sku, title, price, panel, data_gb, days, active=1):
  con.execute("""INSERT INTO products(sku,title,price,panel,data_gb,days,active)
                 VALUES (?,?,?,?,?,?,?)
                 ON CONFLICT(sku) DO UPDATE SET
                 title=excluded.title, price=excluded.price, panel=excluded.panel,
                 data_gb=excluded.data_gb, days=excluded.days, active=excluded.active
              """,(sku,title,price,panel,data_gb,days,active)); con.commit()
def deactivate_product(con, sku):
  con.execute("UPDATE products SET active=0 WHERE sku=?", (sku,)); con.commit()
PY
}

adapters_py(){
  cat >"$BASE/panel_adapters.py"<<'PY'
import aiohttp, json, yaml

class BaseAdapter:
  def __init__(self, spec):
    self.name = spec["name"]
    self.type = spec["type"]
    self.base_url = spec["base_url"].rstrip("/")
    self.key = spec["api_key"]
    self.verify_ssl = bool(spec.get("verify_ssl", 1))
    self.ep = yaml.safe_load(spec["endpoints"]) if isinstance(spec.get("endpoints"), str) else (spec.get("endpoints") or {})
    self.map = yaml.safe_load(spec["mapping"]) if isinstance(spec.get("mapping"), str) else (spec.get("mapping") or {})

  def _url(self, key, **kw): return self.base_url + (self.ep.get(key,"") or "").format(**kw)

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

  async def create_user(self, username, data_gb, days):
    raise NotImplementedError
  async def create_trial(self, username, data_gb, days):
    raise NotImplementedError

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
    sub = (res.get("subscription_url") if isinstance(res,dict) else None) or ""
    return sub, res

  async def create_trial(self, username, data_gb, days):
    return await self.create_user(username, data_gb, days)

class SenayiAdapter(BaseAdapter):
  async def create_user(self, username, data_gb, days):
    url=self._url("create_user")
    payload={"username":username,"traffic":f"{data_gb}GB","days":int(days)}
    res=await self._req("POST",url,json=payload)
    sub=(res.get("subscription_url") if isinstance(res,dict) else None) or ""
    return sub, res
  async def create_trial(self, username, data_gb, days):
    url=self._url("create_trial")
    payload={"username":username,"traffic":f"{data_gb}GB","days":int(days),"trial":True}
    res=await self._req("POST",url,json=payload)
    sub=(res.get("subscription_url") if isinstance(res,dict) else None) or ""
    return sub, res

class MarzneshinAdapter(BaseAdapter):
  async def create_user(self, username, data_gb, days):
    url=self._url("create_user")
    payload={"username":username,"data":int(data_gb),"days":int(days)}
    res=await self._req("POST",url,json=payload)
    sub=(res.get("subscription_url") if isinstance(res,dict) else None) or ""
    return sub, res
  async def create_trial(self, username, data_gb, days):
    url=self._url("create_trial")
    payload={"username":username,"data":int(data_gb),"days":int(days),"trial":True}
    res=await self._req("POST",url,json=payload)
    sub=(res.get("subscription_url") if isinstance(res,dict) else None) or ""
    return sub, res

def build_adapter(spec):
  t = spec["type"].lower()
  if t=="marzban": return MarzbanAdapter(spec)
  if t=="senayi": return SenayiAdapter(spec)
  if t=="marzneshin": return MarzneshinAdapter(spec)
  raise ValueError(f"unknown panel type: {t}")
PY
}

bot_py(){
  cat >"$BASE/bot.py"<<'PY'
# -*- coding: utf-8 -*-
import os, io, yaml, math, re, json, sqlite3, qrcode
from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup, ReplyKeyboardMarkup, KeyboardButton, InputFile
from telegram.ext import Application, CommandHandler, MessageHandler, CallbackQueryHandler, ContextTypes, filters
from db import connect, get_user, add_balance, dec_balance, use_voucher, create_order, set_order_result, user_orders, \
               list_panels, upsert_panel, delete_panel, list_products, get_product, upsert_product, deactivate_product
from panel_adapters import build_adapter

# ------------ Load config ------------
with open("config.yaml","r",encoding="utf-8") as f:
  CFG = yaml.safe_load(f)
BOT_TOKEN = CFG["telegram"]["bot_token"]
ADMINS = set(CFG["telegram"]["admin_ids"])
CURRENCY = CFG["shop"]["currency"]
TRIAL = CFG["shop"]["trial"]
RESELLER_DEFAULT = CFG["shop"]["reseller"]["default_discount_percent"]

con = connect("shop.db")

def is_admin(uid:int)->bool: return uid in ADMINS
def price_after_discount(price, disc): return math.ceil(price*(100-disc)/100)

def main_kb(is_reseller=False):
  rows = [
    [KeyboardButton("🧾 حساب کاربری"), KeyboardButton("💳 افزایش موجودی")],
    [KeyboardButton("🛒 خرید کانفیگ"), KeyboardButton("🎁 دریافت تست")],
    [KeyboardButton("📦 کانفیگ‌های من")]
  ]
  if is_reseller or True:
    rows.append([KeyboardButton("🛠 پنل مدیریت")])
  return ReplyKeyboardMarkup(rows, resize_keyboard=True)

def admin_kb():
  return InlineKeyboardMarkup([
    [InlineKeyboardButton("🧩 مدیریت پنل", callback_data="adm:panels"),
     InlineKeyboardButton("➕ اضافه‌کردن پنل", callback_data="adm:panel_add")],
    [InlineKeyboardButton("🎁 مدیریت تست", callback_data="adm:trial")],
    [InlineKeyboardButton("🛒 اضافه‌کردن محصول", callback_data="adm:prod_add"),
     InlineKeyboardButton("✏️ ویرایش محصولات", callback_data="adm:prod_edit")],
    [InlineKeyboardButton("⬆️ افزایش موجودی", callback_data="adm:bal_inc"),
     InlineKeyboardButton("⬇️ کاهش موجودی", callback_data="adm:bal_dec")],
  ])

def panel_row(p):
  return f"• {p['name']} ({p['type']}) → {p['base_url']}"

async def cmd_start(update:Update, context:ContextTypes.DEFAULT_TYPE):
  u=get_user(con, update.effective_user.id)
  role=u["role"] or "user"
  await update.message.reply_text(
    "سلام! 👋\nبه فروشگاه VPN خوش آمدید. از منوی زیر استفاده کنید.\n"
    "برای خرید، ابتدا موجودی‌تان را افزایش دهید؛ سپس از «🛒 خرید کانفیگ» پلن دلخواه را انتخاب کنید.",
    reply_markup=main_kb(role=='reseller')
  )

# =================== USER FLOWS ===================
async def on_text(update:Update, context:ContextTypes.DEFAULT_TYPE):
  txt=(update.message.text or "").strip()
  uid=update.effective_user.id
  u=get_user(con, uid)
  role=u["role"] or "user"

  if txt=="🧾 حساب کاربری":
    orders = user_orders(con, uid)
    await update.message.reply_text(
      f"شناسه شما: {uid}\nنقش: {role}\nموجودی: {u['balance']} {CURRENCY}\n"
      f"تعداد سفارشات: {len(orders)}",
      reply_markup=main_kb(role=='reseller')
    ); return

  if txt=="💳 افزایش موجودی":
    context.user_data["await_voucher"]=True
    return await update.message.reply_text("کد شارژ/ووچر را ارسال کنید (مثال: ABC-123-XYZ).")

  if context.user_data.pop("await_voucher", False):
    amount=use_voucher(con, uid, txt)
    if amount: return await update.message.reply_text(f"✅ {amount} {CURRENCY} به موجودی افزوده شد.")
    else: return await update.message.reply_text("❌ کد نامعتبر یا استفاده‌شده است.")

  if txt=="🛒 خرید کانفیگ":
    prods=list_products(con)
    if not prods: return await update.message.reply_text("⚠️ هنوز محصولی تعریف نشده. با ادمین در میان بگذارید.")
    rows=[[InlineKeyboardButton(f"{p['title']} — {p['price']} {CURRENCY}", callback_data=f"buy:{p['sku']}")] for p in prods]
    return await update.message.reply_text("پلن مورد نظر را انتخاب کنید:", reply_markup=InlineKeyboardMarkup(rows))

  if txt=="🎁 دریافت تست":
    kb=InlineKeyboardMarkup([[InlineKeyboardButton("تایید دریافت تست",callback_data="trial:ok")]])
    return await update.message.reply_text(
      f"یک تست {TRIAL['data_gb']}GB برای {TRIAL['days']} روز ساخته می‌شود. تایید می‌کنید؟",
      reply_markup=kb)

  if txt=="📦 کانفیگ‌های من":
    orders=user_orders(con, uid)
    if not orders: return await update.message.reply_text("هنوز سفارشی ندارید.")
    rows=[]
    for o in orders:
      cap=f"#{o['id']} {o['sku']} | {o['status']}"
      rows.append([InlineKeyboardButton(cap, callback_data=f"my:{o['id']}")])
    return await update.message.reply_text("لیست سفارشات/تست‌های شما:", reply_markup=InlineKeyboardMarkup(rows))

  if txt=="🛠 پنل مدیریت":
    if not is_admin(uid): return await update.message.reply_text("⛔️ فقط ادمین.")
    return await update.message.reply_text("پنل مدیریت:", reply_markup=admin_kb())

# ---------- BUY ----------
def adapters_from_db():
  pans=[]
  for p in list_panels(con):
    spec=dict(p)
    pans.append(build_adapter(spec))
  return {p.name: p for p in pans}

async def cb_buy(update:Update, context:ContextTypes.DEFAULT_TYPE):
  q=update.callback_query; await q.answer()
  sku=q.data.split(":")[1]
  uid=q.from_user.id
  u=get_user(con, uid)
  role=u["role"] or "user"
  prod=get_product(con, sku)
  if not prod or not prod["active"]:
    return await q.edit_message_text("این محصول موجود نیست.")
  price=prod["price"] if role!="reseller" else math.ceil(prod["price"]*0.85)
  if (u["balance"] or 0) < price:
    return await q.edit_message_text(f"❌ موجودی کافی نیست. قیمت: {price} {CURRENCY}")

  adapters=adapters_from_db()
  if prod["panel"] not in adapters:
    return await q.edit_message_text("⚠️ پنل مربوط به این محصول تعریف نشده.")
  order=create_order(con, uid, {"sku":prod["sku"],"panel":prod["panel"],"data_gb":prod["data_gb"],"days":prod["days"]}, price)
  dec_balance(con, uid, price)
  adapter=adapters[prod["panel"]]
  username=f"{prod['panel']}_{uid}_{order['id']}"
  try:
    sub,res=await adapter.create_user(username=username, data_gb=prod["data_gb"], days=prod["days"])
    cfg_txt = res.get("config") if isinstance(res,dict) else None
    set_order_result(con, order["id"], "delivered", cfg_txt, sub)
    await deliver_config(q, sub or cfg_txt, title=f"سفارش #{order['id']}")
    await q.edit_message_text("✅ خرید موفق. کانفیگ برای شما ارسال شد.")
  except Exception as e:
    set_order_result(con, order["id"], "failed", str(e), None)
    add_balance(con, uid, price)
    await q.edit_message_text("❌ ساخت کانفیگ ناموفق بود:\n"+str(e))

# ---------- TRIAL ----------
async def cb_trial(update:Update, context:ContextTypes.DEFAULT_TYPE):
  q=update.callback_query; await q.answer()
  uid=q.from_user.id
  adapters=adapters_from_db()
  if not adapters: return await q.edit_message_text("⚠️ هیچ پنلی تعریف نشده.")
  panel_name=list(adapters.keys())[0]
  adapter=adapters[panel_name]
  order=create_order(con, uid, {"sku":"_TRIAL_","panel":panel_name,"data_gb":TRIAL["data_gb"],"days":TRIAL["days"]}, 0)
  username=f"trial_{uid}_{order['id']}"
  try:
    sub,res=await adapter.create_trial(username=username, data_gb=TRIAL["data_gb"], days=TRIAL["days"])
    cfg_txt = res.get("config") if isinstance(res,dict) else None
    set_order_result(con, order["id"], "delivered", cfg_txt, sub)
    await deliver_config(q, sub or cfg_txt, title=f"تست #{order['id']}")
    await q.edit_message_text("🎁 تست برای شما ارسال شد.")
  except Exception as e:
    set_order_result(con, order["id"], "failed", str(e), None)
    await q.edit_message_text("❌ ساخت تست ناموفق بود:\n"+str(e))

# ---------- MY CONFIGS ----------
async def cb_my(update:Update, context:ContextTypes.DEFAULT_TYPE):
  q=update.callback_query; await q.answer()
  oid=int(q.data.split(":")[1])
  o = con.execute("SELECT * FROM orders WHERE id=? AND tg_id=?", (oid, q.from_user.id)).fetchone()
  if not o: return await q.edit_message_text("یافت نشد.")
  txt = (o["sub_url"] or o["config_text"] or "—")
  await deliver_config(q, txt, title=f"سفارش #{o['id']}")

# ---------- DELIVER CONFIG + QR ----------
async def deliver_config(q, content:str, title:str):
  text = f"{title}\n\n"
  text += ("Subscription:\n"+content) if content and content.startswith("http") else ("Config:\n"+(content or "—"))
  await q.message.chat.send_message(text)

  data = content or ""
  if not data: return
  # QR برای متن/ساب
  img = qrcode.make(data)
  bio = io.BytesIO(); img.save(bio, format="PNG"); bio.seek(0)
  await q.message.chat.send_photo(InputFile(bio, filename="config.png"), caption="📷 QR Code")

# =================== ADMIN ===================
async def cmd_admin(update:Update, context:ContextTypes.DEFAULT_TYPE):
  if not is_admin(update.effective_user.id): return
  await update.message.reply_text("پنل مدیریت:", reply_markup=admin_kb())

async def cb_admin(update:Update, context:ContextTypes.DEFAULT_TYPE):
  if not is_admin(update.effective_user.id): return
  q=update.callback_query; await q.answer()
  key=q.data.split(":")[1]
  if key=="panels":
    pans=list_panels(con)
    if not pans: return await q.edit_message_text("هنوز هیچ پنلی ثبت نشده.")
    rows=[]
    for p in pans:
      rows.append([InlineKeyboardButton(f"❌ حذف {p['name']}", callback_data=f"adm:panel_del:{p['name']}")])
    txt="🔧 پنل‌های فعلی:\n"+"\n".join([f"• {p['name']} ({p['type']})" for p in pans])
    return await q.edit_message_text(txt, reply_markup=InlineKeyboardMarkup(rows))
  if key.startswith("panel_del:"):
    name=key.split("panel_del:")[1]
    delete_panel(con, name)
    return await q.edit_message_text(f"✅ پنل «{name}» حذف شد.")
  if key=="panel_add":
    context.user_data["adm_wait"]="panel_add"
    return await q.edit_message_text(
      "اطلاعات پنل را به این فرمت بفرست:\n"
      "`name type base_url api_key verify_ssl`\n"
      "سپس یک بلوک YAML برای `endpoints` و (اختیاری) `mapping` بفرست.\n"
      "مثال:\n"
      "`mzb1 marzban https://mzb.example.com ABCDEF 1`\n"
      "```\nendpoints:\n  create_user: /api/admin/users\n  create_trial: /api/admin/users\nmapping:\n  flow: vless\n```",
      parse_mode="Markdown"
    )
  if key=="trial":
    context.user_data["adm_wait"]="trial"
    return await q.edit_message_text("مقدار تست را این‌گونه بفرست:\n`data_gb days`\nمثال: `1 1`", parse_mode="Markdown")
  if key=="prod_add":
    context.user_data["adm_wait"]="prod_add"
    return await q.edit_message_text(
      "محصول را به این فرمت بفرست:\n`sku | title | price | panel | data_gb | days`\n"
      "مثال:\n`mzb-100-30 | مرزبان 100GB/30روز | 180000 | mzb1 | 100 | 30`", parse_mode="Markdown")
  if key=="prod_edit":
    prods=list_products(con)
    if not prods: return await q.edit_message_text("محصولی نیست.")
    rows=[]
    for p in prods:
      rows.append([InlineKeyboardButton(f"✏️ {p['sku']}", callback_data=f"adm:prod_edit:{p['sku']}"),
                   InlineKeyboardButton("🚫 غیر فعال", callback_data=f"adm:prod_off:{p['sku']}")])
    return await q.edit_message_text("انتخاب کنید:", reply_markup=InlineKeyboardMarkup(rows))
  if key.startswith("prod_off:"):
    sku=key.split("prod_off:")[1]; deactivate_product(con, sku)
    return await q.edit_message_text(f"✅ محصول {sku} غیرفعال شد.")
  if key.startswith("prod_edit:"):
    sku=key.split("prod_edit:")[1]
    context.user_data["adm_wait"]="prod_edit:"+sku
    p=get_product(con, sku)
    return await q.edit_message_text(
      "ویرایش با فرمت:\n`title | price | panel | data_gb | days`\n"
      f"فعلی: {p['title']} | {p['price']} | {p['panel']} | {p['data_gb']} | {p['days']}",
      parse_mode="Markdown")
  if key=="bal_inc":
    context.user_data["adm_wait"]="bal_inc"
    return await q.edit_message_text("افزایش موجودی کاربر: `tg_id amount`")
  if key=="bal_dec":
    context.user_data["adm_wait"]="bal_dec"
    return await q.edit_message_text("کاهش موجودی کاربر: `tg_id amount`")

async def on_admin_text(update:Update, context:ContextTypes.DEFAULT_TYPE):
  if not is_admin(update.effective_user.id): return
  wait=context.user_data.get("adm_wait")
  if not wait: return
  txt=update.message.text.strip()

  if wait=="panel_add":
    # first line tokens
    parts=txt.splitlines()
    head=parts[0].strip("`")
    try:
      name,t,base,key,ver=head.split()
      block="\n".join(parts[1:]).strip("`")
      # try parse yaml
      y = yaml.safe_load(block) if block else {}
      endpoints=y.get("endpoints",{})
      mapping=y.get("mapping",{})
      upsert_panel(con, name, t, base, key, bool(int(ver)), yaml.safe_dump(endpoints), yaml.safe_dump(mapping))
      await update.message.reply_text("✅ پنل ثبت شد.")
    except Exception as e:
      await update.message.reply_text(f"❌ فرمت اشتباه: {e}")
    context.user_data["adm_wait"]=None
    return

  if wait=="trial":
    try:
      dgb,days = [int(x) for x in txt.split()]
      TRIAL["data_gb"]=dgb; TRIAL["days"]=days
      # persist in config file (optional); keeping in memory OK
      await update.message.reply_text("✅ تنظیمات تست به‌روز شد.")
    except Exception:
      await update.message.reply_text("❌ فرمت اشتباه.")
    context.user_data["adm_wait"]=None
    return

  if wait=="prod_add":
    try:
      sku,title,price,panel,data_gb,days = [x.strip() for x in txt.split("|")]
      upsert_product(con, sku, title, int(price), panel, int(data_gb), int(days), 1)
      await update.message.reply_text("✅ محصول اضافه شد.")
    except Exception as e:
      await update.message.reply_text(f"❌ فرمت: sku | title | price | panel | data_gb | days")
    context.user_data["adm_wait"]=None
    return

  if wait.startswith("prod_edit:"):
    sku=wait.split(":",1)[1]
    try:
      title,price,panel,data_gb,days = [x.strip() for x in txt.split("|")]
      upsert_product(con, sku, title, int(price), panel, int(data_gb), int(days), 1)
      await update.message.reply_text("✅ محصول ویرایش شد.")
    except Exception:
      await update.message.reply_text("❌ فرمت: title | price | panel | data_gb | days")
    context.user_data["adm_wait"]=None
    return

  if wait=="bal_inc":
    try:
      tid,amt = [int(x) for x in txt.split()]
      add_balance(con, tid, amt)
      await update.message.reply_text("✅ افزایش موجودی انجام شد.")
    except Exception: await update.message.reply_text("❌ فرمت: tg_id amount")
    context.user_data["adm_wait"]=None; return

  if wait=="bal_dec":
    try:
      tid,amt = [int(x) for x in txt.split()]
      dec_balance(con, tid, amt)
      await update.message.reply_text("✅ کاهش موجودی انجام شد.")
    except Exception: await update.message.reply_text("❌ فرمت: tg_id amount")
    context.user_data["adm_wait"]=None; return

def build_app():
  app=Application.builder().token(BOT_TOKEN).build()
  app.add_handler(CommandHandler("start", cmd_start))
  app.add_handler(CommandHandler("admin", cmd_admin))
  app.add_handler(CallbackQueryHandler(cb_buy,   pattern=r"^buy:.+"))
  app.add_handler(CallbackQueryHandler(cb_trial, pattern=r"^trial:ok$"))
  app.add_handler(CallbackQueryHandler(cb_my,    pattern=r"^my:\d+$"))
  app.add_handler(CallbackQueryHandler(cb_admin, pattern=r"^adm:.*"))
  app.add_handler(MessageHandler(filters.USER(list(ADMINS)) & ~filters.COMMAND, on_admin_text))
  app.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, on_text))
  return app

def cmd_admin(update, context):  # placed after to keep linters quiet
  return update.message.reply_text("پنل مدیریت:", reply_markup=admin_kb())

def main():
  print("✅ VPN shop bot running…")
  build_app().run_polling(close_loop=False)

if __name__=="__main__":
  main()
PY
}

service_unit(){
  cat >"$SVC"<<SERVICE
[Unit]
Description=VPN Shop Bot
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$BASE
ExecStart=$VENV/bin/python $BASE/bot.py
Restart=on-failure
RestartSec=5
StandardOutput=append:$BASE/bot.log
StandardError=append:$BASE/bot.err

[Install]
WantedBy=multi-user.target
SERVICE
  systemctl daemon-reload
  systemctl enable "$NAME"
}

cmd_install(){
  ensure_root
  sys_deps
  rm -rf "$BASE"; mkdir -p "$BASE"
  local token admin
  token="$(ask_token)"
  admin="$(ask_admin)"
  reqs
  config_yaml "$token" "$admin"
  db_py
  adapters_py
  bot_py
  python3 -m venv "$VENV"
  . "$VENV/bin/activate"
  pip install --upgrade pip
  pip install -r "$BASE/requirements.txt"
  service_unit
  systemctl restart "$NAME"
  systemctl status "$NAME" --no-pager -l || true
  echo -e "\n🎉 نصب شد. مسیر: $BASE"
  echo "⚙️  تنظیم پنل/محصول از داخل خود بات (🛠 پنل مدیریت)."
  echo "📝 لاگ‌ها: $BASE/bot.log  /  $BASE/bot.err"
}

cmd_reconfigure(){
  ensure_root
  [[ -f "$BASE/config.yaml" ]] || { echo "نصب نیست."; exit 1; }
  local token admin
  token="$(ask_token)"
  admin="$(ask_admin)"
  config_yaml "$token" "$admin"
  systemctl restart "$NAME"
  systemctl status "$NAME" --no-pager -l || true
}

cmd_status(){ ensure_root; systemctl status "$NAME" --no-pager -l || true; }
cmd_logs(){ ensure_root; journalctl -u "$NAME" -e --no-pager || true; }

cmd_uninstall(){
  ensure_root
  systemctl stop "$NAME" 2>/dev/null || true
  systemctl disable "$NAME" 2>/dev/null || true
  rm -f "$SVC"
  systemctl daemon-reload
  rm -rf "$BASE"
  echo "✔️ حذف شد."
}

SUB="${1:-}"; [[ "$SUB" == "@" ]] && { shift; SUB="${1:-}"; }
case "$SUB" in
  install)     cmd_install ;;
  reconfigure) cmd_reconfigure ;;
  status)      cmd_status ;;
  logs)        cmd_logs ;;
  uninstall)   cmd_uninstall ;;
  *) echo "Usage: $0 @ {install|reconfigure|status|logs|uninstall}"; exit 1 ;;
esac
