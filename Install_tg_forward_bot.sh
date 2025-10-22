#!/usr/bin/env bash
set -euo pipefail

# ===== Telegram Forward Bot Installer (Ubuntu/Debian) =====
# Subcommands:
#   install       -> نصب کامل + دریافت Token/IDs/Mode + ساخت سرویس
#   reconfigure   -> فقط تنظیم .env به‌صورت تعاملی + ری‌استارت
#   uninstall     -> حذف کامل سرویس و پوشه
#   status / logs -> وضعیت و لاگ
# =========================================================

NAME="tg-forward-bot"
INSTALL_DIR="/opt/$NAME"
VENV_DIR="$INSTALL_DIR/.venv"
SERVICE_FILE="/etc/systemd/system/$NAME.service"
ENV_FILE="$INSTALL_DIR/.env"
BOT_FILE="$INSTALL_DIR/bot.py"
REQ_FILE="$INSTALL_DIR/requirements.txt"

ensure_root(){ [[ $EUID -eq 0 ]] || { echo "❌ با sudo اجرا کن"; exit 1; }; }

prompt_nonempty(){ local v; while true; do read -r -p "$1" v || true; v="${v%"${v##*[![:space:]]}"}"; [[ -n "$v" ]] && { echo "$v"; return; }; echo "⚠️ خالی نباشه."; done; }
prompt_token(){ local t; while true; do t="$(prompt_nonempty '🔑 BOT Token: ')"; [[ "$t" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]] && { echo "$t"; return; }; echo "⚠️ فرمت نادرست."; done; }
prompt_int(){ local v; while true; do v="$(prompt_nonempty "$1")"; [[ "$v" =~ ^-?[0-9]+$ ]] && { echo "$v"; return; }; echo "⚠️ فقط عدد."; done; }
prompt_mode(){ local m; read -r -p "↪️ Mode (forward/copy) [forward]: " m || true; m="${m,,}"; [[ -z "$m" ]] && m="forward"; [[ "$m" == forward || "$m" == copy ]] || m="forward"; echo "$m"; }

install_deps(){
  apt-get update -y
  apt-get install -y python3 python3-venv python3-pip curl
}

write_bot(){
  cat >"$BOT_FILE"<<'PY'
# -*- coding: utf-8 -*-
import os
from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup, ReplyKeyboardMarkup, KeyboardButton
from telegram.ext import Application, CommandHandler, MessageHandler, CallbackQueryHandler, ContextTypes, filters

TOKEN = os.getenv("BOT_TOKEN","").strip()
ADMIN_ID = int(os.getenv("ADMIN_ID","0") or "0")
CHANNEL_ID = int(os.getenv("CHANNEL_ID","0") or "0")
FORWARD_MODE = os.getenv("FORWARD_MODE","forward").strip().lower()
if not TOKEN or not ADMIN_ID or not CHANNEL_ID or FORWARD_MODE not in ("forward","copy"):
    raise SystemExit("❌ تنظیمات ناقص است (.env).")

blocked=set()
pending_reply={}  # admin->user

def is_admin(uid:int)->bool: return uid==ADMIN_ID
def chan_kb(uid:int):
    toggle = InlineKeyboardButton(("✅ انبلاک" if uid in blocked else "🚫 بلاک"), callback_data=f"tblock:{uid}")
    reply  = InlineKeyboardButton("✉️ پاسخ", callback_data=f"reply:{uid}")
    return InlineKeyboardMarkup([[toggle, reply]])

def start_menu():
    return ReplyKeyboardMarkup([[KeyboardButton("/همدردی"), KeyboardButton("/بازی")]], resize_keyboard=True)

async def start_cmd(u:Update,c:ContextTypes.DEFAULT_TYPE):
    await u.message.reply_text("سلام! پیام خوش‌آمد یا درخواستت را بفرست تا به ادمین برسد. ✅\n/همدردی (ناشناس) • /بازی (بسکتبال تا ۳)",
                               reply_markup=start_menu())

async def empathy_cmd(u:Update,c:ContextTypes.DEFAULT_TYPE):
    if u.effective_user.id in blocked: return await u.message.reply_text("⛔️ مسدود هستی.")
    c.user_data["want_empathy"]=True
    await u.message.reply_text("متن همدردی‌ات را بفرست؛ ناشناس برای ادمین ارسال می‌شود.")

async def maybe_empathy(u:Update,c:ContextTypes.DEFAULT_TYPE):
    if not c.user_data.pop("want_empathy",False): return False
    txt=u.effective_message.text or "(بدون متن)"
    await c.bot.send_message(chat_id=ADMIN_ID,text="💌 همدردی ناشناس:\n—\n"+txt)
    await u.message.reply_text("✅ ارسال شد.")
    return True

async def fwd_all(u:Update,c:ContextTypes.DEFAULT_TYPE):
    m=u.effective_message; user=u.effective_user
    if not m or (m.text and m.text.startswith("/")): return
    if user.id in blocked: return await m.reply_text("⛔️ مسدود هستی.")

    try:
        (await m.copy(chat_id=ADMIN_ID)) if FORWARD_MODE=="copy" else (await m.forward(chat_id=ADMIN_ID))
    except Exception as e: print("admin:",e)

    try:
        if FORWARD_MODE=="copy":
            await m.copy(chat_id=CHANNEL_ID, reply_markup=chan_kb(user.id))
        else:
            sent=await m.forward(chat_id=CHANNEL_ID)
            await c.bot.send_message(chat_id=CHANNEL_ID, text=f"پیام از #{user.id}", reply_markup=chan_kb(user.id), reply_to_message_id=sent.message_id)
    except Exception as e: print("channel:",e)

    await m.reply_text("✅ ارسال شد؛ به ادمین/چنل رسید.")

async def on_toggle(u:Update,c:ContextTypes.DEFAULT_TYPE):
    q=u.callback_query; await q.answer()
    if not is_admin(u.effective_user.id): return await q.edit_message_text("⛔️ فقط ادمین.")
    uid=int(q.data.split(":")[1])
    if uid in blocked: blocked.remove(uid); msg=f"✅ {uid} انبلاک شد."
    else: blocked.add(uid); msg=f"🚫 {uid} بلاک شد."
    try: await q.edit_message_reply_markup(reply_markup=chan_kb(uid))
    except Exception: pass
    await q.message.reply_text(msg)

async def on_reply_btn(u:Update,c:ContextTypes.DEFAULT_TYPE):
    q=u.callback_query; await q.answer()
    if not is_admin(u.effective_user.id): return await q.edit_message_text("⛔️ فقط ادمین.")
    uid=int(q.data.split(":")[1]); pending_reply[ADMIN_ID]=uid
    await c.bot.send_message(chat_id=ADMIN_ID,text=f"پاسخت را بنویس؛ برای کاربر {uid} ارسال می‌شود.")

async def on_admin_msg(u:Update,c:ContextTypes.DEFAULT_TYPE):
    if u.effective_user.id!=ADMIN_ID: return
    uid=pending_reply.pop(ADMIN_ID,None)
    if not uid: return
    if uid in blocked: return await u.message.reply_text("⛔️ کاربر بلاک است.")
    try:
        if u.message.text or u.message.caption:
            txt=u.message.text or u.message.caption
            await c.bot.send_message(chat_id=uid,text="📩 پیام از ادمین:\n\n"+txt)
        else:
            await u.message.copy(chat_id=uid)
        await u.message.reply_text("✅ ارسال شد.")
    except Exception as e:
        await u.message.reply_text(f"❌ نشد: {e}")

# ساده‌ترین ورژن بازی (درخواست → قبول/رد)
import random
games={}
async def game_req(u:Update,c:ContextTypes.DEFAULT_TYPE):
    if u.effective_user.id in blocked: return await u.message.reply_text("⛔️ مسدود هستی.")
    if games.get(u.effective_user.id,{}).get("active"): return await u.message.reply_text("⚠️ بازی قبلی تمام نشده.")
    kb=InlineKeyboardMarkup([[InlineKeyboardButton("✅ قبول",callback_data=f"gacc:{u.effective_user.id}"),
                              InlineKeyboardButton("❌ رد",callback_data=f"gdec:{u.effective_user.id}")]])
    await c.bot.send_message(chat_id=ADMIN_ID,text=f"درخواست بازی از {u.effective_user.id}. قبول؟",reply_markup=kb)
    await u.message.reply_text("درخواست بازی به ادمین ارسال شد.")

def gstate(uid): return {"user":uid,"scores":{"u":0,"a":0},"turn":"u","active":True}
def gkb(turn_u): return InlineKeyboardMarkup([[InlineKeyboardButton("🏀 شوت 🎯",callback_data="gshot")]])
def gtxt(st): return f"نتیجه: شما {st['scores']['u']} - ادمین {st['scores']['a']}\nنوبت {'شما' if st['turn']=='u' else 'ادمین'}"

async def g_acc_dec(u:Update,c:ContextTypes.DEFAULT_TYPE):
    q=u.callback_query; await q.answer()
    if u.effective_user.id!=ADMIN_ID: return
    kind,uid=q.data.split(":"); uid=int(uid)
    if kind=="gdec":
        await q.edit_message_text(f"❌ رد شد ({uid})"); 
        try: await c.bot.send_message(chat_id=uid,text="ادمین بازی را رد کرد.")
        except Exception: pass
        return
    st=gstate(uid); games[uid]=st
    await q.edit_message_text(f"✅ بازی با {uid} شروع شد.\n"+gtxt(st))
    try: await c.bot.send_message(chat_id=uid,text="🏀 بازی شروع شد؛ نوبت شماست.\n"+gtxt(st),reply_markup=gkb(True))
    except Exception: pass
    await c.bot.send_message(chat_id=ADMIN_ID,text="نوبت کاربر است.",reply_markup=gkb(False))

async def g_shot(u:Update,c:ContextTypes.DEFAULT_TYPE):
    q=u.callback_query; await q.answer()
    pid=u.effective_user.id
    tgt=None
    for uid,st in games.items():
        if not st["active"]: continue
        if pid==ADMIN_ID and st["turn"]=="a": tgt=uid; break
        if pid==uid and st["turn"]=="u": tgt=uid; break
    if tgt is None: return
    st=games[tgt]; shooter="a" if pid==ADMIN_ID else "u"
    goal = random.random()<0.5
    if goal: st["scores"][shooter]+=1; res="✅ گل شد!"
    else: res="❌ از دست رفت."
    if st["scores"][shooter]>=3:
        st["active"]=False
        win="ادمین" if shooter=="a" else "شما"
        try: await c.bot.send_message(chat_id=tgt,text=f"{res}\n🏁 پایان! {win} برنده شد.\n"+gtxt(st))
        except Exception: pass
        await c.bot.send_message(chat_id=ADMIN_ID,text=f"{res}\n🏁 پایان! {win} برنده شد.\n"+gtxt(st))
        return
    st["turn"]="a" if shooter=="u" else "u"
    try: await c.bot.send_message(chat_id=tgt,text=f"{res}\n"+gtxt(st),reply_markup=gkb(st["turn"]=="u"))
    except Exception: pass
    await c.bot.send_message(chat_id=ADMIN_ID,text=f"{res}\n"+gtxt(st),reply_markup=gkb(st["turn"]=="a"))

def main():
    app=Application.builder().token(TOKEN).build()
    app.add_handler(CommandHandler("start",start_cmd))
    app.add_handler(CommandHandler(["همدردی"],empathy_cmd))
    app.add_handler(CommandHandler(["بازی","game"],game_req))
    app.add_handler(MessageHandler(filters.USER(user_id=ADMIN_ID) & ~filters.COMMAND,on_admin_msg))
    app.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, maybe_empathy))
    app.add_handler(MessageHandler(filters.ALL & ~filters.COMMAND, fwd_all))
    app.add_handler(CallbackQueryHandler(on_toggle, pattern=r"^tblock:\-?\d+$"))
    app.add_handler(CallbackQueryHandler(on_reply_btn, pattern=r"^reply:\-?\d+$"))
    app.add_handler(CallbackQueryHandler(g_acc_dec, pattern=r"^(gacc|gdec):\d+$"))
    app.add_handler(CallbackQueryHandler(g_shot, pattern=r"^gshot$"))
    print("✅ Bot is running")
    app.run_polling()

if __name__=="__main__": main()
PY
}

write_reqs(){ cat >"$REQ_FILE"<<'REQ'
python-telegram-bot==20.7
REQ
}

make_env_interactive(){
  echo "📝 تنظیمات:"
  TOKEN="$(prompt_token)"
  ADMIN="$(prompt_int '👤 ADMIN_ID: ')"
  CHAN="$(prompt_int '📣 CHANNEL_ID (معمولاً -100...): ')"
  MODE="$(prompt_mode)"
  cat >"$ENV_FILE"<<ENV
BOT_TOKEN=$TOKEN
ADMIN_ID=$ADMIN
CHANNEL_ID=$CHAN
FORWARD_MODE=$MODE
ENV
  echo "✔️ $ENV_FILE ذخیره شد."
}

service_write(){
  cat >"$SERVICE_FILE"<<SERVICE
[Unit]
Description=Telegram Forward Bot ($NAME)
After=network.target
[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR
EnvironmentFile=$ENV_FILE
ExecStart=$VENV_DIR/bin/python $BOT_FILE
Restart=on-failure
RestartSec=5
StandardOutput=append:$INSTALL_DIR/bot.log
StandardError=append:$INSTALL_DIR/bot.err
[Install]
WantedBy=multi-user.target
SERVICE
  systemctl daemon-reload
  systemctl enable "$NAME"
}

cmd_install(){
  ensure_root
  apt-get update -y
  install_deps
  rm -rf "$INSTALL_DIR"; mkdir -p "$INSTALL_DIR"
  write_bot
  write_reqs
  python3 -m venv "$VENV_DIR"
  # shellcheck disable=SC1091
  . "$VENV_DIR/bin/activate"
  pip install --upgrade pip
  pip install -r "$REQ_FILE"
  make_env_interactive
  service_write
  systemctl restart "$NAME"
  systemctl status "$NAME" --no-pager -l || true
  echo "🎉 نصب شد. مسیر: $INSTALL_DIR"
}

cmd_reconf(){ ensure_root; [[ -d "$INSTALL_DIR" ]] || { echo "❌ نصب نیست."; exit 1; }; make_env_interactive; systemctl restart "$NAME"; systemctl status "$NAME" --no-pager -l || true; }
cmd_uninst(){ ensure_root; systemctl stop "$NAME" || true; systemctl disable "$NAME" || true; rm -f "$SERVICE_FILE"; systemctl daemon-reload; rm -rf "$INSTALL_DIR"; echo "✔️ حذف شد."; }
cmd_status(){ ensure_root; systemctl status "$NAME" --no-pager -l || true; }
cmd_logs(){ ensure_root; journalctl -u "$NAME" -e --no-pager || true; }

SUB="${1:-}"; [[ "${1:-}" == "@" ]] && { shift; SUB="${1:-}"; }
case "$SUB" in
  install)     cmd_install ;;
  reconfigure) cmd_reconf  ;;
  uninstall)   cmd_uninst  ;;
  status)      cmd_status  ;;
  logs)        cmd_logs    ;;
  *) echo "Usage: $0 @ {install|reconfigure|status|logs|uninstall}"; exit 1 ;;
esac
