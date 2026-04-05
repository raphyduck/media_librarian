/**
 * WebSocket utility contracts:
 * - normalizeWsError(raw: string): string
 *   Pure textual normalization. Returns a short user-facing reason or '' when unknown.
 * - getWsCloseDetail(context: {
 *     code?: number,
 *     wasOnline?: boolean,
 *     lastError?: string,
 *     isSecure?: boolean,
 *     online?: boolean
 *   }): string
 *   Computes the final visible reason on close from close code + connection context.
 */
function normalizeWsError(raw = '') {
  const message = String(raw || '').toLowerCase();
  if (
    message.includes('tls')
    || message.includes('ssl')
    || message.includes('cert')
    || message.includes('certificate')
    || message.includes('authority invalid')
  ) {
    return 'WS bloqué par TLS/certificat';
  }
  if (
    message.includes('refus')
    || message.includes('refused')
    || message.includes('forbidden')
    || message.includes('403')
  ) {
    return 'WS refusé';
  }
  return '';
}

function getWsCloseDetail({
  code = 1000,
  wasOnline = false,
  lastError = '',
  isSecure = false,
  online = true,
} = {}) {
  if (code === 1000 && wasOnline && !lastError) {
    return '';
  }
  const normalizedError = normalizeWsError(lastError);
  if (!normalizedError && code === 1006 && wasOnline === false && isSecure === true && online !== false) {
    return 'WS bloqué par TLS/certificat';
  }
  return normalizedError;
}

function formatWsStatusLabel(mode, detail = '') {
  const label = mode === 'online' ? 'WS en ligne' : mode === 'fallback' ? 'Mise à jour périodique' : 'WS indisponible';
  return detail && mode !== 'online' ? `${label} · ${detail}` : label;
}

function getWsDisplayState(consecutiveFailures = 0, failureThreshold = 3) {
  const safeThreshold = Math.max(1, Number(failureThreshold) || 1);
  return consecutiveFailures >= safeThreshold
    ? { mode: 'offline', detail: '' }
    : { mode: 'fallback', detail: 'reconnexion…' };
}

function computeReconnectDelayMs(
  attempt = 1,
  { baseMs = 2000, maxMs = 30000, jitterRatio = 0.25, random = Math.random } = {}
) {
  const step = Math.max(1, Number(attempt) || 1) - 1;
  const backoffMs = Math.min(maxMs, baseMs * 2 ** step);
  const jitterMs = backoffMs * jitterRatio * ((typeof random === 'function' ? random() : 0.5) * 2 - 1);
  return Math.max(0, Math.round(backoffMs + jitterMs));
}

if (typeof window !== 'undefined') {
  window.normalizeWsError = normalizeWsError;
  window.getWsCloseDetail = getWsCloseDetail;
  window.formatWsStatusLabel = formatWsStatusLabel;
  window.getWsDisplayState = getWsDisplayState;
  window.computeReconnectDelayMs = computeReconnectDelayMs;
}

if (typeof module !== 'undefined' && module.exports) {
  module.exports = {
    normalizeWsError,
    getWsCloseDetail,
    formatWsStatusLabel,
    getWsDisplayState,
    computeReconnectDelayMs,
  };
}
