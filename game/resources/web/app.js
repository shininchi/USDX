'use strict';

// Guest page: browse the library, request songs and follow the queue.

const PAGE_SIZE = 60;

const state = {
  info: null,
  view: storageGet('sr.view', 'grid'),
  sort: storageGet('sr.sort', 'artist'),
  query: '',
  filters: { language: '', genre: '', decade: '', folder: '', duet: '-1', video: '-1' },
  offset: 0,
  total: 0,
  loading: false,
  requestId: 0,
  queue: [],
  tab: 'songs',
};

const $ = id => document.getElementById(id);

// ---------- info, nickname ----------

async function loadInfo() {
  state.info = await api('/api/info');
  applyAccent(state.info.accent);
  $('nickChip').textContent = state.info.me.nick ? `👤 ${state.info.me.nick}` : `👤 ${t('change_nick')}`;
  $('pausedNotice').classList.toggle('hidden', !state.info.paused);
  return state.info;
}

function fillSelect(select, values, emptyLabel, extra = []) {
  const current = select.value;
  select.replaceChildren(el('option', { value: '', text: emptyLabel }),
    ...extra.map(([value, label]) => el('option', { value, text: label })),
    ...values.map(value => el('option', { value, text: value })));
  select.value = current;
}

function fillFilters() {
  const info = state.info;
  fillSelect($('fLanguage'), info.languages, t('all'), [['-', t('no_language')]]);
  fillSelect($('fGenre'), info.genres, t('all'));
  fillSelect($('fFolder'), info.folders, t('all_f'));
  const decades = $('fDecade');
  const current = decades.value;
  decades.replaceChildren(el('option', { value: '', text: t('all_f') }),
    ...info.decades.slice().reverse().map(d => el('option', { value: d, text: `${d}s` })));
  decades.value = current;
}

function askNick() {
  return new Promise(resolve => {
    const input = el('input', { type: 'text', maxlength: '24', placeholder: t('nick_placeholder'), value: (state.info && state.info.me.nick) || '' });
    let done = false;
    const submit = async e => {
      e.preventDefault();
      try {
        await api('/api/me', { nick: input.value });
        await loadInfo();
        done = true;
        close();
        resolve(true);
      } catch (error) {
        toast(errorText(error), 'error');
      }
    };
    const form = el('form', { class: 'form', onsubmit: submit },
      el('h2', { text: t('nick_title') }),
      el('p', { text: t('nick_text') }),
      input,
      el('button', { class: 'btn-primary', type: 'submit', text: t('save') }));
    const close = openSheet(form, () => { if (!done) resolve(false); });
    setTimeout(() => input.focus(), 50);
  });
}

// ---------- song list ----------

function searchParams(offset) {
  const params = new URLSearchParams({ q: state.query, sort: state.sort, offset, limit: PAGE_SIZE });
  for (const [key, value] of Object.entries(state.filters)) {
    if (value !== '' && value !== '-1') params.set(key, value);
  }
  return params;
}

function activeFilterCount() {
  return Object.values(state.filters).filter(v => v !== '' && v !== '-1').length;
}

function songTags(song) {
  const tags = [];
  if (song.language) tags.push(el('span', { class: 'tag', text: song.language }));
  if (song.year) tags.push(el('span', { class: 'tag', text: song.year }));
  if (song.duet) tags.push(el('span', { class: 'tag', text: t('duet') }));
  if (song.played > 0) tags.push(el('span', { class: 'tag hot', text: `♪ ${song.played}` }));
  return el('div', { class: 'tags' }, tags);
}

function songNode(song) {
  const cover = coverNode(song);
  if (song.queuePos) cover.append(el('span', { class: 'queued-mark', text: `#${song.queuePos}` }));
  const meta = el('div', { class: 'meta' },
    el('div', { class: 'title', text: song.title }),
    el('div', { class: 'artist', text: song.artist }),
    state.view === 'text' && song.queuePos ? el('span', { class: 'queued-text', text: `#${song.queuePos}` }) : null,
    state.view === 'list' ? songTags(song) : null);
  // in the text view the artist goes first
  if (state.view === 'text') meta.prepend(meta.querySelector('.artist'));
  return el('div', { class: 'song', onclick: () => openSong(song.id) }, cover, meta);
}

async function loadSongs(reset) {
  if (reset) {
    state.offset = 0;
    state.total = 0;
    $('results').replaceChildren();
  } else if (state.loading || state.offset >= state.total) {
    return;
  }
  const requestId = ++state.requestId;
  state.loading = true;
  $('summary').textContent = t('loading');
  try {
    const data = await api('/api/songs?' + searchParams(state.offset));
    if (requestId !== state.requestId) return; // a newer search started
    state.total = data.total;
    state.offset += data.items.length;
    $('results').append(...data.items.map(songNode));
    $('summary').textContent = t('songs_count', data.total);
    if (data.total === 0) $('results').append(el('div', { class: 'empty', text: t('no_results') }));
  } catch (error) {
    if (requestId === state.requestId) $('summary').textContent = errorText(error);
  } finally {
    if (requestId === state.requestId) state.loading = false;
  }
  // keep loading while the sentinel is still visible
  if (requestId === state.requestId && state.offset < state.total && isSentinelVisible()) loadSongs(false);
}

function isSentinelVisible() {
  const rect = $('sentinel').getBoundingClientRect();
  return rect.top < window.innerHeight + 400;
}

function setView(view) {
  state.view = view;
  storageSet('sr.view', view);
  $('results').className = `results ${view}`;
  document.querySelectorAll('.view-toggle button').forEach(b => b.classList.toggle('active', b.dataset.view === view));
  loadSongs(true);
}

function updateFiltersBadge() {
  const count = activeFilterCount();
  $('filtersBadge').textContent = count;
  $('filtersBadge').classList.toggle('hidden', count === 0);
}

// ---------- audio preview ----------

const PREVIEW_SECONDS = 30;
const preview = { audio: null, timer: null, fade: null, button: null, video: null };

function stopPreview() {
  clearTimeout(preview.timer);
  clearInterval(preview.fade);
  if (preview.audio) {
    preview.audio.pause();
    preview.audio.removeAttribute('src');
    preview.audio.load();
  }
  if (preview.button) preview.button.textContent = `▶ ${t('listen')}`;
  if (preview.video) preview.video.loop = true; // back to the silent loop
  preview.audio = null;
  preview.button = null;
  preview.video = null;
}

// Keeps the preview clip at the same moment as the audio. The clip starts
// at song.clipStart (audio time), so its position is the audio position
// minus that.
function syncVideo(song, button) {
  const audio = preview.audio;
  const video = button.closest('.detail')?.querySelector('.cover-video');
  if (!audio || !video || video.readyState < 1) return;
  preview.video = video;
  video.loop = false;
  const target = audio.currentTime - song.clipStart;
  if (target < 0 || target > (video.duration || 0)) return;
  if (Math.abs(video.currentTime - target) > 0.35) video.currentTime = target;
  if (video.paused) video.play().catch(() => {});
}

// Same start point as the game: #PREVIEWSTART, or a quarter into the part
// between #START and #END.
function previewStart(song, duration) {
  // with a video clip the audio starts where the clip starts
  if (song.clip && song.clipStart >= 0) return song.clipStart;
  if (song.previewStart >= 0) return song.previewStart;
  const start = song.start || 0;
  const end = song.finish > 0 ? Math.min(song.finish, duration) : duration;
  let offset = (end - start) / 4;
  if (offset > 120) offset = 60;
  return start + offset;
}

function togglePreview(song, button) {
  if (preview.button === button) {
    stopPreview();
    return;
  }
  stopPreview();
  const audio = new Audio(`/api/audio/${song.id}`);
  preview.audio = audio;
  preview.button = button;
  button.textContent = `■ ${t('stop_listening')}`;
  // play() has to be called right in the click handler, otherwise browsers
  // like Firefox block the sound. It starts silent and jumps to the preview
  // position as soon as the length of the song is known.
  // muted instead of volume 0: iOS ignores the volume property
  audio.muted = true;
  const play = () => audio.play().catch(error => {
    if (preview.audio !== audio) return;
    console.warn('Audio preview:', error.name, error.message);
    // Firefox aborts the first play() when the position changes while the
    // file is loading; only a real autoplay block is reported.
    if (error.name === 'NotAllowedError') {
      stopPreview();
      toast(t('err_audio_blocked'), 'error');
    }
  });
  audio.addEventListener('loadedmetadata', () => {
    audio.addEventListener('seeked', () => {
      if (preview.audio !== audio) return;
      audio.muted = false;
      if (audio.paused) play();
    }, { once: true });
    audio.currentTime = previewStart(song, audio.duration || 0);
  }, { once: true });
  if (song.clip) audio.addEventListener('timeupdate', () => { if (preview.audio === audio) syncVideo(song, button); });
  audio.addEventListener('error', () => {
    if (preview.audio !== audio) return;
    console.warn('Audio preview error:', audio.error && audio.error.code);
    stopPreview();
    toast(t('err_generic'), 'error');
  });
  play();
  // fade out at the end of the preview
  preview.timer = setTimeout(() => {
    preview.fade = setInterval(() => {
      audio.volume = Math.max(0, audio.volume - 0.1);
      if (audio.volume <= 0) stopPreview();
    }, 200);
  }, (PREVIEW_SECONDS - 2) * 1000);
}

// ---------- video preview ----------

// Asks the game for the preview clip, waiting while ffmpeg makes it, and
// fades the cover into the muted video once it plays.
async function loadClip(song, cover, isOpen) {
  for (let attempt = 0; attempt < 30 && isOpen(); attempt++) {
    let response;
    try {
      response = await fetch(`/api/video/${song.id}`, { headers: { Range: 'bytes=0-0' } });
    } catch (e) {
      return;
    }
    if (response.status === 202) {
      await new Promise(resolve => setTimeout(resolve, 2000));
      continue;
    }
    if (!response.ok || !isOpen()) return;
    const video = el('video', { class: 'cover-video', muted: true, playsinline: true, loop: true, autoplay: true, preload: 'auto' });
    video.muted = true; // the attribute alone is not enough for autoplay in Safari
    video.addEventListener('playing', () => setTimeout(() => video.classList.add('visible'), 1000), { once: true });
    video.src = `/api/video/${song.id}`;
    cover.append(video);
    video.play().catch(() => {});
    return;
  }
}

// ---------- song detail ----------

async function openSong(id) {
  let song;
  try {
    song = await api(`/api/songs/${id}`);
  } catch (error) {
    toast(errorText(error), 'error');
    return;
  }

  const stats = el('div', { class: 'stats' },
    el('div', { class: 'stat' }, el('strong', { text: song.played }), el('span', { text: t('played') })),
    el('div', { class: 'stat' }, el('strong', { text: song.best || '—' }), el('span', { text: t('best') })),
    el('div', { class: 'stat' }, el('strong', { text: song.requests }), el('span', { text: t('requested') })));

  const scores = song.scores.length
    ? el('div', { class: 'scores' }, song.scores.map(s =>
        el('div', { class: 'score' }, el('span', { text: s.player }), el('strong', { text: s.score }))))
    : el('p', { class: 'summary', text: t('no_scores') });

  const tags = el('div', { class: 'tags' },
    [song.language, song.genre, song.year || '', song.edition, song.duet ? t('duet') : '', song.video ? t('video') : '']
      .filter(Boolean).map(text => el('span', { class: 'tag', text })));

  const row = el('div', { class: 'request-row' });
  let close;
  const act = async (path, okText) => {
    try {
      await api(path, { id: song.id });
      toast(okText, 'ok');
      close();
      refreshQueue();
      loadSongs(true);
    } catch (error) {
      if (error.code === 'nick_required' && await askNick()) return act(path, okText);
      toast(errorText(error), 'error');
    }
  };
  if (song.voted) {
    row.append(el('button', { class: 'btn-ghost', text: t('withdraw'), onclick: () => act('/api/unvote', t('withdraw_ok')) }));
  } else if (song.queuePos) {
    row.append(el('button', { class: 'btn-primary', text: t('vote', song.queuePos), onclick: () => act('/api/request', t('vote_ok')) }));
  } else {
    row.append(el('button', { class: 'btn-primary', text: t('request'), onclick: () => act('/api/request', t('requested_ok')) }));
  }

  const listen = song.audio
    ? el('button', { class: 'btn-ghost listen', text: `▶ ${t('listen')}` })
    : null;
  if (listen) listen.addEventListener('click', () => togglePreview(song, listen));

  const cover = coverNode(song, true);
  let open = true;
  if (song.clip) loadClip(song, cover, () => open);

  close = openSheet(el('div', { class: 'detail' },
    cover,
    el('h2', { text: song.title }),
    el('div', { class: 'artist', text: song.artist }),
    listen,
    tags,
    stats,
    el('h3', { text: t('top_scores') }),
    scores,
    row), () => {
      open = false;
      stopPreview();
      cover.querySelectorAll('video').forEach(v => { v.pause(); v.removeAttribute('src'); v.load(); });
    });
}

// ---------- queue ----------

function queueNode(item) {
  const vote = item.voted
    ? el('button', { class: 'btn-ghost', title: t('withdraw'), text: '♥', onclick: () => queueVote(item, '/api/unvote', t('withdraw_ok')) })
    : el('button', { class: 'btn-primary', title: t('vote', item.position), text: '+1', onclick: () => queueVote(item, '/api/request', t('vote_ok')) });
  return el('div', { class: `queue-item${item.voted ? ' mine' : ''}` },
    el('div', { class: 'pos' }, item.pinned ? el('span', { class: 'pin', title: t('pinned'), text: '📌' }) : item.position),
    coverNode(item),
    el('div', {},
      el('div', { class: 'title', text: item.title }),
      el('div', { class: 'artist', text: item.artist }),
      el('div', { class: 'by', text: `${t('by')}: ${item.by.join(', ')}` })),
    el('div', { class: 'votes' }, el('strong', { text: item.votes }), item.id >= 0 ? vote : null));
}

async function queueVote(item, path, okText) {
  try {
    await api(path, { id: item.id });
    toast(okText, 'ok');
    refreshQueue();
  } catch (error) {
    if (error.code === 'nick_required' && await askNick()) return queueVote(item, path, okText);
    toast(errorText(error), 'error');
  }
}

// ---------- now playing ----------

let nowPlaying = null;

function renderNowPlaying(now) {
  const box = $('nowPlaying');
  const sameSong = now && nowPlaying && now.startedAt === nowPlaying.startedAt;
  nowPlaying = now;
  if (!now) {
    box.classList.add('hidden');
    box.replaceChildren();
    return;
  }
  box.classList.remove('hidden');
  if (sameSong) return; // keep the cover image, only the progress moves
  box.replaceChildren(
    coverNode(now),
    el('div', { class: 'now-text' },
      el('div', { class: 'now-label', text: `♪ ${t('now_playing')}` }),
      el('div', { class: 'now-title', text: `${now.title} — ${now.artist}` }),
      now.players ? el('div', { class: 'now-players', text: `${t('singing')}: ${now.players}` }) : null),
    el('div', { class: 'now-progress' }, el('div', { class: 'now-bar', id: 'nowBar' })));
  updateNowProgress();
}

function updateNowProgress() {
  if (!nowPlaying || !nowPlaying.duration) return;
  const position = Date.now() / 1000 - nowPlaying.startedAt + nowPlaying.offset;
  const bar = $('nowBar');
  if (bar) bar.style.width = `${Math.min(100, Math.max(0, position / nowPlaying.duration * 100))}%`;
}

async function refreshQueue() {
  try {
    const data = await api('/api/queue');
    renderNowPlaying(data.now);
    state.queue = data.items;
    $('queueBadge').textContent = data.items.length;
    $('queueBadge').classList.toggle('hidden', data.items.length === 0);
    $('pausedNotice').classList.toggle('hidden', !data.paused);
    $('queue').replaceChildren(...(data.items.length
      ? data.items.map(queueNode)
      : [el('div', { class: 'empty', text: t('queue_empty') })]));
  } catch (error) {
    if (state.tab === 'queue') $('queue').replaceChildren(el('div', { class: 'empty', text: errorText(error) }));
  }
}

function setTab(tab) {
  state.tab = tab;
  $('tabSongs').classList.toggle('active', tab === 'songs');
  $('tabQueue').classList.toggle('active', tab === 'queue');
  $('songsView').classList.toggle('hidden', tab !== 'songs');
  $('queueView').classList.toggle('hidden', tab !== 'queue');
  if (tab === 'queue') refreshQueue();
}

// ---------- start ----------

async function start() {
  applyTranslations();
  $('sort').value = state.sort;
  $('results').className = `results ${state.view}`;
  document.querySelectorAll('.view-toggle button').forEach(b => {
    b.classList.toggle('active', b.dataset.view === state.view);
    b.addEventListener('click', () => setView(b.dataset.view));
  });

  $('search').addEventListener('input', debounce(e => { state.query = e.target.value; loadSongs(true); }, 250));
  $('sort').addEventListener('change', e => { state.sort = e.target.value; storageSet('sr.sort', state.sort); loadSongs(true); });
  $('filtersBtn').addEventListener('click', () => $('filters').classList.toggle('hidden'));
  const filterInputs = { fLanguage: 'language', fGenre: 'genre', fDecade: 'decade', fFolder: 'folder', fDuet: 'duet', fVideo: 'video' };
  for (const [id, key] of Object.entries(filterInputs)) {
    $(id).addEventListener('change', e => { state.filters[key] = e.target.value; updateFiltersBadge(); loadSongs(true); });
  }
  $('resetFilters').addEventListener('click', () => {
    for (const [id, key] of Object.entries(filterInputs)) {
      state.filters[key] = key === 'duet' || key === 'video' ? '-1' : '';
      $(id).value = state.filters[key];
    }
    updateFiltersBadge();
    loadSongs(true);
  });
  $('tabSongs').addEventListener('click', () => setTab('songs'));
  $('tabQueue').addEventListener('click', () => setTab('queue'));
  $('nickChip').addEventListener('click', askNick);

  new IntersectionObserver(entries => {
    if (entries.some(e => e.isIntersecting)) loadSongs(false);
  }, { rootMargin: '400px' }).observe($('sentinel'));

  try {
    await loadInfo();
    fillFilters();
  } catch (error) {
    $('summary').textContent = errorText(error);
    return;
  }
  loadSongs(true);
  refreshQueue();
  if (!state.info.me.nick) askNick();

  setInterval(refreshQueue, 10000);
  setInterval(updateNowProgress, 1000);
  setInterval(() => loadInfo().catch(() => {}), 30000);
}

start();
