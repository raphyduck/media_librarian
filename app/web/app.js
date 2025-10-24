const state = {
  authenticated: false,
  username: '',
  autoRefresh: null,
  activeTab: 'jobs',
  dirty: {
    config: false,
    scheduler: false,
  },
  isRefreshing: false,
};

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
  const elementId = editorKey === 'config' ? 'config-editor' : 'scheduler-editor';
  const editor = document.getElementById(elementId);
  if (editor) {
    editor.dataset.dirty = dirty ? 'true' : 'false';
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
    setEditorDirty('config', false);
    setEditorDirty('scheduler', false);
    const configEditor = document.getElementById('config-editor');
    const schedulerEditor = document.getElementById('scheduler-editor');
    if (configEditor) {
      configEditor.value = '';
    }
    if (schedulerEditor) {
      schedulerEditor.value = '';
    }
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
        span.textContent = `${label}: r${runningCount} q${queuedCount} f${finishedCount}`;
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

async function loadConfig({ force = false } = {}) {
  const editor = document.getElementById('config-editor');
  if (!editor) {
    return;
  }
  if (!force && isEditorDirty('config')) {
    return;
  }
  try {
    const data = await fetchJson('/config');
    if (!force && isEditorDirty('config')) {
      return;
    }
    editor.value = data.content || '';
    setEditorDirty('config', false);
  } catch (error) {
    if (state.authenticated) {
      showNotification(error.message, 'error');
    }
  }
}

async function loadScheduler({ force = false } = {}) {
  const editor = document.getElementById('scheduler-editor');
  const hint = document.getElementById('scheduler-hint');
  if (!editor || !hint) {
    return;
  }
  if (!force && isEditorDirty('scheduler')) {
    return;
  }
  try {
    const data = await fetchJson('/scheduler');
    editor.disabled = false;
    document.getElementById('save-scheduler').disabled = false;
    document.getElementById('reload-scheduler').disabled = false;
    if (!force && isEditorDirty('scheduler')) {
      return;
    }
    editor.value = data.content || '';
    hint.textContent = 'Modifiez le fichier du scheduler si un planificateur est configuré.';
    setEditorDirty('scheduler', false);
  } catch (error) {
    editor.value = '';
    editor.disabled = true;
    document.getElementById('save-scheduler').disabled = true;
    document.getElementById('reload-scheduler').disabled = true;
    hint.textContent = "Aucun scheduler configuré ou erreur lors du chargement.";
    setEditorDirty('scheduler', false);
    if (state.authenticated) {
      showNotification(error.message, 'error');
    }
  }
}

async function loadConfigTab(options = {}) {
  await loadConfig(options);
  if (!state.authenticated) {
    return;
  }
  await loadScheduler(options);
}

async function saveConfig() {
  const content = document.getElementById('config-editor').value;
  try {
    await fetchJson('/config', {
      method: 'PUT',
      headers: new Headers({ 'Content-Type': 'application/json' }),
      body: JSON.stringify({ content }),
    });
    showNotification('Configuration sauvegardée.');
    setEditorDirty('config', false);
    await loadConfig({ force: true });
  } catch (error) {
    if (state.authenticated) {
      showNotification(error.message, 'error');
    }
  }
}

async function saveScheduler() {
  const content = document.getElementById('scheduler-editor').value;
  try {
    await fetchJson('/scheduler', {
      method: 'PUT',
      headers: new Headers({ 'Content-Type': 'application/json' }),
      body: JSON.stringify({ content }),
    });
    showNotification('Scheduler sauvegardé.');
    setEditorDirty('scheduler', false);
    await loadScheduler({ force: true });
  } catch (error) {
    if (state.authenticated) {
      showNotification(error.message, 'error');
    }
  }
}

async function reloadConfig() {
  try {
    await fetchJson('/config/reload', { method: 'POST' });
    showNotification('Configuration rechargée.');
    setEditorDirty('config', false);
    await loadConfig({ force: true });
  } catch (error) {
    if (state.authenticated) {
      showNotification(error.message, 'error');
    }
  }
}

async function reloadScheduler() {
  try {
    await fetchJson('/scheduler/reload', { method: 'POST' });
    showNotification('Scheduler rechargé.');
    setEditorDirty('scheduler', false);
    await loadScheduler({ force: true });
  } catch (error) {
    if (state.authenticated) {
      showNotification(error.message, 'error');
    }
  }
}

async function restartDaemon() {
  const button = document.getElementById('restart-daemon');
  if (button) {
    button.disabled = true;
  }
  try {
    await fetchJson('/restart', { method: 'POST' });
    showNotification('Redémarrage du démon en cours…');
    stopAutoRefresh();
    setAuthenticated(false);
  } catch (error) {
    showNotification(error.message, 'error');
  } finally {
    if (button) {
      button.disabled = false;
    }
  }
}

const TAB_LOADERS = {
  jobs: () => loadStatus(),
  logs: () => loadLogs(),
  config: (options = {}) => loadConfigTab(options),
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
    await loadConfigTab(options);
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
    await fetchJson('/status');
    setAuthenticated(true, state.username);
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
  document.getElementById('restart-daemon').addEventListener('click', restartDaemon);
  document.getElementById('refresh-logs').addEventListener('click', loadLogs);
  document.getElementById('save-config').addEventListener('click', saveConfig);
  document.getElementById('save-scheduler').addEventListener('click', saveScheduler);
  document.getElementById('reload-config').addEventListener('click', reloadConfig);
  document.getElementById('reload-scheduler').addEventListener('click', reloadScheduler);
  document.getElementById('login-form').addEventListener('submit', handleLogin);
  document.getElementById('logout-button').addEventListener('click', logout);

  const configEditor = document.getElementById('config-editor');
  const schedulerEditor = document.getElementById('scheduler-editor');
  if (configEditor) {
    configEditor.addEventListener('input', () => setEditorDirty('config', true));
  }
  if (schedulerEditor) {
    schedulerEditor.addEventListener('input', () => setEditorDirty('scheduler', true));
  }
}

document.addEventListener('DOMContentLoaded', () => {
  setupEventListeners();
  setEditorDirty('config', false);
  setEditorDirty('scheduler', false);
  setActiveTab(state.activeTab, { skipLoad: true });
  updateConnectionHint();
  bootstrapSession();
});
