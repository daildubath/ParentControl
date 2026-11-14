// All user-facing and admin-facing wording lives here, as plain-text
// templates. {name} placeholders are filled from the values passed to render().
// The controller can override any id through policy ui.wording.

export const DEFAULT_WORDING = Object.freeze({
  // Banners
  "safe_mode": "Protection is in safe mode. Please call {admin_name}{phone_part}.",
  "new_site": "This is a new website for you. Take your time, and don't enter payment or password details unless you're sure.",
  "btn_got_it": "Got it",
  "btn_ask_admin": "Ask {admin_name}",
  "btn_ask_sent": "Message sent to {admin_name}",
  "btn_ask_failed": "Could not reach {admin_name}. Please call.",

  // Full-screen page: blocked site
  "blocked_title": "This website is blocked",
  "blocked_body": "This website was marked as unsafe. Please do not continue. If you think this is a mistake, call {admin_name}{phone_part}.",
  "btn_back": "Go back to safety",

  // Full-screen page: a download that was stopped
  "dl_blocked_title": "This download was stopped",
  "dl_blocked_body": "A download from {domain} was stopped because it is not allowed. If you think this is a mistake, call {admin_name}{phone_part}.",

  // Full-screen page: approval code
  "pin_title": "Ask {admin_name} first",
  "pin_body": "Before you continue with {action_label} on {domain}, please call {admin_name}{phone_part}. If they agree, they will give you a 6-digit code.",
  "btn_send_code": "Send {admin_name} a message",
  "pin_sent": "A message was sent to {admin_name}. Call them, and type the code they give you.",
  "pin_label": "Code from {admin_name}",
  "btn_submit": "Continue",
  "pin_wrong": "That code is not right. You have {attempts_left} tries left.",
  "pin_locked": "Too many wrong codes. Please call {admin_name}{phone_part}.",
  "pin_expired": "That code has expired. Please ask for a new one.",
  "pin_used": "That code was already used. Please ask for a new one.",
  "pin_none": "Please send {admin_name} a message first.",
  "pin_bad_format": "The code is 6 numbers.",
  "pin_unreachable": "Could not reach {admin_name}. Please call them{phone_part}.",
  "pin_too_soon": "Please wait a few seconds before asking again.",
  "pin_ok": "Approved. You can continue.",
  "pin_ok_download": "Approved. Your download will now continue.",
  "btn_continue": "Continue to the website",

  // Banners for detections
  "card_reminder": "You are entering card details. Make sure you trust this website.",
  "card_warn": "Careful: you are entering card details on a website you may not know. {admin_name} has been told.",
  "password_reminder": "This website is asking for a password. Make sure it is the real website.",
  "password_warn": "Careful: this website's password prompt looks unusual. {admin_name} has been told.",

  // Full-screen overlay: wait and think
  "delay_title": "Please stop and think",
  "delay_body": "You are about to continue with {action_label} on {domain}. Scammers like to rush people. Please call {admin_name}{phone_part} before you continue.",
  "delay_countdown": "You can continue in {seconds} seconds.",
  "btn_delay_continue": "Continue",

  // Full-screen overlay: a page that looks like a scam
  "scam_title": "This page looks like a scam",
  "scam_body": "Real companies do not lock your computer or ask for payment this way. Please do not call any number, pay, or install anything. Call {admin_name}{phone_part} instead.",
  "scam_countdown": "You can open the page anyway in {seconds} seconds.",
  "btn_scam_continue": "I understand the risk. Open the page anyway.",
  "scam_reason.tech_support": "It says your computer has a problem and tells you to call someone",
  "scam_reason.gift_card": "It asks for payment with gift cards",
  "scam_reason.crypto_wire": "It asks for a wire transfer or cryptocurrency",
  "scam_reason.remote_tool": "It wants to take remote control of your computer",
  "scam_reason.government": "It threatens you in the name of the government",
  "scam_reason.prize": "It says you won a prize or refund",
  "scam_reason.urgency": "It tries to rush you",
  "scam_reason.phone_number": "It pushes you to call a phone number",

  // Toolbar popup
  "popup_safe": "Looks safe",
  "popup_safe_why": "{admin_name} marked this website as trusted.",
  "popup_careful": "Be careful here",
  "popup_careful_why": "This is a website you have not used before. Do not enter payment or password details unless you are sure.",
  "popup_careful_http": "This website does not use a secure connection. Do not type passwords or card numbers here.",
  "popup_danger": "Do not use this page",
  "popup_danger_blocked": "This website was marked as unsafe.",
  "popup_danger_scam": "This page shows signs of a scam.",
  "popup_neutral": "Nothing to check here",
  "popup_neutral_why": "This is a browser page, not a website.",
  "popup_safemode": "Protection needs attention",
  "popup_safemode_why": "ScamShield is in safe mode. Please call {admin_name}{phone_part}.",
  "btn_panic": "I think I'm being scammed",
  "panic_title": "Stop. You did the right thing.",
  "panic_sent": "{admin_name} has been told and will help you.",
  "panic_not_sent": "We could not reach {admin_name}. Please call now{phone_part}.",
  "panic_step_1": "Do not click or type anything else on that page.",
  "panic_step_2": "Do not pay, buy gift cards, or send money.",
  "panic_step_3": "If someone is on the phone with you, hang up.",
  "panic_step_4": "Call {admin_name}{phone_part} now.",
  "panic_step_5": "If you already shared card details or paid, call your bank right away.",

  // Messages sent to the admin (these never contain typed text or page content)
  "alert.card_entry": "Card entry was detected on {domain}.",
  "alert.password_prompt": "A password prompt on {domain} looked suspicious: {signals}.",
  "alert.bank_login": "A bank login on {domain} is waiting for your approval.",
  "alert.blocked_site": "A blocked website was opened: {domain}",
  "alert.heads_up": "The user asked for your help with a new website: {domain}",
  "alert.pin_request": "Approval requested for {action_label} on {domain}. Code: {pin}. Only give this code if you know what this is and trust it.",
  "alert.download_held": "A download is waiting for your approval: {filename} from {domain}.",
  "alert.download_blocked": "A download was stopped: {filename} from {domain}.",
  "alert.scam_page": "A page on {domain} looks like a scam: {signals}.",
  "alert.panic": "URGENT: the user says they think they are being scammed. Page: {domain}. Please call them now.",
  "alert.test_alert": "This is a test message. ScamShield alerts are working.",
  "alert.pin_failures": "Too many wrong codes were entered for {action_label} on {domain}.",
});

export const ACTION_LABELS = Object.freeze({
  card: "card entry",
  password: "a password prompt",
  download: "a download",
  bank: "a bank login",
  site: "this website",
});

// Plain-language names for the password signals, used in admin alerts.
export const SIGNAL_LABELS = Object.freeze({
  non_whitelisted: "unfamiliar website",
  lookalike: "name looks like a trusted site",
  http: "connection is not secure (http)",
  popup_iframe: "opened in a popup or hidden frame",
  urgency: "urgent, pressuring wording",
  bank_login: "bank login",
  tech_support: "fake computer-problem alarm",
  gift_card: "gift card payment demand",
  crypto_wire: "wire or crypto payment demand",
  remote_tool: "remote-access tool request",
  government: "government threat",
  prize: "prize or refund claim",
  phone_number: "phone number to call",
});

export function render(id, values = {}, overrides = {}) {
  const template = overrides[id] ?? DEFAULT_WORDING[id] ?? "";
  return template.replace(/\{(\w+)\}/g, (_, key) => String(values[key] ?? ""));
}
