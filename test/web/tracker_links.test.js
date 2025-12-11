const test = require('node:test');
const assert = require('node:assert/strict');

const {
  buildTrackerSearchUrl,
  normalizeTrackerTemplates,
} = require('../../app/web/tracker_links.js');

test('normalizes tracker entries and keeps template values', () => {
  const normalized = normalizeTrackerTemplates([
    { name: 'alpha', url_template: 'https://alpha/%title%' },
    { tracker: 'beta', template: 'https://beta/%imdbid%' },
    null,
    { name: '' },
  ]);

  assert.deepEqual(normalized, [
    { name: 'alpha', urlTemplate: 'https://alpha/%title%' },
    { name: 'beta', urlTemplate: 'https://beta/%imdbid%' },
  ]);
});

test('buildTrackerSearchUrl encodes placeholders and validates required fields', () => {
  const template = 'https://tracker/%title%/%year%/%imdbid%';
  const url = buildTrackerSearchUrl(template, {
    title: 'Le garçon',
    year: 2024,
    imdb: 'tt12345',
  });

  assert.equal(url, 'https://tracker/Le%20gar%C3%A7on/2024/tt12345');
  assert.equal(buildTrackerSearchUrl(template, { title: 'Film' }), '');
  assert.equal(buildTrackerSearchUrl('https://tracker/%title%', { title: 'Film' }), 'https://tracker/Film');
});
