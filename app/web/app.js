const state = {
  authenticated: false,
  username: '',
  autoRefresh: null,
  activeTab: 'jobs',
  dirty: {
    config: false,
    scheduler: false,
    templates: false,
    trackers: false,
  },
  isRefreshing: false,
};

const fileEditors = new Map();

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

const LOG_MAX_LINES = 10000;

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
      return parsed.error || parsed.message || JSON.stringify(parsed);
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
    if (!state.authenticated) {
      return;
    }
    refreshAll();
  }, 10000);
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
  const textarea = document.getElementById(options.textareaId);
  if (!textarea) {
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
    textarea.disabled = !enabled;
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
    textarea.value = content || '';
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
    if (includeContent) {
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
      ? options.buildPayload(payload, editor)
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

  textarea.addEventListener('input', () => editor.setDirty(true));
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
    textareaId: 'trackers-editor',
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
    header.innerHTML = `<span>${job.queue || '—'}</span><span>${job.status}</span>`;
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

function renderLogs(logs = {}) {
  const container = document.getElementById('logs-container');
  const template = document.getElementById('log-entry-template');
  container.innerHTML = '';

  Object.entries(logs).forEach(([name, content]) => {
    const fragment = template.content.cloneNode(true);
    const logEntry = fragment.querySelector('.log-entry');
    fragment.querySelector('.log-name').textContent = name;
    const { text: displayContent, truncated } = getLogTail(content || '');
    const logContent = fragment.querySelector('.log-content');
    logContent.textContent = displayContent || '—';
    fragment.querySelector('.copy-log').addEventListener('click', async () => {
      try {
        await navigator.clipboard.writeText(displayContent || '');
        showNotification(`Log « ${name} » copié dans le presse-papiers.`);
      } catch (error) {
        showNotification(`Impossible de copier le log « ${name} ».`, 'error');
      }
    });
    if (truncated) {
      const hint = document.createElement('p');
      hint.className = 'log-hint';
      hint.textContent = `Affichage des ${LOG_MAX_LINES.toLocaleString('fr-FR')} dernières lignes.`;
      logEntry.appendChild(hint);
    }
    container.appendChild(fragment);
    if (logContent) {
      logContent.scrollTop = logContent.scrollHeight;
    }
  });
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

async function loadLogs() {
  try {
    const data = await fetchJson('/logs');
    renderLogs(data.logs || {});
  } catch (error) {
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

const TAB_LOADERS = {
  jobs: () => loadStatus(),
  logs: () => loadLogs(),
  config: (options = {}) => loadConfigurationTab(options),
};

async function refreshActiveTab(options = {}) {
  if (!state.authenticated) {
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
    await loadLogs();
    if (!state.authenticated) {
      return;
    }
    await loadConfigurationTab(options);
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

async function bootstrapSession() {
  try {
    const session = await fetchJson('/session');
    if (!session || !session.username) {
      return;
    }
    setAuthenticated(true, session.username);
    await refreshAll();
  } catch (error) {
    // Auth required or other errors already handled.
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

function setupEventListeners() {
  setupTabs();
  document.getElementById('refresh-status').addEventListener('click', loadStatus);
  document.getElementById('stop-daemon').addEventListener('click', stopDaemon);
  document.getElementById('restart-daemon').addEventListener('click', restartDaemon);
  document.getElementById('refresh-logs').addEventListener('click', loadLogs);
  bindEditorAction('save-config', 'config', 'save');
  bindEditorAction('reload-config', 'config', 'reload');
  bindEditorAction('save-scheduler', 'scheduler', 'save');
  bindEditorAction('reload-scheduler', 'scheduler', 'reload');
  bindEditorAction('save-templates', 'templates', 'save');
  bindEditorAction('reload-templates', 'templates', 'reload');
  bindEditorAction('save-trackers', 'trackers', 'save');
  bindEditorAction('reload-trackers', 'trackers', 'reload');
  document.getElementById('login-form').addEventListener('submit', handleLogin);
  document.getElementById('logout-button').addEventListener('click', logout);
}

document.addEventListener('DOMContentLoaded', () => {
  setupFileEditors();
  setupEventListeners();
  setActiveTab(state.activeTab, { skipLoad: true });
  updateConnectionHint();
  bootstrapSession();
});
