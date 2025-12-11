;(function attachTrackerLinks(global) {
  function normalizeTrackerTemplates(entries) {
    if (!Array.isArray(entries)) {
      return [];
    }
    return entries
      .map((entry) => {
        if (!entry || typeof entry !== 'object') {
          return null;
        }
        const name = (entry.name || entry.tracker || entry.key || '').toString().trim();
        if (!name) {
          return null;
        }
        const template = entry.urlTemplate || entry.url_template || entry.template;
        const urlTemplate = template == null ? '' : String(template).trim();
        return { name, urlTemplate };
      })
      .filter(Boolean);
  }

  function buildTrackerSearchUrl(template, metadata = {}) {
    const normalizedTemplate = (template || '').toString();
    if (!normalizedTemplate) {
      return '';
    }

    const normalizedTitle = (metadata.title || '').toString().trim();
    const normalizedYear = metadata.year == null ? '' : metadata.year.toString().trim();
    const normalizedImdb = (metadata.imdb || metadata.imdbid || '').toString().trim();

    const lowerTemplate = normalizedTemplate.toLowerCase();
    if (lowerTemplate.includes('%title%') && !normalizedTitle) return '';
    if (lowerTemplate.includes('%year%') && !normalizedYear) return '';
    if (lowerTemplate.includes('%imdbid%') && !normalizedImdb) return '';

    let url = normalizedTemplate;
    const replacements = {
      '%title%': normalizedTitle,
      '%year%': normalizedYear,
      '%imdbid%': normalizedImdb,
    };

    Object.entries(replacements).forEach(([placeholder, value]) => {
      const pattern = new RegExp(placeholder, 'gi');
      const replacement = value ? encodeURIComponent(value) : '';
      url = url.replace(pattern, replacement);
    });

    return /%[a-z]+%/i.test(url) ? '' : url;
  }

  if (global && typeof global === 'object') {
    global.normalizeTrackerTemplates = normalizeTrackerTemplates;
    global.buildTrackerSearchUrl = buildTrackerSearchUrl;
  }

  if (typeof module !== 'undefined' && module.exports) {
    module.exports = { normalizeTrackerTemplates, buildTrackerSearchUrl };
  }
})(typeof window !== 'undefined' ? window : globalThis);
