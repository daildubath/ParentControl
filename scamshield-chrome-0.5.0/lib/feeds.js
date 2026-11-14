// Public blocklist feeds: what they are, how to read them, and how to refuse
// a bad download. A feed can only ever ADD blocked domains; the decision
// order in decision.js guarantees it can never block a site the admin trusts.
//
// Two categories:
//   threat - malware/phishing domains. Blocks opening the site AND its requests.
//   ads    - ad/tracker/malvertising domains. Blocks requests only, so a page
//            that merely embeds one still opens.
//
// Feed notes (checked at build time, 2026-11):
//   - Phishing Army: plain domain-per-line list. The page states no extra
//     license restriction on its own feeds and tells users to review upstream
//     sources. Could NOT be downloaded from the build sandbox, so its exact
//     file format is unconfirmed; the parser below is deliberately tolerant
//     and the validator rejects anything that does not look right.
//   - StevenBlack unified hosts: hosts-file format, MIT-licensed project.
//     Downloaded and inspected at build time (~77k domains, ~2.3 MB).
//   - URLhaus hostfile: NOT used. It now requires a free abuse.ch Auth-Key.
//     Adding it later means supporting a request header here.

import { isValidDomain } from "./domains.js";
import { TWO_PART_SUFFIXES } from "./lookalike.js";

export const FEED_DEFINITIONS = Object.freeze([
  {
    id: "phishing_army",
    label: "Phishing Army",
    url: "https://phishing.army/download/phishing-army-domains.txt",
    format: "domains",
    category: "threat",
    minEntries: 500,
    maxBytes: 10_000_000,
  },
  {
    id: "stevenblack",
    label: "StevenBlack unified hosts",
    url: "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts",
    format: "hosts",
    category: "ads",
    minEntries: 10_000,
    maxBytes: 10_000_000,
  },
]);

export const MAX_ENTRIES = 400_000;
const MIN_FRACTION_OF_PREVIOUS = 0.5;

// Never blocked, even if a feed lists them: sites a family member needs for
// ordinary life and the services this extension itself depends on.
export const NEVER_BLOCK = Object.freeze([
  "mozilla.org", "mozilla.com", "mozilla.net", "firefox.com",
  "ntfy.sh", "github.com", "githubusercontent.com",
  "google.com", "gstatic.com", "microsoft.com", "live.com", "apple.com",
  "amazon.com", "wikipedia.org", "gov", "localhost",
]);
const NEVER_BLOCK_SET = new Set(NEVER_BLOCK);

function isProtected(domain) {
  // A bare public suffix such as co.uk would block every site under it.
  if (TWO_PART_SUFFIXES.has(domain)) return true;
  const labels = domain.split(".");
  for (let start = 0; start < labels.length; start += 1) {
    if (NEVER_BLOCK_SET.has(labels.slice(start).join("."))) return true;
  }
  return false;
}

// Turn feed text into a Set of valid, lowercase domains. Lines that do not
// parse are skipped and counted, never trusted.
export function parseFeed(text, format) {
  const domains = new Set();
  let skipped = 0;

  for (const rawLine of String(text).split(/\r?\n/)) {
    const line = rawLine.replace(/#.*$/, "").trim().toLowerCase();
    if (line === "") continue;

    let candidate;
    if (format === "hosts") {
      const parts = line.split(/\s+/);
      if (parts.length < 2 || !["0.0.0.0", "127.0.0.1"].includes(parts[0])) {
        skipped += 1;
        continue;
      }
      candidate = parts[1];
    } else if (format === "domains") {
      candidate = line;
    } else {
      throw new Error(`Unknown feed format: ${format}`);
    }

    if (!isValidDomain(candidate) || isProtected(candidate)) {
      skipped += 1;
      continue;
    }
    domains.add(candidate);
  }
  return { domains, skipped };
}

// Decide whether a freshly parsed feed is safe to use.
// Returns { ok: true } or { ok: false, reason }.
export function validateFeed({ definition, byteLength, entryCount, previousCount = 0 }) {
  if (byteLength > definition.maxBytes) return { ok: false, reason: "too_big" };
  if (entryCount < definition.minEntries) return { ok: false, reason: "too_few_entries" };
  if (entryCount > MAX_ENTRIES) return { ok: false, reason: "too_many_entries" };
  if (previousCount > 0 && entryCount < previousCount * MIN_FRACTION_OF_PREVIOUS) {
    return { ok: false, reason: "shrank_too_much" };
  }
  return { ok: true };
}
