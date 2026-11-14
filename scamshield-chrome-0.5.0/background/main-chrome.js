// Chrome / Chromium entry point (a service worker). Same controller as Firefox;
// only the wiring differs:
//   - blocking uses declarativeNetRequest rules the controller keeps up to date
//     (webRequestBlocking is not available to normally installed extensions)
//   - message replies go through sendResponse (Chrome does not accept a Promise)
// A service worker can be stopped at any time, so everything that matters is in
// storage and the listeners below are registered immediately, at the top level.

import { createController } from "./controller.js";

const FEED_ALARM = "scamshield-feeds";
const api = globalThis.chrome;
const controller = createController({ browser: api, useDnr: true });

api.webNavigation.onBeforeNavigate.addListener((details) => { controller.handleNavigation(details).catch(() => {}); });

api.downloads.onCreated.addListener((item) => { controller.handleDownloadCreated(item).catch(() => {}); });
api.downloads.onChanged.addListener((delta) => { controller.handleDownloadChanged(delta).catch(() => {}); });

api.runtime.onMessage.addListener((message, sender, sendResponse) => {
  controller.handleMessage(message, sender).then(sendResponse, () => sendResponse(undefined));
  return true; // the answer is sent asynchronously
});

const refreshFeeds = () => controller.refreshFeeds().catch(() => {});
api.runtime.onStartup.addListener(refreshFeeds);
api.runtime.onInstalled.addListener(refreshFeeds);
api.alarms.onAlarm.addListener((alarm) => { if (alarm.name === FEED_ALARM) refreshFeeds(); });
api.alarms.get(FEED_ALARM).then((existing) => {
  if (!existing) api.alarms.create(FEED_ALARM, { periodInMinutes: 60, delayInMinutes: 1 });
});
