// Console logger. Debug lines appear only when verbose logging is on.
// Callers must never pass typed text, card numbers or page content.

const PREFIX = "[ScamShield]";

export function createLogger(isVerbose = () => false, sink = console) {
  return {
    debug: (...args) => { if (isVerbose()) sink.debug(PREFIX, ...args); },
    info: (...args) => sink.info(PREFIX, ...args),
    warn: (...args) => sink.warn(PREFIX, ...args),
    error: (...args) => sink.error(PREFIX, ...args),
  };
}
