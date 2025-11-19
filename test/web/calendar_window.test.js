const test = require('node:test');
const assert = require('node:assert/strict');

const { wireCalendarNavigation } = require('../../app/web/calendar_window.js');

function stubElement() {
  const handlers = {};
  return {
    addEventListener: (event, handler) => {
      handlers[event] = handler;
    },
    dispatch: (event) => {
      handlers[event]?.();
    },
    value: '',
  };
}

test('navigation controls delegate to loadCalendar with offsets and dates', () => {
  const calls = [];
  const previous = stubElement();
  const next = stubElement();
  const dateInput = stubElement();
  dateInput.value = '2024-01-05';

  wireCalendarNavigation({ previous, next, dateInput }, (options) => calls.push(options));

  previous.dispatch('click');
  next.dispatch('click');
  dateInput.dispatch('change');

  assert.deepEqual(calls, [
    { offsetDelta: -1, preserveFilters: true },
    { offsetDelta: 1, preserveFilters: true },
    { startDate: '2024-01-05', preserveFilters: true },
  ]);
});
