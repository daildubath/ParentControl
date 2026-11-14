// Downloads, checks and caches the public blocklist feeds.
//
// Rules this file follows:
//   - Each feed is independent: one failing never affects another.
//   - A new download replaces the saved copy only if it passes validation.
//     Otherwise the last good copy keeps working ("last-good-copy").
//   - A failed attempt is retried after an hour, not on every wake-up.
//   - Feeds are fetched over https with no cookies or credentials.

import { FEED_DEFINITIONS, parseFeed, validateFeed } from "../lib/feeds.js";

const FETCH_TIMEOUT_MS = 45_000;
const RETRY_AFTER_FAILURE_MS = 60 * 60_000;
const storageKey = (id) => `feed:${id}`;

export function createFeedManager({
  browser,
  fetchFn,
  now = () => Date.now(),
  logger,
  definitions = FEED_DEFINITIONS,
}) {
  // id -> { domains: Set, count, fetchedAt, lastAttemptAt, lastError }
  const feeds = new Map();

  const emptySets = () => ({ threat: new Set(), ads: new Set() });

  // Merge every loaded feed into one Set per category.
  function currentSets() {
    const sets = emptySets();
    for (const definition of definitions) {
      const feed = feeds.get(definition.id);
      if (!feed?.domains) continue;
      for (const domain of feed.domains) sets[definition.category].add(domain);
    }
    return sets;
  }

  // Read the saved copies. Nothing is downloaded here.
  async function load() {
    feeds.clear();
    for (const definition of definitions) {
      try {
        const saved = (await browser.storage.local.get(storageKey(definition.id)))[storageKey(definition.id)];
        if (!saved || typeof saved.domains !== "string") continue;
        feeds.set(definition.id, {
          domains: new Set(saved.domains.split("\n").filter(Boolean)),
          count: saved.count ?? 0,
          fetchedAt: saved.fetchedAt ?? 0,
          lastAttemptAt: saved.lastAttemptAt ?? 0,
          lastError: saved.lastError ?? "",
        });
      } catch (error) {
        logger.warn(`Saved feed ${definition.id} could not be read:`, error?.message ?? error);
      }
    }
    return currentSets();
  }

  async function save(definition) {
    const feed = feeds.get(definition.id);
    await browser.storage.local.set({
      [storageKey(definition.id)]: {
        domains: [...feed.domains].join("\n"),
        count: feed.count,
        fetchedAt: feed.fetchedAt,
        lastAttemptAt: feed.lastAttemptAt,
        lastError: feed.lastError,
      },
    });
  }

  async function download(definition) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), FETCH_TIMEOUT_MS);
    try {
      const response = await fetchFn(definition.url, {
        method: "GET",
        credentials: "omit",
        cache: "no-store",
        redirect: "follow",
        signal: controller.signal,
      });
      if (!response.ok) return { error: `http_${response.status}` };
      if (response.url && !String(response.url).startsWith("https://")) return { error: "insecure_redirect" };
      const declared = Number(response.headers?.get?.("content-length") ?? 0);
      if (declared > definition.maxBytes) return { error: "too_big" };
      return { text: await response.text() };
    } catch (error) {
      return { error: error?.name === "AbortError" ? "timeout" : "unreachable" };
    } finally {
      clearTimeout(timer);
    }
  }

  // Refresh one feed if it is due. Returns a short status word.
  async function refreshOne(definition, { refreshHours, force }) {
    const previous = feeds.get(definition.id);
    const age = previous ? now() - previous.fetchedAt : Infinity;
    if (!force && previous && age < refreshHours * 3_600_000) return "fresh";
    if (!force && previous?.lastError && now() - previous.lastAttemptAt < RETRY_AFTER_FAILURE_MS) return "waiting_to_retry";
    if (!force && !previous && feeds.get(`attempt:${definition.id}`)?.lastAttemptAt > now() - RETRY_AFTER_FAILURE_MS) {
      return "waiting_to_retry";
    }

    const attemptAt = now();
    const fail = async (reason) => {
      logger.warn(`Feed ${definition.id} not updated (${reason}); keeping the last good copy.`);
      if (previous) {
        previous.lastAttemptAt = attemptAt;
        previous.lastError = reason;
        await save(definition);
      } else {
        // Remember the failed attempt so we do not retry on every wake-up.
        feeds.set(`attempt:${definition.id}`, { lastAttemptAt: attemptAt, lastError: reason });
      }
      return `failed:${reason}`;
    };

    const result = await download(definition);
    if (result.error) return fail(result.error);

    let parsed;
    try {
      parsed = parseFeed(result.text, definition.format);
    } catch {
      return fail("unreadable");
    }
    const verdict = validateFeed({
      definition,
      byteLength: result.text.length,
      entryCount: parsed.domains.size,
      previousCount: previous?.count ?? 0,
    });
    if (!verdict.ok) return fail(verdict.reason);

    feeds.delete(`attempt:${definition.id}`);
    feeds.set(definition.id, {
      domains: parsed.domains,
      count: parsed.domains.size,
      fetchedAt: attemptAt,
      lastAttemptAt: attemptAt,
      lastError: "",
    });
    await save(definition);
    logger.info(`Feed ${definition.id} updated: ${parsed.domains.size} domains.`);
    return "updated";
  }

  // Refresh every due feed. Returns { changed, results }.
  async function refresh({ enabled, refreshHours, force = false }) {
    if (!enabled) return { changed: await clear(), results: {} };
    const results = {};
    let changed = false;
    for (const definition of definitions) {
      try {
        results[definition.id] = await refreshOne(definition, { refreshHours, force });
      } catch (error) {
        logger.warn(`Feed ${definition.id} failed unexpectedly:`, error?.message ?? error);
        results[definition.id] = "failed:error";
      }
      if (results[definition.id] === "updated") changed = true;
    }
    return { changed, results };
  }

  // Feeds switched off: forget the saved copies. True if anything was removed.
  async function clear() {
    const had = [...feeds.keys()].some((key) => !key.startsWith("attempt:"));
    feeds.clear();
    await browser.storage.local.remove(definitions.map((definition) => storageKey(definition.id)));
    return had;
  }

  function status() {
    return Object.fromEntries(definitions.map((definition) => {
      const feed = feeds.get(definition.id);
      const attempt = feeds.get(`attempt:${definition.id}`); // a failed first download
      return [definition.id, feed
        ? { count: feed.count, fetchedAt: feed.fetchedAt, lastError: feed.lastError }
        : { count: 0, fetchedAt: 0, lastError: attempt?.lastError ?? "not_loaded" }];
    }));
  }

  return { load, refresh, clear, currentSets, status };
}
