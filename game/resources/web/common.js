'use strict';

// Shared helpers for the guest page and the admin page.

const LANG = (navigator.language || 'es').toLowerCase().startsWith('es') ? 'es' : 'en';

const TEXTS = {
  es: {
    brand: 'Peticiones', tab_songs: 'Canciones', tab_queue: 'Cola',
    search_placeholder: 'Buscar artista o canción…', filters: 'Filtros',
    sort_artist: 'Artista A–Z', sort_title: 'Título A–Z', sort_popular: 'Más cantadas',
    sort_requested: 'Más pedidas', sort_score: 'Mejor puntuación', sort_year: 'Más recientes',
    f_language: 'Idioma', f_genre: 'Género', f_decade: 'Década', f_folder: 'Carpeta',
    f_duet: 'Dúo', f_video: 'Vídeo', any: 'Cualquiera', yes: 'Sí', no: 'No',
    with_video: 'Con vídeo', without_video: 'Sin vídeo', reset: 'Quitar filtros',
    no_language: 'Sin idioma', all: 'Todos', all_f: 'Todas',
    paused_notice: 'Las peticiones están cerradas ahora mismo.',
    songs_count: n => `${n} ${n === 1 ? 'canción' : 'canciones'}`,
    loading: 'Cargando…', no_results: 'No hay canciones que coincidan.',
    queue_empty: 'Todavía no hay peticiones. ¡Sé el primero!',
    in_queue: pos => `En cola #${pos}`, votes: n => `${n} ${n === 1 ? 'voto' : 'votos'}`,
    played: 'Veces cantada', best: 'Mejor puntuación', requested: 'Veces pedida',
    top_scores: 'Mejores puntuaciones', no_scores: 'Nadie la ha cantado todavía.',
    request: 'Pedir esta canción', vote: pos => `Sumar mi voto (#${pos})`,
    withdraw: 'Retirar mi voto', requested_ok: '¡Pedida! Mira la cola para ver su posición.',
    vote_ok: '¡Voto sumado!', withdraw_ok: 'Voto retirado.',
    nick_title: '¿Cómo te llamas?', nick_text: 'Tu apodo aparecerá junto a las canciones que pidas.',
    nick_placeholder: 'Tu apodo', save: 'Guardar', cancel: 'Cancelar', change_nick: 'Cambiar apodo',
    by: 'Pedida por', duet: 'Dúo', video: 'Vídeo', pinned: 'Fijada',
    err_nick_empty: 'Escribe un apodo.', err_nick_required: 'Antes dinos tu apodo.',
    err_blocked: 'No puedes hacer peticiones.', err_muted: 'Estás silenciado un rato.',
    err_paused: 'Las peticiones están cerradas ahora mismo.',
    err_already_voted: 'Ya has votado esta canción.',
    err_cooldown: s => `Espera ${s} s antes de pedir otra.`,
    err_recently_sung: 'Esta canción se ha cantado hace poco.',
    err_limit: 'Ya tienes el máximo de peticiones pendientes.',
    err_not_found: 'Esa canción ya no está disponible.',
    err_audio_blocked: 'El navegador no deja reproducir el audio. Vuelve a pulsar Escuchar.',
    err_network: 'No hay conexión con el juego.', err_generic: 'Algo ha fallado.',
    // admin
    admin_title: 'Admin · Peticiones', admin_pin: 'PIN de administración', login: 'Entrar',
    err_wrong_pin: 'PIN incorrecto.', err_locked: 'Demasiados intentos. Espera unos minutos.',
    tab_activity: 'Actividad', blocked_ips: 'IPs bloqueadas', no_blocked_ips: 'Ninguna.', unblock_ip: 'Desbloquear',
    maintenance: 'Mantenimiento', reset_stats: 'Reiniciar estadísticas de peticiones', clear_activity: 'Vaciar actividad',
    confirm_reset_stats: '¿Borrar el recuento de veces pedida y el historial de canciones cantadas?',
    confirm_clear_activity: '¿Vaciar el registro de actividad?', delete_user: 'Borrar usuario',
    confirm_delete: n => `¿Borrar a ${n}? Se quitarán sus votos y tendrá que volver a poner su apodo.`,
    no_activity: 'Todavía no hay actividad.', admin_now: (t1, p) => `Sonando: ${t1}${p ? ' · cantan ' + p : ''}`,
    act_request: (w, d) => `${w} ha pedido ${d}`, act_vote: (w, d) => `${w} ha votado ${d}`,
    act_withdraw: (w, d) => `${w} ha retirado su voto a ${d}`, act_join: (w, d) => `${w} ha entrado (${d})`,
    act_nick: (w, d) => `${d} ahora se llama ${w}`, act_sung: (w, d) => `Se ha cantado ${d}`,
    act_admin_login: (w) => `Admin ha entrado desde ${w}`, act_admin_fail: (w) => `PIN incorrecto desde ${w}`,
    act_admin_clear: () => 'Admin ha vaciado la cola', act_admin_remove: (w, d) => `Admin ha quitado ${d}`,
    act_admin_sung: (w, d) => `Admin ha marcado como cantada ${d}`, act_admin_pin: (w, d) => `Admin ha fijado ${d}`,
    act_admin_unpin: (w, d) => `Admin ha desfijado ${d}`, act_admin_block: (w, d) => `Admin ha bloqueado a ${d}`,
    act_admin_unblock: (w, d) => `Admin ha desbloqueado a ${d}`, act_admin_mute: (w, d) => `Admin ha silenciado a ${d}`,
    act_admin_unmute: (w, d) => `Admin ha quitado el silencio a ${d}`, act_admin_rename: (w, d) => `Admin ha renombrado a ${d}`,
    act_admin_delete: (w, d) => `Admin ha borrado a ${d}`, act_admin_settings: () => 'Admin ha cambiado los ajustes',
    act_admin_unblock_ip: (w, d) => `Admin ha desbloqueado la IP ${d}`, act_admin_reset_stats: () => 'Admin ha reiniciado las estadísticas',
    now_playing: 'Sonando ahora', singing: 'Cantan', votes_col: 'Votos', listen: 'Escuchar', stop_listening: 'Parar',
    tab_users: 'Usuarios', tab_settings: 'Ajustes', song: 'Canción', actions: 'Acciones',
    clear_queue: 'Vaciar cola', confirm_clear: '¿Vaciar toda la cola de peticiones?',
    mark_sung: 'Cantada', remove: 'Quitar', move_up: 'Subir', move_down: 'Bajar', pin: 'Fijar arriba', unpin: 'Desfijar',
    nick: 'Apodo', ip: 'IP', requests_col: 'Peticiones', last_seen: 'Última vez', status: 'Estado',
    blocked: 'Bloqueado', muted: m => `Silenciado ${m} min`, active: 'Activo',
    block: 'Bloquear', unblock: 'Desbloquear', mute: 'Silenciar 15 min', unmute: 'Quitar silencio',
    rename: 'Renombrar', rename_prompt: 'Nuevo apodo:', confirm_block: n => `¿Bloquear a ${n}? Se quitarán sus peticiones.`,
    s_paused: 'Peticiones cerradas', s_max_pending: 'Máximo de peticiones pendientes por persona (0 = sin límite)',
    s_cooldown: 'Segundos mínimos entre peticiones de una persona', s_recent: 'Minutos antes de poder volver a pedir una canción cantada',
    saved: 'Guardado.', no_users: 'Todavía no ha entrado nadie.', unavailable: 'no está en la biblioteca',
    ago_s: s => `hace ${s} s`, ago_m: m => `hace ${m} min`, ago_h: h => `hace ${h} h`, ago_d: d => `hace ${d} d`,
  },
  en: {
    brand: 'Requests', tab_songs: 'Songs', tab_queue: 'Queue',
    search_placeholder: 'Search artist or song…', filters: 'Filters',
    sort_artist: 'Artist A–Z', sort_title: 'Title A–Z', sort_popular: 'Most sung',
    sort_requested: 'Most requested', sort_score: 'Best score', sort_year: 'Newest',
    f_language: 'Language', f_genre: 'Genre', f_decade: 'Decade', f_folder: 'Folder',
    f_duet: 'Duet', f_video: 'Video', any: 'Any', yes: 'Yes', no: 'No',
    with_video: 'With video', without_video: 'Without video', reset: 'Clear filters',
    no_language: 'No language', all: 'All', all_f: 'All',
    paused_notice: 'Requests are closed right now.',
    songs_count: n => `${n} ${n === 1 ? 'song' : 'songs'}`,
    loading: 'Loading…', no_results: 'No matching songs.',
    queue_empty: 'No requests yet. Be the first!',
    in_queue: pos => `Queued #${pos}`, votes: n => `${n} ${n === 1 ? 'vote' : 'votes'}`,
    played: 'Times sung', best: 'Best score', requested: 'Times requested',
    top_scores: 'Top scores', no_scores: 'Nobody has sung it yet.',
    request: 'Request this song', vote: pos => `Add my vote (#${pos})`,
    withdraw: 'Withdraw my vote', requested_ok: 'Requested! Check the queue for its position.',
    vote_ok: 'Vote added!', withdraw_ok: 'Vote withdrawn.',
    nick_title: 'What is your name?', nick_text: 'Your nickname is shown next to the songs you request.',
    nick_placeholder: 'Your nickname', save: 'Save', cancel: 'Cancel', change_nick: 'Change nickname',
    by: 'Requested by', duet: 'Duet', video: 'Video', pinned: 'Pinned',
    err_nick_empty: 'Please enter a nickname.', err_nick_required: 'Tell us your nickname first.',
    err_blocked: 'You cannot request songs.', err_muted: 'You are muted for a while.',
    err_paused: 'Requests are closed right now.',
    err_already_voted: 'You already voted for this song.',
    err_cooldown: s => `Wait ${s} s before requesting again.`,
    err_recently_sung: 'This song was sung recently.',
    err_limit: 'You reached the maximum of pending requests.',
    err_not_found: 'That song is no longer available.',
    err_audio_blocked: 'The browser blocked the audio. Press Listen again.',
    err_network: 'Cannot reach the game.', err_generic: 'Something went wrong.',
    admin_title: 'Admin · Requests', admin_pin: 'Admin PIN', login: 'Log in',
    err_wrong_pin: 'Wrong PIN.', err_locked: 'Too many attempts. Wait a few minutes.',
    tab_activity: 'Activity', blocked_ips: 'Blocked IPs', no_blocked_ips: 'None.', unblock_ip: 'Unblock',
    maintenance: 'Maintenance', reset_stats: 'Reset request statistics', clear_activity: 'Clear activity',
    confirm_reset_stats: 'Delete the request counts and the history of sung songs?',
    confirm_clear_activity: 'Clear the activity log?', delete_user: 'Delete user',
    confirm_delete: n => `Delete ${n}? Their votes are removed and they must enter a nickname again.`,
    no_activity: 'No activity yet.', admin_now: (t1, p) => `Playing: ${t1}${p ? ' · singing ' + p : ''}`,
    act_request: (w, d) => `${w} requested ${d}`, act_vote: (w, d) => `${w} voted for ${d}`,
    act_withdraw: (w, d) => `${w} withdrew their vote for ${d}`, act_join: (w, d) => `${w} joined (${d})`,
    act_nick: (w, d) => `${d} is now called ${w}`, act_sung: (w, d) => `${d} was sung`,
    act_admin_login: (w) => `Admin logged in from ${w}`, act_admin_fail: (w) => `Wrong PIN from ${w}`,
    act_admin_clear: () => 'Admin cleared the queue', act_admin_remove: (w, d) => `Admin removed ${d}`,
    act_admin_sung: (w, d) => `Admin marked ${d} as sung`, act_admin_pin: (w, d) => `Admin pinned ${d}`,
    act_admin_unpin: (w, d) => `Admin unpinned ${d}`, act_admin_block: (w, d) => `Admin blocked ${d}`,
    act_admin_unblock: (w, d) => `Admin unblocked ${d}`, act_admin_mute: (w, d) => `Admin muted ${d}`,
    act_admin_unmute: (w, d) => `Admin unmuted ${d}`, act_admin_rename: (w, d) => `Admin renamed ${d}`,
    act_admin_delete: (w, d) => `Admin deleted ${d}`, act_admin_settings: () => 'Admin changed the settings',
    act_admin_unblock_ip: (w, d) => `Admin unblocked IP ${d}`, act_admin_reset_stats: () => 'Admin reset the statistics',
    now_playing: 'Now playing', singing: 'Singing', votes_col: 'Votes', listen: 'Listen', stop_listening: 'Stop',
    tab_users: 'Users', tab_settings: 'Settings', song: 'Song', actions: 'Actions',
    clear_queue: 'Clear queue', confirm_clear: 'Clear the whole request queue?',
    mark_sung: 'Sung', remove: 'Remove', move_up: 'Up', move_down: 'Down', pin: 'Pin to top', unpin: 'Unpin',
    nick: 'Nickname', ip: 'IP', requests_col: 'Requests', last_seen: 'Last seen', status: 'Status',
    blocked: 'Blocked', muted: m => `Muted ${m} min`, active: 'Active',
    block: 'Block', unblock: 'Unblock', mute: 'Mute 15 min', unmute: 'Unmute',
    rename: 'Rename', rename_prompt: 'New nickname:', confirm_block: n => `Block ${n}? Their requests will be removed.`,
    s_paused: 'Requests closed', s_max_pending: 'Maximum pending requests per person (0 = unlimited)',
    s_cooldown: 'Minimum seconds between requests of a person', s_recent: 'Minutes before a sung song can be requested again',
    saved: 'Saved.', no_users: 'Nobody has joined yet.', unavailable: 'not in the library',
    ago_s: s => `${s} s ago`, ago_m: m => `${m} min ago`, ago_h: h => `${h} h ago`, ago_d: d => `${d} d ago`,
  },
};

function t(key, ...args) {
  const value = (TEXTS[LANG] && TEXTS[LANG][key]) ?? TEXTS.es[key] ?? key;
  return typeof value === 'function' ? value(...args) : value;
}

function applyTranslations(root = document) {
  document.documentElement.lang = LANG;
  root.querySelectorAll('[data-i18n]').forEach(node => { node.textContent = t(node.dataset.i18n); });
  root.querySelectorAll('[data-i18n-placeholder]').forEach(node => { node.placeholder = t(node.dataset.i18nPlaceholder); });
}

// Builds DOM nodes. Text is always set with textContent, never as HTML,
// because nicknames and song data come from other people.
function el(tag, props = {}, ...children) {
  const node = document.createElement(tag);
  for (const [key, value] of Object.entries(props)) {
    if (value === undefined || value === null || value === false) continue;
    if (key === 'class') node.className = value;
    else if (key === 'text') node.textContent = value;
    else if (key.startsWith('on')) node.addEventListener(key.slice(2), value);
    else if (key === 'dataset') Object.assign(node.dataset, value);
    else node.setAttribute(key, value === true ? '' : value);
  }
  for (const child of children.flat()) {
    if (child === null || child === undefined || child === false) continue;
    node.append(child instanceof Node ? child : document.createTextNode(String(child)));
  }
  return node;
}

class ApiError extends Error {
  constructor(code, status) {
    super(code);
    this.code = code;
    this.status = status;
  }
}

async function api(path, body) {
  let response;
  try {
    response = await fetch(path, body === undefined ? { credentials: 'same-origin' } : {
      method: 'POST',
      credentials: 'same-origin',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    });
  } catch (e) {
    throw new ApiError('network', 0);
  }
  let data = null;
  try { data = await response.json(); } catch (e) { /* not JSON */ }
  if (!response.ok) throw new ApiError((data && data.error) || 'generic', response.status);
  return data;
}

function errorText(error) {
  const code = error instanceof ApiError ? error.code : 'generic';
  if (code.startsWith('cooldown:')) return t('err_cooldown', code.split(':')[1]);
  const key = 'err_' + code;
  return TEXTS.es[key] ? t(key) : t('err_generic');
}

let toastTimer = null;
function toast(message, kind = '') {
  document.querySelectorAll('.toast').forEach(node => node.remove());
  const node = el('div', { class: `toast ${kind}`, role: 'status', text: message });
  document.body.append(node);
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => node.remove(), 3500);
}

function openSheet(content, onClose) {
  const backdrop = el('div', { class: 'backdrop' });
  const close = () => { backdrop.remove(); document.removeEventListener('keydown', onKey); if (onClose) onClose(); };
  const onKey = e => { if (e.key === 'Escape') close(); };
  const sheet = el('div', { class: 'sheet', role: 'dialog', 'aria-modal': 'true' },
    el('button', { class: 'close', 'aria-label': 'Cerrar', text: '✕', onclick: close }),
    content);
  backdrop.append(sheet);
  backdrop.addEventListener('click', e => { if (e.target === backdrop) close(); });
  document.addEventListener('keydown', onKey);
  document.body.append(backdrop);
  return close;
}

function coverNode(song, full = false) {
  const initials = (song.artist || '?').trim().split(/\s+/).slice(0, 2).map(w => w[0] || '').join('').toUpperCase();
  const box = el('div', { class: 'cover' }, el('div', { class: 'initials', text: initials }));
  if (song.cover && song.id >= 0) {
    const img = el('img', { alt: '', loading: 'lazy', decoding: 'async', src: `/api/cover/${song.id}${full ? '?full=1' : ''}` });
    img.addEventListener('load', () => img.classList.add('loaded'));
    img.addEventListener('error', () => img.remove());
    box.append(img);
  }
  return box;
}

function timeAgo(unix) {
  if (!unix) return '—';
  const s = Math.max(0, Math.round(Date.now() / 1000 - unix));
  if (s < 60) return t('ago_s', s);
  if (s < 3600) return t('ago_m', Math.round(s / 60));
  if (s < 86400) return t('ago_h', Math.round(s / 3600));
  return t('ago_d', Math.round(s / 86400));
}

function debounce(fn, ms) {
  let timer;
  return (...args) => { clearTimeout(timer); timer = setTimeout(() => fn(...args), ms); };
}

function storageGet(key, fallback) {
  try { return localStorage.getItem(key) ?? fallback; } catch (e) { return fallback; }
}

function storageSet(key, value) {
  try { localStorage.setItem(key, value); } catch (e) { /* private mode */ }
}

// Uses the color of the game's theme for highlights. The second color is the
// lighter variant the game uses as well (square root of each channel).
function applyAccent(hex) {
  if (!/^#[0-9a-f]{6}$/i.test(hex || '')) return;
  const channels = [1, 3, 5].map(i => parseInt(hex.slice(i, i + 2), 16) / 255);
  const light = '#' + channels.map(c => Math.round(Math.sqrt(c) * 255).toString(16).padStart(2, '0')).join('');
  const root = document.documentElement.style;
  root.setProperty('--accent', hex);
  root.setProperty('--accent-2', light);
}
