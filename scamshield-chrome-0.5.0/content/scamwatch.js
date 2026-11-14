// Looks for the tell-tale signs of a scam page (fake virus alarms, gift-card or
// crypto payment demands, pushes to install remote-access tools). Everything
// is analysed here in the browser; the background script only ever receives the
// NAMES of the signs found, never the page text. Top frame only.

(() => {
  "use strict";

  globalThis.browser ??= globalThis.chrome; // Chromium has only `chrome`

  // id -> { weight, patterns }. A category counts once, however often it matches.
  const CATEGORIES = {
    tech_support: {
      weight: 3,
      patterns: [
        /your (computer|pc|device|system|mac|browser) (is|has been|may be|was) (infected|compromised|locked|blocked|hacked|damaged)/i,
        /(virus|malware|trojan|spyware)s? (has been |was |were )?(detected|found)/i,
        /(windows|microsoft|apple|mac|system) (defender |security )?(alert|warning|support)[^.]{0,40}(call|contact)/i,
        /(do not|don't|dont) (close|restart|shut ?down|turn off) (this|your)/i,
        /(call|contact|dial)[^.]{0,30}(toll[- ]?free|technician|certified|support (line|team|number))/i,
        /(remove|fix|clean|resolve)[^.\n]{0,25}(the |this |a )?(virus|malware|infection)/i,
        /(security|system) (breach|failure|error)[^.]{0,40}(call|contact)/i,
      ],
    },
    gift_card: {
      weight: 3,
      patterns: [
        /pay[^.\n]{0,50}\bwith\b[^.\n]{0,30}(gift ?cards?|itunes|google play|steam cards?|prepaid cards?)/i,
        /(must|need to|have to|required to|only accept|only way)[^.\n]{0,50}(buy|purchase|send)[^.\n]{0,40}(gift ?cards?|itunes|google play|steam cards?)/i,
        /(gift ?cards?|itunes|google play|steam cards?)[^.\n]{0,60}(read|scratch|tell|send|give)[^.\n]{0,30}(code|number|numbers|pin)/i,
      ],
    },
    crypto_wire: {
      weight: 2,
      patterns: [
        /(bitcoin|crypto(currency)?) (atm|machine|wallet)[^.\n]{0,60}(deposit|send|pay|transfer|scan)/i,
        /(wire (transfer|the money|funds)|western union|moneygram|zelle)[^.\n]{0,60}(immediately|now|today|urgent|fee|pay)/i,
        /(pay|send|transfer)[^.\n]{0,40}(in |with |using )?(bitcoin|btc|usdt|ethereum)/i,
      ],
    },
    remote_tool: {
      weight: 2,
      patterns: [
        /(download|install|open|run|launch|start)[^.\n]{0,40}(anydesk|teamviewer|ultraviewer|ammyy|rustdesk|supremo|screenconnect|splashtop|logmein|quick ?assist)/i,
        /(allow|give|grant)[^.\n]{0,30}(remote access|remote control|remote connection)/i,
        /(technician|agent|specialist)[^.\n]{0,40}(connect|access)[^.\n]{0,20}(your|to your) (computer|pc|device)/i,
      ],
    },
    government: {
      weight: 3,
      patterns: [
        /(irs|social security|medicare|customs|police|fbi|court)[^.\n]{0,60}(arrest|warrant|suspended|frozen|lawsuit|legal action|penalt)/i,
        /(your|the) (social security number|ssn)[^.\n]{0,40}(suspended|compromised|blocked|used)/i,
      ],
    },
    prize: {
      weight: 2,
      patterns: [
        /(you (have |'ve )?(won|been selected)|congratulations[!,.]? you)/i,
        /claim your (prize|reward|gift|refund)/i,
      ],
    },
    urgency: {
      weight: 1,
      patterns: [
        /(within|in the next) \d+ (minutes?|hours?)/i,
        /(act|respond|call) (now|immediately|right away)/i,
        /(do not|don't|dont) (tell|share|discuss)[^.\n]{0,40}(anyone|family|bank)/i,
        /(final|last) (warning|notice)/i,
      ],
    },
  };

  // Pages ABOUT scams (warnings, news reports) use the same words. Two or more
  // "this is about scams" cues and the page is treated as awareness material.
  const AWARENESS = [
    /\b(scam|scams|scammers?|fraudsters?|con artists?)\b/i,
    /\b(report (it|this|a scam|fraud|scams)|to report|how to (spot|avoid|protect|recognize)|protect yourself|beware|warning signs)\b/i,
    /\b(will never|never (ask|call|demand|request))\b/i,
    /\b(police|officials|authorities|investigators|according to)\b[^.]{0,20}\b(say|said|says|warn|warned)\b/i,
    /\b(lost|losing|victims?|victim of) (\$|about|over|nearly|thousands)/i,
  ];

  // A phone number is only a sign when something else looks wrong too.
  const PHONE = /(\+?1[\s.-]?)?\(?\b\d{3}\)?[\s.-]\d{3}[\s.-]\d{4}\b|\b1[\s-]?8(00|33|44|55|66|77|88)[\s-]?\d{3}[\s-]?\d{4}\b/;
  const THRESHOLD = 4;
  const MAX_TEXT = 20000;

  // Pure function: text in, { signals, score } out.
  function analyze(text) {
    const body = String(text ?? "").slice(0, MAX_TEXT);
    const signals = [];
    let score = 0;
    for (const [id, category] of Object.entries(CATEGORIES)) {
      if (category.patterns.some((pattern) => pattern.test(body))) {
        signals.push(id);
        score += category.weight;
      }
    }
    if (score > 0 && PHONE.test(body)) {
      signals.push("phone_number");
      score += 1;
    }
    if (score > 0 && AWARENESS.filter((pattern) => pattern.test(body)).length >= 2) score -= 4;
    return { signals, score, suspicious: score >= THRESHOLD };
  }

  globalThis.__SCAMSHIELD_TEST__ = Object.assign(globalThis.__SCAMSHIELD_TEST__ ?? {}, { analyze });

  if (window.top !== window) return;

  let lastSent = "";
  let runs = 0;
  let timer = null;

  function pageText() {
    const root = document.body;
    return `${document.title}\n${root ? root.innerText : ""}`;
  }

  async function check() {
    timer = null;
    if (runs >= 6) return; // pages that keep changing are only looked at a few times
    runs += 1;
    const result = analyze(pageText());
    if (!result.suspicious) return;
    const key = result.signals.join(",");
    if (key === lastSent) return;
    lastSent = key;
    try {
      await browser.runtime.sendMessage({ type: "scam-signals", signals: result.signals, score: result.score });
    } catch {
      // The background script may be starting up; the next check will retry.
      lastSent = "";
    }
  }

  const schedule = (delay) => {
    if (timer === null) timer = setTimeout(check, delay);
  };

  function start() {
    schedule(600);
    // Scam pop-ups often appear a little after the page loads.
    if (document.body) {
      new MutationObserver(() => schedule(1500)).observe(document.body, { childList: true, subtree: true });
    }
  }

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", start, { once: true });
  else start();
})();
