;(function attachCalendarWindow(global) {
  const ONE_DAY_MS = 86_400_000;

  function truncateDate(input) {
    if (!input) return null;
    const value = new Date(input);
    if (Number.isNaN(value.getTime())) return null;
    value.setHours(0, 0, 0, 0);
    return value;
  }

  function addDays(date, days) {
    return new Date(date.getTime() + days * ONE_DAY_MS);
  }

  function createCalendarWindowManager(options = {}) {
    const now = options.now || (() => new Date());
    const windowLengthForView = options.windowLengthForView || ((view) => (view === 'month' ? 30 : 7));

    let customStart = null;
    let offset = 0;

    function currentWindow(view) {
      const days = windowLengthForView(view);
      const start = addDays(truncateDate(customStart) || truncateDate(now()), offset * days);
      return { start, end: addDays(start, days - 1), days, offset };
    }

    return {
      current(view) {
        return currentWindow(view);
      },
      shift(view, delta) {
        offset += delta;
        return currentWindow(view);
      },
      setStart(view, date) {
        customStart = truncateDate(date);
        offset = 0;
        return currentWindow(view);
      },
      reset(view) {
        customStart = null;
        offset = 0;
        return currentWindow(view);
      },
    };
  }

  function wireCalendarNavigation(elements, loadCalendar) {
    if (!elements || typeof loadCalendar !== 'function') {
      return;
    }
    const { previous, next, dateInput } = elements;
    if (previous?.addEventListener) {
      previous.addEventListener('click', () => loadCalendar({ offsetDelta: -1, preserveFilters: true }));
    }
    if (next?.addEventListener) {
      next.addEventListener('click', () => loadCalendar({ offsetDelta: 1, preserveFilters: true }));
    }
    if (dateInput?.addEventListener) {
      dateInput.addEventListener('change', () => {
        if (dateInput.value) {
          loadCalendar({ startDate: dateInput.value, preserveFilters: true });
        }
      });
    }
  }

  if (global && typeof global === 'object') {
    global.createCalendarWindowManager = createCalendarWindowManager;
    global.wireCalendarNavigation = wireCalendarNavigation;
  }

  if (typeof module !== 'undefined' && module.exports) {
    module.exports = {
      addDays,
      truncateDate,
      createCalendarWindowManager,
      wireCalendarNavigation,
    };
  }
})(typeof window !== 'undefined' ? window : globalThis);
