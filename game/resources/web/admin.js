'use strict';

// Admin page: manage the request queue, guests and limits.

const $ = id => document.getElementById(id);
let currentTab = 'queue';
let refreshTimer = null;
let settings = null;

function show(id, visible) {
  $(id).classList.toggle('hidden', !visible);
}

function showLogin() {
  clearInterval(refreshTimer);
  show('tabs', false);
  ['queueTab', 'usersTab', 'settingsTab', 'activityTab'].forEach(id => show(id, false));
  show('login', true);
  setTimeout(() => $('pin').focus(), 50);
}

function setTab(tab) {
  currentTab = tab;
  document.querySelectorAll('#tabs button').forEach(b => b.classList.toggle('active', b.dataset.tab === tab));
  show('queueTab', tab === 'queue');
  show('usersTab', tab === 'users');
  show('settingsTab', tab === 'settings');
  show('activityTab', tab === 'activity');
}

async function queueAction(action, key) {
  try {
    await api('/api/admin/queue', { action, key });
    refresh();
  } catch (error) {
    handleError(error);
  }
}

async function userAction(action, id, value = '') {
  try {
    await api('/api/admin/user', { action, id, value });
    refresh();
  } catch (error) {
    handleError(error);
  }
}

function handleError(error) {
  if (error.status === 401) showLogin();
  else toast(errorText(error), 'error');
}

function button(text, title, onclick, cls = '') {
  return el('button', { class: cls, title, 'aria-label': title, text, onclick });
}

function renderQueue(queue) {
  $('queueBadge').textContent = queue.length;
  $('queueBadge').classList.toggle('hidden', queue.length === 0);
  if (!queue.length) {
    $('queueRows').replaceChildren(el('tr', {}, el('td', { colspan: '4', class: 'sub', text: t('queue_empty') })));
    return;
  }
  $('queueRows').replaceChildren(...queue.map((item, index) => el('tr', {},
    el('td', {}, item.pinned ? '📌' : String(item.position)),
    el('td', {},
      el('div', { text: `${item.artist} — ${item.title}` }),
      el('div', { class: 'sub', text: `${t('by')}: ${item.by.join(', ')} · ${timeAgo(item.since)}${item.available ? '' : ' · ' + t('unavailable')}` })),
    el('td', {}, String(item.votes)),
    el('td', { class: 'actions' },
      button('↑', t('move_up'), () => queueAction('up', item.key), index === 0 ? 'hidden' : ''),
      button('↓', t('move_down'), () => queueAction('down', item.key), index === queue.length - 1 ? 'hidden' : ''),
      item.pinned
        ? button('📍', t('unpin'), () => queueAction('unpin', item.key))
        : button('📌', t('pin'), () => queueAction('pin', item.key)),
      button('✓', t('mark_sung'), () => queueAction('sung', item.key)),
      button('✕', t('remove'), () => queueAction('remove', item.key), 'btn-danger')))));
}

// Readable device name from the user agent, e.g. "📱 Pixel 8 · Android 14 · Chrome"
function deviceLabel(ua, model) {
  ua = ua || '';
  let icon = '💻', system = '';
  let androidVersion = '';
  if (model && model.includes('|')) [model, androidVersion] = model.split('|');
  const android = ua.match(/Android (\d+(?:\.\d+)?)/);
  if (/iPad/.test(ua) || model === 'iPad') { icon = '📲'; system = 'iPad'; }
  else if (/iPhone/.test(ua)) { icon = '📱'; system = 'iPhone'; }
  else if (android) {
    icon = /Mobile/.test(ua) ? '📱' : '📲';
    system = `Android ${androidVersion || android[1]}`;
    // older user agents still carry the model: "Android 10; SM-G973F"
    const fromUa = ua.match(/Android [\d.]+; ([^;)]+)\)/);
    if (!model && fromUa && fromUa[1] !== 'K') model = fromUa[1].trim();
  }
  else if (/Windows/.test(ua)) system = 'Windows';
  else if (/Macintosh/.test(ua)) system = 'Mac';
  else if (/Linux|X11|CrOS/.test(ua)) system = /CrOS/.test(ua) ? 'ChromeOS' : 'Linux';
  let browser = '';
  if (/SamsungBrowser/.test(ua)) browser = 'Samsung Internet';
  else if (/Edg(e|A|iOS)?\//.test(ua)) browser = 'Edge';
  else if (/Firefox|FxiOS/.test(ua)) browser = 'Firefox';
  else if (/OPR\/|Opera/.test(ua)) browser = 'Opera';
  else if (/Chrome|CriOS/.test(ua)) browser = 'Chrome';
  else if (/Safari/.test(ua)) browser = 'Safari';
  const parts = [model && model !== 'iPad' ? model : '', system, browser].filter(Boolean);
  return parts.length ? `${icon} ${parts.join(' · ')}` : '—';
}

function renderUsers(users) {
  users.sort((a, b) => b.seen - a.seen);
  $('usersBadge').textContent = users.length;
  $('usersBadge').classList.toggle('hidden', users.length === 0);
  if (!users.length) {
    $('userRows').replaceChildren(el('tr', {}, el('td', { colspan: '4', class: 'sub', text: t('no_users') })));
    return;
  }
  $('userRows').replaceChildren(...users.map(user => {
    let status;
    if (user.blocked) status = el('span', { class: 'status-blocked', text: t('blocked') });
    else if (user.mutedFor > 0) status = el('span', { class: 'status-muted', text: t('muted', Math.ceil(user.mutedFor / 60)) });
    else status = el('span', { class: 'status-ok', text: t('active') });
    return el('tr', {},
      el('td', {},
        el('div', { text: user.nick || '—' }),
        el('div', { class: 'device', title: user.ua || '', text: deviceLabel(user.ua, user.model) }),
        el('div', { class: 'sub', text: `${user.ip} · ${timeAgo(user.seen)}` })),
      el('td', {}, `${user.pending} / ${user.requests}`),
      el('td', {}, status),
      el('td', { class: 'actions' },
        button('✎', t('rename'), () => {
          const nick = prompt(t('rename_prompt'), user.nick);
          if (nick) userAction('rename', user.id, nick);
        }),
        user.mutedFor > 0
          ? button('🔊', t('unmute'), () => userAction('unmute', user.id))
          : button('🔇', t('mute'), () => userAction('mute', user.id, '15')),
        user.blocked
          ? button('✓', t('unblock'), () => userAction('unblock', user.id))
          : button('⛔', t('block'), () => { if (confirm(t('confirm_block', user.nick || user.ip))) userAction('block', user.id); }, 'btn-danger'),
        button('🗑', t('delete_user'), () => { if (confirm(t('confirm_delete', user.nick || user.ip))) userAction('delete', user.id); })));
  }));
}

function renderBlockedIps(ips) {
  if (!ips.length) {
    $('blockedIps').replaceChildren(t('no_blocked_ips'));
    return;
  }
  $('blockedIps').replaceChildren(...ips.map(ip => el('div', { class: 'ip-row' },
    el('span', { text: ip }),
    button(t('unblock_ip'), t('unblock_ip'), async () => {
      try { await api('/api/admin/ip', { action: 'unblock', ip }); refresh(); } catch (error) { handleError(error); }
    }, 'btn-ghost'))));
}

function renderActivity(items) {
  if (!items.length) {
    $('activityRows').replaceChildren(el('tr', {}, el('td', { class: 'sub', text: t('no_activity') })));
    return;
  }
  $('activityRows').replaceChildren(...items.map(item => {
    const key = 'act_' + item.kind;
    const text = TEXTS.es[key] ? t(key, item.who, item.detail) : `${item.kind} ${item.who} ${item.detail}`;
    return el('tr', {},
      el('td', { class: 'sub', style: 'white-space: nowrap', text: timeAgo(item.time) }),
      el('td', { text }));
  }));
}

function renderAdminNow(now) {
  $('adminNow').classList.toggle('hidden', !now);
  if (now) $('adminNow').textContent = '♪ ' + t('admin_now', `${now.artist} — ${now.title}`, now.players);
}

async function maintenance(action, question) {
  if (!confirm(question)) return;
  try {
    await api('/api/admin/maintenance', { action });
    toast(t('saved'), 'ok');
    refresh();
  } catch (error) {
    handleError(error);
  }
}

function renderSettings(s, force) {
  $('pausedQuick').checked = s.paused;
  // do not overwrite what the admin is typing
  if (force || !$('settingsForm').contains(document.activeElement)) {
    $('sPaused').checked = s.paused;
    $('sMaxPending').value = s.maxPending;
    $('sCooldown').value = s.cooldown;
    $('sRecent').value = s.recentMinutes;
  }
}

async function refresh(forceSettings = false) {
  try {
    const data = await api('/api/admin/state');
    show('login', false);
    show('tabs', true);
    setTab(currentTab);
    settings = data.settings;
    renderQueue(data.queue);
    renderUsers(data.users);
    renderBlockedIps(data.blockedIps);
    renderActivity(data.activity);
    renderAdminNow(data.now);
    renderSettings(data.settings, forceSettings);
    if (!refreshTimer) refreshTimer = setInterval(() => refresh(), 5000);
  } catch (error) {
    handleError(error);
  }
}

async function saveSettings(values) {
  try {
    await api('/api/admin/settings', values);
    toast(t('saved'), 'ok');
    refresh(true);
  } catch (error) {
    handleError(error);
  }
}

function start() {
  applyTranslations();
  document.title = t('admin_title');

  $('loginForm').addEventListener('submit', async e => {
    e.preventDefault();
    try {
      await api('/api/admin/login', { pin: $('pin').value });
      $('pin').value = '';
      refreshTimer = null;
      refresh(true);
    } catch (error) {
      toast(errorText(error), 'error');
    }
  });

  document.querySelectorAll('#tabs button').forEach(b => b.addEventListener('click', () => setTab(b.dataset.tab)));

  $('clearQueue').addEventListener('click', () => { if (confirm(t('confirm_clear'))) queueAction('clear', ''); });
  $('resetStats').addEventListener('click', () => maintenance('reset_stats', t('confirm_reset_stats')));
  $('clearActivity').addEventListener('click', () => maintenance('clear_activity', t('confirm_clear_activity')));
  $('pausedQuick').addEventListener('change', e => saveSettings({ ...settings, paused: e.target.checked }));
  $('settingsForm').addEventListener('submit', e => {
    e.preventDefault();
    saveSettings({
      paused: $('sPaused').checked,
      maxPending: parseInt($('sMaxPending').value, 10) || 0,
      cooldown: parseInt($('sCooldown').value, 10) || 0,
      recentMinutes: parseInt($('sRecent').value, 10) || 0,
    });
  });

  api('/api/info').then(info => applyAccent(info.accent)).catch(() => {});
  refresh(true);
}

start();
