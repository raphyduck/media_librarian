const state = {
  authenticated: false,
  username: '',
  autoRefresh: null,
  activeTab: 'jobs',
  dirty: {
    config: false,
    apiConfig: false,
    scheduler: false,
    templates: false,
    trackers: false,
  },
  isRefreshing: false,
  calendar: {
    view: 'week',
    entries: [],
    availableGenres: [],
    loadingGenres: false,
    filters: {
      title: '',
      type: '',
      genres: [],
      ratingMin: '',
      ratingMax: '',
      votesMin: '',
      votesMax: '',
      language: '',
      country: '',
    },
  },
  calendarSearch: {
    query: '',
    lastLoadedQuery: '',
    results: [],
    loading: false,
  },
  collection: {
    entries: [],
    sort: 'released_at',
    type: '',
    page: 1,
    perPage: 50,
    total: 0,
    loading: false,
    search: '',
  },
  trackers: {
    entries: [],
    map: {},
    selections: new Map(),
  },
};

const calendarWindow = typeof createCalendarWindowManager === 'function'
  ? createCalendarWindowManager({ windowLengthForView: (view) => (view === 'month' ? 30 : 7) })
  : null;

const fileEditors = new Map();
const CONFIG_FORM_SCHEMA = [
  {
    title: 'Préférences',
    section: null,
    fields: [
      { key: 'preferred_languages', label: 'Langues préférées', type: 'text', placeholder: 'fr en' },
    ],
  },
  {
    title: 'Daemon',
    section: 'daemon',
    fields: [
      { key: 'workers_pool_size', label: 'Pool de workers', type: 'number' },
      {
        key: 'queue_slots',
        label: 'Slots de queue',
        type: 'number',
        description: 'Deprecated; the worker queue is unbounded.',
      },
      {
        key: 'finished_jobs_per_queue',
        label: 'Jobs conservés',
        type: 'number',
        description: 'Keep the last 100 finished/failed/cancelled jobs per queue in memory.',
      },
    ],
  },
  {
    title: 'Deluge',
    section: 'deluge',
    fields: [
      { key: 'host', label: 'Hôte', type: 'text' },
      { key: 'username', label: 'Utilisateur', type: 'text' },
      { key: 'password', label: 'Mot de passe', type: 'password' },
      { key: 'remove_on_completion', label: 'Suppression auto', type: 'number' },
      {
        key: 'max_download_rate',
        label: 'Débit max (kbps)',
        type: 'number',
        description: 'In kbps',
      },
      { key: 'min_torrent_free_space', label: 'Espace libre min', type: 'number' },
      { key: 'default_seed_time', label: 'Seed time par défaut', type: 'number' },
    ],
  },
  {
    title: 'Email',
    section: 'email',
    fields: [
      { key: 'host', label: 'Hôte', type: 'text' },
      { key: 'port', label: 'Port', type: 'number' },
      { key: 'domain', label: 'Domaine', type: 'text' },
      { key: 'username', label: 'Utilisateur', type: 'text' },
      { key: 'password', label: 'Mot de passe', type: 'password' },
      {
        key: 'auth_type',
        label: 'Auth type',
        type: 'select',
        options: ['plain', 'login', 'cram_md5'],
      },
      { key: 'notification_from', label: 'Notification From', type: 'text' },
      { key: 'notification_to', label: 'Notification To', type: 'text' },
      { key: 'notification_cc', label: 'Notification CC', type: 'text' },
      { key: 'notification_bcc', label: 'Notification BCC', type: 'text' },
    ],
  },
  {
    title: 'FFmpeg',
    section: 'ffmpeg_settings',
    fields: [
      { key: 'crf', label: 'CRF', type: 'number' },
      {
        key: 'preset',
        label: 'Preset',
        type: 'select',
        options: ['ultrafast', 'superfast', 'veryfast', 'faster', 'fast', 'medium', 'slow', 'slower', 'veryslow'],
      },
    ],
  },
  {
    title: 'Calendrier',
    section: 'calendar',
    fields: [
      { key: 'refresh_every', label: 'Refresh every', type: 'text' },
      { key: 'refresh_on_start', label: 'Refresh au démarrage', type: 'checkbox' },
      { key: 'window_past_days', label: 'Fenêtre passée (jours)', type: 'number' },
      { key: 'window_future_days', label: 'Fenêtre future (jours)', type: 'number' },
      { key: 'refresh_limit', label: 'Limite de refresh', type: 'number' },
      { key: 'providers', label: 'Providers', type: 'text', placeholder: 'imdb|trakt|tmdb' },
    ],
  },
  {
    title: 'IMDb (optionnel)',
    section: 'imdb',
    fields: [
      {
        key: 'enabled',
        label: 'Activé',
        type: 'checkbox',
        description: 'Optional toggle; remove or set to false to disable the IMDb feed',
      },
    ],
  },
  {
    title: 'Kodi',
    section: 'kodi',
    fields: [
      { key: 'host', label: 'Hôte', type: 'text' },
      { key: 'username', label: 'Utilisateur', type: 'text' },
      { key: 'password', label: 'Mot de passe', type: 'password' },
    ],
  },
  {
    title: 'Trakt',
    section: 'trakt',
    fields: [
      {
        key: 'account_id',
        label: 'Account ID',
        type: 'text',
        description: 'Used for metadata lookups; list automation is retired',
      },
      { key: 'client_id', label: 'Client ID', type: 'text' },
      { key: 'client_secret', label: 'Client secret', type: 'text' },
      {
        key: 'ca_path',
        label: 'CA path',
        type: 'text',
        description: 'Optional override; defaults to system trust store',
      },
      {
        key: 'enable_crl_checks',
        label: 'CRL checks',
        type: 'checkbox',
        description: 'Opt-in CRL checking; will fall back if unsupported',
      },
      {
        key: 'disable_crl_checks',
        label: 'Désactiver CRL checks',
        type: 'checkbox',
        description: 'Legacy override to forcefully disable CRL checks',
      },
    ],
  },
  {
    title: 'TMDB',
    section: 'tmdb',
    fields: [{ key: 'api_key', label: 'API key', type: 'text' }],
  },
  {
    title: 'TVDB',
    section: 'tvdb',
    fields: [{ key: 'api_key', label: 'API key', type: 'text' }],
  },
  {
    title: 'OMDb',
    section: 'omdb',
    fields: [{ key: 'api_key', label: 'API key', type: 'text' }],
  },
];
const configFormState = {
  mode: 'form',
  inputs: [],
};
const apiConfigFormState = {
  mode: 'form',
  inputs: [],
};
const trackerFormState = {
  inputs: [],
};
const API_CONFIG_FORM_SCHEMA = [
  {
    title: 'Réseau',
    section: null,
    fields: [
      { key: 'bind_address', label: 'Adresse de bind', type: 'text', placeholder: '127.0.0.1' },
      { key: 'listen_port', label: 'Port d’écoute', type: 'number' },
    ],
  },
  {
    title: 'Authentification',
    section: 'auth',
    fields: [
      { key: 'username', label: 'Utilisateur', type: 'text' },
      {
        key: 'password_hash',
        label: 'Hash bcrypt',
        type: 'password',
        toggle: true,
      },
      {
        key: 'session_secret',
        label: 'Secret de session',
        type: 'password',
        toggle: true,
        description: 'Optionnel : laissez vide pour une génération automatique dans ~/.medialibrarian/session_secret',
      },
    ],
  },
  {
    title: 'TLS',
    section: null,
    fields: [
      { key: 'ssl_enabled', label: 'TLS activé', type: 'checkbox' },
      { key: 'ssl_certificate_path', label: 'Chemin certificat', type: 'text' },
      { key: 'ssl_private_key_path', label: 'Chemin clé privée', type: 'text' },
      { key: 'ssl_ca_path', label: 'Chemin CA', type: 'text' },
      { key: 'ssl_verify_mode', label: 'Mode de vérification', type: 'text' },
      { key: 'ssl_client_verify_mode', label: 'Mode de vérification client', type: 'text' },
    ],
  },
  {
    title: 'Tokens',
    section: null,
    fields: [
      { key: 'api_token', label: 'API token', type: 'password', toggle: true },
      { key: 'control_token', label: 'Control token', type: 'password', toggle: true },
    ],
  },
];
const TRACKER_FORM_SCHEMA = [
  {
    title: 'Accès',
    section: null,
    fields: [
      { key: 'api_url', label: 'API URL', type: 'text', example: 'https://torznab.example/api' },
      { key: 'api_key', label: 'API key', type: 'text', example: 'replace-with-api-key' },
      {
        key: 'url_template',
        label: 'URL de recherche',
        type: 'text',
        example: 'https://tracker.example/search?title=%title%&year=%year%&imdb=%imdbid%',
        description: 'Placeholders : %title%, %year%, %imdbid%.',
      },
      { key: 'assume_quality', label: 'Qualité présumée', type: 'text', example: 'vf' },
      { key: 'seed_time', label: 'Seed time (h)', type: 'number', example: 24 },
    ],
  },
  {
    title: 'Spécifique au site',
    section: 'site_specific_kw',
    fields: [{ key: 'movies', label: 'Mot-clé movies', type: 'text', example: 'multi' }],
  },
];

const API_BASE_PATH = (() => {
  const { pathname } = window.location;
  if (pathname.endsWith('/')) {
    return pathname;
  }
  const lastSegment = pathname.substring(pathname.lastIndexOf('/') + 1);
  if (!lastSegment || !lastSegment.includes('.')) {
    return `${pathname}/`;
  }
  return pathname.replace(/[^/]*$/, '');
})();

function buildApiUrl(path) {
  const normalizedPath = (path || '').replace(/^\/+/, '');
  return `${API_BASE_PATH}${normalizedPath}`;
}

const LOG_MAX_LINES = Number.parseInt(window.LOG_MAX_LINES, 10) || 1000;

const normalizeTrackerTemplatesFn = typeof normalizeTrackerTemplates === 'function'
  ? normalizeTrackerTemplates
  : () => [];
const buildTrackerSearchUrlFn = typeof buildTrackerSearchUrl === 'function'
  ? buildTrackerSearchUrl
  : () => '';

function parseConfigScalar(raw) {
  if (raw == null) {
    return '';
  }
  const trimmed = String(raw).trim();
  if (trimmed === '') {
    return '';
  }
  if ((trimmed.startsWith("'") && trimmed.endsWith("'")) || (trimmed.startsWith('"') && trimmed.endsWith('"'))) {
    return trimmed.slice(1, -1);
  }
  if (trimmed === 'true') {
    return true;
  }
  if (trimmed === 'false') {
    return false;
  }
  const numeric = Number(trimmed);
  if (!Number.isNaN(numeric) && trimmed !== '') {
    return numeric;
  }
  return trimmed;
}

function parseConfigYaml(content) {
  const data = {};
  let currentSection = null;
  (content || '').split(/\r?\n/).forEach((line) => {
    if (!line.trim() || line.trim().startsWith('#')) {
      return;
    }
    const match = line.replace(/\s+#.*$/, '').match(/^(\s*)([^:]+):\s*(.*)$/);
    if (!match) {
      return;
    }
    const indent = match[1].length;
    const key = match[2].trim();
    const value = match[3] ?? '';
    if (indent === 0) {
      if (value === '') {
        currentSection = key;
        data[currentSection] = data[currentSection] || {};
        return;
      }
      data[key] = parseConfigScalar(value);
      currentSection = null;
      return;
    }
    if (currentSection) {
      data[currentSection] = data[currentSection] || {};
      data[currentSection][key] = parseConfigScalar(value);
    }
  });
  return data;
}

function stringifyConfigScalar(value) {
  if (value === null || value === undefined) {
    return "''";
  }
  if (typeof value === 'boolean') {
    return value ? 'true' : 'false';
  }
  if (typeof value === 'number' && Number.isFinite(value)) {
    return String(value);
  }
  const text = String(value);
  if (text === '') {
    return "''";
  }
  if (/[:#\n]/.test(text) || /^\s|\s$/.test(text)) {
    return `'${text.replace(/'/g, "''")}'`;
  }
  return text;
}

function buildConfigYaml(data = {}, schema = CONFIG_FORM_SCHEMA) {
  const lines = [];
  const handledTop = new Set();
  const handledSections = new Set();

  schema.forEach((section) => {
    if (!section.section) {
      section.fields.forEach((field) => {
        handledTop.add(field.key);
        const value = data[field.key];
        lines.push(`${field.key}: ${stringifyConfigScalar(value)}`);
      });
      return;
    }
    handledSections.add(section.section);
    lines.push(`${section.section}:`);
    const block = data[section.section] || {};
    section.fields.forEach((field) => {
      const value = block[field.key];
      lines.push(`  ${field.key}: ${stringifyConfigScalar(value)}`);
    });
  });

  Object.entries(data).forEach(([key, value]) => {
    if (handledTop.has(key) || handledSections.has(key)) {
      return;
    }
    if (value && typeof value === 'object' && !Array.isArray(value)) {
      lines.push(`${key}:`);
      Object.entries(value).forEach(([childKey, childValue]) => {
        lines.push(`  ${childKey}: ${stringifyConfigScalar(childValue)}`);
      });
      return;
    }
    lines.push(`${key}: ${stringifyConfigScalar(value)}`);
  });

  return `${lines.join('\n')}\n`;
}

function buildConfigForm(containerId, formState, schema, editorKey) {
  const container = document.getElementById(containerId);
  if (!container) {
    return;
  }
  container.innerHTML = '';
  formState.inputs = [];
  schema.forEach((section) => {
    const block = document.createElement('section');
    block.className = 'config-section';
    const title = document.createElement('h3');
    title.textContent = section.title;
    block.appendChild(title);
    const grid = document.createElement('div');
    grid.className = 'grid';
    section.fields.forEach((field) => {
      const label = document.createElement('label');
      label.textContent = field.label;
      let input;
      if (field.type === 'select') {
        input = document.createElement('select');
        (field.options || []).forEach((optionValue) => {
          const option = document.createElement('option');
          option.value = optionValue;
          option.textContent = optionValue;
          input.appendChild(option);
        });
      } else {
        input = document.createElement('input');
        input.type = field.type === 'checkbox' ? 'checkbox' : field.type || 'text';
      }
      if (field.placeholder) {
        input.placeholder = field.placeholder;
      }
      input.dataset.section = section.section || '';
      input.dataset.key = field.key;
      if (field.type === 'checkbox') {
        input.value = '1';
      }
      if (field.description) {
        input.title = field.description;
      }
      if (field.toggle) {
        const wrapper = document.createElement('div');
        wrapper.className = 'field-input-row';
        const toggle = document.createElement('button');
        toggle.type = 'button';
        toggle.className = 'field-toggle';
        toggle.textContent = 'Afficher';
        toggle.addEventListener('click', () => {
          const show = input.type === 'password';
          input.type = show ? 'text' : 'password';
          toggle.textContent = show ? 'Masquer' : 'Afficher';
        });
        wrapper.append(input, toggle);
        label.appendChild(wrapper);
      } else {
        label.appendChild(input);
      }
      if (field.description) {
        const hint = document.createElement('span');
        hint.className = 'field-hint';
        hint.textContent = field.description;
        label.appendChild(hint);
      }
      input.addEventListener('change', () => {
        const editor = getEditor(editorKey);
        if (editor) {
          editor.setDirty(true);
        }
      });
      formState.inputs.push({ input, field, section: section.section });
      grid.appendChild(label);
    });
    block.appendChild(grid);
    container.appendChild(block);
  });
}

function mergeConfigDefaults(data, defaults = {}) {
  if (!defaults || typeof defaults !== 'object') {
    return data;
  }
  const merged = { ...defaults, ...data };
  Object.keys(defaults).forEach((key) => {
    const value = defaults[key];
    if (value && typeof value === 'object' && !Array.isArray(value)) {
      merged[key] = { ...value, ...(data[key] || {}) };
    }
  });
  return merged;
}

function buildSchemaDefaults(schema = []) {
  const data = {};
  schema.forEach((section) => {
    const target = section.section ? (data[section.section] = {}) : data;
    section.fields.forEach((field) => {
      if (field.example !== undefined) {
        target[field.key] = field.example;
      }
    });
  });
  return data;
}

const TRACKER_FORM_DEFAULTS = buildSchemaDefaults(TRACKER_FORM_SCHEMA);

function hydrateConfigForm(content, formState, defaults = {}) {
  const data = mergeConfigDefaults(parseConfigYaml(content), defaults);
  formState.inputs.forEach(({ input, field, section }) => {
    const source = section ? data[section] || {} : data;
    const value = source[field.key];
    if (field.type === 'checkbox') {
      input.checked = Boolean(value);
    } else if (value == null) {
      input.value = '';
    } else {
      if (field.type === 'select' && value !== '' && !Array.from(input.options).some((opt) => opt.value === String(value))) {
        const option = document.createElement('option');
        option.value = String(value);
        option.textContent = String(value);
        input.appendChild(option);
      }
      input.value = String(value);
    }
  });
}

function collectConfigFormData(formState) {
  const data = {};
  formState.inputs.forEach(({ input, field, section }) => {
    const target = section ? (data[section] = data[section] || {}) : data;
    if (field.type === 'checkbox') {
      target[field.key] = input.checked;
      return;
    }
    if (input.type === 'number') {
      const numeric = Number(input.value);
      target[field.key] = input.value === '' || Number.isNaN(numeric) ? '' : numeric;
      return;
    }
    target[field.key] = input.value;
  });
  return data;
}

function configFormToYaml(editor, formState, schema) {
  const base = parseConfigYaml(editor?.textarea?.value || '');
  const updates = collectConfigFormData(formState);
  const merged = mergeConfigUpdates(base, updates);
  return buildConfigYaml(merged, schema);
}

function mergeConfigUpdates(base, updates) {
  const merged = { ...(base || {}) };
  Object.entries(updates).forEach(([key, value]) => {
    if (value && typeof value === 'object' && !Array.isArray(value)) {
      merged[key] = { ...(merged[key] || {}), ...value };
      return;
    }
    merged[key] = value;
  });
  return merged;
}

function setConfigView(mode, { formId, editorId, toggleId, formState, editorKey, schema }) {
  const form = document.getElementById(formId);
  const editor = document.getElementById(editorId);
  const toggle = document.getElementById(toggleId);
  if (!form || !editor || !toggle) {
    return;
  }
  if (mode === 'yaml') {
    const configEditor = getEditor(editorKey);
    if (configEditor) {
      const content = configFormToYaml(configEditor, formState, schema);
      configEditor.applyContent(content);
    }
    form.classList.add('hidden');
    editor.classList.remove('hidden');
    toggle.textContent = 'Formulaire';
    formState.mode = 'yaml';
    return;
  }
  hydrateConfigForm(editor.value, formState);
  form.classList.remove('hidden');
  editor.classList.add('hidden');
  toggle.textContent = 'YAML brut';
  formState.mode = 'form';
}

function getLogTail(content, maxLines = LOG_MAX_LINES) {
  if (!content) {
    return { text: '', truncated: false };
  }

  const normalized = content.replace(/\r\n/g, '\n');
  const endsWithNewline = normalized.endsWith('\n');
  const lines = normalized.split('\n');

  if (endsWithNewline) {
    lines.pop();
  }

  const truncated = lines.length > maxLines;
  if (!truncated) {
    return { text: normalized, truncated: false };
  }

  const tail = lines.slice(-maxLines).join('\n');
  return {
    text: endsWithNewline ? `${tail}\n` : tail,
    truncated: true,
  };
}

function formatDateTime(value) {
  if (!value) {
    return '—';
  }
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) {
    return value;
  }
  return date.toLocaleString();
}

function showNotification(message, kind = 'info') {
  const container = document.getElementById('notification');
  container.textContent = message;
  container.className = kind === 'error' ? 'visible error' : 'visible';
  window.clearTimeout(container._hideTimer);
  container._hideTimer = window.setTimeout(() => {
    container.className = '';
  }, 3500);
}

function setEditorDirty(editorKey, dirty) {
  state.dirty[editorKey] = dirty;
  const entry = fileEditors.get(editorKey);
  const target = entry?.textarea;
  if (target) {
    target.dataset.dirty = dirty ? 'true' : 'false';
  }
}

function isEditorDirty(editorKey) {
  return Boolean(state.dirty[editorKey]);
}

async function parseErrorMessage(response) {
  const text = await response.text();
  if (!text) {
    return '';
  }
  try {
    const parsed = JSON.parse(text);
    if (parsed && typeof parsed === 'object') {
      const message = parsed.error || parsed.message;
      if (message === 'update_restarting' || message === 'restart_only') {
        return '';
      }
      return message || JSON.stringify(parsed);
    }
  } catch (error) {
    // ignore JSON errors, fall back to text
  }
  return text;
}

function stopAutoRefresh() {
  if (state.autoRefresh) {
    window.clearInterval(state.autoRefresh);
    state.autoRefresh = null;
  }
}

function startAutoRefresh() {
  stopAutoRefresh();
  state.autoRefresh = window.setInterval(() => {
    if (!state.authenticated || document.visibilityState === 'hidden') {
      return;
    }
    refreshActiveTab();
  }, 15000);
}

function setTrackerTemplates(trackers = []) {
  const normalized = normalizeTrackerTemplatesFn(trackers);
  state.trackers.entries = normalized;
  state.trackers.map = normalized.reduce((memo, entry) => {
    memo[entry.name] = entry.urlTemplate || '';
    return memo;
  }, {});
}

function resetTrackerTemplates() {
  state.trackers.selections.clear();
  setTrackerTemplates([]);
}

function generateTrackerUrl(trackerName, metadata) {
  const template = state.trackers.map[trackerName] || '';
  return buildTrackerSearchUrlFn(template, metadata);
}

function normalizeEditorEntries(entries) {
  if (!Array.isArray(entries)) {
    return [];
  }
  return entries
    .map((entry) => {
      if (entry == null) {
        return null;
      }
      if (typeof entry === 'string') {
        const value = entry.trim();
        if (!value) {
          return null;
        }
        return { value, label: value };
      }
      if (typeof entry === 'object') {
        const value = entry.value ?? entry.name ?? entry.id ?? entry.key ?? entry.filename;
        if (!value) {
          return null;
        }
        const label = entry.label ?? entry.name ?? entry.title ?? entry.display ?? entry.filename ?? value;
        return { value: String(value), label: String(label) };
      }
      return null;
    })
    .filter(Boolean);
}

function pickSelection(entries, ...candidates) {
  for (const candidate of candidates) {
    const value = typeof candidate === 'string' ? candidate : '';
    if (value && entries.some((entry) => entry.value === value)) {
      return value;
    }
  }
  return entries[0]?.value || '';
}

function extractEntries(data = {}) {
  if (!data || typeof data !== 'object') {
    return undefined;
  }
  const candidates = [data.entries, data.items, data.files, data.templates, data.trackers];
  return candidates.find((value) => Array.isArray(value));
}

function registerFileEditor(key, options) {
  const textarea = options.textareaId ? document.getElementById(options.textareaId) : null;
  if (!textarea && !options.allowMissingTextarea) {
    return null;
  }
  const select = options.selectId ? document.getElementById(options.selectId) : null;
  const hint = options.hintId ? document.getElementById(options.hintId) : null;
  const saveButton = options.saveButtonId ? document.getElementById(options.saveButtonId) : null;
  const reloadButton = options.reloadButtonId ? document.getElementById(options.reloadButtonId) : null;

  const editor = {
    key,
    textarea,
    select,
    hint,
    saveButton,
    reloadButton,
    options,
    current: '',
    hasEntries: !select,
    disabled: false,
    defaultHint: hint ? hint.textContent : '',
  };

  editor.setDirty = (dirty) => setEditorDirty(key, dirty);
  editor.isDirty = () => isEditorDirty(key);
  editor.getSelection = () => (select ? select.value : '');

  editor.updateSelectState = () => {
    if (!select) {
      return;
    }
    const hasOptions = editor.hasEntries && select.options.length > 0;
    select.disabled = editor.disabled || !hasOptions;
  };

  editor.setEnabled = (enabled) => {
    editor.disabled = !enabled;
    if (textarea) {
      textarea.disabled = !enabled;
    }
    if (saveButton) {
      saveButton.disabled = !enabled;
    }
    if (reloadButton) {
      reloadButton.disabled = !enabled;
    }
    editor.updateSelectState();
  };

  editor.applyEntries = (entries, selectedValue) => {
    if (!select || entries === undefined) {
      if (select && selectedValue) {
        select.value = selectedValue;
        editor.current = select.value;
        editor.updateSelectState();
      }
      return;
    }
    const normalized = normalizeEditorEntries(entries);
    select.innerHTML = '';
    editor.hasEntries = normalized.length > 0;
    if (!editor.hasEntries) {
      const option = document.createElement('option');
      option.value = '';
      option.textContent = options.emptyOptionLabel || 'Aucun fichier';
      option.disabled = true;
      option.selected = true;
      select.appendChild(option);
      editor.current = '';
      editor.updateSelectState();
      if (editor.hint && options.emptyHint) {
        editor.hint.textContent = options.emptyHint;
      }
      return;
    }
    normalized.forEach((entry) => {
      const option = document.createElement('option');
      option.value = entry.value;
      option.textContent = entry.label;
      select.appendChild(option);
    });
    const desired = pickSelection(normalized, selectedValue, editor.current, options.defaultSelection);
    select.value = desired;
    editor.current = select.value;
    editor.updateSelectState();
  };

  editor.applyContent = (content) => {
    if (textarea) {
      textarea.value = content || '';
    }
  };

  editor.handleLoadSuccess = (data = {}) => {
    const transformed = typeof options.transformResponse === 'function'
      ? options.transformResponse(data, editor)
      : {
          content: data?.content ?? '',
          entries: extractEntries(data),
          selected:
            data?.name ??
            data?.selected ??
            data?.template ??
            data?.tracker ??
            '',
          hint: data?.hint,
        };
    editor.applyEntries(transformed.entries, transformed.selected);
    editor.applyContent(transformed.content ?? '');
    editor.setDirty(false);
    const enableEditor = !options.disableWhenEmpty || editor.hasEntries;
    editor.setEnabled(enableEditor);
    if (editor.hint) {
      const hintText = transformed.hint
        ?? (editor.hasEntries ? options.successHint : options.emptyHint)
        ?? editor.defaultHint;
      if (hintText) {
        editor.hint.textContent = hintText;
      }
    }
    if (typeof options.afterLoad === 'function') {
      options.afterLoad(editor, transformed, data);
    }
    editor.current = editor.getSelection();
  };

  editor.handleLoadError = (error) => {
    if (options.disableOnError) {
      editor.setEnabled(false);
      editor.applyContent('');
      editor.setDirty(false);
      if (editor.hint) {
        editor.hint.textContent = options.errorHint || error.message || editor.defaultHint;
      }
    }
    if (typeof options.onLoadError === 'function') {
      options.onLoadError(editor, error);
    }
    if (state.authenticated) {
      showNotification(error.message, 'error');
    }
  };

  editor.buildPath = (action, selectionOverride) => {
    if (typeof options.buildPath === 'function') {
      return options.buildPath(action, editor);
    }
    const base =
      action === 'reload'
        ? options.reloadPath
        : action === 'save'
        ? options.savePath || options.loadPath
        : options.loadPath;
    if (!base) {
      return '';
    }
    if (!select) {
      return base;
    }
    const selection =
      selectionOverride !== undefined ? selectionOverride : editor.getSelection();
    if (!selection) {
      return base;
    }
    const keys = Array.isArray(options.selectionKeys) && options.selectionKeys.length
      ? options.selectionKeys
      : [options.paramName || 'name'];
    if (typeof window !== 'undefined' && typeof window.buildEditorSelectionPath === 'function') {
      return window.buildEditorSelectionPath(base, selection, action, keys);
    }
    if (action === 'reload') {
      const query = new URLSearchParams();
      keys.filter(Boolean).forEach((key) => {
        query.set(key, selection);
      });
      const search = query.toString();
      return search ? `${base}?${search}` : base;
    }
    const separator = base.endsWith('/') ? '' : '/';
    return `${base}${separator}${encodeURIComponent(selection)}`;
  };

  editor.buildPayload = ({ includeContent = true, includeSelection = true } = {}) => {
    const payload = {};
    if (includeContent && textarea) {
      payload.content = textarea.value;
    }
    if (includeSelection && select) {
      const selection = editor.getSelection();
      if (selection) {
        const keys = Array.isArray(options.selectionKeys) && options.selectionKeys.length
          ? options.selectionKeys
          : [options.paramName || 'name'];
        keys.filter(Boolean).forEach((key) => {
          payload[key] = selection;
        });
      }
    }
    return typeof options.buildPayload === 'function'
      ? options.buildPayload(payload, editor, { includeContent, includeSelection })
      : payload;
  };

  editor.load = async ({ force = false, selection } = {}) => {
    if (!force && editor.isDirty()) {
      return;
    }
    const requestedSelection =
      selection !== undefined ? selection : select ? editor.getSelection() : undefined;
    const path = editor.buildPath('load', requestedSelection);
    const isStale = () =>
      Boolean(select) && requestedSelection !== undefined && select.value !== requestedSelection;
    try {
      const data = await fetchJson(path);
      if (isStale()) {
        return;
      }
      editor.handleLoadSuccess(data || {});
    } catch (error) {
      if (isStale()) {
        return;
      }
      editor.handleLoadError(error);
    }
  };

  editor.save = async () => {
    try {
      const payload = editor.buildPayload({ includeContent: true, includeSelection: true });
      await fetchJson(editor.buildPath('save'), {
        method: options.saveMethod || 'PUT',
        headers: new Headers({ 'Content-Type': 'application/json' }),
        body: JSON.stringify(payload),
      });
      showNotification(options.saveMessage || 'Fichier sauvegardé.');
      editor.setDirty(false);
      await editor.load({ force: true, selection: select ? editor.getSelection() : undefined });
    } catch (error) {
      if (state.authenticated) {
        showNotification(error.message, 'error');
      }
    }
  };

  editor.reload = async () => {
    if (!options.reloadPath) {
      return;
    }
    try {
      const includeSelection =
        options.includeSelectionInReload ?? Boolean(select && editor.getSelection());
      const payload = includeSelection
        ? editor.buildPayload({ includeContent: false, includeSelection: true })
        : null;
      const init = { method: options.reloadMethod || 'POST' };
      if (payload && Object.keys(payload).length) {
        init.headers = new Headers({ 'Content-Type': 'application/json' });
        init.body = JSON.stringify(payload);
      }
      await fetchJson(editor.buildPath('reload'), init);
      showNotification(options.reloadMessage || 'Fichier rechargé.');
      editor.setDirty(false);
      await editor.load({ force: true, selection: select ? editor.getSelection() : undefined });
    } catch (error) {
      if (state.authenticated) {
        showNotification(error.message, 'error');
      }
    }
  };

  editor.reset = () => {
    editor.applyContent('');
    editor.setDirty(false);
    editor.current = '';
    if (select) {
      editor.applyEntries([], '');
    }
    if (editor.hint) {
      editor.hint.textContent = editor.defaultHint;
    }
    const enabledByDefault =
      options.initiallyEnabled !== false && (!options.disableWhenEmpty || editor.hasEntries);
    editor.setEnabled(enabledByDefault);
  };

  if (textarea) {
    textarea.addEventListener('input', () => editor.setDirty(true));
  }
  if (select) {
    select.addEventListener('change', () => {
      if (editor.isDirty()) {
        select.value = editor.current || '';
        showNotification(
          'Sauvegardez ou annulez vos modifications avant de changer de fichier.',
          'error'
        );
        return;
      }
      editor.current = editor.getSelection();
      editor.load({ force: true, selection: editor.current });
    });
  }

  fileEditors.set(key, editor);
  editor.reset();
  return editor;
}

function getEditor(key) {
  return fileEditors.get(key);
}

async function loadEditor(key, options) {
  const editor = getEditor(key);
  if (editor) {
    await editor.load(options);
  }
}

async function saveEditor(key) {
  const editor = getEditor(key);
  if (editor) {
    await editor.save();
  }
}

async function reloadEditor(key) {
  const editor = getEditor(key);
  if (editor) {
    await editor.reload();
  }
}

function resetEditors() {
  fileEditors.forEach((editor) => {
    editor.reset();
  });
}

function bindEditorAction(buttonId, key, action) {
  const button = document.getElementById(buttonId);
  if (!button) {
    return;
  }
  button.addEventListener('click', async () => {
    if (action === 'save') {
      await saveEditor(key);
    } else if (action === 'reload') {
      await reloadEditor(key);
    } else if (action === 'load') {
      await loadEditor(key, { force: true });
    }
  });
}

function setupFileEditors() {
  registerFileEditor('config', {
    textareaId: 'config-editor',
    loadPath: '/config',
    savePath: '/config',
    reloadPath: '/config/reload',
    saveButtonId: 'save-config',
    reloadButtonId: 'reload-config',
    saveMessage: 'Configuration sauvegardée.',
    reloadMessage: 'Configuration rechargée.',
    afterLoad: (editor, transformed) => {
      if (configFormState.mode === 'form') {
        hydrateConfigForm(transformed.content || '', configFormState);
      }
    },
    buildPayload: (payload, editor) => {
      if (configFormState.mode === 'form' && typeof payload.content === 'string') {
        const content = configFormToYaml(editor, configFormState, CONFIG_FORM_SCHEMA);
        editor.applyContent(content);
        payload.content = content;
      }
      return payload;
    },
  });

  registerFileEditor('apiConfig', {
    textareaId: 'api-config-editor',
    loadPath: '/api-config',
    savePath: '/api-config',
    reloadPath: '/api-config/reload',
    saveButtonId: 'save-api-config',
    reloadButtonId: 'reload-api-config',
    saveMessage: 'Configuration API sauvegardée.',
    reloadMessage: 'Configuration API rechargée.',
    afterLoad: (editor, transformed) => {
      if (apiConfigFormState.mode === 'form') {
        hydrateConfigForm(transformed.content || '', apiConfigFormState);
      }
    },
    buildPayload: (payload, editor) => {
      if (apiConfigFormState.mode === 'form' && typeof payload.content === 'string') {
        const content = configFormToYaml(editor, apiConfigFormState, API_CONFIG_FORM_SCHEMA);
        editor.applyContent(content);
        payload.content = content;
      }
      return payload;
    },
  });

  registerFileEditor('scheduler', {
    textareaId: 'scheduler-editor',
    loadPath: '/scheduler',
    savePath: '/scheduler',
    reloadPath: '/scheduler/reload',
    saveButtonId: 'save-scheduler',
    reloadButtonId: 'reload-scheduler',
    hintId: 'scheduler-hint',
    successHint: 'Modifiez le fichier du scheduler si un planificateur est configuré.',
    errorHint: 'Aucun scheduler configuré ou erreur lors du chargement.',
    saveMessage: 'Scheduler sauvegardé.',
    reloadMessage: 'Scheduler rechargé.',
    disableOnError: true,
  });

  registerFileEditor('templates', {
    textareaId: 'templates-editor',
    selectId: 'templates-select',
    loadPath: '/templates',
    savePath: '/templates',
    reloadPath: '/templates/reload',
    saveButtonId: 'save-templates',
    reloadButtonId: 'reload-templates',
    hintId: 'templates-hint',
    emptyOptionLabel: 'Aucun template disponible',
    emptyHint: 'Aucun template disponible.',
    saveMessage: 'Template sauvegardé.',
    reloadMessage: 'Template rechargé.',
    disableWhenEmpty: true,
    selectionKeys: ['name', 'template'],
  });

  registerFileEditor('trackers', {
    allowMissingTextarea: true,
    selectId: 'trackers-select',
    loadPath: '/trackers',
    savePath: '/trackers',
    reloadPath: '/trackers/reload',
    saveButtonId: 'save-trackers',
    reloadButtonId: 'reload-trackers',
    hintId: 'trackers-hint',
    emptyOptionLabel: 'Aucun tracker disponible',
    emptyHint: 'Aucun tracker disponible.',
    saveMessage: 'Fichier tracker sauvegardé.',
    reloadMessage: 'Fichier tracker rechargé.',
    disableWhenEmpty: true,
    selectionKeys: ['name', 'tracker'],
    afterLoad: (editor, transformed) => {
      const form = document.getElementById('trackers-form');
      if (form) {
        form.classList.toggle('hidden', !editor.getSelection());
      }
      const content = transformed.content || '';
      editor.cachedConfig = editor.getSelection() ? parseConfigYaml(content) : {};
      if (editor.getSelection()) {
        hydrateConfigForm(content, trackerFormState, TRACKER_FORM_DEFAULTS);
      }
    },
    buildPayload: (payload, editor, { includeContent }) => {
      if (includeContent) {
        const updates = collectConfigFormData(trackerFormState);
        const baseConfig = mergeConfigDefaults(editor?.cachedConfig || {}, TRACKER_FORM_DEFAULTS);
        const content = buildConfigYaml(mergeConfigUpdates(baseConfig, updates), TRACKER_FORM_SCHEMA);
        payload.content = content;
      }
      return payload;
    },
  });
}

function setAuthenticated(authenticated, username = '') {
  state.authenticated = authenticated;
  state.username = authenticated ? username : '';

  const dashboard = document.getElementById('dashboard');
  const loginForm = document.getElementById('login-form');
  const status = document.getElementById('session-status');
  const usernameLabel = document.getElementById('session-username');

  if (authenticated) {
    dashboard.classList.remove('hidden');
    loginForm.classList.add('hidden');
    status.hidden = false;
    usernameLabel.textContent = username || '';
    startAutoRefresh();
  } else {
    dashboard.classList.add('hidden');
    loginForm.classList.remove('hidden');
    status.hidden = true;
    usernameLabel.textContent = '';
    state.calendar.entries = [];
    state.calendar.availableGenres = [];
    state.calendar.filters.genres = [];
    resetTrackerTemplates();
    stopAutoRefresh();
    setActiveTab('jobs', { skipLoad: true });
    resetEditors();
  }
}

function updateConnectionHint() {
  const hint = document.querySelector('#session-panel .hint');
  if (!hint) {
    return;
  }

  const protocol = window.location.protocol === 'https:' ? 'https' : 'http';
  const host = window.location.host || '127.0.0.1:8888';
  const base = "Les identifiants sont définis dans la configuration du démon (`api_option.auth`).";
  const path = API_BASE_PATH || '/';
  const normalizedPath = path.startsWith('/') ? path : `/${path}`;
  const url = `${protocol}://${host}${normalizedPath}`;
  const urlMessage = ` Interface disponible sur ${url}.`;
  const tlsReminder = protocol === 'https'
    ? ' En développement, pensez à accepter le certificat TLS auto-signé si nécessaire.'
    : '';

  hint.textContent = `${base}${urlMessage}${tlsReminder}`;
}

function handleUnauthorized() {
  const wasAuthenticated = state.authenticated;
  stopAutoRefresh();
  setAuthenticated(false);
  if (wasAuthenticated) {
    showNotification('Session expirée. Veuillez vous reconnecter.', 'error');
  }
}

async function fetchJson(path, options = {}) {
  const init = { ...options };
  init.credentials = 'include';
  init.headers = new Headers(options.headers || {});

  const url = buildApiUrl(path);
  const response = await fetch(url, init);
  if (response.status === 401 || response.status === 403) {
    const message = await parseErrorMessage(response);
    handleUnauthorized();
    throw new Error(message || 'Authentification requise');
  }
  if (!response.ok) {
    const message = await parseErrorMessage(response);
    throw new Error(message || `Requête échouée (${response.status})`);
  }
  if (response.status === 204) {
    return null;
  }
  return response.json();
}

function formatDate(value) {
  if (!value) return '—';
  try {
    const date = new Date(value);
    return new Intl.DateTimeFormat('fr-FR', {
      dateStyle: 'short',
      timeStyle: 'medium',
    }).format(date);
  } catch (error) {
    return value;
  }
}

function formatDuration(seconds) {
  if (seconds == null) {
    return null;
  }
  const total = Number(seconds);
  if (!Number.isFinite(total) || total < 0) {
    return null;
  }
  let remaining = Math.floor(total);
  const segments = [];
  const units = [
    { size: 86400, label: 'j' },
    { size: 3600, label: 'h' },
    { size: 60, label: 'm' },
  ];
  units.forEach(({ size, label }) => {
    const value = Math.floor(remaining / size);
    if (value > 0 || segments.length) {
      segments.push(`${value}${label}`);
      remaining -= value * size;
    }
  });
  segments.push(`${remaining}s`);
  return segments.slice(0, 3).join(' ');
}

function formatNumber(value, maximumFractionDigits = 1) {
  if (value == null) {
    return null;
  }
  const number = Number(value);
  if (!Number.isFinite(number)) {
    return null;
  }
  return number.toLocaleString('fr-FR', {
    minimumFractionDigits: 0,
    maximumFractionDigits,
  });
}

function updateJobMetrics(snapshot = {}) {
  const container = document.getElementById('jobs-metrics');
  if (!container) {
    return;
  }
  const resources =
    snapshot && typeof snapshot.resources === 'object' && snapshot.resources !== null
      ? snapshot.resources
      : {};
  const uptime = formatDuration(snapshot.uptime_seconds);
  const cpuPercent = formatNumber(resources.cpu_percent);
  const cpuTime = formatNumber(resources.cpu_time_seconds, 1);
  const rss = formatNumber(resources.rss_mb);
  const parts = [];
  if (uptime) {
    parts.push(`Uptime\u00a0: ${uptime}`);
  }
  if (cpuPercent || cpuTime) {
    const cpuParts = [];
    if (cpuPercent) {
      cpuParts.push(`${cpuPercent}%`);
    }
    if (cpuTime) {
      cpuParts.push(`${cpuTime}\u00a0s`);
    }
    parts.push(`CPU\u00a0: ${cpuParts.join(' ')}`);
  }
  if (rss) {
    parts.push(`RAM\u00a0: ${rss}\u00a0Mo`);
  }
  container.innerHTML = parts.map((text) => `<span>${text}</span>`).join('');
  container.hidden = parts.length === 0;
}

async function killJob(jobId) {
  if (!jobId) {
    showNotification('Identifiant du job introuvable.', 'error');
    return;
  }

  try {
    await fetchJson(`/jobs/${encodeURIComponent(jobId)}`, { method: 'DELETE' });
    showNotification(`Job ${jobId} terminé.`);
  } catch (error) {
    showNotification(error.message || 'Impossible de terminer le job.', 'error');
  } finally {
    loadStatus();
  }
}

function renderJobs(data = {}) {
  const finishedStatuses = new Set(['finished', 'failed', 'cancelled']);
  const asArray = (value) => (Array.isArray(value) ? value : []);
  const sourceJobs = Array.isArray(data) ? data : asArray(data.jobs);
  const statusFor = (job) => String(job?.status || '');
  const running = Array.isArray(data.running)
    ? data.running
    : sourceJobs.filter((job) => statusFor(job) === 'running');
  const queued = Array.isArray(data.queued)
    ? data.queued
    : sourceJobs.filter((job) => {
        const status = statusFor(job);
        return status !== 'running' && !finishedStatuses.has(status);
      });
  const finished = Array.isArray(data.finished)
    ? data.finished
    : sourceJobs.filter((job) => finishedStatuses.has(statusFor(job)));

  const computeQueueSummary = (runningJobs, queuedJobs, finishedJobs) => {
    const metrics = new Map();
    const bump = (job, key) => {
      const queueName = String(job?.queue || '');
      if (!metrics.has(queueName)) {
        metrics.set(queueName, { queue: queueName, running: 0, queued: 0, finished: 0, total: 0 });
      }
      const entry = metrics.get(queueName);
      entry[key] += 1;
      entry.total += 1;
    };
    runningJobs.forEach((job) => bump(job, 'running'));
    queuedJobs.forEach((job) => bump(job, 'queued'));
    finishedJobs.forEach((job) => bump(job, 'finished'));
    return Array.from(metrics.values()).sort((a, b) => a.queue.localeCompare(b.queue));
  };

  const queueSummary = Array.isArray(data.queues)
    ? data.queues
    : computeQueueSummary(running, queued, finished);

  const runningList = document.getElementById('jobs-running');
  const queuedList = document.getElementById('jobs-queued');
  const finishedList = document.getElementById('jobs-finished');
  const queueContainer = document.getElementById('jobs-queues');

  const buildItem = (job, { childCount = 0, parentId = null, childIds = [] } = {}) => {
    const li = document.createElement('li');
    li.className = 'job-item';
    const header = document.createElement('header');
    const headerMain = document.createElement('div');
    headerMain.className = 'job-header-main';
    const queue = document.createElement('span');
    queue.textContent = job.queue || '—';
    const status = document.createElement('span');
    status.textContent = job.status;
    headerMain.append(queue, status);

    const actions = document.createElement('div');
    actions.className = 'job-actions';
    if (String(job.status || '') === 'running' && job.id) {
      const button = document.createElement('button');
      button.type = 'button';
      button.className = 'danger';
      button.textContent = 'Terminer';
      button.addEventListener('click', () => killJob(job.id));
      actions.appendChild(button);
    }

    header.append(headerMain, actions);
    const meta = document.createElement('div');
    meta.className = 'job-meta';
    const childIdsMarkup = childIds.map((id) => `<code>${id}</code>`).join(', ');
    const childrenLabel = childCount
      ? `Enfants: ${childCount}${childIdsMarkup ? ` (${childIdsMarkup})` : ''}`
      : childIdsMarkup
      ? `Enfants: ${childIdsMarkup}`
      : '';
    meta.innerHTML = [
      job.id ? `<span>ID: <code>${job.id}</code></span>` : null,
      parentId ? `<span>Parent: <code>${parentId}</code></span>` : null,
      childrenLabel ? `<span>${childrenLabel}</span>` : null,
      job.task ? `<span>Tâche: ${job.task}</span>` : null,
      job.result ? `<span>Résultat: ${job.result}</span>` : null,
      job.error ? `<span class="error">Erreur: ${job.error}</span>` : null,
      `<span>Créé: ${formatDate(job.created_at)}</span>`,
      `<span>Démarré: ${formatDate(job.started_at)}</span>`,
      `<span>Terminé: ${formatDate(job.finished_at)}</span>`,
    ]
      .filter(Boolean)
      .join('');
    li.append(header, meta);
    return li;
  };

  const compareJobs = (a, b) => {
    const queueA = (a.queue || '').toLowerCase();
    const queueB = (b.queue || '').toLowerCase();
    const queueCompare = queueA.localeCompare(queueB);
    if (queueCompare) return queueCompare;
    const createdA = a.created_at || '';
    const createdB = b.created_at || '';
    if (createdA && createdB && createdA !== createdB) {
      return createdA < createdB ? -1 : 1;
    }
    return (a.id || '').localeCompare(b.id || '');
  };

  const buildForest = (collection = []) => {
    if (!collection.length) {
      return [];
    }
    const nodeById = new Map();
    collection.forEach((job, index) => {
      const key = job.id || `__job_${index}`;
      nodeById.set(key, { job, children: [] });
    });
    const roots = [];
    nodeById.forEach((node) => {
      const parentId = node.job.parent_id;
      if (parentId && nodeById.has(parentId)) {
        nodeById.get(parentId).children.push(node);
      } else {
        roots.push(node);
      }
    });
    const buildTree = (node) => {
      node.children.sort((a, b) => compareJobs(a.job, b.job));
      const childIds = Array.isArray(node.job.children_ids) ? node.job.children_ids : [];
      const reportedChildren = childIds.length || node.job.children || 0;
      const element = buildItem(node.job, {
        childCount: node.children.length || reportedChildren,
        parentId: node.job.parent_id || null,
        childIds,
      });
      if (node.children.length) {
        const childList = document.createElement('ul');
        childList.className = 'job-children';
        childList.replaceChildren(...node.children.map(buildTree));
        element.appendChild(childList);
      }
      return element;
    };
    roots.sort((a, b) => compareJobs(a.job, b.job));
    return roots.map(buildTree);
  };

  if (runningList) {
    runningList.replaceChildren(...buildForest(running));
  }
  if (queuedList) {
    queuedList.replaceChildren(...buildForest(queued));
  }
  if (finishedList) {
    const sortedFinished = [...finished].sort(compareJobs);
    finishedList.replaceChildren(
      ...sortedFinished.map((job) =>
        buildItem(job, {
          childCount: Array.isArray(job.children_ids) ? job.children_ids.length : job.children || 0,
          parentId: job.parent_id || null,
          childIds: Array.isArray(job.children_ids) ? job.children_ids : [],
        })
      )
    );
  }

  if (queueContainer) {
    if (!queueSummary.length) {
      queueContainer.textContent = 'Aucune file active.';
    } else {
      const chips = queueSummary.map((entry) => {
        const span = document.createElement('span');
        span.className = 'queue-chip';
        const queueName = String(entry.queue || '');
        const label = queueName.trim() ? queueName : 'default';
        const runningCount = entry.running ?? 0;
        const queuedCount = entry.queued ?? 0;
        const finishedCount = entry.finished ?? 0;
        const description = `${label}: ${runningCount} en cours · ${queuedCount} en attente · ${finishedCount} terminés`;
        span.textContent = description;
        span.title = description;
        return span;
      });
      queueContainer.replaceChildren(...chips);
    }
  }
}

function updateLogFilter(logEntry) {
  const logContent = logEntry.querySelector('.log-content');
  const filterInput = logEntry.querySelector('.log-filter');
  if (!logContent || !filterInput) {
    return;
  }
  const logText = logEntry.dataset.logText || '';
  const fullLogText = logEntry.dataset.fullLogText || logText;
  const hint = logEntry.querySelector('.log-hint');
  const query = filterInput.value.trim().toLowerCase();
  if (!query) {
    if (logEntry.dataset.logName === 'medialibrarian_errors.log') {
      renderErrorBlocks(logEntry, logText);
    } else {
      logContent.textContent = logText || '—';
    }
    if (hint && logEntry.dataset.logTruncated === 'true') {
      hint.textContent = `Affichage des ${LOG_MAX_LINES.toLocaleString('fr-FR')} dernières lignes.`;
    }
    return;
  }
  const filtered = fullLogText
    .split('\n')
    .filter((line) => line.toLowerCase().includes(query))
    .join('\n');
  logContent.textContent = filtered || '—';
  if (hint) {
    hint.textContent = "Filtrage sur l'ensemble du log.";
  }
}

function renderErrorBlocks(logEntry, text) {
  const logContent = logEntry.querySelector('.log-content');
  if (!logContent) {
    return;
  }
  const refreshButton = document.getElementById('refresh-logs');
  const updateRefreshLabel = (hasOpen) => {
    if (!refreshButton) {
      return;
    }
    if (!refreshButton.dataset.defaultText) {
      refreshButton.dataset.defaultText = refreshButton.textContent;
    }
    refreshButton.textContent = hasOpen
      ? `${refreshButton.dataset.defaultText} (auto: pause)`
      : refreshButton.dataset.defaultText;
  };
  const openBlockTitles = new Set(
    Array.from(logContent.querySelectorAll('details.log-error[open]'))
      .map((details) => details.querySelector('.log-error-title')?.textContent || '')
      .filter(Boolean),
  );
  const lines = (text || '').split('\n');
  const blocks = [];
  let current = null;
  const extractErrorPrefix = (line) => {
    const match = line.match(/^(E, \[[^\]]+\] ERROR -- :)(.*)$/);
    if (!match) {
      return null;
    }
    return { prefix: match[1], message: match[2] || '' };
  };
  let previousPrefix = null;
  lines.forEach((line) => {
    const parsed = extractErrorPrefix(line);
    if (parsed) {
      const normalizedMessage = parsed.message.startsWith(' ')
        ? parsed.message.slice(1)
        : parsed.message;
      const isContinuation = Boolean(current)
        && (parsed.prefix === previousPrefix
          || /^\s/.test(normalizedMessage)
          || /^from\b/.test(normalizedMessage));
      if (!current || !isContinuation) {
        if (current) {
          blocks.push(current);
        }
        current = [line];
      } else {
        current.push(line);
      }
      previousPrefix = parsed.prefix;
      return;
    }
    if (current) {
      current.push(line);
    }
    previousPrefix = null;
  });
  if (current) {
    blocks.push(current);
  }
  if (!blocks.length) {
    logContent.textContent = text || '—';
    updateRefreshLabel(false);
    return;
  }
  let hasOpenBlock = false;
  const fragments = blocks.map((block) => {
    const details = document.createElement('details');
    details.className = 'log-error';
    const summary = document.createElement('summary');
    const summaryText = document.createElement('span');
    summaryText.className = 'log-error-title';
    summaryText.textContent = block[0];
    const actions = document.createElement('span');
    actions.className = 'log-actions';
    const copyButton = document.createElement('button');
    copyButton.type = 'button';
    copyButton.className = 'copy-error';
    copyButton.textContent = 'Copier';
    copyButton.addEventListener('click', async (event) => {
      event.preventDefault();
      event.stopPropagation();
      try {
        await navigator.clipboard.writeText(block.join('\n'));
        showNotification("Bloc d'erreur copié dans le presse-papiers.");
      } catch (error) {
        showNotification("Impossible de copier ce bloc d'erreur.", 'error');
      }
    });
    actions.appendChild(copyButton);
    summary.appendChild(summaryText);
    summary.appendChild(actions);
    summary.addEventListener('click', (event) => {
      event.preventDefault();
      event.stopPropagation();
      details.open = !details.open;
    });
    const body = document.createElement('pre');
    body.textContent = block.slice(1).join('\n');
    details.appendChild(summary);
    if (block.length > 1) {
      details.appendChild(body);
    }
    if (openBlockTitles.has(block[0])) {
      details.open = true;
      hasOpenBlock = true;
      stopAutoRefresh();
    }
    details.addEventListener('toggle', () => {
      if (details.open) {
        stopAutoRefresh();
      }
      updateRefreshLabel(Boolean(logContent.querySelector('details.log-error[open]')));
    });
    return details;
  });
  logContent.replaceChildren(...fragments);
  updateRefreshLabel(hasOpenBlock);
}

function renderLogs(logs = {}) {
  const container = document.getElementById('logs-container');
  const template = document.getElementById('log-entry-template');
  const existing = new Map(
    Array.from(container.children).map((entry) => [entry.dataset.logName, entry]),
  );

  Object.entries(logs).forEach(([name, content]) => {
    let logEntry = existing.get(name);
    if (!logEntry) {
      const fragment = template.content.cloneNode(true);
      logEntry = fragment.querySelector('.log-entry');
      logEntry.dataset.logName = name;
      fragment.querySelector('.log-name').textContent = name;
      fragment.querySelector('.log-filter')?.addEventListener('input', () => {
        updateLogFilter(logEntry);
      });
      fragment.querySelector('.copy-log').addEventListener('click', async () => {
        try {
          await navigator.clipboard.writeText(logEntry.dataset.fullLogText || logEntry.dataset.logText || '');
          showNotification(`Log « ${name} » copié dans le presse-papiers.`);
        } catch (error) {
          showNotification(`Impossible de copier le log « ${name} ».`, 'error');
        }
      });
      container.appendChild(fragment);
    }

    const fullLogText = content || '';
    const isErrorLog = name === 'medialibrarian_errors.log';
    const { text: displayContent, truncated } = isErrorLog
      ? { text: fullLogText, truncated: false }
      : getLogTail(fullLogText);
    logEntry.dataset.fullLogText = fullLogText;
    logEntry.dataset.logText = displayContent || '';
    logEntry.dataset.logTruncated = truncated ? 'true' : 'false';
    if (isErrorLog) {
      const query = logEntry.querySelector('.log-filter')?.value.trim();
      if (query) {
        updateLogFilter(logEntry);
      } else {
        renderErrorBlocks(logEntry, fullLogText);
      }
    } else {
      updateLogFilter(logEntry);
    }
    const logContent = logEntry.querySelector('.log-content');

    let hint = logEntry.querySelector('.log-hint');
    if (!isErrorLog && truncated) {
      if (!hint) {
        hint = document.createElement('p');
        hint.className = 'log-hint';
        logEntry.appendChild(hint);
      }
      hint.textContent = `Affichage des ${LOG_MAX_LINES.toLocaleString('fr-FR')} dernières lignes.`;
    } else if (hint) {
      hint.remove();
    }

    if (logContent) {
      logContent.scrollTop = logContent.scrollHeight;
    }
  });

  existing.forEach((entry, name) => {
    if (!Object.prototype.hasOwnProperty.call(logs, name)) {
      entry.remove();
    }
  });
}

function pickEntryValue(entry, keys) {
  if (!entry || typeof entry !== 'object') {
    return null;
  }
  return keys.map((key) => entry[key]).find((value) => value !== undefined && value !== null) ?? null;
}

function resolveImdbId(entry) {
  const clean = (value) => (value == null ? '' : String(value).trim());
  const ids = entry?.ids || {};
  const source = clean(pickEntryValue(entry, ['source'])).toLowerCase();
  return clean(ids.imdb)
    || clean(ids.imdb_id)
    || clean(pickEntryValue(entry, ['imdb_id', 'imdb']))
    || (source === 'imdb' ? clean(pickEntryValue(entry, ['external_id'])) : '');
}

function resolveExternalUrl(entry) {
  const clean = (value) => (value == null ? '' : String(value).trim());
  const ids = entry?.ids || {};
  const mediaType = (pickEntryValue(entry, ['media_type', 'type', 'kind', 'category']) || '').toString().toLowerCase();
  const isShow = /tv|show|serie/.test(mediaType);

  const imdbId = resolveImdbId(entry);
  if (imdbId) {
    return `https://www.imdb.com/title/${imdbId}`;
  }

  const tmdbId = clean(ids.tmdb) || clean(pickEntryValue(entry, ['tmdb_id', 'tmdb']));
  if (tmdbId) {
    return `https://www.themoviedb.org/${isShow ? 'tv' : 'movie'}/${tmdbId}`;
  }

  const traktId = clean(ids.trakt) || clean(pickEntryValue(entry, ['trakt_id', 'trakt']));
  if (traktId) {
    return `https://trakt.tv/${isShow ? 'shows' : 'movies'}/${traktId}`;
  }

  return '';
}

function normalizeCalendarEntries(data = {}) {
  if (Array.isArray(data)) {
    return data;
  }
  const candidates = [data.entries, data.items, data.results, data.calendar];
  const entries = candidates.find(Array.isArray);
  return Array.isArray(entries) ? entries : [];
}

function extractGenres(entry) {
  const raw = pickEntryValue(entry, ['genres', 'genre', 'tags', 'categories']);
  if (!raw) {
    return [];
  }
  const normalized = Array.isArray(raw) ? raw : String(raw).split(/[,;]/);
  return normalized
    .map((value) => String(value || '').trim())
    .filter(Boolean)
    .map((value) => value.toLowerCase())
    .filter(Boolean);
}

function collectGenres(entries = []) {
  const set = new Set();
  entries.forEach((entry) => {
    extractGenres(entry).forEach((genre) => set.add(genre));
  });
  return Array.from(set).sort((a, b) => a.localeCompare(b));
}

function resolveCalendarDate(entry) {
  const raw = pickEntryValue(entry, [
    'date',
    'release_date',
    'air_date',
    'airing_at',
    'first_aired',
    'on',
  ]);
  if (!raw) {
    return null;
  }
  const date = new Date(raw);
  return Number.isNaN(date.getTime()) ? null : date;
}

function updateCalendarGenres() {
  const select = document.getElementById('calendar-genres');
  if (!select) {
    return;
  }
  const previous = new Set(state.calendar.filters.genres);
  const available = state.calendar.availableGenres || [];
  if (!available.length) {
    select.innerHTML = '';
    const option = document.createElement('option');
    option.disabled = true;
    option.value = '';
    option.textContent = 'Aucun genre détecté';
    select.appendChild(option);
    return;
  }
  select.innerHTML = '';
  available.forEach((genre) => {
    const option = document.createElement('option');
    option.value = genre;
    option.textContent = genre;
    option.selected = previous.has(genre);
    select.appendChild(option);
  });
}

function readCalendarFilters() {
  const filters = state.calendar.filters;
  const viewSelect = document.getElementById('calendar-view');
  state.calendar.view = viewSelect?.value || 'week';

  filters.title = (document.getElementById('calendar-title-filter')?.value || '').trim().toLowerCase();
  filters.type = (document.getElementById('calendar-type')?.value || '').toLowerCase();
  const genreSelect = document.getElementById('calendar-genres');
  filters.genres = genreSelect
    ? Array.from(genreSelect.selectedOptions)
        .map((option) => option.value)
        .filter(Boolean)
    : [];

  const ratingMinRaw = document.getElementById('calendar-rating-min')?.value || '';
  const ratingMaxRaw = document.getElementById('calendar-rating-max')?.value || '';
  const ratingMin = ratingMinRaw === '' ? '' : Number(ratingMinRaw);
  const ratingMax = ratingMaxRaw === '' ? '' : Number(ratingMaxRaw);
  filters.ratingMin = Number.isFinite(ratingMin) ? ratingMin : '';
  filters.ratingMax = Number.isFinite(ratingMax) ? ratingMax : '';

  const votesMinRaw = document.getElementById('calendar-votes-min')?.value || '';
  const votesMaxRaw = document.getElementById('calendar-votes-max')?.value || '';
  const votesMin = votesMinRaw === '' ? '' : Number(votesMinRaw);
  const votesMax = votesMaxRaw === '' ? '' : Number(votesMaxRaw);
  filters.votesMin = Number.isFinite(votesMin) ? votesMin : '';
  filters.votesMax = Number.isFinite(votesMax) ? votesMax : '';

  filters.language = (document.getElementById('calendar-language')?.value || '').trim();
  filters.country = (document.getElementById('calendar-country')?.value || '').trim();
  return filters;
}

function resolveCalendarWindow(options = {}) {
  const view = state.calendar.view || 'week';
  if (!calendarWindow) {
    return null;
  }
  if (options.resetWindow) {
    return calendarWindow.reset(view);
  }
  if (options.startDate) {
    return calendarWindow.setStart(view, options.startDate);
  }
  if (options.offsetDelta) {
    return calendarWindow.shift(view, options.offsetDelta);
  }
  return calendarWindow.current(view);
}

function formatCalendarDate(date) {
  if (!date) {
    return '';
  }
  const year = date.getFullYear();
  const month = `${date.getMonth() + 1}`.padStart(2, '0');
  const day = `${date.getDate()}`.padStart(2, '0');
  return `${year}-${month}-${day}`;
}

function updateCalendarWindowDisplay(range) {
  if (!range) {
    return;
  }
  const label = document.getElementById('calendar-window-label');
  if (label) {
    const formatter = new Intl.DateTimeFormat('fr-FR', {
      day: 'numeric',
      month: 'short',
      year: 'numeric',
    });
    label.textContent = `${formatter.format(range.start)} – ${formatter.format(range.end)}`;
  }
  const startInput = document.getElementById('calendar-start-date');
  if (startInput) {
    startInput.value = formatCalendarDate(range.start);
  }
}

function entryMatchesFilters(entry, filters) {
  const title = (pickEntryValue(entry, ['title', 'name']) || '').toString().toLowerCase();
  if (filters.title && !title.includes(filters.title)) {
    return false;
  }

  const type = (pickEntryValue(entry, ['type', 'kind', 'category']) || '').toString().toLowerCase();
  if (filters.type && filters.type !== type) {
    return false;
  }

  if (filters.genres.length) {
    const genres = extractGenres(entry);
    const matches = filters.genres.some((genre) => genres.includes(genre));
    if (!matches) {
      return false;
    }
  }

  const rating = Number(pickEntryValue(entry, ['imdb_rating', 'rating', 'score']));
  if (filters.ratingMin !== '' && !Number.isFinite(rating)) {
    return false;
  }
  if (filters.ratingMin !== '' && rating < filters.ratingMin) {
    return false;
  }
  if (filters.ratingMax !== '' && !Number.isFinite(rating)) {
    return false;
  }
  if (filters.ratingMax !== '' && rating > filters.ratingMax) {
    return false;
  }

  const votes = Number(pickEntryValue(entry, ['imdb_votes', 'votes', 'vote_count']));
  if (filters.votesMin !== '' && (!Number.isFinite(votes) || votes < filters.votesMin)) {
    return false;
  }
  if (filters.votesMax !== '' && (!Number.isFinite(votes) || votes > filters.votesMax)) {
    return false;
  }

  const language = (pickEntryValue(entry, ['language', 'lang', 'original_language']) || '').toString().toLowerCase();
  if (filters.language && !language.includes(filters.language.toLowerCase())) {
    return false;
  }

  const countryRaw = pickEntryValue(entry, ['country', 'origin_country', 'production_country']);
  const countries = Array.isArray(countryRaw)
    ? countryRaw.map((value) => String(value || '').toLowerCase())
    : String(countryRaw || '').toLowerCase();
  if (filters.country && !countries.toString().includes(filters.country.toLowerCase())) {
    return false;
  }

  return true;
}

function buildCalendarGroups(entries, view) {
  const currentYear = new Date().getFullYear();
  const groups = new Map();
  const startOfWeek = (date) => {
    const copy = new Date(date);
    const weekday = (copy.getDay() + 6) % 7;
    copy.setHours(0, 0, 0, 0);
    copy.setDate(copy.getDate() - weekday);
    return copy;
  };

  entries.forEach((entry) => {
    const date = resolveCalendarDate(entry);
    const key = date
      ? view === 'month'
        ? `${date.getFullYear()}-${date.getMonth()}`
        : startOfWeek(date).toISOString()
      : 'no-date';
    if (!groups.has(key)) {
      const label = (() => {
        if (!date) return 'Sans date';
        if (view === 'month') {
          const options = { month: 'long' };
          if (date.getFullYear() !== currentYear) {
            options.year = 'numeric';
          }
          return new Intl.DateTimeFormat('fr-FR', options).format(date);
        }
        const start = startOfWeek(date);
        const end = new Date(start);
        end.setDate(start.getDate() + 6);
        const showYear =
          start.getFullYear() !== currentYear ||
          end.getFullYear() !== currentYear ||
          start.getFullYear() !== end.getFullYear();
        const format = (value) =>
          new Intl.DateTimeFormat('fr-FR', {
            day: 'numeric',
            month: 'short',
            ...(showYear ? { year: 'numeric' } : {}),
          }).format(value);
        return `Semaine du ${format(start)} au ${format(end)}`;
      })();
      groups.set(key, { label, sortKey: date ? date.getTime() : Number.POSITIVE_INFINITY, items: [] });
    }
    groups.get(key).items.push({ entry, date });
  });

  return Array.from(groups.values()).sort((a, b) => a.sortKey - b.sortKey);
}

function buildCalendarEntryCard(entry, date = resolveCalendarDate(entry)) {
  const item = document.createElement('article');
  item.className = 'calendar-item';

  const downloaded = isDownloaded(entry);
  if (downloaded) {
    item.classList.add('calendar-item--downloaded');
  }

  const titleText = pickEntryValue(entry, ['title', 'name']) || 'Titre inconnu';
  const mediaUrl = pickEntryValue(entry, ['poster_url', 'poster', 'backdrop_url', 'backdrop']);
  const media = document.createElement('div');
  media.className = 'calendar-media';
  if (mediaUrl) {
    const img = document.createElement('img');
    img.loading = 'lazy';
    img.src = mediaUrl;
    img.alt = `${titleText} - visuel`;
    media.appendChild(img);
  } else {
    const placeholder = document.createElement('div');
    placeholder.className = 'calendar-media-fallback';
    placeholder.textContent = titleText.charAt(0) || '?';
    media.appendChild(placeholder);
  }

  const body = document.createElement('div');
  body.className = 'calendar-body';

  const header = document.createElement('header');
  const externalUrl = resolveExternalUrl(entry);
  const titleEl = document.createElement('h4');
  if (externalUrl) {
    const link = document.createElement('a');
    link.href = externalUrl;
    link.target = '_blank';
    link.rel = 'noopener noreferrer';
    link.textContent = titleText;
    titleEl.appendChild(link);
  } else {
    titleEl.textContent = titleText;
  }
  const dateLabel = document.createElement('span');
  dateLabel.className = 'calendar-meta';
  if (!date) {
    dateLabel.textContent = 'Date inconnue';
  } else {
    const options = {
      weekday: 'short',
      day: 'numeric',
      month: 'short',
    };
    if (date.getFullYear() !== new Date().getFullYear()) {
      options.year = 'numeric';
    }
    dateLabel.textContent = new Intl.DateTimeFormat('fr-FR', options).format(date);
  }
  header.append(titleEl, dateLabel);
  body.appendChild(header);

  const synopsisText = (() => {
    const rawSynopsis = pickEntryValue(entry, ['synopsis', 'overview', 'summary', 'description', 'plot']);
    return rawSynopsis == null ? '' : String(rawSynopsis).trim();
  })();
  if (synopsisText) {
    const synopsisEl = document.createElement('p');
    synopsisEl.className = 'calendar-synopsis';
    synopsisEl.textContent = synopsisText;
    body.appendChild(synopsisEl);
  }

  const badges = document.createElement('div');
  badges.className = 'calendar-badges';
  const type = pickEntryValue(entry, ['type', 'kind', 'category']);
  if (type) {
    badges.appendChild(makeCalendarBadge(type));
  }
  const rating = pickEntryValue(entry, ['imdb_rating', 'rating', 'score']);
  if (rating !== undefined && rating !== null && rating !== '') {
    badges.appendChild(makeCalendarBadge(`IMDb ${rating}`));
  }
  const votes = resolveVoteCount(entry);
  if (votes !== null) {
    badges.appendChild(makeCalendarBadge(`${formatVoteCount(votes)} votes`));
  }
  const genres = extractGenres(entry);
  if (genres.length) {
    badges.appendChild(makeCalendarBadge(genres.slice(0, 3).join(', ')));
  }
  if (downloaded) {
    const badge = makeCalendarBadge('Téléchargé');
    badge.classList.add('calendar-badge--success');
    badges.appendChild(badge);
  }
  const inWatchlist = isInWatchlist(entry);
  if (inWatchlist) {
    badges.appendChild(makeCalendarBadge("Dans la liste d’intérêt"));
  }
  if (badges.childElementCount) {
    body.appendChild(badges);
  }

  const metaSegments = [];
  const language = pickEntryValue(entry, ['language', 'lang', 'original_language']);
  const country = pickEntryValue(entry, ['country', 'origin_country', 'production_country']);
  if (language) {
    metaSegments.push(`Langue: ${language}`);
  }
  if (country) {
    metaSegments.push(`Pays: ${country}`);
  }
  if (metaSegments.length) {
    const meta = document.createElement('div');
    meta.className = 'calendar-meta';
    meta.textContent = metaSegments.join(' · ');
    body.appendChild(meta);
  }

  if (!inWatchlist && !downloaded) {
    const actions = document.createElement('div');
    actions.className = 'calendar-actions-row';
    const button = document.createElement('button');
    button.type = 'button';
    button.textContent = 'Ajouter à la liste d’intérêt';
    button.addEventListener('click', () => addToWatchlist(entry, button));
    actions.appendChild(button);
    body.appendChild(actions);
  }

  item.append(media, body);
  return item;
}

function buildCalendarSearchCard(entry) {
  const item = document.createElement('article');
  item.className = 'calendar-item calendar-search-item';

  const body = document.createElement('div');
  body.className = 'calendar-body';
  const header = document.createElement('header');
  const title = document.createElement('h4');
  title.textContent = pickEntryValue(entry, ['title', 'name']) || 'Titre inconnu';
  header.appendChild(title);

  const year = pickEntryValue(entry, ['year', 'release_year']) || resolveCalendarDate(entry)?.getFullYear();
  if (year) {
    const yearLabel = document.createElement('span');
    yearLabel.className = 'calendar-search-year';
    yearLabel.textContent = String(year);
    header.appendChild(yearLabel);
  }
  body.appendChild(header);

  const synopsis = pickEntryValue(entry, ['synopsis', 'overview', 'summary', 'description', 'plot']);
  if (synopsis) {
    const description = document.createElement('p');
    description.className = 'calendar-synopsis';
    description.textContent = synopsis;
    body.appendChild(description);
  }

  const actions = document.createElement('div');
  actions.className = 'calendar-search-actions';
  const importButton = document.createElement('button');
  importButton.type = 'button';
  importButton.textContent = 'Importer dans le calendrier';
  importButton.addEventListener('click', () => importCalendarEntry(entry, importButton));
  const watchlistButton = document.createElement('button');
  watchlistButton.type = 'button';
  watchlistButton.textContent = "Ajouter à la liste d’intérêt";
  watchlistButton.addEventListener('click', () => addToWatchlist(entry, watchlistButton));
  actions.append(importButton, watchlistButton);
  body.appendChild(actions);

  item.appendChild(body);
  return item;
}

function makeCalendarBadge(text) {
  const span = document.createElement('span');
  span.className = 'calendar-badge';
  span.textContent = text;
  return span;
}

function formatVoteCount(value) {
  if (!Number.isFinite(value)) {
    return '';
  }
  if (value < 1000) {
    return new Intl.NumberFormat('fr-FR').format(Math.round(value));
  }
  return new Intl.NumberFormat('fr-FR', { notation: 'compact', maximumFractionDigits: 1 }).format(value);
}

function resolveVoteCount(entry) {
  const votes = Number(pickEntryValue(entry, ['imdb_votes', 'votes', 'vote_count']));
  return Number.isFinite(votes) && votes >= 0 ? votes : null;
}

function resolveIdentifier(entry) {
  const ids = entry && typeof entry === 'object' && entry.ids && typeof entry.ids === 'object' ? entry.ids : {};
  return [
    pickEntryValue(entry, ['external_id']),
    pickEntryValue(ids, ['external_id', 'slug', 'id']),
    pickEntryValue(entry, ['id', 'slug', 'imdb_id', 'tmdb_id', 'tvdb_id', 'trakt_id']),
    pickEntryValue(ids, ['imdb', 'imdb_id', 'tmdb', 'tmdb_id', 'tvdb', 'tvdb_id', 'trakt', 'trakt_id']),
    pickEntryValue(entry, ['title', 'name']),
  ].find(Boolean) || null;
}

function isDownloaded(entry) {
  const downloaded = pickEntryValue(entry, ['downloaded']);
  if (downloaded !== undefined && downloaded !== null) {
    return Boolean(downloaded);
  }
  const flag = pickEntryValue(entry, ['is_downloaded', 'download_status', 'status']);
  if (typeof flag === 'string') {
    return flag.toLowerCase().includes('download');
  }
  return Boolean(flag);
}

function isInWatchlist(entry) {
  const flag = pickEntryValue(entry, [
    'in_watchlist',
    'watchlist',
    'on_watchlist',
    'listed',
    'in_interest_list',
  ]);
  if (typeof flag === 'string') {
    const normalized = flag.toLowerCase();
    return normalized.includes('watch') || normalized.includes('interest');
  }
  return Boolean(flag);
}

function buildCalendarImportPayload(entry, options = {}) {
  const imdbId = resolveImdbId(entry);
  const title = (pickEntryValue(entry, ['title', 'name']) || '').toString().trim();
  const type = (pickEntryValue(entry, ['media_type', 'type', 'kind', 'category']) || '').toString().toLowerCase();
  if (!imdbId || !title || !type) {
    return null;
  }

  const ids = { ...(entry?.ids || {}) };
  ['imdb', 'imdb_id', 'tmdb', 'tmdb_id', 'tvdb', 'tvdb_id', 'trakt', 'trakt_id'].forEach((key) => {
    const value = pickEntryValue(entry, [key]);
    if (value) {
      ids[key] = value;
    }
  });
  const cleanIds = Object.fromEntries(Object.entries(ids).filter(([, value]) => value));

  const payload = {
    imdb_id: imdbId,
    title,
    type,
  };
  if (Object.keys(cleanIds).length) {
    payload.ids = cleanIds;
  }

  const releaseDate = resolveCalendarDate(entry);
  if (releaseDate instanceof Date && !Number.isNaN(releaseDate.getTime())) {
    payload.release_date = releaseDate.toISOString();
  }
  const synopsis = pickEntryValue(entry, ['synopsis', 'overview', 'summary', 'description', 'plot']);
  if (synopsis) {
    payload.synopsis = synopsis;
  }
  const poster = pickEntryValue(entry, ['poster', 'poster_url']);
  if (poster) {
    payload.poster = poster;
  }
  const backdrop = pickEntryValue(entry, ['backdrop', 'backdrop_url']);
  if (backdrop) {
    payload.backdrop = backdrop;
  }
  const rating = pickEntryValue(entry, ['imdb_rating', 'rating', 'score']);
  if (rating !== null && rating !== undefined && rating !== '') {
    payload.rating = rating;
  }
  const votes = pickEntryValue(entry, ['imdb_votes', 'votes', 'vote_count']);
  if (votes !== null && votes !== undefined && votes !== '') {
    payload.imdb_votes = votes;
  }
  const externalId = pickEntryValue(entry, ['external_id', 'id', 'slug']);
  if (externalId) {
    payload.external_id = externalId;
  }
  const source = pickEntryValue(entry, ['source']);
  if (source) {
    payload.source = source;
  }
  if (options.watchlist) {
    payload.watchlist = true;
  }
  return payload;
}

async function submitCalendarImport(entry, button, options = {}) {
  if (!state.authenticated) {
    return;
  }
  const payload = buildCalendarImportPayload(entry, options);
  if (!payload) {
    showNotification(options.errorMessage || "Impossible d'importer cet élément.", 'error');
    return;
  }
  const originalLabel = button?.textContent;
  if (button) {
    button.disabled = true;
  }
  try {
    await fetchJson('/calendar/import', {
      method: 'POST',
      headers: new Headers({ 'Content-Type': 'application/json' }),
      body: JSON.stringify(payload),
    });
    if (options.watchlist) {
      entry.in_watchlist = true;
      entry.watchlist = true;
      entry.in_interest_list = true;
      if (Array.isArray(state.calendar.entries)) {
        state.calendar.entries = state.calendar.entries.map((item) => (item === entry ? entry : item));
      }
    }
    showNotification(options.successMessage || 'Ajouté au calendrier.');
    if (button && options.buttonText) {
      button.textContent = options.buttonText;
    }
    await loadCalendar({ preserveFilters: true });
  } catch (error) {
    showNotification(error.message || options.errorMessage || "Impossible d'importer cet élément.", 'error');
    if (button) {
      button.disabled = false;
      button.textContent = originalLabel || button.textContent;
    }
  }
}

async function importCalendarEntry(entry, button) {
  return submitCalendarImport(entry, button, {
    successMessage: 'Ajouté au calendrier.',
    buttonText: 'Importé',
    errorMessage: "Impossible d'importer cet élément.",
  });
}

async function addToWatchlist(entry, button) {
  return submitCalendarImport(entry, button, {
    watchlist: true,
    successMessage: 'Ajouté à la liste d’intérêt.',
    buttonText: 'Ajouté à la liste d’intérêt',
    errorMessage: "Impossible d'ajouter cet élément.",
  });
}

function renderCalendar(data = null) {
  const container = document.getElementById('calendar-content');
  if (!container) {
    return;
  }
  const entries = normalizeCalendarEntries(data ?? state.calendar.entries ?? []);
  state.calendar.entries = entries;
  updateCalendarGenres();
  const filters = readCalendarFilters();
  const filtered = entries.filter((entry) => entryMatchesFilters(entry, filters));
  if (!filtered.length) {
    container.innerHTML = '<p class="hint">Aucune sortie ne correspond aux filtres.</p>';
    return;
  }

  const groups = buildCalendarGroups(filtered, state.calendar.view);
  const fragments = groups.map((group) => {
    const wrapper = document.createElement('article');
    wrapper.className = 'calendar-group';
    const title = document.createElement('h3');
    title.textContent = group.label;
    wrapper.appendChild(title);

    const list = document.createElement('div');
    list.className = 'calendar-items';
    group.items
      .sort((a, b) => (a.date?.getTime() || 0) - (b.date?.getTime() || 0))
      .forEach(({ entry, date }) => {
        list.appendChild(buildCalendarEntryCard(entry, date));
      });

    wrapper.appendChild(list);
    return wrapper;
  });

  container.replaceChildren(...fragments);
}

function renderCalendarSearchResults(data = null) {
  const container = document.getElementById('calendar-search-results');
  if (!container) {
    return;
  }
  const entries = normalizeCalendarEntries(data ?? state.calendarSearch.results ?? []);
  state.calendarSearch.results = entries;
  if (!entries.length) {
    container.innerHTML = '<p class="hint">Aucun résultat.</p>';
    return;
  }
  const cards = entries.map((entry) => buildCalendarSearchCard(entry));
  container.replaceChildren(...cards);
}

async function loadCalendarGenres() {
  if (!state.authenticated || state.calendar.loadingGenres) {
    return;
  }
  state.calendar.loadingGenres = true;
  try {
    const data = await fetchJson('/calendar');
    const entries = normalizeCalendarEntries(data || []);
    state.calendar.availableGenres = collectGenres(entries);
    updateCalendarGenres();
  } catch (error) {
    if (state.authenticated) {
      showNotification(error.message, 'error');
    }
  } finally {
    state.calendar.loadingGenres = false;
  }
}

async function loadCalendar(options = {}) {
  if (!state.authenticated) {
    return;
  }
  const needsGenres = options.refreshGenres
    || (!state.calendar.availableGenres.length && !state.calendar.loadingGenres);
  if (needsGenres) {
    loadCalendarGenres();
  }
  const filters = readCalendarFilters();
  const range = resolveCalendarWindow(options);
  updateCalendarWindowDisplay(range);
  const search = new URLSearchParams();
  if (filters.type) search.set('type', filters.type);
  if (filters.genres.length) search.set('genres', filters.genres.join(','));
  if (filters.ratingMin !== '') search.set('imdb_min', filters.ratingMin);
  if (filters.ratingMax !== '') search.set('imdb_max', filters.ratingMax);
  if (filters.votesMin !== '') search.set('imdb_votes_min', filters.votesMin);
  if (filters.votesMax !== '') search.set('imdb_votes_max', filters.votesMax);
  if (filters.language) search.set('language', filters.language);
  if (filters.country) search.set('country', filters.country);
  if (filters.title) search.set('title', filters.title);
  if (range) {
    search.set('start_date', formatCalendarDate(range.start));
    search.set('end_date', formatCalendarDate(range.end));
    search.set('window', range.days);
    search.set('offset', range.offset);
  }
  const path = `/calendar${search.toString() ? `?${search.toString()}` : ''}`;
  try {
    const data = await fetchJson(path);
    renderCalendar(data || {});
  } catch (error) {
    if (state.authenticated) {
      showNotification(error.message, 'error');
    }
  }
}

async function loadCalendarSearch(query) {
  if (!state.authenticated || state.calendarSearch.loading) {
    return;
  }
  const input = document.getElementById('calendar-search-query');
  const normalized = (query ?? input?.value ?? state.calendarSearch.query ?? '').toString().trim();
  state.calendarSearch.query = normalized;
  if (
    normalized
    && normalized === state.calendarSearch.lastLoadedQuery
    && state.calendarSearch.results.length
  ) {
    return;
  }
  if (input && input.value !== normalized) {
    input.value = normalized;
  }
  const container = document.getElementById('calendar-search-results');
  if (!normalized) {
    state.calendarSearch.results = [];
    if (container) {
      container.innerHTML = '<p class="hint">Entrez une recherche pour démarrer.</p>';
    }
    return;
  }
  if (container) {
    container.innerHTML = '<p class="hint">Recherche en cours…</p>';
  }
  state.calendarSearch.loading = true;
  try {
    const search = new URLSearchParams({ title: normalized });
    const data = await fetchJson(`/calendar/search?${search.toString()}`);
    renderCalendarSearchResults(data);
    state.calendarSearch.lastLoadedQuery = normalized;
  } catch (error) {
    if (state.authenticated) {
      showNotification(error.message, 'error');
    }
    if (container) {
      container.innerHTML = '<p class="hint">Recherche indisponible.</p>';
    }
  } finally {
    state.calendarSearch.loading = false;
  }
}

async function refreshCalendarFeed() {
  try {
    await fetchJson('/calendar/refresh', { method: 'POST' });
    showNotification('Flux calendrier rafraîchi.');
  } catch (error) {
    showNotification(error.message || 'Impossible de rafraîchir le flux calendrier.', 'error');
  } finally {
    loadCalendar({ preserveFilters: true, refreshGenres: true });
  }
}

function resolveCollectionSort(value) {
  if (value === 'year' || value === 'title') {
    return value;
  }
  return 'released_at';
}

function resolveCollectionSortOption(sort) {
  return sort === 'released_at' ? 'date' : sort;
}

function resolveCollectionType(value) {
  const type = value?.toString().trim();
  return ['movie', 'show', 'all', 'unmatched'].includes(type) ? type : '';
}

function normalizeFileEntries(files) {
  return (Array.isArray(files) ? files : [])
    .map((file) => (file == null ? '' : String(file).trim()))
    .filter(Boolean);
}

function buildFileList(files) {
  const normalized = normalizeFileEntries(files);
  if (!normalized.length) {
    return null;
  }
  const list = document.createElement('ul');
  list.className = 'file-list';
  normalized.forEach((file) => {
    const item = document.createElement('li');
    item.textContent = file;
    list.appendChild(item);
  });
  return list;
}

function buildFileAccordion(files, label = 'Fichiers') {
  const list = buildFileList(files);
  if (!list) {
    return null;
  }
  const details = document.createElement('details');
  details.className = 'collection-files';
  const summary = document.createElement('summary');
  summary.textContent = `${label} (${list.childElementCount})`;
  details.append(summary, list);
  return details;
}

function closeCollectionModal() {
  const modal = document.getElementById('collection-modal');
  if (modal) {
    modal.classList.add('hidden');
  }
}

function buildSeasonHierarchy(entry) {
  const wrapper = document.createElement('div');
  const seasons = Array.isArray(entry?.seasons) ? entry.seasons : [];
  if (!seasons.length) {
    const hint = document.createElement('p');
    hint.className = 'hint';
    hint.textContent = 'Aucune saison détectée.';
    wrapper.appendChild(hint);
    return wrapper;
  }

  seasons.forEach((seasonEntry) => {
    const block = document.createElement('details');
    block.className = 'season-block';
    block.open = true;
    const summary = document.createElement('summary');
    const episodeCount = Array.isArray(seasonEntry?.episodes) ? seasonEntry.episodes.length : 0;
    summary.textContent = `Saison ${seasonEntry?.season ?? '?'} (${episodeCount} ép.)`;
    block.appendChild(summary);

    const episodeList = document.createElement('ul');
    episodeList.className = 'episode-list';
    (seasonEntry?.episodes || []).forEach((episode) => {
      const episodeItem = document.createElement('li');
      const label = document.createElement('div');
      const fileCount = normalizeFileEntries(episode?.files).length;
      label.textContent = `Épisode ${episode?.episode ?? '?'}${fileCount ? ` • ${fileCount} fichier(s)` : ''}`;
      episodeItem.appendChild(label);
      const files = buildFileList(episode?.files);
      if (files) {
        episodeItem.appendChild(files);
      }
      episodeList.appendChild(episodeItem);
    });

    block.appendChild(episodeList);
    wrapper.appendChild(block);
  });

  return wrapper;
}

function openCollectionModal(entry, titleText) {
  const modal = document.getElementById('collection-modal');
  const body = document.getElementById('collection-modal-body');
  const title = document.getElementById('collection-modal-title');
  if (!modal || !body || !title) {
    return;
  }
  const content = buildSeasonHierarchy(entry);
  body.replaceChildren(content);
  title.textContent = titleText || 'Saisons';
  modal.classList.remove('hidden');
}

function renderCollectionCard(entry) {
  const item = document.createElement('li');
  item.className = 'calendar-item';

  const media = document.createElement('div');
  media.className = 'calendar-media';
  const posterUrl = pickEntryValue(entry, ['poster_url', 'poster', 'backdrop_url', 'backdrop']);
  const titleText = pickEntryValue(entry, ['title', 'name']) || 'Titre inconnu';
  if (posterUrl) {
    const img = document.createElement('img');
    img.loading = 'lazy';
    img.src = posterUrl;
    img.alt = `${titleText} - visuel`;
    media.appendChild(img);
  } else {
    const placeholder = document.createElement('div');
    placeholder.className = 'calendar-media-fallback';
    placeholder.textContent = titleText.charAt(0) || '?';
    media.appendChild(placeholder);
  }

  const body = document.createElement('div');
  body.className = 'calendar-body';

  const header = document.createElement('header');
  const externalUrl = resolveExternalUrl(entry);
  const titleEl = document.createElement('h4');
  if (externalUrl) {
    const link = document.createElement('a');
    link.href = externalUrl;
    link.target = '_blank';
    link.rel = 'noopener noreferrer';
    link.textContent = titleText;
    titleEl.appendChild(link);
  } else {
    titleEl.textContent = titleText;
  }
  const releaseDate = (() => {
    const date = entry.released_at ? new Date(entry.released_at) : null;
    return date instanceof Date && !Number.isNaN(date.getTime()) ? date : null;
  })();
  const addedAt = (() => {
    const date = entry.created_at ? new Date(entry.created_at) : null;
    return date instanceof Date && !Number.isNaN(date.getTime()) ? date : null;
  })();
  const metaLabel = document.createElement('span');
  metaLabel.className = 'calendar-meta';
  metaLabel.textContent = releaseDate?.getFullYear()
    || entry.year
    || (addedAt ? new Intl.DateTimeFormat('fr-FR', { dateStyle: 'medium' }).format(addedAt) : 'Date inconnue');
  header.append(titleEl, metaLabel);
  body.appendChild(header);

  const synopsisText = (() => {
    const rawSynopsis = pickEntryValue(entry, ['synopsis', 'overview', 'summary', 'description', 'plot']);
    return rawSynopsis == null ? '' : String(rawSynopsis).trim();
  })();
  if (synopsisText) {
    const synopsis = document.createElement('p');
    synopsis.className = 'calendar-synopsis';
    synopsis.textContent = synopsisText;
    body.appendChild(synopsis);
  }

  if (addedAt) {
    const addedLabel = document.createElement('div');
    addedLabel.className = 'calendar-meta';
    addedLabel.textContent = `Ajouté le ${new Intl.DateTimeFormat('fr-FR', { dateStyle: 'medium' }).format(addedAt)}`;
    body.appendChild(addedLabel);
  }

  const files = buildFileAccordion(entry.files, 'Fichiers');
  if (files) {
    body.appendChild(files);
  }

  if (entry.media_type === 'show') {
    const seasons = Array.isArray(entry.seasons) ? entry.seasons : [];
    const seasonButton = document.createElement('button');
    seasonButton.type = 'button';
    seasonButton.textContent = 'Saisons / épisodes';
    seasonButton.disabled = !seasons.length;
    seasonButton.addEventListener('click', () => openCollectionModal(entry, titleText));
    body.appendChild(seasonButton);
  }

  item.append(media, body);
  return item;
}

function renderCollectionPagination() {
  const pageLabel = document.getElementById('collection-page');
  const prev = document.getElementById('collection-prev');
  const next = document.getElementById('collection-next');
  const perPage = state.collection.perPage || 1;
  const totalPages = Math.max(1, Math.ceil((state.collection.total || 0) / perPage));
  const currentPage = Math.min(Math.max(state.collection.page || 1, 1), totalPages);

  if (pageLabel) {
    pageLabel.textContent = totalPages > 1 ? `Page ${currentPage} / ${totalPages}` : `Page ${currentPage}`;
  }
  if (prev) {
    prev.disabled = state.collection.loading || currentPage <= 1;
  }
  if (next) {
    next.disabled = state.collection.loading || currentPage >= totalPages;
  }
}

function renderCollection(data = null) {
  const container = document.getElementById('collection-content');
  if (!container) {
    return;
  }

  if (data) {
    state.collection.entries = Array.isArray(data.entries) ? data.entries : [];
    const pagination = data.pagination || {};
    state.collection.page = pagination.page ?? state.collection.page ?? 1;
    state.collection.perPage = pagination.per_page ?? state.collection.perPage ?? 50;
    state.collection.total = pagination.total ?? state.collection.total ?? 0;
    state.collection.sort = resolveCollectionSort(data.sort ?? state.collection.sort);
    state.collection.type = resolveCollectionType(data.type ?? state.collection.type);
  }

  const typeSelect = document.getElementById('collection-type');
  if (typeSelect && typeSelect.value !== state.collection.type) {
    typeSelect.value = state.collection.type;
  }

  const entries = state.collection.entries || [];
  if (!entries.length) {
    container.innerHTML = '<p class="hint">Aucun média dans la collection.</p>';
    renderCollectionPagination();
    return;
  }

  const list = document.createElement('ol');
  list.className = 'calendar-items collection-list';
  entries.forEach((entry) => list.appendChild(renderCollectionCard(entry)));
  container.replaceChildren(list);
  renderCollectionPagination();
}

async function loadCollection(options = {}) {
  if (!state.authenticated) {
    return;
  }

  const sortInput = options.sort ?? document.getElementById('collection-sort')?.value ?? state.collection.sort;
  const sort = resolveCollectionSort(sortInput);
  const typeSelect = document.getElementById('collection-type');
  const typeInput = options.type ?? typeSelect?.value ?? state.collection.type;
  const type = resolveCollectionType(typeInput);
  const page = Math.max(1, options.page ?? state.collection.page ?? 1);
  const perPage = Math.max(1, options.perPage ?? state.collection.perPage ?? 50);
  const searchInput = document.getElementById('collection-search');
  const rawSearch = options.search ?? searchInput?.value ?? state.collection.search ?? '';
  const searchTerm = rawSearch.toString().trim();

  const sortSelect = document.getElementById('collection-sort');
  if (sortSelect) {
    const expected = resolveCollectionSortOption(sort);
    if (sortSelect.value !== expected) {
      sortSelect.value = expected;
    }
  }

  if (typeSelect && typeSelect.value !== type) {
    typeSelect.value = type;
  }

  if (searchInput && searchInput.value !== searchTerm) {
    searchInput.value = searchTerm;
  }

  const search = new URLSearchParams({ sort, page, per_page: perPage });
  if (type) {
    search.set('type', type);
  }
  if (searchTerm) {
    search.set('search', searchTerm);
  }
  const path = `/collection${search.toString() ? `?${search.toString()}` : ''}`;
  state.collection.loading = true;
  state.collection.sort = sort;
  state.collection.type = type;
  state.collection.page = page;
  state.collection.perPage = perPage;
  state.collection.search = searchTerm;
  renderCollection();

  try {
    const data = await fetchJson(path);
    renderCollection({ ...data, sort, type });
  } catch (error) {
    if (state.authenticated) {
      showNotification(error.message, 'error');
    }
  } finally {
    state.collection.loading = false;
    renderCollection();
  }
}

async function loadStatus() {
  try {
    const data = await fetchJson('/status');
    updateJobMetrics(data);
    renderJobs(data);
  } catch (error) {
    if (state.authenticated) {
      showNotification(error.message, 'error');
    }
  }
}

async function loadLogs({ force = false } = {}) {
  if (!force && state.activeTab !== 'logs') {
    return;
  }
  try {
    const data = await fetchJson('/logs');
    renderLogs(data.logs || {});
  } catch (error) {
    if (state.authenticated) {
      showNotification(error.message, 'error');
    }
  }
}

async function validateTorrent(entry) {
  const identifier = entry?.identifier || entry?.name;
  if (!identifier) {
    showNotification('Identifiant de torrent introuvable.', 'error');
    return;
  }
  try {
    await fetchJson('/torrents/validate', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ identifier }),
    });
    showNotification('Torrent validé.');
    loadPendingTorrents();
  } catch (error) {
    showNotification(error?.message || 'Impossible de valider le torrent.', 'error');
  }
}

async function deleteTorrent(entry) {
  const identifier = entry?.identifier || entry?.name;
  if (!identifier) {
    showNotification('Identifiant de torrent introuvable.', 'error');
    return;
  }
  try {
    await fetchJson('/torrents/delete', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ identifier }),
    });
    showNotification('Torrent supprimé.');
    loadPendingTorrents();
  } catch (error) {
    showNotification(error?.message || 'Impossible de supprimer le torrent.', 'error');
  }
}

function renderPendingTorrentList(rowsId, emptyId, entries = []) {
  const tbody = document.getElementById(rowsId);
  const emptyHint = document.getElementById(emptyId);
  if (!tbody || !emptyHint) {
    return;
  }

  tbody.innerHTML = '';
  const normalized = Array.isArray(entries) ? entries : [];
  if (!normalized.length) {
    emptyHint.classList.remove('hidden');
    return;
  }
  emptyHint.classList.add('hidden');

  const labels = ['Nom', 'Tracker', 'Catégorie', 'Ajouté', 'Disponible le', 'Identifiant'];
  normalized.forEach((entry) => {
    const row = document.createElement('tr');
    const status = Number(entry?.status);
    const cells = [
      entry?.name || '—',
      entry?.tracker || '—',
      entry?.category || '—',
      formatDateTime(entry?.created_at),
      formatDateTime(entry?.waiting_until),
      entry?.identifier || '—',
    ];

    cells.forEach((value, index) => {
      const cell = document.createElement('td');
      cell.dataset.label = labels[index];
      cell.textContent = value || '—';
      row.appendChild(cell);
    });

    const cell = document.createElement('td');
    cell.className = 'actions-cell';
    cell.dataset.label = 'Actions';
    if (status === 2) {
      const pendingLabel = document.createElement('span');
      pendingLabel.className = 'calendar-badge';
      pendingLabel.textContent = 'En attente de téléchargement';
      cell.appendChild(pendingLabel);
    }
    if (status === 1) {
      const validateButton = document.createElement('button');
      validateButton.type = 'button';
      validateButton.textContent = 'Valider';
      validateButton.addEventListener('click', () => validateTorrent(entry));
      cell.appendChild(validateButton);
    }
    if (status === 1 || status === 2) {
      const deleteButton = document.createElement('button');
      deleteButton.type = 'button';
      deleteButton.textContent = 'Supprimer';
      deleteButton.addEventListener('click', () => deleteTorrent(entry));
      cell.appendChild(deleteButton);
    }
    if (!cell.childNodes.length) {
      cell.textContent = '—';
    }
    row.appendChild(cell);

    tbody.appendChild(row);
  });
}

function renderPendingTorrents(data = {}) {
  const validation = Array.isArray(data.validation) ? data.validation : [];
  const downloads = Array.isArray(data.downloads) ? data.downloads : [];
  renderPendingTorrentList('pending-validation-rows', 'pending-validation-empty', validation);
  renderPendingTorrentList('pending-download-rows', 'pending-download-empty', downloads);
}

async function loadPendingTorrents() {
  try {
    const data = await fetchJson('/torrents/pending');
    renderPendingTorrents(data || {});
  } catch (error) {
    renderPendingTorrents();
    const message = error?.message || 'Impossible de charger les torrents en attente.';
    showNotification(message, 'error');
  }
}

function renderWatchlist(entries = [], { message } = {}) {
  const tbody = document.getElementById('watchlist-rows');
  const emptyHint = document.getElementById('watchlist-empty');
  const trackerHint = document.getElementById('watchlist-trackers-hint');
  if (!tbody || !emptyHint) {
    return;
  }

  tbody.innerHTML = '';
  const normalized = Array.isArray(entries) ? entries : [];
  const defaultMessage = emptyHint.dataset.defaultText || emptyHint.textContent || '';
  emptyHint.dataset.defaultText = defaultMessage;
  emptyHint.textContent = message || defaultMessage;
  const trackers = Array.isArray(state.trackers?.entries) ? state.trackers.entries : [];
  const hasTrackers = trackers.length > 0;
  if (trackerHint) {
    trackerHint.textContent = hasTrackers
      ? ''
      : 'Aucun tracker configuré. Ajoutez un `url_template` dans config/trackers/*.yml pour générer les liens.';
    trackerHint.classList.toggle('hidden', hasTrackers || (!trackerHint.textContent && normalized.length));
  }
  if (!normalized.length) {
    emptyHint.classList.remove('hidden');
    return;
  }
  emptyHint.classList.add('hidden');

  const labels = ['Titre', 'Type', 'Année', 'IMDB', 'URL'];
  const trackerLabel = 'Recherche tracker';

  normalized.forEach((entry) => {
    const row = document.createElement('tr');
    const ids = entry && typeof entry.ids === 'object' ? entry.ids : {};
    const title = entry.title || '';
    const type = entry.type || '';
    const releaseDateYear = entry.release_date ? new Date(entry.release_date).getFullYear() : '';
    const year = entry.year || entry.release_year || (Number.isFinite(releaseDateYear) ? releaseDateYear : '');
    const imdb = entry.imdb_id || ids.imdb || '';
    const externalId = imdb || entry.id || ids.slug || '';
    const url = entry.url || '';
    const metadata = { ids, title, type, year, release_date: entry.release_date, imdb, url };

    const cells = [
      { text: title || '—' },
      { text: type || '—' },
      { text: year || '—' },
      { text: imdb || externalId || '—' },
      url ? { link: url } : { text: '—' },
    ];

    cells.forEach((value, index) => {
      const cell = document.createElement('td');
      cell.dataset.label = labels[index];
      if (value.link) {
        const link = document.createElement('a');
        link.href = value.link;
        link.target = '_blank';
        link.rel = 'noreferrer noopener';
        link.textContent = 'Lien';
        cell.appendChild(link);
      } else {
        cell.textContent = value.text || '—';
      }
      row.appendChild(cell);
    });

    const trackerCell = document.createElement('td');
    trackerCell.dataset.label = trackerLabel;
    if (!hasTrackers) {
      trackerCell.textContent = 'Aucun tracker configuré';
    } else {
      const selectionKey = externalId || imdb || title;
      const select = document.createElement('select');
      trackers.forEach(({ name }) => {
        const option = document.createElement('option');
        option.value = name;
        option.textContent = name;
        select.appendChild(option);
      });

      const stored = state.trackers.selections.get(selectionKey);
      const availableNames = trackers.map((tracker) => tracker.name);
      const defaultSelection = availableNames.includes(stored) ? stored : trackers[0]?.name;
      if (defaultSelection) {
        select.value = defaultSelection;
      }

      const link = document.createElement('a');
      link.target = '_blank';
      link.rel = 'noreferrer noopener';
      link.textContent = 'Lien';

      const refreshTrackerLink = () => {
        const trackerName = select.value;
        const generatedUrl = generateTrackerUrl(trackerName, { title, year, imdb });
        if (generatedUrl) {
          link.href = generatedUrl;
          link.textContent = 'Ouvrir';
          link.removeAttribute('aria-disabled');
          link.tabIndex = 0;
        } else {
          link.removeAttribute('href');
          link.textContent = 'Lien indisponible';
          link.setAttribute('aria-disabled', 'true');
          link.tabIndex = -1;
        }
      };

      select.addEventListener('change', () => {
        state.trackers.selections.set(selectionKey, select.value);
        refreshTrackerLink();
      });

      refreshTrackerLink();
      trackerCell.appendChild(select);
      trackerCell.appendChild(document.createTextNode(' '));
      trackerCell.appendChild(link);
    }
    row.appendChild(trackerCell);

    const actionsCell = document.createElement('td');
    actionsCell.className = 'actions-cell';
    actionsCell.dataset.label = 'Actions';
    const removeButton = document.createElement('button');
    removeButton.type = 'button';
    removeButton.textContent = 'Supprimer';
    removeButton.addEventListener('click', () => removeWatchlistEntry(externalId, type));
    actionsCell.appendChild(removeButton);
    row.appendChild(actionsCell);

    tbody.appendChild(row);
  });
}

async function loadWatchlist() {
  try {
    const data = await fetchJson('/watchlist');
    renderWatchlist(data?.entries || []);
  } catch (error) {
    const message = error?.message || 'Impossible de charger la liste.';
    renderWatchlist([], { message });
    showNotification(message, 'error');
  }
}

async function removeWatchlistEntry(imdbId, type) {
  if (!imdbId) {
    return;
  }
  const payload = { imdb_id: imdbId };
  if (type) {
    payload.type = type;
  }
  try {
    await fetchJson('/watchlist', {
      method: 'DELETE',
      headers: new Headers({ 'Content-Type': 'application/json' }),
      body: JSON.stringify(payload),
    });
    showNotification('Élément retiré de la liste.');
    await loadWatchlist();
  } catch (error) {
    showNotification(error.message, 'error');
  }
}

function parseSchedulerTemplate(content, parsed) {
  if (parsed && typeof parsed === 'object') {
    return parsed;
  }
  if (!content) {
    return null;
  }
  if (typeof YAML !== 'undefined' && typeof YAML.parse === 'function') {
    try {
      return YAML.parse(content);
    } catch (error) {
      // ignore
    }
  }
  if (typeof jsyaml !== 'undefined' && typeof jsyaml.load === 'function') {
    try {
      return jsyaml.load(content);
    } catch (error) {
      // ignore
    }
  }
  return null;
}

function extractSchedulerTasks(template) {
  if (!template || typeof template !== 'object') {
    return [];
  }
  const tasks = [];
  ['periodic', 'continuous'].forEach((type) => {
    const section = template[type];
    if (!section || typeof section !== 'object') {
      return;
    }
    Object.entries(section).forEach(([name, entry]) => {
      if (!entry || typeof entry !== 'object') {
        return;
      }
      let base = [];
      if (Array.isArray(entry.command)) {
        base = entry.command.map((value) => String(value));
      } else if (typeof entry.command === 'string') {
        base = entry.command.split('.');
      }
      if (!base.length) {
        return;
      }
      const schedule = entry.every || entry.cron || entry.interval || '';
      const typeLabel = type === 'continuous' ? 'Continu' : 'Périodique';
      const scheduleText = schedule ? `${typeLabel} · ${schedule}` : typeLabel;
      tasks.push({
        name: name || base.join(' '),
        type,
        schedule: schedule ? String(schedule) : '',
        command: base,
        queue: entry.queue || '',
        task: name || '',
        description: entry.description || '',
        arg_values: entry.arg_values || entry.argValues || {},
        meta: scheduleText ? [scheduleText] : [],
      });
    });
  });
  return tasks;
}

function buildCommandKeySet(commands = []) {
  return new Set(
    (commands || [])
      .map((entry) => entry?.baseKey || baseCommandKey(entry?.command))
      .filter((value) => value)
  );
}

function renderSchedulerTasks(tasks = [], { message } = {}) {
  const container = document.getElementById('scheduler-task-list');
  if (!container) {
    return;
  }
  renderCommandList(container, tasks, message || 'Aucune tâche planifiée.');
}

function baseCommandKey(command = []) {
  if (!Array.isArray(command)) {
    return '';
  }
  return command
    .filter((part) => part && !String(part).startsWith('--'))
    .map((part) => String(part).trim())
    .filter(Boolean)
    .join(' ');
}

function normalizeCommandEntries(entries, { allowEmptyCommand = false } = {}) {
  const list = Array.isArray(entries)
    ? entries
    : Array.isArray(entries?.commands)
      ? entries.commands
      : [];
  return list
    .map((entry) => {
      if (entry == null) {
        return null;
      }
      const normalized = typeof entry === 'object' && !Array.isArray(entry)
        ? { ...entry }
        : { name: String(entry), command: entry };
      const parts = Array.isArray(normalized.command)
        ? normalized.command
        : typeof normalized.command === 'string'
          ? normalized.command.split('.')
          : [];
      normalized.command = parts
        .map((part) => String(part).trim())
        .filter(Boolean);
      if (!normalized.name) {
        normalized.name = normalized.command.join(' ');
      }
      if (!normalized.command.length && !allowEmptyCommand) {
        return null;
      }
      if (allowEmptyCommand) {
        const args = normalized.args || normalized.template_args;
        if (
          !normalized.name
          && !normalized.command.length
          && !(Array.isArray(args) && args.length)
          && !normalized.arg_values
          && !normalized.argValues
        ) {
          return null;
        }
      }
      return normalized;
    })
    .filter(Boolean);
}

function renderCommandList(container, commands = [], emptyMessage, options = {}) {
  container.innerHTML = '';
  const { titleSource, titleFormat } = options;

  if (!commands.length) {
    const hint = document.createElement('p');
    hint.className = 'hint';
    hint.textContent = emptyMessage;
    container.appendChild(hint);
    return;
  }

  commands.forEach((command) => {
    const item = document.createElement('article');
    item.className = 'scheduler-task';

    const body = document.createElement('div');
    body.className = 'task-body';

    const title = document.createElement('h3');
    const commandTitle = (command.command || []).join(' ');
    let titleText = titleSource === 'command' ? commandTitle : (command.name || commandTitle);
    if (titleFormat === 'commandWithTemplate') {
      titleText = commandTitle
        ? (command.name ? `${commandTitle} - ${command.name}` : commandTitle)
        : (command.name || '');
    }
    title.textContent = titleText;
    body.appendChild(title);

    const metaLabels = [];
    if (command.meta) {
      if (Array.isArray(command.meta)) {
        metaLabels.push(...command.meta.filter(Boolean));
      } else if (command.meta) {
        metaLabels.push(String(command.meta));
      }
    }
    if (command.queue) {
      metaLabels.push(`File : ${command.queue}`);
    }
    if (metaLabels.length) {
      const meta = document.createElement('div');
      meta.className = 'task-meta';
      meta.textContent = metaLabels.join(' · ');
      body.appendChild(meta);
    }

    const argsContainer = document.createElement('div');
    argsContainer.className = 'command-args';

    const inputs = [];
    const argValues = command.arg_values || command.argValues || {};
    const templateArgs = command.template_args || command.templateArgs || [];
    const argList = Array.isArray(templateArgs) && templateArgs.length
      ? templateArgs.map((name) => ({ name, required: false }))
      : Array.isArray(command.args) && command.args.length
        ? command.args.filter((arg) => arg?.name)
        : Object.keys(argValues).map((name) => ({ name, required: false }));
    if (argList.length) {
      argList.forEach((arg) => {
        const wrapper = document.createElement('label');
        wrapper.className = 'command-arg';
        wrapper.textContent = arg.name;

        const input = document.createElement('input');
        input.type = 'text';
        input.dataset.argName = arg.name;
        input.placeholder = arg.required ? 'Requis' : 'Optionnel';
        input.required = Boolean(arg.required);
        const value = argValues[arg.name];
        if (value != null) {
          input.value = String(value);
        }
        wrapper.appendChild(input);
        argsContainer.appendChild(wrapper);
        inputs.push(input);
      });
    } else {
      const hint = document.createElement('p');
      hint.className = 'hint';
      hint.textContent = 'Aucun argument requis.';
      argsContainer.appendChild(hint);
    }

    body.appendChild(argsContainer);

    const actions = document.createElement('div');
    actions.className = 'task-actions';
    const button = document.createElement('button');
    button.type = 'button';
    button.textContent = 'Lancer';
    button.addEventListener('click', () => {
      const missing = inputs.some((input) => input.required && !input.value.trim());
      if (missing) {
        showNotification('Merci de remplir les arguments requis.', 'error');
        return;
      }

      const args = inputs
        .map((input) => {
          const value = input.value.trim();
          return value ? `--${input.dataset.argName}=${value}` : null;
        })
        .filter(Boolean);

      const task = {
        name: command.name,
        command: [...(command.command || []), ...args],
        queue: command.queue || '',
        task: command.name,
      };

      runSchedulerTask(task, button);
    });
    actions.appendChild(button);

    item.appendChild(body);
    item.appendChild(actions);
    container.appendChild(item);
  });
}

function renderAvailableCommands(commands = [], scheduledKeys = new Set()) {
  const container = document.getElementById('available-command-list');
  if (!container) {
    return;
  }

  const available = Array.isArray(commands)
    ? commands.filter((command) => {
        const key = baseCommandKey(command.command);
        return key && !scheduledKeys.has(key);
      })
    : [];

  renderCommandList(container, available, 'Aucune commande CLI disponible.');
}

function renderTemplateCommands(commands = [], { message } = {}) {
  const container = document.getElementById('template-command-list');
  if (!container) {
    return;
  }

  renderCommandList(
    container,
    commands,
    message || 'Aucun template de commande disponible.',
    { titleFormat: 'commandWithTemplate' }
  );
}

async function runSchedulerTask(task, button) {
  if (!task?.command?.length) {
    return;
  }
  if (button) {
    button.disabled = true;
  }
  const payload = {
    command: task.command,
    wait: false,
    task: task.task || task.name,
  };
  if (task.queue) {
    payload.queue = task.queue;
  }
  try {
    await fetchJson('/jobs', {
      method: 'POST',
      headers: new Headers({ 'Content-Type': 'application/json' }),
      body: JSON.stringify(payload),
    });
    showNotification('Job ajouté à la file.');
    await loadStatus();
  } catch (error) {
    showNotification(error.message, 'error');
  } finally {
    if (button) {
      button.disabled = false;
    }
  }
}

async function loadSchedulerTasks() {
  const container = document.getElementById('scheduler-task-list');
  if (!container) {
    return;
  }
  let tasks = [];
  let scheduledKeys = new Set();
  try {
    const data = await fetchJson('/scheduler');
    const template = parseSchedulerTemplate(data?.content, data?.entries);
    tasks = extractSchedulerTasks(template);
    scheduledKeys = buildCommandKeySet(tasks);
    renderSchedulerTasks(tasks);
  } catch (error) {
    renderSchedulerTasks([], { message: error.message });
    if (state.authenticated) {
      showNotification(error.message, 'error');
    }
  }

  try {
    const commandData = await fetchJson('/commands');
    const commands = normalizeCommandEntries(commandData?.commands);
    renderAvailableCommands(commands, scheduledKeys);
  } catch (error) {
    renderAvailableCommands([], scheduledKeys);
    if (state.authenticated) {
      showNotification(error.message, 'error');
    }
  }

  try {
    const templateData = await fetchJson('/template_commands');
    const templates = normalizeCommandEntries(templateData?.commands, { allowEmptyCommand: true });
    renderTemplateCommands(templates);
  } catch (error) {
    renderTemplateCommands([], { message: error.message });
    if (state.authenticated) {
      showNotification(error.message, 'error');
    }
  }
}

async function loadConfigurationTab(options = {}) {
  await loadEditor('config', options);
  if (!state.authenticated) {
    return;
  }
  await loadEditor('apiConfig', options);
  if (!state.authenticated) {
    return;
  }
  await loadEditor('scheduler', options);
  if (!state.authenticated) {
    return;
  }
  await loadEditor('templates', options);
  if (!state.authenticated) {
    return;
  }
  await loadEditor('trackers', options);
}

async function loadTrackersInfo() {
  try {
    const data = await fetchJson('/trackers/info');
    setTrackerTemplates(data?.trackers || []);
  } catch (error) {
    resetTrackerTemplates();
    if (state.authenticated) {
      showNotification(error.message, 'error');
    }
  }
}

async function loadDownloadsTab() {
  await loadTrackersInfo();
  await Promise.all([loadPendingTorrents(), loadWatchlist()]);
}

async function controlDaemon({ path, buttonId, message }) {
  const button = buttonId ? document.getElementById(buttonId) : null;
  if (button) {
    button.disabled = true;
  }
  try {
    await fetchJson(path, { method: 'POST' });
    if (message) {
      showNotification(message);
    }
    setAuthenticated(false);
  } catch (error) {
    showNotification(error.message, 'error');
  } finally {
    if (button) {
      button.disabled = false;
    }
  }
}

async function restartDaemon() {
  await controlDaemon({
    path: '/restart',
    buttonId: 'restart-daemon',
    message: 'Redémarrage du démon en cours…',
  });
}

async function stopDaemon() {
  await controlDaemon({
    path: '/stop',
    buttonId: 'stop-daemon',
    message: 'Arrêt du démon en cours…',
  });
}

async function updateCodeAndStop() {
  await controlDaemon({
    path: '/update-stop',
    buttonId: 'update-stop-daemon',
    message: 'Mise à jour + arrêt en cours…',
  });
}

const TAB_LOADERS = {
  jobs: () => loadStatus(),
  logs: () => loadLogs(),
  scheduler: () => loadSchedulerTasks(),
  config: (options = {}) => loadConfigurationTab(options),
  calendar: (options = {}) => loadCalendar(options),
  'calendar-search': () => loadCalendarSearch(state.calendarSearch.query),
  collection: (options = {}) => loadCollection(options),
  downloads: () => loadDownloadsTab(),
};

async function refreshActiveTab(options = {}) {
  if (!state.authenticated && !(await syncSession())) {
    return;
  }
  const loader = TAB_LOADERS[state.activeTab];
  if (typeof loader === 'function') {
    await loader(options);
  }
}

async function refreshAll(options = {}) {
  if (!state.authenticated || state.isRefreshing) {
    return;
  }
  state.isRefreshing = true;
  try {
    await loadStatus();
    if (!state.authenticated) {
      return;
    }
    if (state.activeTab === 'logs') {
      await loadLogs();
      if (!state.authenticated) {
        return;
      }
    }
    await loadSchedulerTasks();
    if (!state.authenticated) {
      return;
    }
    await loadConfigurationTab(options);
    if (!state.authenticated) {
      return;
    }
    await loadDownloadsTab();
  } finally {
    state.isRefreshing = false;
  }
}

async function handleLogin(event) {
  event.preventDefault();
  const form = event.target;
  const username = form.username.value.trim();
  const password = form.password.value;
  if (!username || !password) {
    showNotification('Veuillez renseigner vos identifiants.', 'error');
    return;
  }
  try {
    const response = await fetchJson('/session', {
      method: 'POST',
      headers: new Headers({ 'Content-Type': 'application/json' }),
      body: JSON.stringify({ username, password }),
    });
    form.reset();
    const resolvedUsername = response?.username || username;
    setAuthenticated(true, resolvedUsername);
    showNotification('Connexion réussie.');
    await refreshAll();
  } catch (error) {
    showNotification(error.message, 'error');
  }
}

async function logout() {
  try {
    await fetchJson('/session', { method: 'DELETE' });
    showNotification('Déconnexion effectuée.');
  } catch (error) {
    if (state.authenticated) {
      showNotification(error.message, 'error');
    }
  } finally {
    setAuthenticated(false);
  }
}

async function syncSession() {
  try {
    const session = await fetchJson('/session');
    if (session?.username) {
      setAuthenticated(true, session.username);
      return true;
    }
  } catch (error) {
    // Authorization failures are handled by fetchJson.
  }
  return state.authenticated;
}

async function bootstrapSession() {
  if (await syncSession()) {
    await refreshAll();
  }
}

function setActiveTab(tabName, { skipLoad = false } = {}) {
  const resolved = TAB_LOADERS[tabName] ? tabName : 'jobs';
  state.activeTab = resolved;

  const buttons = document.querySelectorAll('.tab-button');
  buttons.forEach((button) => {
    const isActive = button.dataset.tab === resolved;
    button.classList.toggle('active', isActive);
    button.setAttribute('aria-selected', String(isActive));
    button.setAttribute('tabindex', isActive ? '0' : '-1');
  });

  const panels = document.querySelectorAll('.tab-panel');
  panels.forEach((panel) => {
    const isActive = panel.dataset.tab === resolved;
    panel.classList.toggle('active', isActive);
    panel.hidden = !isActive;
  });

  if (!skipLoad) {
    refreshActiveTab();
  }
}

function setupTabs() {
  const buttons = document.querySelectorAll('.tab-button');
  buttons.forEach((button) => {
    button.addEventListener('click', () => {
      const { tab } = button.dataset;
      setActiveTab(tab);
    });
  });
}

function setupCalendarEvents() {
  const refresh = document.getElementById('refresh-calendar');
  if (refresh) {
    refresh.addEventListener('click', () => loadCalendar({ preserveFilters: true }));
  }
  const refreshFeed = document.getElementById('refresh-calendar-feed');
  if (refreshFeed) {
    refreshFeed.addEventListener('click', refreshCalendarFeed);
  }
  const titleFilter = document.getElementById('calendar-title-filter');
  const imdbSearchButton = document.getElementById('calendar-imdb-search');
  const toggleImdbButton = () => {
    if (!imdbSearchButton || !titleFilter) {
      return;
    }
    const query = titleFilter.value.trim();
    const shouldShow = Boolean(query);
    imdbSearchButton.hidden = !shouldShow;
    imdbSearchButton.disabled = !shouldShow;
  };
  const calendarView = document.getElementById('calendar-view');
  if (calendarView) {
    calendarView.addEventListener('change', () => loadCalendar({ preserveFilters: true, resetWindow: true }));
  }
  if (titleFilter) {
    titleFilter.addEventListener('input', () => {
      toggleImdbButton();
      loadCalendar({ preserveFilters: true });
    });
  }
  if (imdbSearchButton) {
    imdbSearchButton.addEventListener('click', () => {
      const query = titleFilter?.value.trim();
      if (!query) {
        return;
      }
      setActiveTab('calendar-search');
      loadCalendarSearch(query);
    });
  }
  const ids = [
    'calendar-type',
    'calendar-genres',
    'calendar-rating-min',
    'calendar-rating-max',
    'calendar-votes-min',
    'calendar-votes-max',
    'calendar-language',
    'calendar-country',
  ];
  ids
    .map((id) => document.getElementById(id))
    .filter(Boolean)
    .forEach((input) => {
      const event = input.tagName === 'SELECT' ? 'change' : 'input';
      input.addEventListener(event, () => loadCalendar({ preserveFilters: true }));
    });
  toggleImdbButton();
  wireCalendarNavigation(
    {
      previous: document.getElementById('calendar-prev'),
      next: document.getElementById('calendar-next'),
      dateInput: document.getElementById('calendar-start-date'),
    },
    (options) => loadCalendar(options),
  );
}

function setupCalendarSearchEvents() {
  const form = document.getElementById('calendar-search-form');
  const input = document.getElementById('calendar-search-query');
  if (form && input) {
    form.addEventListener('submit', (event) => {
      event.preventDefault();
      loadCalendarSearch(input.value);
    });
  }
}

function setupCollectionEvents() {
  const searchForm = document.getElementById('collection-search-form');
  const searchInput = document.getElementById('collection-search');
  if (searchForm && searchInput) {
    searchForm.addEventListener('submit', (event) => {
      event.preventDefault();
      loadCollection({ search: searchInput.value, page: 1 });
    });
  }

  const sort = document.getElementById('collection-sort');
  if (sort) {
    sort.addEventListener('change', () => loadCollection({ sort: sort.value, page: 1 }));
  }

  const type = document.getElementById('collection-type');
  if (type) {
    type.addEventListener('change', () => loadCollection({ type: type.value, page: 1 }));
  }

  const prev = document.getElementById('collection-prev');
  if (prev) {
    prev.addEventListener('click', () => loadCollection({ page: Math.max(1, state.collection.page - 1) }));
  }

  const next = document.getElementById('collection-next');
  if (next) {
    next.addEventListener('click', () => loadCollection({ page: state.collection.page + 1 }));
  }

  const modalClose = document.getElementById('collection-modal-close');
  if (modalClose) {
    modalClose.addEventListener('click', closeCollectionModal);
  }

  const modal = document.getElementById('collection-modal');
  if (modal) {
    modal.addEventListener('click', (event) => {
      if (event.target === modal) {
        closeCollectionModal();
      }
    });
  }

  document.addEventListener('keydown', (event) => {
    if (event.key === 'Escape') {
      closeCollectionModal();
    }
  });
}

function setupEventListeners() {
  setupTabs();
  const toggleConfigView = document.getElementById('toggle-config-view');
  if (toggleConfigView) {
    toggleConfigView.addEventListener('click', () => {
      setConfigView(configFormState.mode === 'form' ? 'yaml' : 'form', {
        formId: 'config-form',
        editorId: 'config-editor',
        toggleId: 'toggle-config-view',
        formState: configFormState,
        editorKey: 'config',
        schema: CONFIG_FORM_SCHEMA,
      });
    });
  }
  const toggleApiConfigView = document.getElementById('toggle-api-config-view');
  if (toggleApiConfigView) {
    toggleApiConfigView.addEventListener('click', () => {
      setConfigView(apiConfigFormState.mode === 'form' ? 'yaml' : 'form', {
        formId: 'api-config-form',
        editorId: 'api-config-editor',
        toggleId: 'toggle-api-config-view',
        formState: apiConfigFormState,
        editorKey: 'apiConfig',
        schema: API_CONFIG_FORM_SCHEMA,
      });
    });
  }
  document.getElementById('refresh-status').addEventListener('click', loadStatus);
  document.getElementById('stop-daemon').addEventListener('click', stopDaemon);
  document.getElementById('restart-daemon').addEventListener('click', restartDaemon);
  document.getElementById('update-stop-daemon').addEventListener('click', updateCodeAndStop);
  document.getElementById('refresh-logs').addEventListener('click', loadLogs);
  const refreshSchedulerTasks = document.getElementById('refresh-scheduler-tasks');
  if (refreshSchedulerTasks) {
    refreshSchedulerTasks.addEventListener('click', loadSchedulerTasks);
  }
  bindEditorAction('save-config', 'config', 'save');
  bindEditorAction('reload-config', 'config', 'reload');
  bindEditorAction('save-api-config', 'apiConfig', 'save');
  bindEditorAction('reload-api-config', 'apiConfig', 'reload');
  bindEditorAction('save-scheduler', 'scheduler', 'save');
  bindEditorAction('reload-scheduler', 'scheduler', 'reload');
  bindEditorAction('save-templates', 'templates', 'save');
  bindEditorAction('reload-templates', 'templates', 'reload');
  bindEditorAction('save-trackers', 'trackers', 'save');
  bindEditorAction('reload-trackers', 'trackers', 'reload');
  ['refresh-watchlist', 'refresh-pending-torrents']
    .map((id) => document.getElementById(id))
    .filter(Boolean)
    .forEach((button) => button.addEventListener('click', loadDownloadsTab));
  document.getElementById('login-form').addEventListener('submit', handleLogin);
  document.getElementById('logout-button').addEventListener('click', logout);
  setupCalendarEvents();
  setupCalendarSearchEvents();
  setupCollectionEvents();
}

document.addEventListener('DOMContentLoaded', () => {
  buildConfigForm('config-form', configFormState, CONFIG_FORM_SCHEMA, 'config');
  buildConfigForm('api-config-form', apiConfigFormState, API_CONFIG_FORM_SCHEMA, 'apiConfig');
  buildConfigForm('trackers-form', trackerFormState, TRACKER_FORM_SCHEMA, 'trackers');
  setConfigView('form', {
    formId: 'config-form',
    editorId: 'config-editor',
    toggleId: 'toggle-config-view',
    formState: configFormState,
    editorKey: 'config',
    schema: CONFIG_FORM_SCHEMA,
  });
  setConfigView('form', {
    formId: 'api-config-form',
    editorId: 'api-config-editor',
    toggleId: 'toggle-api-config-view',
    formState: apiConfigFormState,
    editorKey: 'apiConfig',
    schema: API_CONFIG_FORM_SCHEMA,
  });
  setupFileEditors();
  setupEventListeners();
  setActiveTab(state.activeTab, { skipLoad: true });
  updateConnectionHint();
  bootstrapSession();
});
