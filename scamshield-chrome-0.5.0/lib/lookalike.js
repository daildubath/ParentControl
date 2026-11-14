// Lookalike-domain check: does this host imitate a domain the admin trusts?
//
// Catches character swaps (paypa1.com, rnybank.com), typos, lookalike letters
// from other alphabets (via punycode), and trusted names stuffed into another
// domain (chase-secure-login.com, mybank.example.evil.net).
//
// Limitation: there is no public-suffix list here. A short built-in list of
// common two-part endings (co.uk, com.au, ...) approximates "registrable
// domain". Unusual endings may be misjudged; the other password signals still
// apply either way.

import { isIpHost } from "./domains.js";

export const TWO_PART_SUFFIXES = new Set([
  "co.uk", "org.uk", "ac.uk", "gov.uk", "com.au", "net.au", "org.au", "co.nz",
  "co.jp", "ne.jp", "com.br", "com.mx", "co.in", "co.za", "com.cn", "com.tr",
  "com.sg", "com.hk", "com.ar", "co.kr",
]);

// Letters from other alphabets that look like Latin ones.
const HOMOGLYPHS = {
  "а": "a", "е": "e", "о": "o", "р": "p", "с": "c", "х": "x", "у": "y", "і": "i", "ѕ": "s", "ј": "j", "һ": "h",
  "ο": "o", "ν": "v", "ρ": "p", "α": "a", "ι": "i", "κ": "k", "τ": "t",
};

// Standard punycode decoder (RFC 3492), so xn-- labels can be compared by sight.
function decodePunycode(input) {
  const base = 36, tMin = 1, tMax = 26, skew = 38, damp = 700;
  const output = [];
  const basicEnd = input.lastIndexOf("-");
  for (let i = 0; i < Math.max(basicEnd, 0); i += 1) output.push(input.charCodeAt(i));

  const adapt = (delta, count, first) => {
    let k = 0;
    delta = first ? Math.floor(delta / damp) : delta >> 1;
    delta += Math.floor(delta / count);
    for (; delta > ((base - tMin) * tMax) >> 1; k += base) delta = Math.floor(delta / (base - tMin));
    return Math.floor(k + ((base - tMin + 1) * delta) / (delta + skew));
  };
  const digit = (code) => (code >= 48 && code < 58 ? code - 22 : code >= 65 && code < 91 ? code - 65 : code >= 97 && code < 123 ? code - 97 : base);

  let n = 128, bias = 72, i = 0;
  for (let index = basicEnd > 0 ? basicEnd + 1 : 0; index < input.length;) {
    const oldI = i;
    for (let w = 1, k = base; ; k += base) {
      if (index >= input.length) throw new RangeError("bad punycode");
      const d = digit(input.charCodeAt(index++));
      if (d >= base) throw new RangeError("bad punycode");
      i += d * w;
      const t = k <= bias ? tMin : k >= bias + tMax ? tMax : k - bias;
      if (d < t) break;
      w *= base - t;
    }
    bias = adapt(i - oldI, output.length + 1, oldI === 0);
    n += Math.floor(i / (output.length + 1));
    i %= output.length + 1;
    output.splice(i++, 0, n);
  }
  return String.fromCodePoint(...output);
}

// A label as people see it: punycode decoded.
function visibleLabel(label) {
  if (!label.startsWith("xn--")) return label;
  try {
    return decodePunycode(label.slice(4));
  } catch {
    return label;
  }
}

// Reduce a label to a comparable "skeleton": common look-alike swaps undone.
export function skeleton(label) {
  let text = visibleLabel(label).toLowerCase();
  text = Array.from(text, (char) => HOMOGLYPHS[char] ?? char).join("");
  text = text.replace(/rn/g, "m").replace(/vv/g, "w").replace(/cl/g, "d");
  text = text.replace(/[0]/g, "o").replace(/[1|]/g, "l").replace(/3/g, "e").replace(/5/g, "s").replace(/@/g, "a");
  return text.replace(/-/g, "");
}

// "a.b.example.co.uk" -> { name: "example", registrable: "example.co.uk" }
export function registrable(host) {
  const labels = host.split(".");
  const lastTwo = labels.slice(-2).join(".");
  const keep = TWO_PART_SUFFIXES.has(lastTwo) ? 3 : 2;
  const parts = labels.slice(-keep);
  return { name: parts[0], registrable: parts.join("."), labels };
}

function editDistanceAtMostOne(a, b) {
  if (Math.abs(a.length - b.length) > 1) return false;
  let i = 0, j = 0, edits = 0;
  while (i < a.length && j < b.length) {
    if (a[i] === b[j]) {
      i += 1; j += 1;
    } else {
      edits += 1;
      if (edits > 1) return false;
      if (a.length > b.length) i += 1;
      else if (a.length < b.length) j += 1;
      else { i += 1; j += 1; }
    }
  }
  return edits + (a.length - i) + (b.length - j) <= 1;
}

// Returns the trusted domain that `host` imitates, or null.
export function lookalikeOf(host, trustedDomains) {
  if (isIpHost(host)) return null;
  const subject = registrable(host);

  for (const trusted of trustedDomains) {
    const target = registrable(trusted);
    if (subject.registrable === target.registrable) continue; // the real site or its subdomain

    const wanted = skeleton(target.name);
    if (wanted.length < 4) continue; // too short to judge fairly
    const seen = skeleton(subject.name);

    if (seen === wanted) return trusted;
    if (wanted.length >= 5 && editDistanceAtMostOne(seen, wanted)) return trusted;

    // The trusted name used as a word inside another domain name.
    const words = subject.labels
      .flatMap((label) => visibleLabel(label).split("-"))
      .map((word) => skeleton(word));
    if (words.includes(wanted)) return trusted;
  }
  return null;
}
