// Host name helpers. An entry in a domain list matches that domain and all of
// its subdomains, never a bare top-level domain.

export const DOMAIN_PATTERN = /^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z0-9-]{2,}$/;
const IPV4_PATTERN = /^\d{1,3}(\.\d{1,3}){3}$/;

export function isValidDomain(value) {
  return typeof value === "string" && value.length <= 253 && DOMAIN_PATTERN.test(value);
}

export function normalizeHost(hostname) {
  return String(hostname).toLowerCase().replace(/\.$/, "");
}

// Host of an http(s) URL, or null for anything else (extension pages, about:, data:).
export function hostFromUrl(url) {
  try {
    const parsed = new URL(url);
    if (parsed.protocol !== "http:" && parsed.protocol !== "https:") {
      return null;
    }
    return normalizeHost(parsed.hostname);
  } catch {
    return null;
  }
}

// IP addresses (v4, or v6 in brackets/with colons) only ever match exactly.
export function isIpHost(host) {
  return IPV4_PATTERN.test(host) || host.includes(":");
}

// "a.b.example.com" -> "a.b.example.com", "b.example.com", "example.com"
export function* hostSuffixes(host) {
  if (isIpHost(host)) {
    yield host;
    return;
  }
  const labels = host.split(".");
  for (let start = 0; start < labels.length - 1; start += 1) {
    yield labels.slice(start).join(".");
  }
}

// Returns the list entry that matched, or null.
export function findMatch(host, domainSet) {
  for (const candidate of hostSuffixes(host)) {
    if (domainSet.has(candidate)) {
      return candidate;
    }
  }
  return null;
}
