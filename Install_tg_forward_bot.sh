#!/usr/bin/env bash
set -euo pipefail

# =========================================
# Telegram Forward Bot Installer (Ubuntu/Debian)
# Subcommands:
#   install       -> نصب کامل + سوال پرسیدن (Token/IDs/Mode) + ساخت سرویس
#   reconfigure   -> فقط ویرایش مقادیر .env با پرسش تعاملی + ری‌استارت سرویس
#   uninstall     -> حذف کامل
#   status        -> وضعیت سرویس
#   logs          -> نمایش لاگ
# =========================================

NAME="tg-forward-bot"
INSTALL_DIR_BASE="/opt"
PYTHON_VERSION_BIN="python3"
SERVICE_USER="root"

SUBCMD=""
if [[ "${1:-}" == "@" ]]; then shift; fi
SUBCMD="${1:-}"; shift || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) NAME="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done

INSTALL_DIR="$INSTALL_DIR_BASE/$NAME"
VENV_DIR="$INSTALL_DIR/.venv"
SERVICE_FILE="/etc/systemd/system/${NAME}.service"
ENV_FILE="$INSTALL_DIR/.env"
BOT_FILE="$INSTALL_DIR/bot.py"
REQ_FILE="$INSTALL_DIR/requirements.txt"

ensure_root() { if [[ $EUID -ne 0 ]]; then echo "❌ لطفاً با sudo اجرا کنید."; exit 1; fi; }

detect_os() {
  if [[ -f /etc/debian_version || -f /etc/lsb-release ]]; then echo "debianlike"; else echo "unknown"; fi
}

prompt_nonempty() {
  local label="$1" var
  while true; do
    read -r -p "$label" var || true
    var="$(echo -n "$var" | sed 's/[[:space:]]*$//')"
    if [[ -n "$var" ]]; then echo "$var"; return 0; fi
    echo "⚠️ مقدار نمی‌تواند خالی باشد."
  done
}

prompt_token() {
  local t
  while true; do
    t="$(prompt_nonempty '🔑 BOT Token (از BotFather): ')"
    if [[ "$t" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]]; then echo "$t"; return 0; fi
    echo "⚠️ فرمت توکن درست نیست. نمونه: 123456789:ABCdefGh_..."
  done
}

prompt_int() {
  local label="$1" v
  while true; do
    v="$(prompt_nonempty "$label")"
    if [[ "$v" =~ ^-?[0-9]+$ ]]; then echo "$v"; return 0; fi
    echo "⚠️ فقط عدد وارد کنید (Channel ID معمولا با -100 شروع می‌شود)."
  done
}

prompt_mode() {
  local m
  while true; do
    read -r -p "↪️ حالت ارسال (forward/copy) [forward]: " m || true
    m="${m,,}"
    [[ -z "$m" ]] && m="forward"
    if [[ "$m" == "forward" || "$m" == "copy" ]]; then echo "$m"; return 0; fi
    echo "⚠️ فقط forward یا copy"
  done
}

install_deps() {
  echo "📦 نصب پیش‌نیازها..."
  apt-get update -y
  apt-get install -y $PYTHON_VERSION_BIN python3-venv python3-pip curl
}

create_layout() {
  echo "📁 ساخت مسیر $INSTALL_DIR"
  mkdir -p "$INSTALL_DIR"
}

write_bot_py() {
  cat > "$BOT_FILE" <<'PY'
# -*- coding: utf-8 -*-
# Telegram Forward Bot (python-telegram-bot v20.x)
import os
from telegram import Update
from telegram.ext import Application, ContextTypes, MessageHandler, CommandHandler, filters

# خواندن تنظیمات از Environment (که systemd از .env لود می‌کند)
TOKEN = os.getenv("BOT_TOKEN", "").strip()
ADMIN_ID = os.getenv("ADMIN_ID", "").strip()
CHANNEL_ID = os.getenv("CHANNEL_ID", "").strip()
FORWARD_MODE = os.getenv("FORWARD_MODE", "forward").strip().lower()

def _ensure_env():
    missing = []
    if not TOKEN: missing.append("BOT_TOKEN")
    if not ADMIN_ID: missing.append("ADMIN_ID")
    if not CHANNEL_ID: missing.append("CHANNEL_ID")
    if FORWARD_MODE not in ("forward", "copy"): missing.append("FORWARD_MODE (forward/copy)")
    if missing:
        raise SystemExit("❌ تنظیمات ناقص است: " + ", ".join(missing))

def _as_int(x: str) -> int:
    try: return int(x)
    except Exception: raise SystemExit(f"❌ مقدار باید عددی باشد: {x}")

async def start_cmd(update: Update, context: ContextTypes.DEFAULT_TYPE):
    await update.message.reply_text(
        "سلام! 👋\n"
        "لطفاً پیام خوش‌آمد یا درخواست‌تان را ارسال کنید تا برای ادمین/چنل فوروارد شود. ✅"
    )

async def help_cmd(update: Update, context: ContextTypes.DEFAULT_TYPE):
    await update.message.reply_text(
        "این بات هر پیام شما را برای ادمین و چنل تعیین‌شده ارسال می‌کند.\n"
        "حالت ارسال: forward/copy (در .env قابل تغییر است)."
    )

async def forward_all(update: Update, context: ContextTypes.DEFAULT_TYPE):
    msg = update.effective_message
    if not msg or (msg.text and msg.text.startswith("/")):
        return

    admin_id = _as_int(ADMIN_ID)
    channel_id = _as_int(CHANNEL_ID)
    targets = [admin_id] if admin_id == channel_id else [admin_id, channel_id]

    ok = False
    for dest in targets:
        try:
            if FORWARD_MODE == "copy":
                await msg.copy(chat_id=dest)
            else:
                await msg.forward(chat_id=dest)
            ok = True
        except Exception as e:
            print(f"⚠️ ارسال به {dest} خطا داد: {e}")

    if ok:
        await msg.reply_text("✅ ارسال شد؛ پیام شما به دست ادمین/چنل رسید.")
    else:
        await msg.reply_text("❌ نشد ارسال کنم. لطفاً بعداً دوباره تلاش کنید.")

def main():
    _ensure_env()
    app = Application.builder().token(TOKEN).build()
    app.add_handler(CommandHandler("start", start_cmd))
    app.add_handler(CommandHandler("help", help_cmd))
    app.add_handler(MessageHandler(filters.ALL & ~filters.COMMAND, forward_all))
    print("✅ Bot is running (Ctrl+C to stop).")
    app.run_polling()  # بلاکینگ و بدون درگیری با asyncio.run

if __name__ == "__main__":
    main()
PY
}

write_requirements() {
  cat > "$REQ_FILE" <<'REQ'
python-telegram-bot==20.7
REQ
}

create_venv_and_install() {
  echo "🐍 ساخت venv و نصب وابستگی‌ها..."
  $PYTHON_VERSION_BIN -m venv "$VENV_DIR"
  # shellcheck disable=SC1091
  source "$VENV_DIR/bin/activate"
  pip install --upgrade pip
  pip install -r "$REQ_FILE"
}

prompt_and_write_env() {
  echo
  echo "📝 لطفاً تنظیمات را وارد کنید:"
  local token admin channel mode
  token="$(prompt_token)"
  admin="$(prompt_int '👤 ADMIN_ID (آیدی عددی ادمین): ')"
  channel="$(prompt_int '📣 CHANNEL_ID (معمولاً -100...): ')"
  mode="$(prompt_mode)"

  cat > "$ENV_FILE" <<ENV
BOT_TOKEN=$token
ADMIN_ID=$admin
CHANNEL_ID=$channel
FORWARD_MODE=$mode
ENV
  echo "✔️ تنظیمات در $ENV_FILE ذخیره شد."
}

write_service() {
  echo "🧩 ساخت سرویس systemd: $SERVICE_FILE"
  cat > "$SERVICE_FILE" <<SERVICE
[Unit]
Description=Telegram Forward Bot ($NAME)
After=network.target

[Service]
Type=simple
User=$SERVICE_USER
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

start_service() {
  systemctl restart "$NAME"
  systemctl status "$NAME" --no-pager -l || true
  echo
  echo "🎉 سرویس '$NAME' اجرا شد."
  echo "📄 مسیر نصب: $INSTALL_DIR"
  echo "📝 لاگ‌ها: $INSTALL_DIR/bot.log  و  $INSTALL_DIR/bot.err"
}

cmd_install() {
  ensure_root
  [[ "$(detect_os)" == "debianlike" ]] || echo "⚠️ روی Debian/Ubuntu تست شده."
  install_deps
  create_layout
  write_bot_py
  write_requirements
  create_venv_and_install
  prompt_and_write_env
  write_service
  start_service
}

cmd_reconfigure() {
  ensure_root
  if [[ ! -d "$INSTALL_DIR" ]]; then echo "❌ نصب پیدا نشد در $INSTALL_DIR"; exit 1; fi
  prompt_and_write_env
  systemctl restart "$NAME"
  systemctl status "$NAME" --no-pager -l || true
}

cmd_uninstall() {
  ensure_root
  systemctl stop "$NAME" || true
  systemctl disable "$NAME" || true
  rm -f "$SERVICE_FILE"
  systemctl daemon-reload
  rm -rf "$INSTALL_DIR"
  echo "✔️ حذف شد."
}

cmd_status()  { ensure_root; systemctl status "$NAME" --no-pager -l || true; }
cmd_logs()    { ensure_root; journalctl -u "$NAME" -e --no-pager || true; }

case "$SUBCMD" in
  install)     cmd_install ;;
  reconfigure) cmd_reconfigure ;;
  uninstall)   cmd_uninstall ;;
  status)      cmd_status ;;
  logs)        cmd_logs ;;
  *)
    cat <<USAGE
Usage:
  $0 @ install [--name NAME]      # نصب کامل + سوال پرسیدن و تنظیم .env
  $0 @ reconfigure [--name NAME]   # ویرایش تعاملی .env و ری‌استارت
  $0 @ status [--name NAME]
  $0 @ logs [--name NAME]
  $0 @ uninstall [--name NAME]
USAGE
    ;;
esac
