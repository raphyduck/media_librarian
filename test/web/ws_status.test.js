const test = require('node:test');
const assert = require('node:assert/strict');

const { formatWsStatusLabel, getWsCloseDetail, normalizeWsError } = require('../../app/web/ws_status.js');

test('maps only qualified websocket errors to short visible messages', () => {
  assert.equal(normalizeWsError('net::ERR_CERT_AUTHORITY_INVALID'), 'WS bloqué par TLS/certificat');
  assert.equal(normalizeWsError('Error during WebSocket handshake: 403'), 'WS refusé');
  assert.equal(normalizeWsError(''), '');
  assert.equal(normalizeWsError('WebSocket closed unexpectedly'), '');
});

test('keeps fallback reason empty unless a qualified failure was observed', () => {
  assert.equal(getWsCloseDetail({ code: 1000, wasOnline: true, lastError: '' }), '');
  assert.equal(getWsCloseDetail({ code: 1006, wasOnline: false, lastError: 'Error during WebSocket handshake: 403' }), 'WS refusé');
  assert.equal(getWsCloseDetail({ code: 1006, wasOnline: true, lastError: '' }), '');
});

test('formats fallback badge with visible websocket reason', () => {
  assert.equal(formatWsStatusLabel('fallback', 'WS refusé'), 'Mise à jour périodique · WS refusé');
  assert.equal(formatWsStatusLabel('online', 'WS refusé'), 'WS en ligne');
});
