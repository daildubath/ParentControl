// One-time approval codes.
//
// A challenge is tied to one action on one domain. Only a salted hash of the
// code is stored; the code itself goes to the admin and nowhere else. A code
// expires, works once, and locks after too many wrong attempts.

const encoder = new TextEncoder();

const toHex = (bytes) => Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");

// Uniform 6-digit code (rejection sampling avoids modulo bias).
export function randomPin() {
  const limit = 4294967296 - (4294967296 % 1000000);
  const buffer = new Uint32Array(1);
  for (;;) {
    crypto.getRandomValues(buffer);
    if (buffer[0] < limit) {
      return String(buffer[0] % 1000000).padStart(6, "0");
    }
  }
}

async function hashPin(pin, salt, action, domain) {
  const data = encoder.encode(`${salt}|${action}|${domain}|${pin}`);
  return toHex(new Uint8Array(await crypto.subtle.digest("SHA-256", data)));
}

// Compare two equal-length hex strings without stopping at the first difference.
function constantTimeEqual(a, b) {
  if (a.length !== b.length) return false;
  let difference = 0;
  for (let index = 0; index < a.length; index += 1) {
    difference |= a.charCodeAt(index) ^ b.charCodeAt(index);
  }
  return difference === 0;
}

// Returns { challenge, pin }. Store the challenge; send the pin to the admin.
export async function createChallenge({ action, domain, ttlMs, maxAttempts, now }) {
  const pin = randomPin();
  const saltBytes = new Uint8Array(16);
  crypto.getRandomValues(saltBytes);
  const salt = toHex(saltBytes);
  return {
    pin,
    challenge: {
      action,
      domain,
      salt,
      hash: await hashPin(pin, salt, action, domain),
      expiresAt: now + ttlMs,
      attemptsLeft: maxAttempts,
      status: "pending",
    },
  };
}

// Returns { result, challenge, attemptsLeft } where result is one of:
// ok, wrong, locked, expired, used, mismatch, bad_format.
// The returned challenge is the updated record to store.
export async function verifyChallenge(challenge, pinInput, { action, domain, now }) {
  const unchanged = (result) => ({ result, challenge, attemptsLeft: challenge.attemptsLeft });

  if (challenge.action !== action || challenge.domain !== domain) return unchanged("mismatch");
  if (challenge.status === "used") return unchanged("used");
  if (challenge.status === "locked") return unchanged("locked");
  if (now > challenge.expiresAt) {
    return { result: "expired", challenge: { ...challenge, status: "expired" }, attemptsLeft: 0 };
  }
  if (challenge.status !== "pending") return unchanged(challenge.status);
  if (typeof pinInput !== "string" || !/^\d{6}$/.test(pinInput)) return unchanged("bad_format");

  const candidate = await hashPin(pinInput, challenge.salt, action, domain);
  if (constantTimeEqual(candidate, challenge.hash)) {
    return { result: "ok", challenge: { ...challenge, status: "used" }, attemptsLeft: challenge.attemptsLeft };
  }

  const attemptsLeft = challenge.attemptsLeft - 1;
  const status = attemptsLeft <= 0 ? "locked" : "pending";
  return {
    result: attemptsLeft <= 0 ? "locked" : "wrong",
    challenge: { ...challenge, attemptsLeft: Math.max(attemptsLeft, 0), status },
    attemptsLeft: Math.max(attemptsLeft, 0),
  };
}
