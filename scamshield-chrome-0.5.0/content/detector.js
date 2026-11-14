// Detects card entry and password prompts, in every frame of every page.
//
// It reports FACTS only (that a card-like value was typed, that a password
// field exists, whether the page is http, framed, or opened by another page).
// It never sends, stores or logs what was typed. Policy decisions are made by
// the background script, which answers whether to lock the fields.

(() => {
  "use strict";

  globalThis.browser ??= globalThis.chrome; // Chromium has only `chrome`

  const CARD_FIELD_TYPES = ["", "text", "tel", "number", "search", "password"];
  const CARD_HINT = /(^|[^a-z])(card|cc|credit|debit)[\s_.\-]*(num|no|number|#)|cardnumber|ccnum|creditcard|carte|kartennummer/i;
  const URGENCY_PHRASES = [
    /account (will be|has been) (locked|suspended|closed|restricted)/,
    /verify your (account|identity)( now| immediately)?/,
    /within (24|48) hours/,
    /unusual (sign-?in|activity|login)/,
    /security alert/,
    /immediate(ly)? action/,
    /your (computer|device) (is|has been) (infected|compromised)/,
    /call (us )?(now|immediately)/,
    /final (warning|notice)/,
  ];

  const state = {
    cardFallback: true,
    urgency: false,
    reported: { card: false, password: false },
    locked: { card: false, password: false },
  };
  const lockedFields = new Map(); // field -> its original readOnly value
  let applyingLock = false;

  // ---- Card detection ------------------------------------------------------

  function luhnValid(digits) {
    let sum = 0;
    let double = false;
    for (let index = digits.length - 1; index >= 0; index -= 1) {
      let value = digits.charCodeAt(index) - 48;
      if (double) {
        value *= 2;
        if (value > 9) value -= 9;
      }
      sum += value;
      double = !double;
    }
    return sum % 10 === 0;
  }

  // A field that is labeled as a card number (by autocomplete or its name).
  function looksLikeCardField(field) {
    if (!(field instanceof HTMLInputElement)) return false;
    if (!CARD_FIELD_TYPES.includes((field.type || "").toLowerCase())) return false;
    const tokens = (field.getAttribute("autocomplete") || "").toLowerCase().split(/\s+/);
    if (tokens.includes("cc-number")) return true;
    if (tokens.some((token) => token.startsWith("cc-"))) return false; // expiry, cvc, name...
    const hints = [field.name, field.id, field.placeholder, field.getAttribute("aria-label")].join(" ");
    return CARD_HINT.test(hints);
  }

  // Card-like value in this field? Reads the value only to count digits.
  function holdsCardNumber(field) {
    if (!(field instanceof HTMLInputElement)) return null;
    const type = (field.type || "").toLowerCase();
    if (!CARD_FIELD_TYPES.includes(type)) return null;
    const digits = field.value.replace(/[\s-]/g, "");
    if (!/^\d+$/.test(digits)) return null;
    if (looksLikeCardField(field)) return digits.length >= 4 ? "field" : null;
    if (!state.cardFallback || type === "password") return null;
    return digits.length >= 13 && digits.length <= 19 && luhnValid(digits) ? "fallback" : null;
  }

  function onInput(event) {
    if (applyingLock || state.reported.card) return;
    const via = holdsCardNumber(event.target);
    if (via) report("card", { type: "card-detected", via }, event.target);
  }

  // ---- Password detection --------------------------------------------------

  const isVisible = (element) =>
    element.offsetWidth > 0 || element.offsetHeight > 0 || element.getClientRects().length > 0;

  const passwordFields = () => Array.from(document.querySelectorAll('input[type="password"]')).filter(isVisible);

  function crossOriginFrame() {
    if (window.top === window) return false;
    try {
      void window.top.location.hostname;
      return false;
    } catch {
      return true;
    }
  }

  function looksUrgent() {
    const text = (document.body ? document.body.innerText : "").slice(0, 30000).toLowerCase();
    return URGENCY_PHRASES.filter((pattern) => pattern.test(text)).length >= 2;
  }

  function scanForPassword() {
    if (state.reported.password) return;
    const fields = passwordFields();
    if (fields.length === 0) return;
    report("password", {
      type: "password-field",
      facts: {
        protocol: location.protocol,
        crossOriginFrame: crossOriginFrame(),
        hasOpener: window.top === window && window.opener !== null,
        urgent: state.urgency ? looksUrgent() : false,
      },
    });
  }

  let scanTimer = null;
  function scheduleScan() {
    clearTimeout(scanTimer);
    scanTimer = setTimeout(() => {
      if (!state.reported.password) scanForPassword();
      if (state.locked.card || state.locked.password) lockAll();
    }, 300);
  }

  // ---- Reporting and locking -----------------------------------------------

  async function report(kind, message, triggerField) {
    state.reported[kind] = true;
    let reply;
    try {
      reply = await browser.runtime.sendMessage(message);
    } catch {
      return;
    }
    if (reply && reply.lock) {
      lockKind(reply.fields === "card" ? "card" : "password", triggerField);
    }
  }

  const cardFields = () =>
    Array.from(document.querySelectorAll("input")).filter(
      (field) => looksLikeCardField(field) || holdsCardNumber(field) === "fallback",
    );

  function lockField(field) {
    if (lockedFields.has(field)) return;
    lockedFields.set(field, field.readOnly);
    applyingLock = true;
    try {
      if (field.value !== "") {
        field.value = "";
        field.dispatchEvent(new Event("input", { bubbles: true }));
      }
      field.readOnly = true;
      field.blur();
    } finally {
      applyingLock = false;
    }
  }

  function lockKind(kind, triggerField) {
    state.locked[kind] = true;
    const fields = kind === "card" ? cardFields() : passwordFields();
    if (triggerField instanceof HTMLInputElement) fields.push(triggerField);
    fields.forEach(lockField);
  }

  // Fields that appear after the lock (many sites build forms late).
  function lockAll() {
    if (state.locked.card) cardFields().forEach(lockField);
    if (state.locked.password) passwordFields().forEach(lockField);
  }

  function unlockKind(kind) {
    state.locked[kind] = false;
    for (const [field, wasReadOnly] of Array.from(lockedFields)) {
      const isCard = looksLikeCardField(field);
      const isPassword = field.type === "password";
      if ((kind === "card" && isCard) || (kind === "password" && isPassword)) {
        field.readOnly = wasReadOnly;
        lockedFields.delete(field);
      }
    }
  }

  // Backstop: even if the page flips readOnly back, locked fields take no input.
  function blockIfLocked(event) {
    if (lockedFields.has(event.target)) {
      event.preventDefault();
      event.stopImmediatePropagation();
    }
  }

  // ---- Start-up ------------------------------------------------------------

  async function start() {
    let reply;
    try {
      reply = await browser.runtime.sendMessage({ type: "detector-init" });
    } catch {
      return;
    }
    if (!reply || !reply.watch) return;

    state.cardFallback = reply.cardFallback !== false;
    state.urgency = reply.urgency === true;

    browser.runtime.onMessage.addListener((message) => {
      if (message && message.type === "approval-granted") {
        const kind = message.action === "card" ? "card" : "password";
        state.reported[kind] = true; // approved: stop watching this kind
        unlockKind(kind);
      }
    });

    for (const type of ["beforeinput", "keydown", "paste", "drop"]) {
      document.addEventListener(type, blockIfLocked, true);
    }
    if (reply.watch.card) {
      document.addEventListener("input", onInput, true);
      document.addEventListener("change", onInput, true);
      // Autofilled values may already be present.
      for (const field of document.querySelectorAll("input")) {
        const via = holdsCardNumber(field);
        if (via && !state.reported.card) report("card", { type: "card-detected", via }, field);
      }
    } else {
      state.reported.card = true;
    }
    if (reply.watch.password) {
      scanForPassword();
      new MutationObserver(scheduleScan).observe(document.documentElement, { childList: true, subtree: true });
    } else {
      state.reported.password = true;
    }
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", start, { once: true });
  } else {
    start();
  }
})();
