// Turns ScamShield's lists into Chrome declarativeNetRequest rules.
//
// Chrome only allows blocking web requests from code (webRequestBlocking) for
// extensions installed by enterprise policy. A normally installed extension has
// to hand Chrome a set of rules instead, and Chrome applies them itself. This
// file builds those rules. It is pure (no browser calls), so it can be tested.
//
// Priorities, highest first (a higher priority rule wins):
//   3  allow     admin-trusted hosts (whitelist and banks): never touched
//   2  block     admin blacklist + malware/phishing feeds: every request;
//                a blocked site itself is redirected to the blocked page
//   1  block     ad and tracker hosts: not on trusted pages
//
// A domain in a rule also matches its subdomains, the same as ScamShield's lists.

import { classify } from "./decision.js";
import { isValidDomain } from "./domains.js";

export const DOMAINS_PER_RULE = 1000;

const ALL_TYPES = [
  "main_frame", "sub_frame", "stylesheet", "script", "image", "font", "object",
  "xmlhttprequest", "ping", "csp_report", "media", "websocket", "other",
];
const SUBRESOURCE_TYPES = ALL_TYPES.filter((type) => type !== "main_frame");

const clean = (domains) => [...new Set(domains)].filter(isValidDomain).sort();

function chunks(list, size) {
  const out = [];
  for (let i = 0; i < list.length; i += size) out.push(list.slice(i, i + size));
  return out;
}

// Returns an array of rules with ids 1, 2, 3 ... ready for updateDynamicRules.
export function buildRules({ config, lists, adSet, blockedPagePath = "/pages/interstitial.html?mode=blocked" }) {
  const trusted = clean([...lists.whitelist, ...(config.bank_policy === "off" ? [] : lists.banks)]);

  // Feed domains only count when ScamShield's own decision would block them
  // (an admin entry for the same domain always wins over the feed).
  const feedBlocked = [...lists.feed].filter((domain) => classify(domain, lists, config).tier === "blacklist");
  const blocked = clean([...lists.blacklist, ...feedBlocked]);
  const ads = clean([...adSet]);

  const rules = [];
  const add = (rule) => rules.push({ id: rules.length + 1, ...rule });

  for (const part of chunks(trusted, DOMAINS_PER_RULE)) {
    add({ priority: 3, action: { type: "allow" }, condition: { requestDomains: part, resourceTypes: ALL_TYPES } });
  }
  for (const part of chunks(blocked, DOMAINS_PER_RULE)) {
    add({ priority: 2, action: { type: "block" }, condition: { requestDomains: part, resourceTypes: SUBRESOURCE_TYPES } });
    add({
      priority: 2,
      action: { type: "redirect", redirect: { extensionPath: blockedPagePath } },
      condition: { requestDomains: part, resourceTypes: ["main_frame"] },
    });
  }
  for (const part of chunks(ads, DOMAINS_PER_RULE)) {
    const condition = { requestDomains: part, resourceTypes: SUBRESOURCE_TYPES };
    if (trusted.length > 0) condition.excludedInitiatorDomains = trusted;
    add({ priority: 1, action: { type: "block" }, condition });
  }
  return rules;
}
