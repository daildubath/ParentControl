// The extension's brain, written against an injected `browser` object so it
// can be tested without Firefox. It enforces policy; it never decides policy.

import { STRICT_BASELINE, validatePolicy } from "../lib/config.js";
import { buildLists, classify } from "../lib/decision.js";
import { basename, isRiskyDownload, lastSegment, nameFromUrl } from "../lib/download-types.js";
import { findMatch, hostFromUrl, isValidDomain } from "../lib/domains.js";
import { FEED_DEFINITIONS } from "../lib/feeds.js";
import { createLogger } from "../lib/logger.js";
import { lookalikeOf } from "../lib/lookalike.js";
import { ACTION_LABELS, render } from "../lib/messages.js";
import { sendAlert } from "../lib/notifier.js";
import { createChallenge, verifyChallenge } from "../lib/pin.js";
import { buildRules } from "../lib/dnr.js";
import { createFeedManager } from "./feed-manager.js";
import { createOptionsApi } from "./options.js";

const ACTIONS = Object.keys(ACTION_LABELS);
const ALERT_COOLDOWN_MS = 60_000;
const PIN_REQUEST_COOLDOWN_MS = 15_000;
const APPROVAL_MS = 10 * 60_000;
const DELAY_TOLERANCE_MS = 1500;
const MAX_SEEN_HOSTS = 5000;
const MAX_TRACKED_TABS = 500;
const DOWNLOAD_TAB_COOLDOWN_MS = 60_000;
const HELD_MAX_AGE_MS = 30 * 60_000; // a held download older than this is deleted, not released
const REMOTE_TOOLS = /anydesk|teamviewer|ultraviewer|ammyy|rustdesk|supremo|screenconnect|splashtop|logmein|quickassist|quick[-_ ]assist/i;
const STRICTNESS = { whitelist: 1, graylist: 2, blacklist: 3 };

export function createController({
  browser,
  fetchFn = (...args) => fetch(...args),
  now = () => Date.now(),
  logger,
  feedDefinitions = FEED_DEFINITIONS,
  useDnr = false, // Chrome: block with declarativeNetRequest rules instead of webRequest
}) {
  const state = {
    config: structuredClone(STRICT_BASELINE),
    lists: buildLists(STRICT_BASELINE),
    adSet: new Set(),
    threatSet: new Set(),
    safeMode: true,
    safeReason: "loading",
    source: "none", // "managed" (policy), "local" (settings page) or "none"
    adRuleIds: new Set(), // Chrome: ids of the ad-blocking rules, to count them per page
    dnrOk: null, // Chrome: did the last rule update succeed? (null = not used yet)
    dnrRuleCount: 0,
  };
  const log = logger ?? createLogger(() => state.config.verbose_logging);
  const lastAlertAt = new Map();
  const lastPinRequestAt = new Map();
  const lastDownloadTabAt = new Map();
  const tabTopHost = new Map(); // tab id -> host of the page it is showing
  const tabScam = new Map(); // tab id -> { host, signals } for pages flagged as scams
  const tabAds = new Map(); // tab id -> ads blocked on the current page (Firefox)
  const feeds = createFeedManager({ browser, fetchFn, now, logger: log, definitions: feedDefinitions });

  // Rebuild the lookup sets whenever the policy or the feeds change.
  function rebuildLists() {
    state.lists = buildLists(state.config, state.threatSet);
  }

  // ---- Storage helpers -----------------------------------------------------

  const readKey = async (area, key) => (await area.get(key))[key];

  // ---- Startup: load and validate the policy --------------------------------
  //
  // Order: a managed policy (installed by the admin as root) always wins. Only
  // when there is none are the settings saved from the settings page used.
  // An invalid policy of either kind means safe mode, never "no protection".

  function useConfig(config, source) {
    state.config = config;
    state.source = source;
    rebuildLists();
    state.safeMode = false;
    state.safeReason = "";
    log.info(`Policy loaded (${source}).`);
  }

  async function loadPolicy() {
    let managed;
    try {
      managed = await browser.storage.managed.get(null);
    } catch (error) {
      managed = undefined;
      log.warn("Managed policy could not be read:", error?.message ?? error);
    }

    if (managed && Object.keys(managed).length > 0) {
      const outcome = validatePolicy(managed);
      if (outcome.ok) useConfig(outcome.config, "managed");
      else enterSafeMode("invalid_policy", outcome.errors, "managed");
      return;
    }

    const local = await readKey(browser.storage.local, "localPolicy");
    if (local === undefined) {
      enterSafeMode("not_configured", ["No policy was found."], "none");
      return;
    }
    const outcome = validatePolicy(local);
    if (outcome.ok) useConfig(outcome.config, "local");
    else enterSafeMode("invalid_local_policy", outcome.errors, "local");
  }

  async function init() {
    await loadPolicy();
    await loadSavedFeeds();
    await applySeenSitesReset();
  }

  // Called after the settings page saves: use the new settings right away.
  async function applyLocalPolicy() {
    await loadPolicy();
    await loadSavedFeeds();
    await applySeenSitesReset();
    refreshFeeds().catch(() => {});
  }

  // Chrome: give the browser the current block/allow rules. Updates run one at a
  // time so two changes cannot interleave. If Chrome refuses the rules, the
  // navigation handler below still redirects blocked sites (dnrOk === false).
  let dnrChain = Promise.resolve();
  function syncBlockingRules() {
    if (!useDnr || !browser.declarativeNetRequest) return Promise.resolve();
    dnrChain = dnrChain.then(async () => {
      try {
        const rules = buildRules({ config: state.config, lists: state.lists, adSet: state.adSet });
        const existing = await browser.declarativeNetRequest.getDynamicRules();
        await browser.declarativeNetRequest.updateDynamicRules({
          removeRuleIds: existing.map((rule) => rule.id),
          addRules: rules,
        });
        state.dnrOk = true;
        state.dnrRuleCount = rules.length;
        state.adRuleIds = new Set(rules.filter((rule) => rule.priority === 1).map((rule) => rule.id));
      } catch (error) {
        state.dnrOk = false;
        log.error("Blocking rules were not accepted by the browser:", error?.message ?? error);
      }
    });
    return dnrChain;
  }

  // Saved feed copies are read at startup; downloading happens in refreshFeeds().
  async function loadSavedFeeds() {
    if (!state.config.feeds.enabled) {
      state.threatSet = new Set();
      state.adSet = new Set();
    } else {
      const sets = await feeds.load();
      state.threatSet = sets.threat;
      state.adSet = sets.ads;
    }
    rebuildLists();
    await syncBlockingRules();
  }

  // Download any feed that is due. Called at startup and by an hourly alarm.
  let refreshing = null;
  function refreshFeeds({ force = false } = {}) {
    // Startup, install and the alarm can all ask at once; a normal request joins the
    // run already in progress. A forced request ("Update now") waits for it, then
    // does its own real run.
    if (refreshing && !force) return refreshing;
    const previous = refreshing ?? Promise.resolve();
    const run = previous.catch(() => {}).then(async () => {
      await ready;
      const { enabled, refresh_hours: refreshHours } = state.config.feeds;
      const { changed, results } = await feeds.refresh({ enabled, refreshHours, force });
      if (changed || !enabled) await loadSavedFeeds();
      return { changed, results, status: feeds.status() };
    });
    refreshing = run;
    const clear = () => { if (refreshing === run) refreshing = null; };
    run.then(clear, clear);
    return run;
  }

  function enterSafeMode(reason, errors, source = "none") {
    state.config = structuredClone(STRICT_BASELINE);
    rebuildLists();
    state.safeMode = true;
    state.safeReason = reason;
    state.source = source;
    log.error(`Safe mode (${reason}):`, errors.slice(0, 10).join("; "));
  }

  // The admin can clear the "already seen" sites by changing the reset token.
  async function applySeenSitesReset() {
    const token = state.config.seen_sites_reset_token;
    const stored = await readKey(browser.storage.local, "seenResetToken");
    if (stored !== token) {
      await browser.storage.local.set({ seenHosts: [], seenResetToken: token });
      log.debug("Seen-sites list reset.");
    }
  }

  const ready = init().catch((error) => {
    enterSafeMode("startup_error", [String(error?.message ?? error)]);
  });

  // ---- Small shared helpers ------------------------------------------------

  const textValues = (extra = {}) => {
    const { name, phone } = state.config.admin;
    return {
      admin_name: name,
      admin_phone: phone,
      phone_part: phone ? ` at ${phone}` : "",
      ...extra,
    };
  };

  const say = (id, extra) => render(id, textValues(extra), state.config.ui.wording);

  // Send an admin alert, at most once a minute per event and domain.
  async function notify(eventType, details, { ignoreCooldown = false } = {}) {
    const key = `${eventType}|${details.domain}`;
    const last = lastAlertAt.get(key);
    if (!ignoreCooldown && last !== undefined && now() - last < ALERT_COOLDOWN_MS) {
      log.debug("Alert suppressed (cooldown):", eventType);
      return { ok: false, error: "cooldown" };
    }
    lastAlertAt.set(key, now());
    const outcome = await sendAlert(state.config, eventType, details, { fetchFn });
    if (!outcome.ok) log.warn("Alert not delivered:", eventType, outcome.error);
    return outcome;
  }

  const classifyHost = (host) => classify(host, state.lists, state.config);

  const interstitialUrl = (params) =>
    browser.runtime.getURL(`pages/interstitial.html?${new URLSearchParams(params)}`);

  // Only the extension's own pages may start or verify approvals.
  const isExtensionPage = (sender) =>
    typeof sender?.url === "string" && sender.url.startsWith(browser.runtime.getURL("pages/"));

  // The site the user is on: the tab's address, not a frame's (frames can be foreign).
  const isPopup = (sender) =>
    typeof sender?.url === "string" && sender.url.startsWith(browser.runtime.getURL("pages/popup.html"));

  const topHost = (sender) => hostFromUrl(sender?.tab?.url) ?? hostFromUrl(sender?.url);

  // Send a command to a tab (optionally one frame). A closed tab is not an error.
  async function sendToTab(tabId, message, options) {
    if (tabId === undefined || !browser.tabs?.sendMessage) return;
    try {
      await browser.tabs.sendMessage(tabId, message, options);
    } catch (error) {
      log.debug("Tab message not delivered:", message.type, error?.message ?? error);
    }
  }

  // ---- Approvals (a verified code or a finished wait unlocks one action on one domain) --

  async function hasApproval(action, domain) {
    const approval = await readKey(browser.storage.session, `approval:${action}:${domain}`);
    return Boolean(approval) && approval.until > now();
  }

  async function grantApproval(action, domain, tabId) {
    await browser.storage.session.set({ [`approval:${action}:${domain}`]: { until: now() + APPROVAL_MS } });
    await sendToTab(tabId, { type: "approval-granted", action });
    if (action === "download") await releaseHeldDownloads(domain);
  }

  // ---- Request blocking ----------------------------------------------------

  function rememberTopHost(tabId, host) {
    tabTopHost.delete(tabId);
    tabTopHost.set(tabId, host);
    if (tabTopHost.size > MAX_TRACKED_TABS) tabTopHost.delete(tabTopHost.keys().next().value);
  }

  const forgetTab = (tabId) => {
    tabTopHost.delete(tabId);
    tabScam.delete(tabId);
    tabAds.delete(tabId);
  };

  // A new page in a tab: forget what we knew about the old one.
  function startPage(tabId) {
    tabScam.delete(tabId);
    tabAds.delete(tabId);
    browser.storage.session.remove(`tabScam:${tabId}`).catch(() => {});
    setBadge(tabId, null);
  }

  // ---- Counters shown in the toolbar popup (numbers only, saved on this computer) --
  let statsChain = Promise.resolve();
  function bump(name) {
    statsChain = statsChain.then(async () => {
      try {
        const saved = (await readKey(browser.storage.local, "stats")) ?? { since: now() };
        saved[name] = (saved[name] ?? 0) + 1;
        await browser.storage.local.set({ stats: saved });
      } catch (error) {
        log.debug("Counter not saved:", error?.message ?? error);
      }
    });
    return statsChain;
  }

  // Red "!" on the toolbar icon while a tab shows something dangerous.
  async function setBadge(tabId, level) {
    const action = browser.action ?? browser.browserAction;
    if (!action?.setBadgeText || tabId === undefined || tabId < 0) return;
    try {
      await action.setBadgeText({ tabId, text: level === "danger" ? "!" : "" });
      if (level === "danger" && action.setBadgeBackgroundColor) {
        await action.setBadgeBackgroundColor({ tabId, color: "#d92d20" });
      }
    } catch {
      // The tab may already be gone.
    }
  }

  // One listener sees every request.
  //   - A blacklisted site (admin list or malware feed) is replaced by the blocked page.
  //   - Requests to blacklisted hosts, and to ad hosts, are dropped quietly.
  //   - Hosts the admin trusts (whitelist, banks) are never touched, and ads
  //     are left alone on trusted pages so a bank or shop keeps working.
  async function handleBeforeRequest(details) {
    await ready;
    if (details.tabId < 0) return {}; // the browser's or the extension's own traffic
    const host = hostFromUrl(details.url);
    if (!host) return {};
    const decision = classifyHost(host);

    if (details.type === "main_frame") {
      rememberTopHost(details.tabId, host);
      startPage(details.tabId);
      if (decision.tier !== "blacklist") return {};
      log.debug("Blocked main-frame navigation:", host, decision.reason);
      bump("sites_blocked");
      setBadge(details.tabId, "danger");
      notify("blocked_site", { domain: host });
      return { redirectUrl: interstitialUrl({ mode: "blocked", host }) };
    }

    if (decision.tier === "whitelist") return {};
    if (decision.tier === "blacklist") return { cancel: true };

    if (state.adSet.size > 0 && findMatch(host, state.adSet)) {
      const top = tabTopHost.get(details.tabId) ?? hostFromUrl(details.documentUrl ?? details.originUrl);
      if (top && classifyHost(top).tier === "whitelist") return {};
      tabAds.set(details.tabId, (tabAds.get(details.tabId) ?? 0) + 1);
      return { cancel: true };
    }
    return {};
  }

  // Chrome: called for every top-level navigation. Chrome's own rules already
  // redirect blocked sites; this tells the admin, and acts as a backstop if the
  // rules could not be installed.
  async function handleNavigation(details) {
    await ready;
    if (!details || details.frameId !== 0 || details.tabId < 0) return;
    const host = hostFromUrl(details.url);
    if (!host) return;
    startPage(details.tabId);
    const decision = classifyHost(host);
    if (decision.tier !== "blacklist") return;
    bump("sites_blocked");
    setBadge(details.tabId, "danger");
    notify("blocked_site", { domain: host });
    if (state.dnrOk === false) {
      await attempt("redirect", () => browser.tabs.update(details.tabId, { url: interstitialUrl({ mode: "blocked", host }) }));
    }
  }

  // ---- Downloads -------------------------------------------------------------

  const readHeld = async () => (await readKey(browser.storage.session, "heldDownloads")) ?? [];

  // Every change to the held list goes through here, one at a time, so two
  // downloads starting together cannot overwrite each other's entry.
  let heldLock = Promise.resolve();
  function updateHeld(mutate) {
    const run = heldLock.then(async () => {
      const list = await readHeld();
      const result = await mutate(list);
      await browser.storage.session.set({ heldDownloads: list });
      return result;
    });
    heldLock = run.catch(() => {});
    return run;
  }

  // Host a download comes from. blob: addresses are judged by the page that made them.
  function downloadHost(url) {
    const direct = hostFromUrl(url);
    if (direct) return direct;
    try {
      if (String(url).startsWith("blob:")) return hostFromUrl(new URL(url).origin);
    } catch { /* not a usable address */ }
    return null;
  }

  async function attempt(label, fn) {
    try {
      await fn();
      return true;
    } catch (error) {
      log.debug(`Download step failed (${label}):`, error?.message ?? error);
      return false;
    }
  }

  // Stop a download and delete whatever reached the disk.
  async function destroyDownload(id) {
    await attempt("cancel", () => browser.downloads.cancel(id));
    await attempt("removeFile", () => browser.downloads.removeFile(id));
    await attempt("erase", () => browser.downloads.erase({ id }));
  }

  // Open one explanation tab per domain, not one per file.
  async function openDownloadTab(params, key) {
    const last = lastDownloadTabAt.get(key);
    if (last !== undefined && now() - last < DOWNLOAD_TAB_COOLDOWN_MS) return;
    lastDownloadTabAt.set(key, now());
    await attempt("open tab", () => browser.tabs.create({ url: interstitialUrl(params), active: true }));
  }

  // The strictest of: where the file is, where it finally came from after any
  // redirects, and which page sent you. A download with no usable web address
  // gets its own one-off name, so approving it unlocks nothing else.
  function judgeDownload(item) {
    const hosts = [downloadHost(item.url), downloadHost(item.finalUrl), hostFromUrl(item.referrer)].filter(Boolean);
    let best = { tier: "graylist", host: null };
    let rank = 0;
    for (const host of hosts) {
      const tier = classifyHost(host).tier;
      if (STRICTNESS[tier] > rank) {
        rank = STRICTNESS[tier];
        best = { tier, host };
      }
    }
    const domain = best.host && isValidDomain(best.host) ? best.host : `unknown-${item.id}.invalid`;
    return { tier: best.tier, domain };
  }

  async function handleDownloadCreated(item) {
    await ready;
    if (!item || item.id === undefined) return;

    const { tier, domain } = judgeDownload(item);
    const filename = basename(item.filename) || basename(nameFromUrl(item.url)) || "a file";

    let mode = state.config.tiers[tier].download;
    if (tier === "blacklist") mode = "block"; // a blocked source never delivers files
    else if (state.config.hold_all_downloads && mode !== "block") mode = "hold_all";
    // Remote-control programs are the scammer's favourite tool: always ask the admin first.
    else if (tier !== "whitelist" && mode !== "block" && REMOTE_TOOLS.test(`${filename} ${nameFromUrl(item.finalUrl)} ${nameFromUrl(item.url)}`)) {
      mode = "hold_all";
    }

    if (mode === "allow") return;
    // Chrome often reports no file name yet, so fall back to the name in the address.
    const knownName = item.filename || nameFromUrl(item.finalUrl) || nameFromUrl(item.url);
    if (mode === "hold_risky" && !isRiskyDownload({ filename: knownName, mime: item.mime }).risky) return;

    if (mode === "block") {
      log.debug("Download blocked:", domain);
      await destroyDownload(item.id);
      bump("downloads_blocked");
      notify("download_blocked", { domain, filename }, { ignoreCooldown: true });
      await openDownloadTab({ mode: "download-blocked", domain }, `blocked|${domain}`);
      return;
    }

    // hold_risky (risky file) or hold_all: wait for the admin's code.
    if (await hasApproval("download", domain)) return;
    log.debug("Download held:", domain);
    await holdDownload(item, domain, filename);
    bump("downloads_held");
    // Every held file is announced, so the admin knows what a code will release.
    notify("download_held", { domain, filename }, { ignoreCooldown: true });
    await openDownloadTab({ mode: "pin", action: "download", domain }, `pin|${domain}`);
  }

  // Pause when possible. If a pause is not possible, delete the partial file and
  // download it again once the admin approves.
  async function holdDownload(item, domain, filename) {
    const paused = await attempt("pause", () => browser.downloads.pause(item.id));
    if (!paused) await destroyDownload(item.id);
    const saveName = lastSegment(item.filename) || nameFromUrl(item.url) || "download";
    await updateHeld((list) => {
      list.push({
        id: item.id, url: item.url, filename, saveName: saveName.slice(0, 200),
        domain, method: paused ? "pause" : "redownload", heldAt: now(),
      });
    });
  }

  // A held download must stay held: re-pause if resumed, delete if it finished anyway.
  async function handleDownloadChanged(delta) {
    await ready;
    if (!delta || delta.id === undefined) return;
    const todo = await updateHeld((list) => {
      const entry = list.find((candidate) => candidate.id === delta.id && candidate.method === "pause");
      if (!entry) return null;
      if (delta.state?.current === "complete") {
        entry.method = "redownload";
        return "delete";
      }
      return delta.paused?.current === false ? "pause" : null;
    });
    if (todo === "delete") await destroyDownload(delta.id);
    else if (todo === "pause") await attempt("re-pause", () => browser.downloads.pause(delta.id));
  }

  // The admin approved this domain: let its held downloads go. Entries that have
  // waited too long are deleted instead, so an old item is not freed by a new approval.
  async function releaseHeldDownloads(domain) {
    const mine = await updateHeld((list) => {
      const taken = list.filter((entry) => entry.domain === domain);
      for (const entry of taken) list.splice(list.indexOf(entry), 1);
      return taken;
    });

    for (const entry of mine) {
      if (now() - entry.heldAt > HELD_MAX_AGE_MS) {
        await destroyDownload(entry.id);
        continue;
      }
      if (entry.method === "pause") {
        const resumed = await attempt("resume", () => browser.downloads.resume(entry.id));
        if (resumed) continue;
      }
      // Approval is on record, so the new download passes the check above.
      await attempt("redownload", () => browser.downloads.download({ url: entry.url, filename: entry.saveName }));
    }
  }

  // ---- Browser-only settings page ---------------------------------------------

  const options = createOptionsApi({
    browser,
    now,
    validatePolicy,
    log,
    getView: () => ({ source: state.source, safeMode: state.safeMode, safeReason: state.safeReason }),
    applyLocalPolicy,
    sendTestAlert: () => sendAlert(state.config, "test_alert", { domain: "" }, { fetchFn }),
    getFeedInfo: () => {
      const status = feeds.status();
      return {
        enabled: state.config.feeds.enabled,
        feeds: feedDefinitions.map((definition) => ({
          id: definition.id,
          label: definition.label,
          category: definition.category,
          ...status[definition.id],
        })),
      };
    },
    refreshFeedsNow: () => refreshFeeds({ force: true }),
    checkSite: (input) => {
      let host;
      try {
        const text = String(input ?? "").trim();
        host = hostFromUrl(text.includes("://") ? text : `http://${text}`);
      } catch { host = null; }
      if (!host) return null;
      const decision = classifyHost(host);
      return {
        host,
        tier: decision.tier,
        reason: decision.reason,
        matched: decision.matched,
        ads: state.adSet.size > 0 && Boolean(findMatch(host, state.adSet)),
      };
    },
  });

  // ---- Messages from content scripts and the full-screen page --------------

  async function handleMessage(message, sender) {
    await ready;
    if (!message || typeof message.type !== "string") return undefined;
    if (message.type.startsWith("options-")) return options.handle(message, sender);

    switch (message.type) {
      case "page-loaded":
        return handlePageLoaded(sender);
      case "ask-admin":
        return handleAskAdmin(sender);
      case "detector-init":
        return handleDetectorInit(sender);
      case "card-detected":
        return handleDetection("card", message, sender);
      case "password-field":
        return handleDetection("password", message, sender);
      case "delay-complete":
        return handleDelayComplete(message, sender);
      case "scam-signals":
        return handleScamSignals(message, sender);
      case "scam-dismissed":
        return handleScamDismissed(sender);
      case "popup-state":
        return isPopup(sender) ? handlePopupState(message) : undefined;
      case "popup-panic":
        return isPopup(sender) ? handlePanic(message) : undefined;
      case "popup-ask":
        return isPopup(sender) ? handlePopupAsk(message) : undefined;
      case "get-interstitial":
        return isExtensionPage(sender) ? handleGetInterstitial(message) : undefined;
      case "request-pin":
        return isExtensionPage(sender) ? handleRequestPin(message) : undefined;
      case "verify-pin":
        return isExtensionPage(sender) ? handleVerifyPin(message, sender) : undefined;
      case "check-approval":
        return isExtensionPage(sender)
          ? { approved: await hasApproval(message.action, message.domain) }
          : undefined;
      default:
        return undefined;
    }
  }

  const noticeBanner = (text) => ({
    kind: "notice",
    text,
    textScale: state.config.ui.text_scale,
    buttons: [{ id: "dismiss", label: say("btn_got_it") }],
  });

  // The content script asks, once per top-level page, whether to show a banner.
  async function handlePageLoaded(sender) {
    if (sender?.frameId !== undefined && sender.frameId !== 0) return { banner: null };
    const host = hostFromUrl(sender?.url);
    if (!host) return { banner: null };
    const textScale = state.config.ui.text_scale;

    if (state.safeMode) {
      return {
        banner: {
          kind: "safe_mode",
          text: say("safe_mode"),
          textScale,
          buttons: [{ id: "dismiss", label: say("btn_got_it") }],
        },
      };
    }

    const decision = classifyHost(host);
    const notice = state.config.new_site_notice;
    if (decision.tier !== "graylist" || notice === "off") return { banner: null };

    if (notice === "once") {
      const seen = (await readKey(browser.storage.local, "seenHosts")) ?? [];
      if (seen.includes(host)) return { banner: null };
      await browser.storage.local.set({ seenHosts: [...seen, host].slice(-MAX_SEEN_HOSTS) });
    }

    return {
      banner: {
        kind: "new_site",
        text: say("new_site"),
        textScale,
        buttons: [
          { id: "dismiss", label: say("btn_got_it") },
          { id: "ask", label: say("btn_ask_admin"), sentLabel: say("btn_ask_sent"), failedLabel: say("btn_ask_failed") },
        ],
      },
    };
  }

  async function handleAskAdmin(sender) {
    const host = hostFromUrl(sender?.url);
    if (!host) return { ok: false };
    const outcome = await notify("heads_up", { domain: host });
    // A repeated tap inside the cooldown counts as sent: the admin already has it.
    return { ok: outcome.ok || outcome.error === "cooldown" };
  }

  // ---- Detections: card entry and password prompts ---------------------------

  // Tells a frame what is worth watching for, so quiet pages cost nothing.
  async function handleDetectorInit(sender) {
    const host = topHost(sender);
    if (!host) return { watch: { card: false, password: false } };
    const decision = classifyHost(host);
    const tier = state.config.tiers[decision.tier];
    const signals = state.config.password_signals;

    const watchCard = tier.card !== "off" && !(await hasApproval("card", host));
    const watchBank = decision.pinPerLogin && !(await hasApproval("bank", host));
    const anySignal = Object.values(signals).some(Boolean);
    const watchPassword = watchBank || (tier.password !== "off" && anySignal && !(await hasApproval("password", host)));

    return {
      watch: { card: watchCard, password: watchPassword },
      urgency: signals.urgency === true,
      cardFallback: state.config.card_fallback,
    };
  }

  // Which of the enabled password signals fire for this page?
  function passwordSignals(host, decision, facts) {
    const enabled = state.config.password_signals;
    const fired = [];
    if (enabled.non_whitelisted && decision.tier !== "whitelist") fired.push("non_whitelisted");
    if (enabled.lookalike && decision.tier !== "whitelist") {
      const trusted = [...state.config.lists.whitelist, ...state.config.lists.bank_domains];
      if (lookalikeOf(host, trusted)) fired.push("lookalike");
    }
    if (enabled.http && facts.protocol === "http:" && host !== "localhost") fired.push("http");
    if (enabled.popup_iframe && (facts.crossOriginFrame === true || facts.hasOpener === true)) fired.push("popup_iframe");
    if (enabled.urgency && facts.urgent === true) fired.push("urgency");
    return fired;
  }

  // Turn a detection into a reaction at the right severity level.
  async function handleDetection(kind, message, sender) {
    const none = { lock: false };
    const host = topHost(sender);
    if (!host) return none;
    const decision = classifyHost(host);
    const facts = message.facts && typeof message.facts === "object" ? message.facts : {};

    let action = kind;
    let level;
    let signals = [];

    if (kind === "card") {
      level = state.config.tiers[decision.tier].card;
    } else if (decision.pinPerLogin) {
      // Bank login with "approve every login": always needs the admin's code.
      action = "bank";
      level = "block";
      signals = ["bank_login"];
    } else {
      signals = passwordSignals(host, decision, facts);
      level = signals.length > 0 ? state.config.tiers[decision.tier].password : "off";
    }

    if (level === "off" || (await hasApproval(action, host))) return none;
    log.debug("Detection:", action, "level", level, "on", host);
    bump(kind === "card" ? "card_warnings" : "password_warnings");

    const tabId = sender.tab?.id;
    const alertEvent = { card: "card_entry", password: "password_prompt", bank: "bank_login" }[action];
    const alertDetails = { domain: host, action, signals };
    const lock = { lock: level === "delay" || level === "block", fields: kind };

    if (level === "reminder" || level === "warn") {
      const bannerId = `${kind}_${level}`;
      await sendToTab(tabId, { type: "show-banner", banner: noticeBanner(say(bannerId)) }, { frameId: 0 });
      if (level === "warn") notify(alertEvent, alertDetails);
      return none;
    }

    notify(alertEvent, alertDetails);
    const extra = { domain: host, action_label: ACTION_LABELS[action] };
    const textScale = state.config.ui.text_scale;

    if (level === "delay") {
      await browser.storage.session.set({ [`delayStart:${action}:${host}`]: now() });
      await sendToTab(tabId, {
        type: "show-overlay",
        overlay: {
          mode: "delay",
          action,
          textScale,
          admin: state.config.admin,
          seconds: state.config.delay_seconds,
          title: say("delay_title", extra),
          body: say("delay_body", extra),
          countdownText: say("delay_countdown", { seconds: "{seconds}" }),
          continueLabel: say("btn_delay_continue"),
          backLabel: say("btn_back"),
        },
      }, { frameId: 0 });
    } else {
      await sendToTab(tabId, {
        type: "show-overlay",
        overlay: {
          mode: "pin",
          action,
          textScale,
          backLabel: say("btn_back"),
          src: interstitialUrl({ mode: "pin", action, domain: host }),
        },
      }, { frameId: 0 });
    }
    return lock;
  }

  // The wait is over: believe it only if enough real time has passed.
  async function handleDelayComplete(message, sender) {
    const action = message.action;
    const host = topHost(sender);
    if ((action !== "card" && action !== "password") || !host) return { ok: false };

    const key = `delayStart:${action}:${host}`;
    const startedAt = await readKey(browser.storage.session, key);
    const waitMs = state.config.delay_seconds * 1000;
    if (startedAt === undefined || now() - startedAt < waitMs - DELAY_TOLERANCE_MS) return { ok: false };

    await browser.storage.session.remove(key);
    await grantApproval(action, host, sender.tab?.id);
    return { ok: true };
  }


  // ---- Scam pages ---------------------------------------------------------------

  const SCAM_KNOWN = new Set(["tech_support", "gift_card", "crypto_wire", "remote_tool", "government", "prize", "urgency", "phone_number"]);

  // The page-reading script reports only the NAMES of the signs it found.
  async function handleScamSignals(message, sender) {
    const host = topHost(sender);
    const tabId = sender?.tab?.id;
    if (!host || tabId === undefined || sender.frameId !== 0 || state.config.scam_detection === false) return { ok: false };
    if (classifyHost(host).tier === "whitelist") return { ok: false }; // trusted sites and banks are left alone

    const signals = (Array.isArray(message.signals) ? message.signals : [])
      .filter((id) => SCAM_KNOWN.has(id)).slice(0, 8);
    if (signals.length === 0) return { ok: false };
    // Do not trust the page's own score: it needs at least one real scam sign, not just urgency or a phone number.
    const strong = signals.filter((id) => id !== "urgency" && id !== "phone_number");
    if (strong.length === 0) return { ok: false };

    const dismissed = (await readKey(browser.storage.session, `scamOk:${host}`)) ?? 0;
    if (dismissed > now()) return { ok: false };

    tabScam.set(tabId, { host, signals });
    // Chrome stops the background worker when idle; keep this so the popup still knows.
    browser.storage.session.set({ [`tabScam:${tabId}`]: { host, signals } }).catch(() => {});
    setBadge(tabId, "danger");
    bump("scam_pages");
    notify("scam_page", { domain: host, signals });

    const textScale = state.config.ui.text_scale;
    await sendToTab(tabId, {
      type: "show-overlay",
      overlay: {
        mode: "scam",
        action: "scam",
        textScale,
        admin: state.config.admin,
        seconds: Math.max(state.config.delay_seconds, 15),
        reasons: signals.map((id) => say(`scam_reason.${id}`)),
        title: say("scam_title"),
        body: say("scam_body"),
        countdownText: say("scam_countdown", { seconds: "{seconds}" }),
        continueLabel: say("btn_scam_continue"),
        backLabel: say("btn_back"),
      },
    }, { frameId: 0 });
    return { ok: true };
  }

  // After the wait, the user may look at the page anyway (remembered for 30 minutes).
  async function handleScamDismissed(sender) {
    const host = topHost(sender);
    if (!host || sender?.frameId !== 0) return { ok: false };
    await browser.storage.session.set({ [`scamOk:${host}`]: now() + 30 * 60_000 });
    tabScam.delete(sender.tab?.id);
    browser.storage.session.remove(`tabScam:${sender.tab?.id}`).catch(() => {});
    setBadge(sender.tab?.id, null);
    return { ok: true };
  }

  // ---- Toolbar popup --------------------------------------------------------------

  async function adsBlockedOn(tabId) {
    if (!useDnr) return tabAds.get(tabId) ?? 0;
    try {
      // Chrome-only call; only reached when useDnr is true (Firefox never gets here).
      const matched = await browser.declarativeNetRequest["getMatchedRules"]({ tabId });
      return matched.rulesMatchedInfo.filter((entry) => state.adRuleIds.has(entry.rule.ruleId)).length;
    } catch {
      return 0;
    }
  }

  async function handlePopupState(message) {
    const tabId = Number.isInteger(message.tabId) ? message.tabId : undefined;
    const url = typeof message.url === "string" ? message.url : "";
    const stats = (await readKey(browser.storage.local, "stats")) ?? {};
    const host = /^https?:/i.test(url) ? hostFromUrl(url) : null;
    const isInternal = url.startsWith(browser.runtime.getURL("pages/interstitial.html"));

    let level = "neutral";
    let title = say("popup_neutral");
    let why = say("popup_neutral_why");
    let reasons = [];

    const scam = tabId === undefined ? undefined
      : (tabScam.get(tabId) ?? (await readKey(browser.storage.session, `tabScam:${tabId}`)) ?? undefined);
    if (state.safeMode) {
      level = "careful"; title = say("popup_safemode"); why = say("popup_safemode_why");
    }
    if (isInternal) {
      level = "danger"; title = say("popup_danger"); why = say("popup_danger_blocked");
    } else if (host) {
      const decision = classifyHost(host);
      if (decision.tier === "blacklist") {
        level = "danger"; title = say("popup_danger"); why = say("popup_danger_blocked");
      } else if (scam && scam.host === host) {
        level = "danger"; title = say("popup_danger"); why = say("popup_danger_scam");
        reasons = scam.signals.map((id) => say(`scam_reason.${id}`));
      } else if (decision.tier === "whitelist") {
        level = "safe"; title = say("popup_safe"); why = say("popup_safe_why");
      } else if (url.startsWith("http:")) {
        level = "careful"; title = say("popup_careful"); why = say("popup_careful_http");
      } else {
        level = "careful"; title = say("popup_careful"); why = say("popup_careful_why");
      }
    }

    return {
      level, title, why, reasons, host,
      ads: tabId !== undefined && host ? await adsBlockedOn(tabId) : 0,
      stats: {
        sites_blocked: stats.sites_blocked ?? 0,
        downloads_held: (stats.downloads_held ?? 0) + (stats.downloads_blocked ?? 0),
        warnings: (stats.card_warnings ?? 0) + (stats.password_warnings ?? 0),
        scam_pages: stats.scam_pages ?? 0,
      },
      admin: state.config.admin,
      textScale: state.config.ui.text_scale,
      texts: Object.fromEntries(
        ["btn_panic", "panic_title", "panic_step_1", "panic_step_2", "panic_step_3", "panic_step_4", "panic_step_5", "btn_ask_admin", "btn_ask_sent", "btn_ask_failed"]
          .map((id) => [id, say(id)]),
      ),
    };
  }

  // "I think I'm being scammed": tell the admin at once, whatever the cooldown.
  async function handlePanic(message) {
    const url = typeof message.url === "string" ? message.url : "";
    const host = (/^https?:/i.test(url) ? hostFromUrl(url) : null) ?? "an unknown page";
    bump("panics");
    const outcome = await notify("panic", { domain: host }, { ignoreCooldown: true });
    return { ok: outcome.ok === true, text: say(outcome.ok ? "panic_sent" : "panic_not_sent") };
  }

  async function handlePopupAsk(message) {
    const url = typeof message.url === "string" ? message.url : "";
    const host = /^https?:/i.test(url) ? hostFromUrl(url) : null;
    if (!host) return { ok: false };
    const outcome = await notify("heads_up", { domain: host });
    return { ok: outcome.ok || outcome.error === "cooldown" };
  }

  // ---- Full-screen page: approval codes -----------------------------------------

  // Everything the full-screen page needs to draw itself, already worded.
  function handleGetInterstitial(message) {
    const domain = String(message.domain ?? message.host ?? "");
    const action = ACTIONS.includes(message.action) ? message.action : "site";
    const extra = { domain, action_label: ACTION_LABELS[action] };
    const ids = [
      "blocked_title", "blocked_body", "btn_back", "pin_title", "pin_body",
      "btn_send_code", "pin_sent", "pin_label", "btn_submit", "pin_ok", "btn_continue",
      "dl_blocked_title", "dl_blocked_body",
    ];
    return {
      texts: Object.fromEntries(ids.map((id) => [id, say(id, extra)])),
      textScale: state.config.ui.text_scale,
      admin: state.config.admin,
      pinDigits: 6,
    };
  }

  async function handleRequestPin(message) {
    const { action, domain } = message;
    if (!ACTIONS.includes(action) || !isValidDomain(domain)) return { ok: false, error: "bad_request" };

    const key = `${action}|${domain}`;
    const last = lastPinRequestAt.get(key);
    if (last !== undefined && now() - last < PIN_REQUEST_COOLDOWN_MS) {
      return { ok: false, error: "too_soon", text: say("pin_too_soon") };
    }
    lastPinRequestAt.set(key, now());

    const { challenge, pin } = await createChallenge({
      action,
      domain,
      ttlMs: state.config.pin.ttl_minutes * 60_000,
      maxAttempts: state.config.pin.max_attempts,
      now: now(),
    });
    const storageKey = `challenge:${action}:${domain}`;
    await browser.storage.session.set({ [storageKey]: challenge });

    // The code goes straight to the admin. If it cannot be delivered, discard
    // it, so a code nobody received can never be guessed into use.
    const outcome = await sendAlert(state.config, "pin_request", { domain, action, pin }, { fetchFn });
    if (!outcome.ok) {
      await browser.storage.session.remove(storageKey);
      log.warn("Approval code not delivered:", outcome.error);
      return { ok: false, error: "unreachable", text: say("pin_unreachable") };
    }
    log.debug("Approval code sent for", action, domain);
    return { ok: true, text: say("pin_sent") };
  }

  async function handleVerifyPin(message, sender) {
    const { action, domain, pin } = message;
    if (!ACTIONS.includes(action) || !isValidDomain(domain)) return { result: "bad_request" };

    const storageKey = `challenge:${action}:${domain}`;
    const challenge = await readKey(browser.storage.session, storageKey);
    if (!challenge) return { result: "none", text: say("pin_none") };

    const outcome = await verifyChallenge(challenge, pin, { action, domain, now: now() });
    await browser.storage.session.set({ [storageKey]: outcome.challenge });

    if (outcome.result === "ok") {
      await grantApproval(action, domain, sender?.tab?.id);
      return { result: "ok", text: say(action === "download" ? "pin_ok_download" : "pin_ok") };
    }
    if (outcome.result === "locked" && challenge.status !== "locked") {
      notify("pin_failures", { domain, action });
    }

    const textIds = {
      wrong: "pin_wrong", locked: "pin_locked", expired: "pin_expired",
      used: "pin_used", bad_format: "pin_bad_format", mismatch: "pin_none",
    };
    return {
      result: outcome.result,
      attemptsLeft: outcome.attemptsLeft,
      text: say(textIds[outcome.result] ?? "pin_none", { attempts_left: outcome.attemptsLeft }),
    };
  }

  return {
    ready,
    handleBeforeRequest,
    handleNavigation,
    handleDownloadCreated,
    handleDownloadChanged,
    refreshFeeds,
    forgetTab,
    handleMessage,
    hasApproval,
    classifyHost,
    getState: () => ({
      safeMode: state.safeMode,
      safeReason: state.safeReason,
      source: state.source,
      dnrOk: state.dnrOk,
      dnrRuleCount: state.dnrRuleCount,
      config: state.config,
      feeds: feeds.status(),
      threatCount: state.threatSet.size,
      adCount: state.adSet.size,
    }),
  };
}
