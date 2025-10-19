const state = {
  token: '',
  autoRefresh: null,
};

function applyToken(headers = new Headers()) {
  const result = new Headers(headers);
  if (state.token) {
    result.set('X-Control-Token', state.token);
  }
  return result;
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

async function fetchJson(path, options = {}) {
  const init = { ...options };
  init.headers = applyToken(options.headers);
  const response = await fetch(path, init);
  if (!response.ok) {
    const text = await response.text();
    let message = text;
    try {
      const parsed = JSON.parse(text);
      message = parsed.error || JSON.stringify(parsed);
    } catch (error) {
      // ignore JSON errors, fall back to text
    }
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
    fragment.querySelector('.log-content').textContent = content || '—';
    fragment.querySelector('.copy-log').addEventListener('click', async () => {
      try {
        await navigator.clipboard.writeText(content || '');
        showNotification(`Log « ${name} » copié dans le presse-papiers.`);
      } catch (error) {
        showNotification(`Impossible de copier le log « ${name} ».`, 'error');
      }
    });
    container.appendChild(fragment);
  });
}

async function loadStatus() {
  try {
    const data = await fetchJson('/status');
    renderJobs(Array.isArray(data) ? data : data?.jobs || []);
  } catch (error) {
    showNotification(error.message, 'error');
  }
}

async function loadLogs() {
  try {
    const data = await fetchJson('/logs');
    renderLogs(data.logs || {});
  } catch (error) {
    showNotification(error.message, 'error');
  }
}

async function loadConfig() {
  try {
    const data = await fetchJson('/config');
    document.getElementById('config-editor').value = data.content || '';
  } catch (error) {
    showNotification(error.message, 'error');
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
    showNotification(error.message, 'error');
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
    showNotification(error.message, 'error');
  }
}

async function reloadConfig() {
  try {
    await fetchJson('/config/reload', { method: 'POST' });
    showNotification('Configuration rechargée.');
  } catch (error) {
    showNotification(error.message, 'error');
  }
}

async function reloadScheduler() {
  try {
    await fetchJson('/scheduler/reload', { method: 'POST' });
    showNotification('Scheduler rechargé.');
  } catch (error) {
    showNotification(error.message, 'error');
  }
}

function setupTokenHandling() {
  const input = document.getElementById('control-token');
  const clear = document.getElementById('clear-token');
  const stored = window.localStorage.getItem('ml-control-token');
  if (stored) {
    state.token = stored;
    input.value = stored;
  }
  input.addEventListener('input', (event) => {
    const value = event.target.value.trim();
    state.token = value;
    if (value) {
      window.localStorage.setItem('ml-control-token', value);
    } else {
      window.localStorage.removeItem('ml-control-token');
    }
  });
  clear.addEventListener('click', () => {
    state.token = '';
    input.value = '';
    window.localStorage.removeItem('ml-control-token');
    showNotification('Jeton effacé.');
  });
}

function setupEventListeners() {
  document.getElementById('refresh-status').addEventListener('click', loadStatus);
  document.getElementById('refresh-logs').addEventListener('click', loadLogs);
  document.getElementById('save-config').addEventListener('click', saveConfig);
  document.getElementById('save-scheduler').addEventListener('click', saveScheduler);
  document.getElementById('reload-config').addEventListener('click', reloadConfig);
  document.getElementById('reload-scheduler').addEventListener('click', reloadScheduler);
}

document.addEventListener('DOMContentLoaded', () => {
  setupTokenHandling();
  setupEventListeners();
  loadStatus();
  loadLogs();
  loadConfig();
  loadScheduler();
  state.autoRefresh = window.setInterval(() => {
    loadStatus();
    loadLogs();
  }, 10000);
});
