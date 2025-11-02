;(function attachPathUtilities(global) {
  function buildEditorSelectionPath(base, selection, action, keys) {
    const normalizedBase = base || '';
    if (!normalizedBase || !selection) {
      return normalizedBase;
    }

    if (action === 'reload') {
      const effectiveKeys = Array.isArray(keys) ? keys.filter(Boolean) : [];
      const queryKeys = effectiveKeys.length ? effectiveKeys : ['name'];
      const query = new URLSearchParams();
      queryKeys.forEach((key) => {
        query.set(key, selection);
      });
      const search = query.toString();
      return search ? `${normalizedBase}?${search}` : normalizedBase;
    }

    const separator = normalizedBase.endsWith('/') ? '' : '/';
    return `${normalizedBase}${separator}${encodeURIComponent(selection)}`;
  }

  if (global && typeof global === 'object') {
    global.buildEditorSelectionPath = buildEditorSelectionPath;
  }

  if (typeof module !== 'undefined' && module.exports) {
    module.exports = { buildEditorSelectionPath };
  }
})(typeof window !== 'undefined' ? window : globalThis);
