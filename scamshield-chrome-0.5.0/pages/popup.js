// Toolbar popup: shows if the current page looks safe, and has the big
// "I think I'm being scammed" button. All wording comes from the background
// script; every piece of text is set with textContent.
"use strict";
globalThis.browser ??= globalThis.chrome;

const $ = (id) => document.getElementById(id);
let current = { tabId: undefined, url: "" };

function render(info) {
  document.body.dataset.level = info.level;
  document.documentElement.style.setProperty("--scale", String(Math.min(info.textScale ?? 1, 1.05)));
  $("title").textContent = info.title;
  $("why").textContent = info.why;
  $("host").textContent = info.host ?? "";
  const list = $("reasons");
  list.textContent = "";
  for (const reason of info.reasons ?? []) {
    const li = document.createElement("li");
    li.textContent = reason;
    list.append(li);
  }
  list.hidden = list.children.length === 0;
  $("n-ads").textContent = String(info.ads);
  $("n-sites").textContent = String(info.stats.sites_blocked);
  $("n-scams").textContent = String(info.stats.scam_pages);
  $("n-dl").textContent = String(info.stats.downloads_held);
  $("panic").textContent = info.texts.btn_panic;
  const ask = $("ask");
  ask.hidden = info.level !== "careful" || !info.host;
  ask.textContent = info.texts.btn_ask_admin;
  ask.disabled = false;
  ask.onclick = async () => {
    ask.disabled = true;
    let ok = false;
    try { ok = (await browser.runtime.sendMessage({ type: "popup-ask", url: current.url }))?.ok === true; } catch { ok = false; }
    ask.textContent = ok ? info.texts.btn_ask_sent : info.texts.btn_ask_failed;
    ask.disabled = ok;
  };

  $("panic").onclick = async () => {
    $("panic").disabled = true;
    let reply = null;
    try { reply = await browser.runtime.sendMessage({ type: "popup-panic", url: current.url }); } catch { reply = null; }
    showSteps(info, reply);
  };
}

function showSteps(info, reply) {
  $("main").hidden = true;
  $("steps").hidden = false;
  document.body.dataset.level = reply?.ok ? "safe" : "danger";
  $("steps-title").textContent = info.texts.panic_title;
  $("steps-sent").textContent = reply?.text ?? "";
  const list = $("steps-list");
  list.textContent = "";
  for (const id of ["panic_step_1", "panic_step_2", "panic_step_3", "panic_step_5"]) {
    const li = document.createElement("li");
    li.textContent = info.texts[id];
    list.append(li);
  }
  $("steps-call").textContent = info.texts.panic_step_4;
}

async function start() {
  let tab;
  try { [tab] = await browser.tabs.query({ active: true, currentWindow: true }); } catch { tab = undefined; }
  current = { tabId: tab?.id, url: tab?.url ?? "" };
  let info = null;
  try { info = await browser.runtime.sendMessage({ type: "popup-state", tabId: current.tabId, url: current.url }); } catch { info = null; }
  if (!info) {
    $("title").textContent = "ScamShield is starting";
    $("why").textContent = "Please close this and try again in a moment.";
    return;
  }
  render(info);
}
start();
