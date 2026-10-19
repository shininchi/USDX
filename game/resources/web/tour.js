'use strict';

// Guided tour of the guest page: shown once on the first visit (and again
// from "See the guide"), it dims the page but the part it explains.

Object.assign(TEXTS.es, {
  tour_next: 'Siguiente', tour_back: 'Atrás', tour_skip: 'Saltar', tour_done: '¡A cantar!',
  tour_step: (n, total) => `${n} de ${total}`, tour_replay: 'Ver la guía',
  tour_welcome_t: 'Bienvenido al Cancionero',
  tour_welcome: 'Desde aquí eliges qué cantar en el karaoke. Te enseñamos lo básico en un momento.',
  tour_nick_t: 'Tu apodo',
  tour_nick: 'Sale junto a las canciones que pides y en tus puntuaciones. Púlsalo para cambiarlo.',
  tour_mic_t: 'Tu micrófono',
  tour_mic: 'Elige con qué micrófono cantas para que las puntuaciones vayan a tu nombre. Se puede cambiar en la lista de canciones o con la canción en pausa. Desde aquí también lo sueltas con «Dejar mi micrófono».',
  tour_search_t: 'Buscar',
  tour_search: 'Escribe parte del artista o del título.',
  tour_filters_t: 'Filtros y orden',
  tour_filters: 'Filtra por idioma, género, década, carpeta, dúo o vídeo, ordena la lista y cambia entre cuadrícula, lista o solo texto.',
  tour_lucky_t: 'Canción al azar',
  tour_lucky: '¿No sabes qué cantar? Pulsa el bloque y te tocará una canción de las que estás viendo, con tus filtros. Puedes volver a tirar.',
  tour_song_t: 'Pedir una canción',
  tour_song: 'Toca una canción para ver sus detalles, escucharla y pedirla.',
  tour_records_t: 'Logros',
  tour_records: 'Las calificaciones que consigues al cantar, cuántas veces cada una, y tu mejor racha de canciones ganadas.',
  tour_queue_t: 'En cola',
  tour_queue: 'Lo que se va a cantar. Si alguien ya ha pedido una canción que te gusta, súmale tu voto para que suba; puedes retirarlo cuando quieras.',
  tour_share_t: 'Invita a más gente',
  tour_share: 'Toca el logo y aparecerá el código QR del Cancionero para que otros lo abran en su móvil, o para compartir el enlace.',
  tour_end_t: 'Eso es todo',
  tour_end: 'Si quieres volver a ver esta guía, está al final de «En cola».',
});

Object.assign(TEXTS.en, {
  tour_next: 'Next', tour_back: 'Back', tour_skip: 'Skip', tour_done: "Let's sing!",
  tour_step: (n, total) => `${n} of ${total}`, tour_replay: 'See the guide',
  tour_welcome_t: 'Welcome to the Songbook',
  tour_welcome: 'This is where you pick what to sing at the karaoke. Here is the basics in a moment.',
  tour_nick_t: 'Your nickname',
  tour_nick: 'It shows next to the songs you request and on your scores. Tap it to change it.',
  tour_mic_t: 'Your microphone',
  tour_mic: 'Pick the microphone you sing with so the scores go to your name. It can be changed in the song list or with the song paused. You also give it back here with "Leave my microphone".',
  tour_search_t: 'Search',
  tour_search: 'Type part of the artist or the title.',
  tour_filters_t: 'Filters and order',
  tour_filters: 'Filter by language, genre, decade, folder, duet or video, sort the list and switch between grid, list or text only.',
  tour_lucky_t: 'Random song',
  tour_lucky: 'Not sure what to sing? Tap the block and you get one of the songs you are looking at, with your filters. You can spin again.',
  tour_song_t: 'Request a song',
  tour_song: 'Tap a song to see its details, listen to it and request it.',
  tour_records_t: 'Achievements',
  tour_records: 'The ratings you get singing, how many times each, and your best streak of songs won.',
  tour_queue_t: 'In queue',
  tour_queue: 'What is going to be sung. If someone already requested a song you like, add your vote so it moves up; you can take it back any time.',
  tour_share_t: 'Invite more people',
  tour_share: 'Tap the logo and the QR code of the Songbook shows up for others to open it on their phone, or to share the link.',
  tour_end_t: "That's all",
  tour_end: 'To see this guide again, it is at the end of "In queue".',
});

const TOUR_KEY = 'sr.tour';
const TOUR_STEPS = [
  { key: 'welcome' },
  { key: 'nick', target: () => $('nickChip') },
  { key: 'mic', target: () => $('micChip') },
  { key: 'search', target: () => $('search') },
  { key: 'filters', target: () => document.querySelector('#songsView .toolbar') },
  { key: 'lucky', target: () => $('luckyBtn') },
  { key: 'song', target: () => document.querySelector('#results .song') },
  { key: 'records', target: () => $('tabRecords') },
  { key: 'queue', target: () => $('tabQueue') },
  { key: 'share', target: () => $('brandLogo') },
  { key: 'end' },
];

let tour = null;

function startTour() {
  if (tour) return;
  if (state.tab !== 'songs') setTab('songs');
  window.scrollTo({ top: 0 });
  const spot = el('div', { class: 'tour-spot' });
  const card = el('div', { class: 'tour-card', role: 'dialog', 'aria-modal': 'true' });
  const layer = el('div', { class: 'tour-layer' }, spot, card);
  document.body.append(layer);
  tour = { index: 0, layer, spot, card };
  const onKey = e => { if (e.key === 'Escape') endTour(); };
  const onMove = () => placeTour();
  tour.cleanup = () => {
    document.removeEventListener('keydown', onKey);
    window.removeEventListener('resize', onMove);
    window.removeEventListener('scroll', onMove, true);
  };
  document.addEventListener('keydown', onKey);
  window.addEventListener('resize', onMove);
  window.addEventListener('scroll', onMove, true);
  showTourStep(0);
}

function endTour() {
  if (!tour) return;
  tour.cleanup();
  tour.layer.remove();
  tour = null;
  storageSet(TOUR_KEY, 'done');
}

function showTourStep(index) {
  tour.index = index;
  const step = TOUR_STEPS[index];
  const last = index === TOUR_STEPS.length - 1;
  tour.card.replaceChildren(
    el('div', { class: 'tour-count', text: t('tour_step', index + 1, TOUR_STEPS.length) }),
    el('h2', { text: t(`tour_${step.key}_t`) }),
    el('p', { text: t(`tour_${step.key}`) }),
    el('div', { class: 'tour-buttons' },
      last ? null : el('button', { class: 'btn-ghost', text: t('tour_skip'), onclick: endTour }),
      index > 0 ? el('button', { class: 'btn-ghost', text: t('tour_back'), onclick: () => showTourStep(index - 1) }) : null,
      el('button', { class: 'btn-primary', text: last ? t('tour_done') : t('tour_next'),
        onclick: () => (last ? endTour() : showTourStep(index + 1)) })));
  const target = step.target && step.target();
  if (target && target.getBoundingClientRect().width > 0) {
    const rect = target.getBoundingClientRect();
    if (rect.top < 0 || rect.bottom > window.innerHeight) target.scrollIntoView({ block: 'center' });
  }
  placeTour();
  tour.card.querySelector('.btn-primary').focus({ preventScroll: true });
}

// the light circle on the part explained, and the card next to it
function placeTour() {
  if (!tour) return;
  const step = TOUR_STEPS[tour.index];
  const target = step.target && step.target();
  const rect = target && target.getBoundingClientRect();
  const { spot, card } = tour;
  const margin = 12;
  if (!rect || rect.width === 0) {
    spot.classList.add('none');
    card.style.top = `${Math.max(margin, (window.innerHeight - card.offsetHeight) / 2)}px`;
    card.style.left = `${Math.max(margin, (window.innerWidth - card.offsetWidth) / 2)}px`;
    return;
  }
  spot.classList.remove('none');
  const pad = 6;
  spot.style.top = `${rect.top - pad}px`;
  spot.style.left = `${rect.left - pad}px`;
  spot.style.width = `${rect.width + pad * 2}px`;
  spot.style.height = `${rect.height + pad * 2}px`;
  // below the target if it fits, above otherwise
  const below = rect.bottom + pad + margin;
  const top = below + card.offsetHeight <= window.innerHeight
    ? below
    : Math.max(margin, rect.top - pad - margin - card.offsetHeight);
  const left = Math.min(Math.max(margin, rect.left + rect.width / 2 - card.offsetWidth / 2),
    window.innerWidth - card.offsetWidth - margin);
  card.style.top = `${top}px`;
  card.style.left = `${left}px`;
}

function maybeStartTour() {
  if (storageGet(TOUR_KEY, '') !== 'done') setTimeout(startTour, 300);
}
