const test = require('node:test');
const assert = require('node:assert/strict');

const { buildEditorSelectionPath } = require('../../app/web/path_utils.js');

test('returns base path when no selection is provided', () => {
  assert.equal(buildEditorSelectionPath('/templates', '', 'load'), '/templates');
  assert.equal(buildEditorSelectionPath('/templates', null, 'save'), '/templates');
});

test('appends selection as path segment for load and save actions', () => {
  assert.equal(
    buildEditorSelectionPath('/templates', 'alpha.yml', 'load'),
    '/templates/alpha.yml',
  );
  assert.equal(
    buildEditorSelectionPath('/trackers/', 'main.yml', 'save'),
    '/trackers/main.yml',
  );
});

test('encodes special characters in path segments', () => {
  assert.equal(
    buildEditorSelectionPath('/templates', 'français.yaml', 'load'),
    '/templates/fran%C3%A7ais.yaml',
  );
});

test('preserves query strategy for reload actions', () => {
  assert.equal(
    buildEditorSelectionPath('/templates', 'alpha.yml', 'reload', ['name']),
    '/templates?name=alpha.yml',
  );
});

test('supports multiple selection keys for reload actions', () => {
  assert.equal(
    buildEditorSelectionPath('/trackers', 'main.yml', 'reload', ['name', 'alt']),
    '/trackers?name=main.yml&alt=main.yml',
  );
});
