// Full-screen page. Three modes, chosen by the address:
//   ?mode=blocked&host=example.com
//   ?mode=download-blocked&domain=example.com
//   ?mode=pin&action=card&domain=example.com&next=https://example.com/checkout
// All words come from the background script; text is set with textContent.

globalThis.browser ??= globalThis.chrome; // Chromium has only `chrome`

const params = new URLSearchParams(location.search);
const requestedMode = params.get("mode");
const mode = ["pin", "download-blocked"].includes(requestedMode) ? requestedMode : "blocked";
const domain = params.get("domain") ?? params.get("host") ?? "";
const action = params.get("action") ?? "site";

const $ = (id) => document.getElementById(id);

// Only continue to an http(s) address on the same domain that was approved.
function safeNextUrl() {
  try {
    const next = new URL(params.get("next") ?? "");
    const sameSite = next.hostname === domain || next.hostname.endsWith(`.${domain}`);
    return (next.protocol === "https:" || next.protocol === "http:") && sameSite ? next.href : null;
  } catch {
    return null;
  }
}

function goBack() {
  if (history.length > 1) history.back();
  else location.href = "about:blank";
}

async function start() {
  const info = await browser.runtime.sendMessage({ type: "get-interstitial", mode, domain, action });
  if (!info) return;
  const { texts, textScale, admin } = info;
  document.documentElement.style.setProperty("--scale", String(textScale));
  document.body.dataset.mode = mode; // picks the icon and colors

  $("back").textContent = texts.btn_back;
  $("back").addEventListener("click", goBack);
  // Inside the overlay, the overlay supplies its own back button.
  if (window.top !== window) $("back").hidden = true;
  $("contact").textContent = admin.phone ? `${admin.name}: ${admin.phone}` : admin.name;

  if (mode === "blocked" || mode === "download-blocked") {
    const prefix = mode === "blocked" ? "blocked" : "dl_blocked";
    document.title = texts[`${prefix}_title`];
    $("title").textContent = texts[`${prefix}_title`];
    $("body").textContent = texts[`${prefix}_body`];
    return;
  }

  document.title = texts.pin_title;
  $("title").textContent = texts.pin_title;
  $("body").textContent = texts.pin_body;
  $("pin-section").hidden = false;
  $("send-code").textContent = texts.btn_send_code;
  $("pin-label").textContent = texts.pin_label;
  $("submit").textContent = texts.btn_submit;
  $("continue").textContent = texts.btn_continue;

  $("send-code").addEventListener("click", async () => {
    $("send-code").disabled = true;
    const reply = await browser.runtime.sendMessage({ type: "request-pin", action, domain });
    $("status").textContent = reply?.text ?? "";
    if (reply?.ok) {
      $("pin-form").hidden = false;
      $("pin-input").focus();
    }
    // Allow another try after a short wait, or immediately if delivery failed.
    setTimeout(() => { $("send-code").disabled = false; }, reply?.ok ? 15000 : 1000);
  });

  $("pin-form").addEventListener("submit", async (event) => {
    event.preventDefault();
    const reply = await browser.runtime.sendMessage({
      type: "verify-pin", action, domain, pin: $("pin-input").value.trim(),
    });
    $("status").textContent = reply?.text ?? "";
    $("pin-input").value = "";
    if (reply?.result === "ok") {
      $("pin-form").hidden = true;
      const next = safeNextUrl();
      if (next) {
        $("continue").hidden = false;
        $("continue").addEventListener("click", () => { location.href = next; });
        $("continue").focus();
      }
    }
  });
}

start();
