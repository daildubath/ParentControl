// Draws ScamShield's notices on the page (top frame only): the banner and the
// full-screen overlay. It owns no policy: the background script decides when,
// and with what words. Everything lives in closed shadow roots so page styles
// and scripts cannot change or read it, and all text is set with textContent,
// never as markup.

(() => {
  "use strict";

  globalThis.browser ??= globalThis.chrome; // Chromium has only `chrome`

  if (window.top !== window) return;

  const SVG_NS = "http://www.w3.org/2000/svg";
  // Inline shield icon built with DOM calls (no markup strings). tone: blue|red|amber
  function shieldIcon(glyph) {
    const svg = document.createElementNS(SVG_NS, "svg");
    svg.setAttribute("viewBox", "0 0 64 64");
    svg.setAttribute("aria-hidden", "true");
    svg.setAttribute("class", "icon");
    const body = document.createElementNS(SVG_NS, "path");
    body.setAttribute("d", "M32 3.5 57 12.5v18c0 15.6-10.4 27.1-25 30.5C17.4 57.6 7 46.1 7 30.5v-18z");
    body.setAttribute("class", "icon-body");
    const mark = document.createElementNS(SVG_NS, "path");
    mark.setAttribute("class", "icon-mark");
    mark.setAttribute("d", glyph === "stop" ? "M32 17v17M32 43.5v.5" : "M20 32l8 8 16-17");
    svg.append(body, mark);
    return svg;
  }

  let bannerHost = null;
  let overlay = null; // { host, action, timer, observer }

  // ---- Banner ---------------------------------------------------------------

  function showBanner(banner) {
    removeBanner();
    const host = document.createElement("div");
    host.style.cssText = "all: initial; position: fixed; top: 0; left: 0; right: 0; z-index: 2147483646;";
    const root = host.attachShadow({ mode: "closed" });

    const style = document.createElement("style");
    const safeMode = banner.kind === "safe_mode";
    style.textContent = `
      .bar {
        box-sizing: border-box; width: 100%; padding: 14px 20px;
        background: ${safeMode ? "linear-gradient(90deg,#8f1230,#b4232f)" : "linear-gradient(90deg,#0d2c54,#1d4ed8)"}; color: #ffffff;
        font: ${18 * banner.textScale}px/1.4 system-ui, "Segoe UI", sans-serif;
        border-bottom: 4px solid #ffd54a; box-shadow: 0 6px 18px rgba(0,0,0,.28);
        display: flex; flex-wrap: wrap; gap: 12px 18px; align-items: center;
      }
      .icon { width: 2.2em; height: 2.2em; flex: none; }
      .icon-body { fill: rgba(255,255,255,.95); }
      .icon-mark { fill: none; stroke: ${safeMode ? "#b4232f" : "#1d4ed8"}; stroke-width: 6; stroke-linecap: round; stroke-linejoin: round; }
      .text { flex: 1 1 320px; font-weight: 600; }
      .buttons { display: flex; flex-wrap: wrap; gap: 12px; }
      ${BUTTON_CSS}
    `;

    const bar = document.createElement("div");
    bar.className = "bar";
    bar.setAttribute("role", "region");
    bar.setAttribute("aria-label", "ScamShield notice");

    const text = document.createElement("div");
    text.className = "text";
    text.textContent = banner.text;
    bar.append(shieldIcon(safeMode ? "stop" : "check"), text);

    const buttons = document.createElement("div");
    buttons.className = "buttons";
    for (const spec of banner.buttons) {
      const button = document.createElement("button");
      button.type = "button";
      button.textContent = spec.label;
      button.addEventListener("click", () => onBannerButton(spec, button));
      buttons.append(button);
    }
    bar.append(buttons);

    root.append(style, bar);
    document.documentElement.append(host);
    bannerHost = host;
    buttons.querySelector("button")?.focus({ preventScroll: true });
  }

  function removeBanner() {
    if (bannerHost) bannerHost.remove();
    bannerHost = null;
  }

  async function onBannerButton(spec, button) {
    if (spec.id === "dismiss") {
      removeBanner();
      return;
    }
    if (spec.id === "ask") {
      button.disabled = true;
      let ok = false;
      try {
        ok = (await browser.runtime.sendMessage({ type: "ask-admin" }))?.ok === true;
      } catch {
        ok = false;
      }
      button.textContent = ok ? spec.sentLabel : spec.failedLabel;
      button.disabled = ok;
    }
  }

  const BUTTON_CSS = `
    button {
      font: inherit; font-weight: 700; min-height: 48px; padding: 8px 22px; cursor: pointer;
      background: #ffd54a; color: #111111; border: 2px solid #ffffff; border-radius: 12px;
      box-shadow: 0 2px 0 rgba(0,0,0,.25);
    }
    button.primary { background: #ffffff; color: #0d2c54; }
    button.quiet { background: transparent; color: #ffffff; border-color: rgba(255,255,255,.55); box-shadow: none; }
    button:focus-visible { outline: 4px solid #ffffff; outline-offset: 3px; }
    button[disabled] { opacity: 0.8; cursor: default; }
  `;

  // ---- Full-screen overlay -----------------------------------------------------
  // mode "delay": a countdown, then a Continue button.
  // mode "pin": the approval-code page, framed.
  // mode "scam": a page that looks like a scam; reasons, Leave, delayed Continue.

  function showOverlay(spec) {
    removeOverlay();
    const host = document.createElement("div");
    host.style.cssText = "all: initial; position: fixed; inset: 0; z-index: 2147483647;";
    const root = host.attachShadow({ mode: "closed" });

    const style = document.createElement("style");
    const danger = spec.mode === "scam";
    style.textContent = `
      .screen {
        box-sizing: border-box; width: 100%; height: 100%; padding: 24px; overflow: auto;
        background: ${danger ? "radial-gradient(circle at 50% 0%, #5a0f1a, #1a0a10 70%)" : "radial-gradient(circle at 50% 0%, #1b3d73, #0a1628 70%)"}; color: #ffffff;
        font: ${18 * spec.textScale}px/1.45 system-ui, "Segoe UI", sans-serif;
        display: flex; flex-direction: column; align-items: center; gap: 18px;
      }
      .inner {
        margin: auto; width: min(820px, 100%); text-align: center; padding: clamp(22px, 4vw, 40px);
        background: rgba(255,255,255,.07); border: 1px solid rgba(255,255,255,.22); border-radius: 24px;
        box-shadow: 0 20px 60px rgba(0,0,0,.45);
      }
      .icon { width: 4em; height: 4em; filter: drop-shadow(0 6px 10px rgba(0,0,0,.4)); }
      .icon-body { fill: ${danger ? "#e5484d" : "#ffd54a"}; }
      .icon-mark { fill: none; stroke: ${danger ? "#ffffff" : "#0d2c54"}; stroke-width: 6; stroke-linecap: round; stroke-linejoin: round; }
      h1 { margin: 0.3em 0 0.4em; font-size: 1.7em; line-height: 1.2; }
      p { margin: 0 0 0.8em; }
      ul.reasons { list-style: none; margin: 0.4em auto 1em; padding: 0; max-width: 34em; text-align: left; }
      ul.reasons li { padding: 0.45em 0.9em 0.45em 2.2em; margin: 0.4em 0; background: rgba(255,255,255,.1); border-radius: 12px; position: relative; }
      ul.reasons li::before { content: "!"; position: absolute; left: 0.75em; font-weight: 900; color: #ffd54a; }
      .contact { display: inline-block; font-weight: 800; color: #111; background: #ffd54a; padding: 0.35em 1.1em; border-radius: 999px; }
      .countdown { font-weight: 700; min-height: 1.4em; }
      iframe { width: min(900px, 100%); flex: 1 1 auto; min-height: 60%; border: 0; background: transparent; }
      .actions { display: flex; flex-wrap: wrap; gap: 16px; margin-top: 1em; justify-content: center; }
      ${BUTTON_CSS}
    `;

    const screen = document.createElement("div");
    screen.className = "screen";
    screen.setAttribute("role", "dialog");
    screen.setAttribute("aria-modal", "true");
    screen.setAttribute("aria-label", "ScamShield");

    const backButton = document.createElement("button");
    backButton.type = "button";
    backButton.textContent = spec.backLabel;
    backButton.className = "primary";
    backButton.addEventListener("click", () => {
      if (history.length > 1) history.back();
      else location.href = "about:blank";
    });

    let timer = null;
    if (spec.mode === "pin") {
      const frame = document.createElement("iframe");
      frame.src = spec.src;
      frame.title = "ScamShield approval";
      const actions = document.createElement("div");
      actions.className = "actions";
      actions.append(backButton);
      screen.append(frame, actions);
    } else {
      const inner = document.createElement("div");
      inner.className = "inner";
      const title = document.createElement("h1");
      title.textContent = spec.title;
      const body = document.createElement("p");
      body.textContent = spec.body;
      const contactRow = document.createElement("p");
      const contact = document.createElement("span");
      contact.className = "contact";
      contact.textContent = spec.admin.phone ? `\u260E ${spec.admin.name}: ${spec.admin.phone}` : spec.admin.name;
      contactRow.append(contact);
      let reasons = null;
      if (Array.isArray(spec.reasons) && spec.reasons.length) {
        reasons = document.createElement("ul");
        reasons.className = "reasons";
        for (const reason of spec.reasons.slice(0, 6)) {
          const li = document.createElement("li");
          li.textContent = String(reason);
          reasons.append(li);
        }
      }
      const countdown = document.createElement("p");
      countdown.className = "countdown";
      countdown.setAttribute("role", "status");
      const actions = document.createElement("div");
      actions.className = "actions";
      const continueButton = document.createElement("button");
      continueButton.type = "button";
      continueButton.textContent = spec.continueLabel;
      continueButton.className = "quiet";
      continueButton.hidden = true;
      continueButton.addEventListener("click", async () => {
        continueButton.disabled = true;
        let ok = false;
        try {
          ok = (await browser.runtime.sendMessage(
            spec.mode === "scam" ? { type: "scam-dismissed" } : { type: "delay-complete", action: spec.action },
          ))?.ok === true;
        } catch {
          ok = false;
        }
        if (ok) removeOverlay();
        else continueButton.disabled = false;
      });
      actions.append(continueButton, backButton);
      inner.append(shieldIcon("stop"), title, body);
      if (reasons) inner.append(reasons);
      inner.append(contactRow, countdown, actions);
      screen.append(inner);

      // Count down against the clock, so a throttled timer cannot shorten the wait.
      const endsAt = Date.now() + (spec.seconds ?? 0) * 1000;
      const tick = () => {
        const left = Math.ceil((endsAt - Date.now()) / 1000);
        if (left <= 0) {
          countdown.textContent = "";
          continueButton.hidden = false;
          continueButton.focus();
          clearInterval(timer);
        } else {
          countdown.textContent = spec.countdownText.replace("{seconds}", String(left));
        }
      };
      timer = setInterval(tick, 500);
      tick();
    }

    root.append(style, screen);
    document.documentElement.append(host);
    if (document.body) document.body.inert = true; // nothing behind the overlay can be used
    backButton.focus({ preventScroll: true });

    // If the page removes the overlay, put it back.
    const observer = new MutationObserver(() => {
      if (overlay && !host.isConnected) document.documentElement.append(host);
    });
    observer.observe(document.documentElement, { childList: true });
    overlay = { host, action: spec.action, timer, observer };
  }

  function removeOverlay() {
    if (!overlay) return;
    overlay.observer.disconnect();
    clearInterval(overlay.timer);
    overlay.host.remove();
    if (document.body) document.body.inert = false;
    overlay = null;
  }

  // ---- Messages from the background script ----------------------------------

  browser.runtime.onMessage.addListener((message) => {
    if (!message || typeof message.type !== "string") return;
    if (message.type === "show-banner") showBanner(message.banner);
    else if (message.type === "show-overlay") showOverlay(message.overlay);
    else if (message.type === "approval-granted" && overlay && overlay.action === message.action) removeOverlay();
  });

  // ---- Page-load banner (new-site notice, safe mode) -------------------------

  async function start() {
    let reply;
    try {
      reply = await browser.runtime.sendMessage({ type: "page-loaded" });
    } catch {
      return;
    }
    if (reply && reply.banner) showBanner(reply.banner);
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", start, { once: true });
  } else {
    start();
  }
})();
