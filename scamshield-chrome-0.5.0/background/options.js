// Browser-only mode: the settings page's brain. It is used only when no managed
// policy is installed (the controller decides that). Settings are stored in the
// browser and guarded by an admin passcode. Everything here answers messages
// from pages/options.html and nothing else.
//
// Storage:
//   local   adminPasscode  { salt, hash, iterations }
//   local   passcodeGuard  { failures, lockedUntil }
//   local   localPolicy    the saved policy object (same format as the managed policy)
//   session optionsUnlockedUntil  time the settings were unlocked until

import { createPasscodeRecord, checkPasscode, passcodeProblem } from "../lib/passcode.js";

const UNLOCK_MS = 10 * 60_000;
const FAILURES_PER_LOCK = 5;
const BASE_LOCK_MS = 5 * 60_000;
const MAX_LOCK_MS = 60 * 60_000;

// Severity presets offered by the page. Changing any value afterwards makes it "custom".
export const SEVERITY_PRESETS = Object.freeze({
  gentle: {
    whitelist: { card: "off", password: "off", download: "allow" },
    graylist: { card: "reminder", password: "reminder", download: "allow" },
    blacklist: { card: "block", password: "block", download: "block" },
  },
  standard: {
    whitelist: { card: "reminder", password: "off", download: "allow" },
    graylist: { card: "delay", password: "warn", download: "hold_risky" },
    blacklist: { card: "block", password: "block", download: "block" },
  },
  strict: {
    whitelist: { card: "reminder", password: "off", download: "allow" },
    graylist: { card: "block", password: "block", download: "hold_risky" },
    blacklist: { card: "block", password: "block", download: "block" },
  },
});

// What the page starts from before anything has been saved.
export function starterPolicy() {
  return {
    schema_version: 1,
    admin: { name: "", phone: "" },
    notifier: { provider: "ntfy", server: "https://ntfy.sh", topic: "" },
    severity_preset: "standard",
    tiers: structuredClone(SEVERITY_PRESETS.standard),
    lists: { whitelist: [], graylist: [], blacklist: [], bank_domains: [] },
    bank_policy: "approve_once",
    hold_all_downloads: false,
  };
}

export function createOptionsApi({
  browser, now, validatePolicy, getView, applyLocalPolicy, sendTestAlert, log,
  getFeedInfo, refreshFeedsNow, checkSite,
}) {
  const OPTIONS_URL = () => browser.runtime.getURL("pages/options.html");
  const readKey = async (area, key) => (await area.get(key))[key];

  const isOptionsPage = (sender) => typeof sender?.url === "string" && sender.url.startsWith(OPTIONS_URL());

  async function unlockedUntil() {
    return (await readKey(browser.storage.session, "optionsUnlockedUntil")) ?? 0;
  }
  const isUnlocked = async () => (await unlockedUntil()) > now();

  // ---- passcode attempts are counted and slowed down ----

  async function lockedUntil() {
    const guard = (await readKey(browser.storage.local, "passcodeGuard")) ?? { failures: 0, lockedUntil: 0 };
    return guard.lockedUntil > now() ? guard.lockedUntil : 0;
  }

  async function recordFailure() {
    const guard = (await readKey(browser.storage.local, "passcodeGuard")) ?? { failures: 0, lockedUntil: 0 };
    guard.failures += 1;
    if (guard.failures % FAILURES_PER_LOCK === 0) {
      const rounds = guard.failures / FAILURES_PER_LOCK;
      guard.lockedUntil = now() + Math.min(BASE_LOCK_MS * 2 ** (rounds - 1), MAX_LOCK_MS);
    }
    await browser.storage.local.set({ passcodeGuard: guard });
    return guard;
  }

  const clearFailures = () => browser.storage.local.set({ passcodeGuard: { failures: 0, lockedUntil: 0 } });

  // Checks a passcode with the attempt limit. Returns { ok } or { ok:false, error, lockedUntil? }.
  async function verify(passcode) {
    const record = await readKey(browser.storage.local, "adminPasscode");
    if (!record) return { ok: false, error: "no_passcode" };
    const lock = await lockedUntil();
    if (lock) return { ok: false, error: "locked", lockedUntil: lock };
    if (await checkPasscode(record, passcode)) {
      await clearFailures();
      return { ok: true };
    }
    const guard = await recordFailure();
    return { ok: false, error: guard.lockedUntil > now() ? "locked" : "wrong", lockedUntil: guard.lockedUntil };
  }

  // ---- what the page is shown ----

  async function state() {
    const view = getView();
    const hasPasscode = Boolean(await readKey(browser.storage.local, "adminPasscode"));
    const unlocked = hasPasscode && (await isUnlocked());
    const reply = {
      source: view.source, // "managed", "local" or "none"
      safeMode: view.safeMode,
      safeReason: view.safeReason,
      hasPasscode,
      unlocked,
      lockedUntil: await lockedUntil(),
      presets: SEVERITY_PRESETS,
    };
    // Settings are shown only to someone who has unlocked them.
    if (unlocked && view.source !== "managed") {
      reply.policy = (await readKey(browser.storage.local, "localPolicy")) ?? starterPolicy();
    }
    return reply;
  }

  async function guardedByUnlock(action) {
    if (getView().source === "managed") return { ok: false, error: "managed_active" };
    if (!(await isUnlocked())) return { ok: false, error: "locked_settings" };
    return action();
  }

  // ---- message handlers ----

  async function setupPasscode({ passcode }) {
    if (getView().source === "managed") return { ok: false, error: "managed_active" };
    if (await readKey(browser.storage.local, "adminPasscode")) return { ok: false, error: "already_set" };
    const problem = passcodeProblem(passcode);
    if (problem) return { ok: false, error: "weak", text: problem };
    await browser.storage.local.set({ adminPasscode: await createPasscodeRecord(passcode) });
    await clearFailures();
    await browser.storage.session.set({ optionsUnlockedUntil: now() + UNLOCK_MS });
    log.info("Admin passcode created.");
    return { ok: true };
  }

  async function unlock({ passcode }) {
    if (getView().source === "managed") return { ok: false, error: "managed_active" };
    const outcome = await verify(passcode);
    if (outcome.ok) await browser.storage.session.set({ optionsUnlockedUntil: now() + UNLOCK_MS });
    return outcome;
  }

  async function lock() {
    await browser.storage.session.remove("optionsUnlockedUntil");
    return { ok: true };
  }

  async function changePasscode({ oldPasscode, newPasscode }) {
    if (getView().source === "managed") return { ok: false, error: "managed_active" };
    const problem = passcodeProblem(newPasscode);
    if (problem) return { ok: false, error: "weak", text: problem };
    const outcome = await verify(oldPasscode);
    if (!outcome.ok) return outcome;
    await browser.storage.local.set({ adminPasscode: await createPasscodeRecord(newPasscode) });
    return { ok: true };
  }

  const save = ({ policy }) => guardedByUnlock(async () => {
    const outcome = validatePolicy(policy);
    if (!outcome.ok) return { ok: false, error: "invalid", errors: outcome.errors.slice(0, 12) };
    if (/REPLACE_ME/.test(policy.notifier.topic)) {
      return { ok: false, error: "invalid", errors: ["notifier.topic: replace the placeholder with a real topic"] };
    }
    await browser.storage.local.set({ localPolicy: policy });
    await applyLocalPolicy();
    log.info("Local settings saved.");
    return { ok: true };
  });

  const testAlert = () => guardedByUnlock(async () => {
    const outcome = await sendTestAlert();
    return { ok: outcome.ok, error: outcome.error };
  });

  // Automatic blocklists: what was downloaded, update now, and "is this site blocked?".
  const feedsInfo = () => guardedByUnlock(async () => ({ ok: true, feeds: getFeedInfo() }));
  const feedsRefresh = () => guardedByUnlock(async () => {
    await refreshFeedsNow();
    return { ok: true, feeds: getFeedInfo() };
  });
  const siteCheck = ({ site }) => guardedByUnlock(async () => {
    const result = checkSite(site);
    return result ? { ok: true, ...result } : { ok: false, error: "bad_site" };
  });

  async function handle(message, sender) {
    if (!isOptionsPage(sender)) return undefined; // only the settings page may ask
    switch (message.type) {
      case "options-state": return state();
      case "options-setup-passcode": return setupPasscode(message);
      case "options-unlock": return unlock(message);
      case "options-lock": return lock();
      case "options-change-passcode": return changePasscode(message);
      case "options-save": return save(message);
      case "options-test-alert": return testAlert();
      case "options-feeds-info": return feedsInfo();
      case "options-feeds-refresh": return feedsRefresh();
      case "options-check-site": return siteCheck(message);
      default: return undefined;
    }
  }

  return { handle };
}
