const test = require('node:test');
const assert = require('node:assert/strict');

const {
  computeReconnectDelayMs,
  formatWsStatusLabel,
  getWsCloseDetail,
  getWsDisplayState,
  normalizeWsError,
} = require('../../app/web/ws_status.js');

test('maps only qualified websocket errors to short visible messages', () => {
  assert.equal(normalizeWsError('net::ERR_CERT_AUTHORITY_INVALID'), 'WS bloqué par TLS/certificat');
  assert.equal(normalizeWsError('Error during WebSocket handshake: 403'), 'WS refusé');
  assert.equal(
    normalizeWsError('Error during WebSocket handshake: 403', { isSecure: false, online: false }),
    'WS refusé',
  );
  assert.equal(normalizeWsError(''), '');
  assert.equal(normalizeWsError('WebSocket closed unexpectedly'), '');
});

test('keeps fallback reason empty unless a qualified failure was observed', () => {
  assert.equal(getWsCloseDetail({ code: 1000, wasOnline: true, lastError: '' }), '');
  assert.equal(getWsCloseDetail({ code: 1006, wasOnline: false, lastError: 'Error during WebSocket handshake: 403' }), 'WS refusé');
  assert.equal(getWsCloseDetail({ code: 1006, wasOnline: true, lastError: '' }), '');

  assert.equal(
    getWsCloseDetail({ code: 1006, wasOnline: false, lastError: '', isSecure: true, online: true }),
    'WS bloqué par TLS/certificat',
  );
});

test('formats fallback badge with visible websocket reason', () => {
  assert.equal(formatWsStatusLabel('fallback', 'WS refusé'), 'Mise à jour périodique · WS refusé');
  assert.equal(formatWsStatusLabel('online', 'WS refusé'), 'WS en ligne');
});

test('maps websocket status by consecutive failures and threshold', () => {
  assert.deepEqual(getWsDisplayState(1, 3), { mode: 'fallback', detail: 'reconnexion…' });
  assert.deepEqual(getWsDisplayState(2, 3), { mode: 'fallback', detail: 'reconnexion…' });
  assert.deepEqual(getWsDisplayState(3, 3), { mode: 'offline', detail: '' });
  assert.deepEqual(getWsDisplayState(1, 0), { mode: 'offline', detail: '' });
});

test('computes reconnect delay with exponential backoff and jitter', () => {
  const random = () => 0.5;
  assert.equal(computeReconnectDelayMs(1, { random }), 2000);
  assert.equal(computeReconnectDelayMs(2, { random }), 4000);
  assert.equal(computeReconnectDelayMs(3, { random }), 8000);
  assert.equal(computeReconnectDelayMs(8, { random }), 30000);

  assert.equal(computeReconnectDelayMs(1, { random: () => 0 }), 1500);
  assert.equal(computeReconnectDelayMs(1, { random: () => 1 }), 2500);
});
