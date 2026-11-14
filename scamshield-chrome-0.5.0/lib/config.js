// Policy validation and the strict built-in baseline.
//
// The policy arrives through browser.storage.managed (written by the
// controller into policies.json). It is validated here against the same rules
// as policy.schema.json (schema version 1). Anything invalid means the
// extension runs on the strict baseline ("safe mode") instead of unprotected.

import { isValidDomain } from "./domains.js";

export const SCHEMA_VERSION = 1;
export const LEVELS = ["off", "reminder", "warn", "delay", "block"];
export const DOWNLOAD_MODES = ["allow", "hold_risky", "block"];
export const TIER_NAMES = ["whitelist", "graylist", "blacklist"];

const TOPIC_PATTERN = /^[A-Za-z0-9_-]{20,64}$/;
const TOKEN_PATTERN = /^tk_[A-Za-z0-9]{10,64}$/;
const SERVER_PATTERN = /^https:\/\/[A-Za-z0-9.-]+(:[0-9]{1,5})?$/;
const PHONE_PATTERN = /^[0-9+().\- ]{3,32}$/;
const WORDING_KEY_PATTERN = /^[a-z0-9_.]{1,64}$/;

// Used when the policy is missing or invalid. Everything unknown is graylist,
// and the graylist is as strict as the schema allows without an admin contact.
export const STRICT_BASELINE = Object.freeze({
  schema_version: SCHEMA_VERSION,
  admin: { name: "your helper", phone: "" },
  notifier: null,
  severity_preset: "custom",
  tiers: {
    whitelist: { card: "reminder", password: "off", download: "allow" },
    graylist: { card: "block", password: "block", download: "hold_risky" },
    blacklist: { card: "block", password: "block", download: "block" },
  },
  lists: { whitelist: [], graylist: [], blacklist: [], bank_domains: [] },
  bank_policy: "off",
  hold_all_downloads: false,
  password_signals: {
    non_whitelisted: true,
    lookalike: true,
    http: true,
    popup_iframe: true,
    urgency: false,
  },
  new_site_notice: "once",
  ui: { text_scale: 1.5, wording: {} },
  feeds: { enabled: true, refresh_hours: 24 },
  pin: { ttl_minutes: 5, max_attempts: 3 },
  verbose_logging: false,
  delay_seconds: 45,
  card_fallback: true,
  scam_detection: true,
  seen_sites_reset_token: "",
});

const TOP_LEVEL_KEYS = new Set([
  "schema_version", "admin", "notifier", "severity_preset", "tiers", "lists",
  "bank_policy", "hold_all_downloads", "password_signals", "new_site_notice",
  "ui", "feeds", "pin", "verbose_logging", "delay_seconds", "card_fallback",
  "scam_detection", "seen_sites_reset_token",
]);

const isObject = (value) => value !== null && typeof value === "object" && !Array.isArray(value);

// Small checker that collects error messages instead of throwing.
function makeChecker() {
  const errors = [];
  const fail = (path, message) => errors.push(`${path}: ${message}`);

  const checkKeys = (value, path, allowed, required = []) => {
    if (!isObject(value)) {
      fail(path, "must be an object");
      return false;
    }
    for (const key of Object.keys(value)) {
      if (!allowed.includes(key)) fail(`${path}.${key}`, "unknown property");
    }
    for (const key of required) {
      if (!(key in value)) fail(path, `missing required property '${key}'`);
    }
    return true;
  };

  const checkEnum = (value, path, options) => {
    if (!options.includes(value)) fail(path, `must be one of ${options.join(", ")}`);
  };

  const checkBoolean = (value, path) => {
    if (typeof value !== "boolean") fail(path, "must be true or false");
  };

  const checkInteger = (value, path, min, max) => {
    if (!Number.isInteger(value) || value < min || value > max) {
      fail(path, `must be a whole number from ${min} to ${max}`);
    }
  };

  const checkDomainList = (value, path) => {
    if (!Array.isArray(value)) {
      fail(path, "must be a list of domains");
      return;
    }
    if (value.length > 5000) fail(path, "has more than 5000 entries");
    if (new Set(value).size !== value.length) fail(path, "has duplicate entries");
    value.forEach((entry, index) => {
      if (!isValidDomain(entry)) fail(`${path}[${index}]`, "is not a valid lowercase domain");
    });
  };

  return { errors, fail, checkKeys, checkEnum, checkBoolean, checkInteger, checkDomainList };
}

// Returns { ok: true, config } with defaults filled in, or { ok: false, errors }.
export function validatePolicy(raw) {
  const c = makeChecker();

  if (!isObject(raw)) {
    return { ok: false, errors: ["policy: must be an object"] };
  }
  for (const key of Object.keys(raw)) {
    if (!TOP_LEVEL_KEYS.has(key)) c.fail(key, "unknown property");
  }
  for (const key of ["schema_version", "admin", "notifier", "tiers", "lists"]) {
    if (!(key in raw)) c.fail("policy", `missing required property '${key}'`);
  }
  if ("schema_version" in raw && raw.schema_version !== SCHEMA_VERSION) {
    c.fail("schema_version", `must be ${SCHEMA_VERSION}`);
  }

  if ("admin" in raw && c.checkKeys(raw.admin, "admin", ["name", "phone"], ["name", "phone"])) {
    const { name, phone } = raw.admin;
    if (typeof name !== "string" || name.length < 1 || name.length > 60) {
      c.fail("admin.name", "must be 1 to 60 characters");
    }
    if (typeof phone !== "string" || !PHONE_PATTERN.test(phone)) {
      c.fail("admin.phone", "must be a phone number (digits and + ( ) . - space)");
    }
  }

  if ("notifier" in raw && c.checkKeys(raw.notifier, "notifier", ["provider", "server", "topic", "token"], ["provider", "server", "topic"])) {
    const { provider, server, topic, token } = raw.notifier;
    if (token !== undefined && (typeof token !== "string" || !TOKEN_PATTERN.test(token))) {
      c.fail("notifier.token", "must be an ntfy access token (tk_ followed by letters and digits)");
    }
    c.checkEnum(provider, "notifier.provider", ["ntfy"]);
    if (typeof server !== "string" || !SERVER_PATTERN.test(server)) {
      c.fail("notifier.server", "must be an https:// server address");
    }
    if (typeof topic !== "string" || !TOPIC_PATTERN.test(topic)) {
      c.fail("notifier.topic", "must be 20 to 64 letters, digits, _ or -");
    }
  }

  if ("severity_preset" in raw) {
    c.checkEnum(raw.severity_preset, "severity_preset", ["gentle", "standard", "strict", "custom"]);
  }

  if ("tiers" in raw && c.checkKeys(raw.tiers, "tiers", TIER_NAMES, TIER_NAMES)) {
    for (const tierName of TIER_NAMES) {
      const tier = raw.tiers[tierName];
      const path = `tiers.${tierName}`;
      if (tier !== undefined && c.checkKeys(tier, path, ["card", "password", "download"], ["card", "password", "download"])) {
        c.checkEnum(tier.card, `${path}.card`, LEVELS);
        c.checkEnum(tier.password, `${path}.password`, LEVELS);
        c.checkEnum(tier.download, `${path}.download`, DOWNLOAD_MODES);
      }
    }
  }

  if ("lists" in raw) {
    const listNames = ["whitelist", "graylist", "blacklist", "bank_domains"];
    if (c.checkKeys(raw.lists, "lists", listNames, listNames)) {
      for (const listName of listNames) {
        if (listName in raw.lists) c.checkDomainList(raw.lists[listName], `lists.${listName}`);
      }
    }
  }

  if ("bank_policy" in raw) c.checkEnum(raw.bank_policy, "bank_policy", ["approve_once", "approve_every", "off"]);
  if ("hold_all_downloads" in raw) c.checkBoolean(raw.hold_all_downloads, "hold_all_downloads");
  if ("verbose_logging" in raw) c.checkBoolean(raw.verbose_logging, "verbose_logging");
  if ("new_site_notice" in raw) c.checkEnum(raw.new_site_notice, "new_site_notice", ["off", "once", "every_visit"]);

  if ("delay_seconds" in raw) c.checkInteger(raw.delay_seconds, "delay_seconds", 5, 300);
  if ("card_fallback" in raw) c.checkBoolean(raw.card_fallback, "card_fallback");
  if ("scam_detection" in raw) c.checkBoolean(raw.scam_detection, "scam_detection");

  if ("seen_sites_reset_token" in raw) {
    const token = raw.seen_sites_reset_token;
    if (typeof token !== "string" || token.length > 64) {
      c.fail("seen_sites_reset_token", "must be text of at most 64 characters");
    }
  }

  if ("password_signals" in raw) {
    const signalNames = ["non_whitelisted", "lookalike", "http", "popup_iframe", "urgency"];
    if (c.checkKeys(raw.password_signals, "password_signals", signalNames)) {
      for (const [name, value] of Object.entries(raw.password_signals)) {
        c.checkBoolean(value, `password_signals.${name}`);
      }
    }
  }

  if ("ui" in raw && c.checkKeys(raw.ui, "ui", ["text_scale", "wording"])) {
    const { text_scale: scale, wording } = raw.ui;
    if (scale !== undefined && (typeof scale !== "number" || scale < 1 || scale > 3)) {
      c.fail("ui.text_scale", "must be a number from 1 to 3");
    }
    if (wording !== undefined) {
      if (!isObject(wording) || Object.keys(wording).length > 60) {
        c.fail("ui.wording", "must be an object with at most 60 entries");
      } else {
        for (const [key, text] of Object.entries(wording)) {
          if (!WORDING_KEY_PATTERN.test(key)) c.fail(`ui.wording.${key}`, "invalid message id");
          if (typeof text !== "string" || text.length > 300) {
            c.fail(`ui.wording.${key}`, "must be text of at most 300 characters");
          }
        }
      }
    }
  }

  if ("feeds" in raw && c.checkKeys(raw.feeds, "feeds", ["enabled", "refresh_hours"])) {
    if ("enabled" in raw.feeds) c.checkBoolean(raw.feeds.enabled, "feeds.enabled");
    if ("refresh_hours" in raw.feeds) c.checkInteger(raw.feeds.refresh_hours, "feeds.refresh_hours", 1, 168);
  }

  if ("pin" in raw && c.checkKeys(raw.pin, "pin", ["ttl_minutes", "max_attempts"])) {
    if ("ttl_minutes" in raw.pin) c.checkInteger(raw.pin.ttl_minutes, "pin.ttl_minutes", 1, 30);
    if ("max_attempts" in raw.pin) c.checkInteger(raw.pin.max_attempts, "pin.max_attempts", 1, 10);
  }

  if (c.errors.length > 0) {
    return { ok: false, errors: c.errors };
  }

  // Valid: fill in defaults for optional values.
  const defaults = structuredClone(STRICT_BASELINE);
  const config = {
    ...defaults,
    ...raw,
    bank_policy: raw.bank_policy ?? "approve_once",
    severity_preset: raw.severity_preset ?? "standard",
    password_signals: { ...defaults.password_signals, ...raw.password_signals },
    ui: { ...defaults.ui, ...raw.ui },
    feeds: { ...defaults.feeds, ...raw.feeds },
    pin: { ...defaults.pin, ...raw.pin },
  };
  return { ok: true, config };
}
