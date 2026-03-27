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

if (typeof window !== 'undefined') {
  window.normalizeWsError = normalizeWsError;
  window.getWsCloseDetail = getWsCloseDetail;
  window.formatWsStatusLabel = formatWsStatusLabel;
}

if (typeof module !== 'undefined' && module.exports) {
  module.exports = { normalizeWsError, getWsCloseDetail, formatWsStatusLabel };
}
