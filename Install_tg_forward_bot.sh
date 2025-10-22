# -*- coding: utf-8 -*-
"""
Telegram Forward Bot – full features (PTB v20.7)

Features:
- /start: راهنما + دعوت به ارسال پیام خوش‌آمد
- فوروارد/کپی همه پیام‌ها به ادمین و چنل، با inline keyboard زیر پیام چنل:
    [🚫 بلاک/✅ انبلاک] [✉️ پاسخ]
- بلاک/انبلاک: جلوگیری کامل از استفاده کاربر
- پاسخ: ادمین با زدن «✉️ پاسخ» از همان‌جا پیام می‌نویسد و برای کاربر ارسال می‌شود
- /همدردی: ارسال ناشناس کاربر به ادمین
- /بازی یا /game: بازی بسکتبال نوبتی تا امتیاز 3 بین کاربر و ادمین
"""

import os
import random
from typing import Dict, Any

from telegram import (
    Update, InlineKeyboardButton, InlineKeyboardMarkup, ReplyKeyboardMarkup, KeyboardButton
)
from telegram.ext import (
    Application, CommandHandler, MessageHandler, CallbackQueryHandler,
    ContextTypes, filters
)

# ---------- Config from environment ----------
TOKEN = os.getenv("BOT_TOKEN", "").strip()
ADMIN_ID = int(os.getenv("ADMIN_ID", "0") or "0")
CHANNEL_ID = int(os.getenv("CHANNEL_ID", "0") or "0")
FORWARD_MODE = os.getenv("FORWARD_MODE", "forward").strip().lower()

if not TOKEN or not ADMIN_ID or not CHANNEL_ID or FORWARD_MODE not in ("forward", "copy"):
    raise SystemExit("❌ تنظیمات ناقص است. BOT_TOKEN / ADMIN_ID / CHANNEL_ID / FORWARD_MODE را در .env پر کنید.")

# ---------- In-memory state (می‌شود با persistence هم عوض کرد) ----------
blocked_users: set[int] = set()
pending_reply_for_admin: Dict[int, int] = {}  # admin_id -> target_user_id (فقط برای ADMIN_ID استفاده می‌شود)
games: Dict[int, Dict[str, Any]] = {}  # key: user_id; value: state dict

# ---------- Helpers ----------
def is_admin(user_id: int) -> bool:
    return user_id == ADMIN_ID

def channel_buttons(user_id: int) -> InlineKeyboardMarkup:
    """دکمه‌های زیر پیام چنل؛ بسته به وضعیت بلاک/انبلاک تغییر می‌کند."""
    blocked = user_id in blocked_users
    toggle = InlineKeyboardButton("✅ انبلاک" if blocked else "🚫 بلاک",
                                  callback_data=f"toggleblock:{user_id}")
    reply = InlineKeyboardButton("✉️ پاسخ", callback_data=f"reply:{user_id}")
    return InlineKeyboardMarkup([[toggle, reply]])

def start_menu() -> ReplyKeyboardMarkup:
    return ReplyKeyboardMarkup(
        [[KeyboardButton("/همدردی"), KeyboardButton("/بازی")]],
        resize_keyboard=True
    )

async def safe_reply(msg, text):
    try:
        await msg.reply_text(text)
    except Exception:
        pass

# ---------- Command: /start ----------
async def start_cmd(update: Update, context: ContextTypes.DEFAULT_TYPE):
    await update.message.reply_text(
        "سلام! 👋\n"
        "برای شروع، لطفاً پیام خوش‌آمد یا درخواست‌تان را بفرستید تا برای ادمین ارسال کنم. ✅\n\n"
        "دستورات:\n"
        "• /همدردی → ارسال ناشناس به ادمین\n"
        "• /بازی → درخواست بازی بسکتبال با ادمین (تا ۳ امتیاز)\n",
        reply_markup=start_menu()
    )

# ---------- Command: /همدردی ----------
async def empathy_cmd(update: Update, context: ContextTypes.DEFAULT_TYPE):
    user = update.effective_user
    if user and user.id in blocked_users:
        return await update.message.reply_text("⛔️ دسترسی شما مسدود است.")
    # انتظار داریم پیام بعدی کاربر متن همدردی باشد
    context.user_data["awaiting_empathy"] = True
    await update.message.reply_text("لطفاً پیام همدردی‌ات را بفرست؛ ناشناس برای ادمین ارسال می‌شود.")

async def handle_empathy_text(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not context.user_data.pop("awaiting_empathy", False):
        return False
    txt = update.effective_message.text or "(بدون متن)"
    # برای ناشناس بودن، copy می‌کنیم و هویّت را لو نمی‌دهیم
    prefix = "💌 همدردی ناشناس جدید:\n—\n"
    try:
        await context.bot.send_message(chat_id=ADMIN_ID, text=prefix + txt)
        await update.message.reply_text("✅ ارسال شد (به صورت ناشناس).")
    except Exception:
        await update.message.reply_text("❌ ارسال نشد. کمی بعد دوباره امتحان کن.")
    return True

# ---------- Forward/copy all messages to admin & channel with buttons ----------
async def forward_all(update: Update, context: ContextTypes.DEFAULT_TYPE):
    msg = update.effective_message
    user = update.effective_user

    if not msg or (msg.text and msg.text.startswith("/")):
        return

    if user and user.id in blocked_users:
        return await safe_reply(msg, "⛔️ شما مسدود هستید.")

    # مقصدها: ادمین + چنل
    destinations = [ADMIN_ID] if ADMIN_ID == CHANNEL_ID else [ADMIN_ID, CHANNEL_ID]

    # به ادمین بدون دکمه
    try:
        if FORWARD_MODE == "copy":
            await msg.copy(chat_id=ADMIN_ID, caption=(msg.caption or None))
        else:
            await msg.forward(chat_id=ADMIN_ID)
    except Exception as e:
        print("forward to admin error:", e)

    # به چنل همراه با دکمه‌های مدیریت
    try:
        if FORWARD_MODE == "copy":
            sent = await msg.copy(chat_id=CHANNEL_ID, reply_markup=channel_buttons(user.id))
        else:
            sent = await msg.forward(chat_id=CHANNEL_ID)
            # پیام فورواردشده را نمی‌توان ویرایش کرد؛ یک پیام کناری می‌فرستیم با دکمه‌ها
            await context.bot.send_message(
                chat_id=CHANNEL_ID,
                text=f"پیام از کاربر #{user.id}",
                reply_markup=channel_buttons(user.id),
                reply_to_message_id=sent.message_id
            )
    except Exception as e:
        print("forward to channel error:", e)

    # تأیید برای کاربر
    await safe_reply(msg, "✅ ارسال شد؛ پیام شما به دست ادمین/چنل رسید.")

# ---------- Inline button handlers: block / unblock / reply ----------
async def on_toggleblock(update: Update, context: ContextTypes.DEFAULT_TYPE):
    cq = update.callback_query
    await cq.answer()
    if not is_admin(update.effective_user.id):
        return await cq.edit_message_text("⛔️ فقط ادمین می‌تواند بلاک/انبلاک کند.")
    try:
        user_id = int(cq.data.split(":")[1])
    except Exception:
        return
    if user_id in blocked_users:
        blocked_users.remove(user_id)
        text = f"✅ کاربر {user_id} انبلاک شد."
    else:
        blocked_users.add(user_id)
        text = f"🚫 کاربر {user_id} بلاک شد."
    # آپدیت دکمه‌ها
    try:
        await cq.edit_message_reply_markup(reply_markup=channel_buttons(user_id))
    except Exception:
        pass
    await cq.message.reply_text(text)

async def on_reply_request(update: Update, context: ContextTypes.DEFAULT_TYPE):
    cq = update.callback_query
    await cq.answer()
    if not is_admin(update.effective_user.id):
        return await cq.edit_message_text("⛔️ فقط ادمین می‌تواند پاسخ بدهد.")
    try:
        user_id = int(cq.data.split(":")[1])
    except Exception:
        return
    pending_reply_for_admin[ADMIN_ID] = user_id
    await context.bot.send_message(
        chat_id=ADMIN_ID,
        text=f"✉️ پاسخ به کاربر {user_id} را بنویس و ارسال کن… (اولین پیام بعدی‌ات برای او ارسال می‌شود)"
    )

async def on_admin_message(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """اگر ادمین پیامی بده و در حالت پاسخ باشد، به کاربر مقصد ارسال کن."""
    if update.effective_user.id != ADMIN_ID:
        return
    target = pending_reply_for_admin.pop(ADMIN_ID, None)
    if not target:
        return  # پیام آزاد ادمین؛ کاری نکن
    if target in blocked_users:
        return await update.message.reply_text("⛔️ این کاربر بلاک است.")
    try:
        # پیام ادمین را برای کاربر ارسال کن
        if update.message.text or update.message.caption:
            txt = update.message.text or update.message.caption
            await context.bot.send_message(chat_id=target, text=f"📩 پیام از ادمین:\n\n{txt}")
        elif update.message.effective_attachment:
            # برای مدیاها: فوروارد/کپی ساده
            await update.message.copy(chat_id=target)
        await update.message.reply_text("✅ برای کاربر ارسال شد.")
    except Exception as e:
        await update.message.reply_text(f"❌ ارسال نشد: {e}")

# ---------- Basketball game ----------
def game_state_template(user_id: int) -> Dict[str, Any]:
    return {
        "user": user_id,
        "scores": {"user": 0, "admin": 0},
        "turn": "user",  # user یا admin
        "active": True,
    }

def game_keyboard(user_turn: bool) -> InlineKeyboardMarkup:
    label = "🏀 شوت 🎯"
    btn = InlineKeyboardButton(label, callback_data="shot")
    info = InlineKeyboardButton("ℹ️ وضعیت", callback_data="noop")
    # فقط کسی که نوبتش است باید بتواند شوت بزند؛
    # کنترل در سمت هندلر انجام می‌شود (با چک کردن شناسه کلیک‌کننده)
    return InlineKeyboardMarkup([[btn, info]])

def score_text(state: Dict[str, Any]) -> str:
    u = state["scores"]["user"]
    a = state["scores"]["admin"]
    turn = "نوبت شماست" if state["turn"] == "user" else "نوبت ادمین است"
    return f"نتیجه: شما {u}  -  ادمین {a}\n{turn}\n(اولین نفر تا ۳ امتیاز برنده می‌شود)"

async def game_request(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """کاربر /بازی می‌زند: از ادمین تایید می‌گیرند."""
    user = update.effective_user
    if user.id in blocked_users:
        return await update.message.reply_text("⛔️ شما مسدود هستید.")
    # اگر بازی قبلی کاربر هنوز فعال است
    if games.get(user.id, {}).get("active"):
        return await update.message.reply_text("⚠️ بازی قبلی شما هنوز تمام نشده است.")

    kb = InlineKeyboardMarkup([
        [InlineKeyboardButton("✅ قبول", callback_data=f"acceptgame:{user.id}"),
         InlineKeyboardButton("❌ رد", callback_data=f"declinegame:{user.id}")]
    ])
    await context.bot.send_message(
        chat_id=ADMIN_ID,
        text=f"🎮 درخواست بازی بسکتبال از کاربر {user.id}.\nقبول می‌کنی؟",
        reply_markup=kb
    )
    await update.message.reply_text("درخواست بازی برای ادمین ارسال شد. منتظر تایید بمان…")

async def on_game_accept_or_decline(update: Update, context: ContextTypes.DEFAULT_TYPE):
    cq = update.callback_query
    await cq.answer()
    if not is_admin(update.effective_user.id):
        return await cq.edit_message_text("⛔️ فقط ادمین می‌تواند تایید کند.")
    data = cq.data
    action, user_id_s = data.split(":")
    user_id = int(user_id_s)

    if action == "declinegame":
        await cq.edit_message_text(f"❌ بازی با کاربر {user_id} رد شد.")
        try:
            await context.bot.send_message(chat_id=user_id, text="متاسفانه ادمین بازی را رد کرد.")
        except Exception:
            pass
        return

    # accept
    state = game_state_template(user_id)
    games[user_id] = state
    await cq.edit_message_text(f"✅ بازی با {user_id} شروع شد!\n" + score_text(state))

    # پیام شروع برای کاربر
    try:
        await context.bot.send_message(
            chat_id=user_id,
            text="🏀 بازی شروع شد! شما شروع‌کننده‌اید.\n" + score_text(state),
            reply_markup=game_keyboard(user_turn=True)
        )
    except Exception:
        pass
    # پیام راهنما برای ادمین
    await context.bot.send_message(
        chat_id=ADMIN_ID,
        text="بازی شروع شد. نوبتِ کاربر است. منتظر بمانید…",
        reply_markup=game_keyboard(user_turn=False)
    )

async def on_shot(update: Update, context: ContextTypes.DEFAULT_TYPE):
    cq = update.callback_query
    player_id = update.effective_user.id
    await cq.answer()

    # تشخیص اینکه این کلیک مربوط به کدام بازی است
    # بازی‌ها به ازای user_id ذخیره شده‌اند؛ اگر ادمین بزند، باید بازی‌ای پیدا کنیم که turn=admin است
    target_user_id = None
    for uid, st in games.items():
        if st.get("active"):
            if player_id == ADMIN_ID and st["turn"] == "admin":
                target_user_id = uid
                break
            if player_id == uid and st["turn"] == "user":
                target_user_id = uid
                break
    if target_user_id is None:
        return  # کلیک بی‌اعتبار یا نوبت شما نیست

    state = games[target_user_id]
    shooter = "admin" if player_id == ADMIN_ID else "user"

    # شلیک
    goal = random.random() < 0.5  # 50% موفقیت
    if goal:
        state["scores"][shooter] += 1
        result = "✅ گل شد!"
    else:
        result = "❌ از دست رفت."

    # بررسی پایان بازی
    if state["scores"][shooter] >= 3:
        state["active"] = False
        winner_txt = "ادمین" if shooter == "admin" else "شما"
        # اطلاع به هر دو
        try:
            await context.bot.send_message(
                chat_id=target_user_id,
                text=f"{result}\n\n🏁 بازی تمام شد! **{winner_txt}** برنده شد.\n" + score_text(state)
            )
        except Exception:
            pass
        try:
            await context.bot.send_message(
                chat_id=ADMIN_ID,
                text=f"{result}\n\n🏁 بازی تمام شد! {winner_txt} برنده شد.\n" + score_text(state)
            )
        except Exception:
            pass
        return

    # نوبت عوض شود
    state["turn"] = "admin" if shooter == "user" else "user"

    # به‌روزرسانی پیام‌ها برای هر طرف
    try:
        await context.bot.send_message(
            chat_id=target_user_id,
            text=f"{result}\n" + score_text(state),
            reply_markup=game_keyboard(user_turn=(state["turn"] == "user"))
        )
    except Exception:
        pass
    try:
        await context.bot.send_message(
            chat_id=ADMIN_ID,
            text=f"{result}\n" + score_text(state),
            reply_markup=game_keyboard(user_turn=(state["turn"] == "admin"))
        )
    except Exception:
        pass

# ---------- Help ----------
async def help_cmd(update: Update, context: ContextTypes.DEFAULT_TYPE):
    await update.message.reply_text(
        "دستورات:\n"
        "/start — شروع\n"
        "/همدردی — ارسال ناشناس به ادمین\n"
        "/بازی یا /game — بازی بسکتبال با ادمین\n"
    )

# ---------- Main ----------
def main():
    app = Application.builder().token(TOKEN).build()

    # Commands
    app.add_handler(CommandHandler("start", start_cmd))
    app.add_handler(CommandHandler("help", help_cmd))
    app.add_handler(CommandHandler(["بازی", "game"], game_request))
    app.add_handler(CommandHandler("همدردی", empathy_cmd))

    # Admin reply message (when pending)
    app.add_handler(MessageHandler(filters.USER(user_id=ADMIN_ID) & ~filters.COMMAND, on_admin_message))

    # Empathy free-text handler
    app.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, handle_empathy_text))

    # Forward all (non-commands), but AFTER empathy handler so آن پیام مصرف نشود
    app.add_handler(MessageHandler(filters.ALL & ~filters.COMMAND, forward_all))

    # Callback buttons
    app.add_handler(CallbackQueryHandler(on_toggleblock, pattern=r"^toggleblock:\-?\d+$"))
    app.add_handler(CallbackQueryHandler(on_reply_request, pattern=r"^reply:\-?\d+$"))
    app.add_handler(CallbackQueryHandler(on_game_accept_or_decline, pattern=r"^(acceptgame|declinegame):\d+$"))
    app.add_handler(CallbackQueryHandler(on_shot, pattern=r"^shot$"))
    app.add_handler(CallbackQueryHandler(lambda u,c: u.callback_query.answer(), pattern=r"^noop$"))

    print("✅ Bot is running (Ctrl+C to stop).")
    app.run_polling(close_loop=False)

if __name__ == "__main__":
    main()
