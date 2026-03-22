const test = require('node:test');
const assert = require('node:assert/strict');

const { formatWsStatusLabel, getWsCloseDetail, normalizeWsError } = require('../../app/web/ws_status.js');

test('maps websocket errors to short visible messages', () => {
  assert.equal(normalizeWsError('net::ERR_CERT_AUTHORITY_INVALID', { isSecure: true }), 'WS bloqué par TLS/certificat');
  assert.equal(normalizeWsError('Error during WebSocket handshake: 403', { isSecure: false }), 'WS refusé');
  assert.equal(normalizeWsError('', { isSecure: false, online: true }), 'WS indisponible');
});

test('keeps fallback reason empty for normal closes but visible for failures', () => {
  assert.equal(getWsCloseDetail({ code: 1000, wasOnline: true, lastError: '' }), '');
  assert.equal(getWsCloseDetail({ code: 1006, wasOnline: false, lastError: 'Error during WebSocket handshake: 403' }), 'WS refusé');
  assert.equal(getWsCloseDetail({ code: 1006, wasOnline: true, lastError: '' }), 'WS indisponible');
});

test('formats fallback badge with visible websocket reason', () => {
  assert.equal(formatWsStatusLabel('fallback', 'WS refusé'), 'Mise à jour périodique · WS refusé');
  assert.equal(formatWsStatusLabel('online', 'WS refusé'), 'WS en ligne');
});
