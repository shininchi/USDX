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

  close = openSheet(el('div', { class: 'detail' },
    coverNode(song, true),
    el('h2', { text: song.title }),
    el('div', { class: 'artist', text: song.artist }),
    tags,
    stats,
    el('h3', { text: t('top_scores') }),
    scores,
    row));
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

async function refreshQueue() {
  try {
    const data = await api('/api/queue');
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
  setInterval(() => loadInfo().catch(() => {}), 30000);
}

start();
