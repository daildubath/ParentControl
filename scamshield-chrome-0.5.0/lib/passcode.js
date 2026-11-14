// The admin passcode that guards the settings page when no managed policy is
// installed. Only a salted, slow hash is stored (PBKDF2-SHA-256).

export const MIN_PASSCODE_LENGTH = 8;
const DEFAULT_ITERATIONS = 200_000;
const encoder = new TextEncoder();

const toHex = (bytes) => [...bytes].map((byte) => byte.toString(16).padStart(2, "0")).join("");
const fromHex = (hex) => Uint8Array.from(hex.match(/../g) ?? [], (pair) => Number.parseInt(pair, 16));

async function derive(passcode, salt, iterations) {
  const key = await crypto.subtle.importKey("raw", encoder.encode(passcode), "PBKDF2", false, ["deriveBits"]);
  const bits = await crypto.subtle.deriveBits({ name: "PBKDF2", hash: "SHA-256", salt, iterations }, key, 256);
  return new Uint8Array(bits);
}

// Returns a message describing what is wrong with a passcode, or null if it is fine.
export function passcodeProblem(passcode) {
  if (typeof passcode !== "string" || passcode.length < MIN_PASSCODE_LENGTH) {
    return `The passcode must be at least ${MIN_PASSCODE_LENGTH} characters.`;
  }
  if (passcode.length > 200) return "The passcode is too long.";
  return null;
}

export async function createPasscodeRecord(passcode, { iterations = DEFAULT_ITERATIONS } = {}) {
  const salt = crypto.getRandomValues(new Uint8Array(16));
  const hash = await derive(passcode, salt, iterations);
  return { salt: toHex(salt), hash: toHex(hash), iterations };
}

// Compares without stopping at the first difference.
export async function checkPasscode(record, passcode) {
  if (!record || typeof passcode !== "string" || passcode.length > 200) return false;
  const expected = fromHex(record.hash);
  const actual = await derive(passcode, fromHex(record.salt), record.iterations);
  if (expected.length !== actual.length) return false;
  let difference = 0;
  for (let i = 0; i < expected.length; i += 1) difference |= expected[i] ^ actual[i];
  return difference === 0;
}
