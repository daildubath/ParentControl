// The settings page for browser-only mode. It holds no settings itself: it
// asks the background script for them, and every change goes back through the
// background script, which checks the passcode and validates the policy.
// All text is set with textContent, never as markup.

globalThis.browser ??= globalThis.chrome; // Chromium has only `chrome`

const $ = (id) => document.getElementById(id);
const send = (message) => browser.runtime.sendMessage(message);

const TIERS = ["whitelist", "graylist", "blacklist"];
const TIER_LABELS = { whitelist: "Trusted sites", graylist: "New sites", blacklist: "Blocked sites" };
const LEVELS = { off: "Nothing", reminder: "Reminder", warn: "Warn + tell admin", delay: "Wait and think", block: "Admin code needed" };
const DOWNLOADS = { allow: "Allow", hold_risky: "Hold risky files", block: "Block" };
const LISTS = ["whitelist", "bank_domains", "graylist", "blacklist"];

let current = null; // the policy being edited
let presets = {};

function notice(text, kind = "") {
  const box = $("notice");
  box.textContent = text;
  box.className = `notice ${kind}`;
  box.hidden = text === "";
}

function show(section) {
  for (const id of ["managed", "setup", "unlock", "editor"]) $(id).hidden = id !== section;
}

function lockText(until) {
  const minutes = Math.max(1, Math.ceil((until - Date.now()) / 60_000));
  return `Too many wrong passcodes. Try again in about ${minutes} minute${minutes === 1 ? "" : "s"}.`;
}

const errorText = {
  wrong: "That passcode is not right.",
  no_passcode: "No passcode has been created yet.",
  already_set: "A passcode already exists.",
  managed_active: "These settings are managed by policy.",
  locked_settings: "The settings are locked. Enter the passcode first.",
};

// ---- building the form ----

function selectFor(id, options, value) {
  const select = document.createElement("select");
  select.id = id;
  for (const [key, label] of Object.entries(options)) {
    const option = document.createElement("option");
    option.value = key;
    option.textContent = label;
    select.append(option);
  }
  select.value = value;
  return select;
}

function buildTiers(tiers) {
  const body = $("tiers");
  body.replaceChildren();
  for (const tier of TIERS) {
    const row = document.createElement("tr");
    const head = document.createElement("th");
    head.scope = "row";
    head.textContent = TIER_LABELS[tier];
    row.append(head);
    for (const [field, options] of [["card", LEVELS], ["password", LEVELS], ["download", DOWNLOADS]]) {
      const cell = document.createElement("td");
      const select = selectFor(`tier-${tier}-${field}`, options, tiers[tier][field]);
      select.setAttribute("aria-label", `${TIER_LABELS[tier]}: ${field}`);
      select.addEventListener("change", () => { $("preset").value = "custom"; });
      cell.append(select);
      row.append(cell);
    }
    body.append(row);
  }
}

const FEED_PROBLEMS = {
  not_loaded: "Not downloaded yet",
  unreachable: "Could not connect",
  timeout: "Took too long",
  too_big: "File too large",
  too_few_entries: "List looked wrong (too short)",
  too_many_entries: "List looked wrong (too long)",
  shrank_too_much: "List looked wrong (shrank a lot)",
  unreadable: "Could not read the list",
  insecure_redirect: "Refused (not secure)",
};
const problemText = (code) => FEED_PROBLEMS[code] ?? (/^http_/.test(code) ? `Server error (${code.slice(5)})` : "Problem");

function showFeeds(info) {
  const body = $("feeds");
  body.replaceChildren();
  $("feeds-enabled").checked = info.enabled;
  for (const feed of info.feeds) {
    const row = document.createElement("tr");
    const ok = feed.count > 0 && !feed.lastError;
    const cells = [
      feed.label,
      feed.category === "threat" ? "Malware and phishing sites" : "Ads and trackers",
      feed.count > 0 ? feed.count.toLocaleString() : "0",
      feed.fetchedAt ? new Date(feed.fetchedAt).toLocaleString() : "never",
      !info.enabled ? "Switched off" : ok ? "Working" : problemText(feed.lastError || "not_loaded"),
    ];
    for (const text of cells) {
      const cell = document.createElement("td");
      cell.textContent = text;
      row.append(cell);
    }
    body.append(row);
  }
}

async function loadFeeds() {
  const reply = await send({ type: "options-feeds-info" });
  if (reply.ok) showFeeds(reply.feeds);
}

const REASONS = {
  admin_whitelist: "It is on your trusted list.",
  admin_blacklist: "It is on your own blocked list.",
  bank: "It is a bank on your list.",
  admin_graylist: "It is on your watch list.",
  feed_blacklist: "It is on an automatic malware or phishing blocklist.",
  unlisted: "It is not on any list, so it is treated as a new website.",
};

function fillForm(policy) {
  loadFeeds();
  $("admin-name").value = policy.admin.name;
  $("admin-phone").value = policy.admin.phone;
  $("ntfy-server").value = policy.notifier.server;
  $("ntfy-topic").value = policy.notifier.topic;
  $("ntfy-token").value = policy.notifier.token ?? "";
  buildTiers(policy.tiers);
  $("preset").value = policy.severity_preset ?? "custom";
  $("bank-policy").value = policy.bank_policy ?? "approve_once";
  $("hold-all").checked = policy.hold_all_downloads === true;
  $("scam-detection").checked = policy.scam_detection !== false;
  for (const name of LISTS) $(`list-${name}`).value = (policy.lists[name] ?? []).join("\n");
}

// "https://www.Example.com/page" -> "www.example.com"; the background script validates the rest.
function parseList(text) {
  const entries = text.split(/[\s,]+/).map((entry) => entry.trim().toLowerCase().replace(/^[a-z]+:\/\//, "").replace(/[/?#].*$/, "")).filter(Boolean);
  return [...new Set(entries)];
}

function readForm() {
  const policy = structuredClone(current);
  policy.admin = { name: $("admin-name").value.trim(), phone: $("admin-phone").value.trim() };
  policy.notifier = { provider: "ntfy", server: $("ntfy-server").value.trim(), topic: $("ntfy-topic").value.trim() };
  const token = $("ntfy-token").value.trim();
  if (token) policy.notifier.token = token;
  policy.tiers = Object.fromEntries(TIERS.map((tier) => [tier, {
    card: $(`tier-${tier}-card`).value,
    password: $(`tier-${tier}-password`).value,
    download: $(`tier-${tier}-download`).value,
  }]));
  policy.severity_preset = $("preset").value;
  policy.bank_policy = $("bank-policy").value;
  policy.hold_all_downloads = $("hold-all").checked;
  policy.scam_detection = $("scam-detection").checked;
  policy.feeds = { refresh_hours: 24, ...policy.feeds, enabled: $("feeds-enabled").checked };
  policy.lists = Object.fromEntries(LISTS.map((name) => [name, parseList($(`list-${name}`).value)]));
  return policy;
}

function randomTopic() {
  const bytes = crypto.getRandomValues(new Uint8Array(24));
  return btoa(String.fromCharCode(...bytes)).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
}

// ---- screens ----

async function refresh(message = "", kind = "") {
  const info = await send({ type: "options-state" });
  presets = info.presets;
  notice(message, kind);
  if (info.source === "managed") return show("managed");
  if (!info.hasPasscode) return show("setup");
  if (!info.unlocked) {
    show("unlock");
    if (info.lockedUntil) notice(lockText(info.lockedUntil), "bad");
    return undefined;
  }
  current = info.policy;
  fillForm(current);
  show("editor");
  if (!message && info.safeMode) notice("ScamShield is in safe mode until you save settings that are valid.", "bad");
  return undefined;
}

function failure(reply) {
  if (reply.error === "locked") return lockText(reply.lockedUntil);
  return reply.text ?? errorText[reply.error] ?? "That did not work.";
}

$("setup-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  if ($("setup-pass").value !== $("setup-pass2").value) return notice("The two passcodes are different.", "bad");
  const reply = await send({ type: "options-setup-passcode", passcode: $("setup-pass").value });
  $("setup-pass").value = $("setup-pass2").value = "";
  return reply.ok ? refresh("Passcode created. Now fill in the settings below.", "ok") : notice(failure(reply), "bad");
});

$("unlock-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  const reply = await send({ type: "options-unlock", passcode: $("unlock-pass").value });
  $("unlock-pass").value = "";
  return reply.ok ? refresh() : notice(failure(reply), "bad");
});

$("preset").addEventListener("change", () => {
  const preset = presets[$("preset").value];
  if (!preset) return;
  for (const tier of TIERS) {
    for (const field of ["card", "password", "download"]) $(`tier-${tier}-${field}`).value = preset[tier][field];
  }
});

$("make-topic").addEventListener("click", () => { $("ntfy-topic").value = randomTopic(); });

async function save() {
  const reply = await send({ type: "options-save", policy: readForm() });
  if (reply.ok) { notice("Saved. The new settings are active now.", "ok"); await loadFeeds(); return true; }
  notice(reply.errors ? `Please fix: ${reply.errors.join("; ")}` : failure(reply), "bad");
  return false;
}

$("editor").addEventListener("submit", async (event) => {
  event.preventDefault();
  if (await save()) current = readForm();
});

$("test-alert").addEventListener("click", async () => {
  if (!(await save())) return;
  const reply = await send({ type: "options-test-alert" });
  notice(reply.ok ? "Test message sent. Check the admin's phone." : "Could not send the test message. Check the server, topic and token.", reply.ok ? "ok" : "bad");
});

$("feeds-refresh").addEventListener("click", async () => {
  // Settings are saved first, so a changed on/off switch takes effect before updating.
  if (!(await save())) return;
  notice("Updating the lists. This can take a few seconds.", "");
  const reply = await send({ type: "options-feeds-refresh" });
  if (!reply.ok) return notice(failure(reply), "bad");
  showFeeds(reply.feeds);
  const bad = reply.feeds.feeds.filter((feed) => feed.lastError).length;
  return notice(bad ? "Updated, but some lists had a problem. See the Status column." : "Lists updated.", bad ? "bad" : "ok");
});

async function checkSite() {
  const reply = await send({ type: "options-check-site", site: $("check-site").value });
  const out = $("check-result");
  if (!reply.ok) {
    out.textContent = reply.error === "bad_site" ? "Type a website name, like example.com." : failure(reply);
    return;
  }
  const blocked = reply.tier === "blacklist";
  const adsOnly = reply.ads && reply.reason === "unlisted";
  const parts = [`${reply.host}: ${blocked ? "BLOCKED." : reply.tier === "whitelist" ? "Trusted." : "Allowed, with care."} ${adsOnly ? "The site itself is not blocked." : (REASONS[reply.reason] ?? "")}`];
  if (reply.ads) parts.push("It is on the ad and tracker list, so ads and trackers from it are blocked.");
  out.textContent = parts.join(" ");
}
$("check-button").addEventListener("click", checkSite);
$("check-site").addEventListener("keydown", (event) => { if (event.key === "Enter") { event.preventDefault(); checkSite(); } });

$("lock").addEventListener("click", async () => {
  await send({ type: "options-lock" });
  await refresh("Settings locked.");
});

$("change-pass").addEventListener("click", async () => {
  const reply = await send({ type: "options-change-passcode", oldPasscode: $("old-pass").value, newPasscode: $("new-pass").value });
  $("old-pass").value = $("new-pass").value = "";
  notice(reply.ok ? "Passcode changed." : failure(reply), reply.ok ? "ok" : "bad");
});

$("json-show").addEventListener("click", () => { $("json").value = JSON.stringify(readForm(), null, 2); });
$("json-load").addEventListener("click", () => {
  try {
    const parsed = JSON.parse($("json").value);
    if (!parsed || typeof parsed !== "object" || !parsed.admin || !parsed.notifier || !parsed.tiers || !parsed.lists) throw new Error("incomplete");
    current = parsed;
    fillForm(parsed);
    notice("Loaded into the form. Press Save to keep it.", "ok");
  } catch {
    notice("That text is not a complete settings file.", "bad");
  }
});

refresh();
