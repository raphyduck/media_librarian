const state = {
  authenticated: false,
  username: '',
  autoRefresh: null,
};

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
    loadStatus();
    loadLogs();
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
  const urlMessage = ` Interface disponible sur ${protocol}://${host}/.`;
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

  const response = await fetch(path, init);
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

function renderJobs(jobs = []) {
  const running = jobs.filter((job) => job.status !== 'finished');
  const finished = jobs.filter((job) => job.status === 'finished');

  const runningList = document.getElementById('jobs-running');
  const finishedList = document.getElementById('jobs-finished');

  const buildItem = (job) => {
    const li = document.createElement('li');
    li.className = 'job-item';
    const header = document.createElement('header');
    header.innerHTML = `<span>${job.queue || '—'}</span><span>${job.status}</span>`;
    const meta = document.createElement('div');
    meta.className = 'job-meta';
    meta.innerHTML = [
      job.id ? `<span>ID: <code>${job.id}</code></span>` : null,
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

  runningList.replaceChildren(...running.map(buildItem));
  finishedList.replaceChildren(...finished.map(buildItem));
}

function renderLogs(logs = {}) {
  const container = document.getElementById('logs-container');
  const template = document.getElementById('log-entry-template');
  container.innerHTML = '';

  Object.entries(logs).forEach(([name, content]) => {
    const fragment = template.content.cloneNode(true);
    fragment.querySelector('.log-name').textContent = name;
    const { text: displayContent, truncated } = getLogTail(content || '');
    fragment.querySelector('.log-content').textContent = displayContent || '—';
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
      fragment.querySelector('.log-entry').appendChild(hint);
    }
    container.appendChild(fragment);
  });
}

async function loadStatus() {
  try {
    const data = await fetchJson('/status');
    renderJobs(Array.isArray(data) ? data : data?.jobs || []);
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

async function loadConfig() {
  try {
    const data = await fetchJson('/config');
    document.getElementById('config-editor').value = data.content || '';
  } catch (error) {
    if (state.authenticated) {
      showNotification(error.message, 'error');
    }
  }
}

async function loadScheduler() {
  const editor = document.getElementById('scheduler-editor');
  const hint = document.getElementById('scheduler-hint');
  try {
    const data = await fetchJson('/scheduler');
    editor.disabled = false;
    document.getElementById('save-scheduler').disabled = false;
    document.getElementById('reload-scheduler').disabled = false;
    editor.value = data.content || '';
    hint.textContent = 'Modifiez le fichier du scheduler si un planificateur est configuré.';
  } catch (error) {
    editor.value = '';
    editor.disabled = true;
    document.getElementById('save-scheduler').disabled = true;
    document.getElementById('reload-scheduler').disabled = true;
    hint.textContent = "Aucun scheduler configuré ou erreur lors du chargement.";
    if (state.authenticated) {
      showNotification(error.message, 'error');
    }
  }
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
  } catch (error) {
    if (state.authenticated) {
      showNotification(error.message, 'error');
    }
  }
}

async function refreshAll() {
  if (!state.authenticated) {
    return;
  }
  await loadStatus();
  if (!state.authenticated) {
    return;
  }
  await loadLogs();
  if (!state.authenticated) {
    return;
  }
  await loadConfig();
  if (!state.authenticated) {
    return;
  }
  await loadScheduler();
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

function setupEventListeners() {
  document.getElementById('refresh-status').addEventListener('click', loadStatus);
  document.getElementById('refresh-logs').addEventListener('click', loadLogs);
  document.getElementById('save-config').addEventListener('click', saveConfig);
  document.getElementById('save-scheduler').addEventListener('click', saveScheduler);
  document.getElementById('reload-config').addEventListener('click', reloadConfig);
  document.getElementById('reload-scheduler').addEventListener('click', reloadScheduler);
  document.getElementById('login-form').addEventListener('submit', handleLogin);
  document.getElementById('logout-button').addEventListener('click', logout);
}

document.addEventListener('DOMContentLoaded', () => {
  setupEventListeners();
  updateConnectionHint();
  bootstrapSession();
});
