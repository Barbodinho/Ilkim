#!/usr/bin/env bash
set -euo pipefail

# =========================================
# Telegram Forward Bot Installer (Ubuntu/Debian)
# Usage examples:
#   sudo bash -c "$(curl -fsSL https://YOUR_RAW_URL/install-tg-forward-bot.sh)" @ install --name tg-forward-bot
#   sudo bash -c "$(curl -fsSL https://YOUR_RAW_URL/install-tg-forward-bot.sh)" @ uninstall --name tg-forward-bot
#   sudo bash -c "$(curl -fsSL https://YOUR_RAW_URL/install-tg-forward-bot.sh)" @ status --name tg-forward-bot
#   sudo bash -c "$(curl -fsSL https://YOUR_RAW_URL/install-tg-forward-bot.sh)" @ logs --name tg-forward-bot
# =========================================

NAME="tg-forward-bot"
INSTALL_DIR_BASE="/opt"
PYTHON_VERSION_BIN="python3"
SERVICE_USER="root"   # در صورت نیاز می‌تونی کاربر جدا بسازی

# پارس آرگومان‌ها
SUBCMD=""
if [[ "${1:-}" == "@" ]]; then
  shift
fi
SUBCMD="${1:-}"
shift || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)
      NAME="${2:-}"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

INSTALL_DIR="$INSTALL_DIR_BASE/$NAME"
VENV_DIR="$INSTALL_DIR/.venv"
SERVICE_FILE="/etc/systemd/system/${NAME}.service"

ensure_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "❌ لطفاً با sudo اجرا کنید."
    exit 1
  fi
}

detect_os() {
  if [[ -f /etc/debian_version ]]; then
    echo "debian"
  elif [[ -f /etc/lsb-release ]]; then
    echo "ubuntu"
  else
    echo "unknown"
  fi
}

install_deps() {
  echo "📦 نصب پیش‌نیازها..."
  apt-get update -y
  apt-get install -y $PYTHON_VERSION_BIN python3-venv python3-pip curl
}

create_layout() {
  echo "📁 ساخت دایرکتوری: $INSTALL_DIR"
  mkdir -p "$INSTALL_DIR"
}

write_bot_py() {
  cat > "$INSTALL_DIR/bot.py" <<'PYCODE'
# -*- coding: utf-8 -*-
# Telegram Forward Bot (python-telegram-bot v20.x)
import os
import asyncio
from typing import Optional

try:
    from telegram import Update
    from telegram.ext import Application, ContextTypes, MessageHandler, CommandHandler, filters
except ImportError:
    raise SystemExit(
        "❌ python-telegram-bot نصب نیست. داخل اسکریپت نصب انجام می‌شود."
    )

def env_or_prompt(key: str, prompt: str, allow_empty: bool=False) -> str:
    v = os.getenv(key, "").strip()
    if v or allow_empty:
        return v
    try:
        v = input(prompt).strip()
    except EOFError:
        v = ""
    if not v and not allow_empty:
        raise SystemExit(f"❌ مقدار {key} نباید خالی باشد.")
    return v

def env_or_prompt_int(key: str, prompt: str) -> int:
    v = os.getenv(key, "").strip()
    if v:
        try:
            return int(v)
        except ValueError:
            raise SystemExit(f"❌ {key} باید عددی باشد.")
    while True:
        try:
            x = input(prompt).strip()
        except EOFError:
            x = ""
        try:
            return int(x)
        except ValueError:
            print("⚠️ لطفاً عدد صحیح وارد کنید (ممکن است منفی باشد).")

def read_choice(env_key: str, prompt: str, choices, default: Optional[str]=None) -> str:
    v = os.getenv(env_key, "").strip().lower()
    low = [c.lower() for c in choices]
    if v in low:
        return v
    while True:
        try:
            x = input(prompt).strip().lower()
        except EOFError:
            x = ""
        if not x and default:
            return default.lower()
        if x in low:
            return x
        print(f"⚠️ گزینه نامعتبر. انتخاب‌ها: {', '.join(choices)}")

async def main():
    token = env_or_prompt("BOT_TOKEN", "🔑 Bot Token: ")
    admin_id = env_or_prompt_int("ADMIN_ID", "👤 آیدی عددی ادمین: ")
    channel_id = env_or_prompt_int("CHANNEL_ID", "📣 آیدی عددی چنل (مثل -100...): ")
    fwd_mode = read_choice("FORWARD_MODE", "↪️ حالت ارسال (forward/copy) [پیش‌فرض: forward]: ",
                           ["forward", "copy"], default="forward")

    async def start_cmd(update: Update, context: ContextTypes.DEFAULT_TYPE):
        await update.message.reply_text("سلام! پیام‌ها را به ادمین و چنل می‌فرستم. ✅")

    async def help_cmd(update: Update, context: ContextTypes.DEFAULT_TYPE):
        await update.message.reply_text(
            "Forward bot فعال است.\n"
            f"- Admin: {admin_id}\n"
            f"- Channel: {channel_id}\n"
            f"- Mode: {fwd_mode}\n"
            "forward = با برچسب Forwarded (حفظ هویت فرستنده)\n"
            "copy = بدون برچسب Forwarded"
        )

    async def forward_all(update: Update, context: ContextTypes.DEFAULT_TYPE):
        msg = update.effective_message
        if not msg:
            return
        targets = [admin_id] if admin_id == channel_id else [admin_id, channel_id]
        for dest in targets:
            try:
                if fwd_mode == "copy":
                    await msg.copy(chat_id=dest)
                else:
                    await msg.forward(chat_id=dest)
            except Exception as e:
                print(f"⚠️ ارسال به {dest} خطا داد: {e}")
        try:
            await msg.reply_text("✅ ارسال شد.")
        except Exception:
            pass

    app = Application.builder().token(token).build()
    app.add_handler(CommandHandler("start", start_cmd))
    app.add_handler(CommandHandler("help", help_cmd))
    app.add_handler(MessageHandler(filters.ALL & ~filters.COMMAND, forward_all))
    print("✅ Bot is running (Ctrl+C to stop).")
    await app.run_polling(close_loop=False)

if __name__ == "__main__":
    try:
        asyncio.run(main())
    except (KeyboardInterrupt, SystemExit):
        print("\n⏹ متوقف شد.")
PYCODE
}

write_requirements() {
  cat > "$INSTALL_DIR/requirements.txt" <<'REQ'
python-telegram-bot==20.7
REQ
}

create_venv_and_install() {
  echo "🐍 ساخت venv و نصب وابستگی‌ها..."
  $PYTHON_VERSION_BIN -m venv "$VENV_DIR"
  # shellcheck disable=SC1091
  source "$VENV_DIR/bin/activate"
  pip install --upgrade pip
  pip install -r "$INSTALL_DIR/requirements.txt"
}

write_env_file() {
  cat > "$INSTALL_DIR/.env" <<'ENVV'
# برای اجرای سرویس systemd باید این‌ها را مقداردهی کنی:
# BOT_TOKEN=123456:ABC-DEF...
# ADMIN_ID=123456789
# CHANNEL_ID=-1001234567890
# FORWARD_MODE=forward
ENVV
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
EnvironmentFile=$INSTALL_DIR/.env
ExecStart=$VENV_DIR/bin/python $INSTALL_DIR/bot.py
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
  echo "🎉 سرویس '$NAME' نصب/راه‌اندازی شد."
  echo "📄 مسیر نصب: $INSTALL_DIR"
  echo "📝 لاگ‌ها: $INSTALL_DIR/bot.log  و  $INSTALL_DIR/bot.err"
  echo "🔧 حتماً فایل $INSTALL_DIR/.env را با مقادیر درست پر کن و سپس:"
  echo "    sudo systemctl restart $NAME"
}

cmd_install() {
  ensure_root
  if [[ "$(detect_os)" == "unknown" ]]; then
    echo "⚠️ سیستم عامل ناشناخته. ادامه می‌دهم اما روی Debian/Ubuntu تست شده."
  fi
  install_deps
  create_layout
  write_bot_py
  write_requirements
  create_venv_and_install
  write_env_file
  write_service
  start_service
}

cmd_uninstall() {
  ensure_root
  echo "🧹 توقف و حذف سرویس $NAME"
  systemctl stop "$NAME" || true
  systemctl disable "$NAME" || true
  rm -f "$SERVICE_FILE"
  systemctl daemon-reload
  echo "🗑 حذف دایرکتوری نصب: $INSTALL_DIR"
  rm -rf "$INSTALL_DIR"
  echo "✔️ انجام شد."
}

cmd_status() {
  ensure_root
  systemctl status "$NAME" --no-pager -l || true
}

cmd_logs() {
  ensure_root
  journalctl -u "$NAME" -e --no-pager || true
}

case "$SUBCMD" in
  install)   cmd_install ;;
  uninstall) cmd_uninstall ;;
  status)    cmd_status ;;
  logs)      cmd_logs ;;
  *)
    cat <<USAGE
Usage:
  $0 @ install [--name NAME]
  $0 @ uninstall [--name NAME]
  $0 @ status [--name NAME]
  $0 @ logs [--name NAME]

Notes:
- بعد از نصب، فایل .env را در $INSTALL_DIR پر کن:
    BOT_TOKEN, ADMIN_ID, CHANNEL_ID, FORWARD_MODE
  سپس:
    sudo systemctl restart $NAME
- اگر .env خالی باشد و سرویس اجرا شود، bot.py چون ورودی تعاملی ندارد اجرا نمی‌شود.
USAGE
    ;;
esac
