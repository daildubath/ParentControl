// Admin alerts.
//
// Alert content (buildAlert) is separate from delivery (providers), so a new
// provider or a prettier format can be added without touching the rest of the
// extension. Alerts carry only an event type, a domain and, for approval
// requests, the one-time code. Never typed text or page content.

import { ACTION_LABELS, SIGNAL_LABELS, render } from "./messages.js";

const EVENTS = {
  card_entry: { title: "Card entry detected", wording: "alert.card_entry", priority: 4, tags: ["credit_card"] },
  password_prompt: { title: "Suspicious password prompt", wording: "alert.password_prompt", priority: 4, tags: ["lock"] },
  bank_login: { title: "Bank login waiting", wording: "alert.bank_login", priority: 4, tags: ["bank"] },
  blocked_site: { title: "Blocked website opened", wording: "alert.blocked_site", priority: 4, tags: ["no_entry"] },
  scam_page: { title: "Scam page warning", wording: "alert.scam_page", priority: 4, tags: ["warning", "rotating_light"] },
  panic: { title: "URGENT: possible scam in progress", wording: "alert.panic", priority: 5, tags: ["sos", "rotating_light"] },
  heads_up: { title: "Help requested", wording: "alert.heads_up", priority: 3, tags: ["raising_hand"] },
  pin_request: { title: "Approval requested", wording: "alert.pin_request", priority: 5, tags: ["key"] },
  download_held: { title: "Download waiting", wording: "alert.download_held", priority: 4, tags: ["package"] },
  download_blocked: { title: "Download stopped", wording: "alert.download_blocked", priority: 4, tags: ["no_entry"] },
  test_alert: { title: "Test message", wording: "alert.test_alert", priority: 3, tags: ["white_check_mark"] },
  pin_failures: { title: "Wrong codes entered", wording: "alert.pin_failures", priority: 4, tags: ["warning"] },
};

// Turn an event into plain content. details: { domain, action?, pin?, filename? }.
export function buildAlert(eventType, details) {
  const event = EVENTS[eventType];
  if (!event) throw new Error(`Unknown alert event: ${eventType}`);
  const message = render(event.wording, {
    domain: details.domain ?? "",
    pin: details.pin ?? "",
    filename: details.filename ?? "a file",
    action_label: ACTION_LABELS[details.action] ?? ACTION_LABELS.site,
    signals: (details.signals ?? []).map((name) => SIGNAL_LABELS[name] ?? name).join(", "),
  });
  return { title: `ScamShield: ${event.title}`, message, priority: event.priority, tags: event.tags };
}

// ntfy.sh (or a self-hosted ntfy server) using JSON publishing, which keeps
// non-ASCII text safe. The topic acts as the shared secret.
const ntfyProvider = {
  async send(notifier, alert, { fetchFn, timeoutMs }) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMs);
    try {
      const response = await fetchFn(notifier.server, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          ...(notifier.token ? { Authorization: `Bearer ${notifier.token}` } : {}),
        },
        body: JSON.stringify({
          topic: notifier.topic,
          title: alert.title,
          message: alert.message,
          priority: alert.priority,
          tags: alert.tags,
        }),
        signal: controller.signal,
      });
      if (!response.ok) {
        return { ok: false, error: `server_status_${response.status}` };
      }
      return { ok: true };
    } catch (error) {
      return { ok: false, error: error?.name === "AbortError" ? "timeout" : "unreachable" };
    } finally {
      clearTimeout(timer);
    }
  },
};

// Add future providers here (for example a Telegram bot or a dashboard).
export const providers = { ntfy: ntfyProvider };

// Returns { ok, error? }. Never throws: a failed alert must not break browsing.
export async function sendAlert(config, eventType, details, { fetchFn, timeoutMs = 8000 } = {}) {
  if (!config.notifier) return { ok: false, error: "no_notifier" };
  const provider = providers[config.notifier.provider];
  if (!provider) return { ok: false, error: "unknown_provider" };
  try {
    return await provider.send(config.notifier, buildAlert(eventType, details), { fetchFn, timeoutMs });
  } catch {
    return { ok: false, error: "unreachable" };
  }
}
