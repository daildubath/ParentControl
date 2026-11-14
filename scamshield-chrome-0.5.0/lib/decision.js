// Decides which tier a host belongs to.
//
// Order (first match wins):
//   1. admin whitelist
//   2. admin blacklist
//   3. admin-verified bank (unless bank_policy is "off")
//   4. admin graylist
//   5. public feed blacklist
//   6. everything else is graylist
// Admin entries therefore always beat feed data, and a bad feed entry can
// never block a site the admin trusts.

import { findMatch } from "./domains.js";

export function buildLists(config, feedDomains = new Set()) {
  return {
    whitelist: new Set(config.lists.whitelist),
    graylist: new Set(config.lists.graylist),
    blacklist: new Set(config.lists.blacklist),
    banks: new Set(config.lists.bank_domains),
    feed: feedDomains,
  };
}

// Returns { tier, reason, matched, bank, pinPerLogin }.
export function classify(host, lists, config) {
  let matched = findMatch(host, lists.whitelist);
  if (matched) {
    return { tier: "whitelist", reason: "admin_whitelist", matched, bank: false, pinPerLogin: false };
  }

  matched = findMatch(host, lists.blacklist);
  if (matched) {
    return { tier: "blacklist", reason: "admin_blacklist", matched, bank: false, pinPerLogin: false };
  }

  if (config.bank_policy !== "off") {
    matched = findMatch(host, lists.banks);
    if (matched) {
      return {
        tier: "whitelist",
        reason: "bank",
        matched,
        bank: true,
        pinPerLogin: config.bank_policy === "approve_every",
      };
    }
  }

  matched = findMatch(host, lists.graylist);
  if (matched) {
    return { tier: "graylist", reason: "admin_graylist", matched, bank: false, pinPerLogin: false };
  }

  matched = findMatch(host, lists.feed);
  if (matched) {
    return { tier: "blacklist", reason: "feed_blacklist", matched, bank: false, pinPerLogin: false };
  }

  return { tier: "graylist", reason: "unlisted", matched: null, bank: false, pinPerLogin: false };
}
