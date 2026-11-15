// Builds the Pixelbolt recipes for the evals README art (one hero and one banner for each section).
// Run:     node build-recipes.mjs          (writes *.pixel.json beside this file)
// Render:  ./render.sh                     (needs Pixelbolt: PIXELBOLT=/path/to/Pixelbolt/bin/pixelbolt.js)
// The icons are small original pixel drawings. They are not the official logos.
import { writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));

const palette = {
  n: '#0e1a2b', N: '#15263d', M: '#1d3454',
  g: '#2f9e5b', G: '#1b6b3c', h: '#62d48b',
  s: '#cfd6de', S: '#8b95a1', k: '#0a0f18',
  y: '#ffd23f', o: '#ff8a3d', r: '#e0334f', R: '#ff7a8e',
  c: '#3ddcff', C: '#1d8fb3', w: '#f4f6fa', l: '#8fe05a', L: '#4aa83a',
  p: '#f2b894', b: '#3a6ea5', B: '#264a73', m: '#5a3a22',
  d: '#7a5538', D: '#4d3424', v: '#a678ff', V: '#6b45c0',
  P: '#3d7ab8', Y: '#ffd43b', a: '#dc322f', A: '#8f1d1b',
  e: '#9aa3ad', E: '#2065b8', f: '#f5c542', F: '#c9962b', u: '#e9eef5', t: '#2a3f5e',
};

// ---------------------------------------------------------------- drawing helpers
const rect = (x, y, w, h, color) => ({ op: 'rect', x, y, w, h, color, filled: true });
const px = (x, y, color) => ({ op: 'pixel', x, y, color });
const line = (x, y, x2, y2, color) => ({ op: 'line', x, y, x2, y2, color });
const text = (x, y, t, color, align = 'left') => ({ op: 'text', x, y, text: t, color, align });
const grid = (x, y, rows) => ({ op: 'grid', x, y, rows });
const ellipse = (x, y, w, h, color) => ({ op: 'ellipse', x, y, w, h, color, filled: true });

function along(path, t) {
  const seg = []; let total = 0;
  for (let i = 0; i < path.length - 1; i++) {
    const d = Math.abs(path[i + 1][0] - path[i][0]) + Math.abs(path[i + 1][1] - path[i][1]);
    seg.push(d); total += d;
  }
  let dist = Math.min(Math.max(t, 0), 1) * total;
  for (let i = 0; i < seg.length; i++) {
    if (dist <= seg[i] || i === seg.length - 1) {
      const f = seg[i] ? dist / seg[i] : 0;
      return [Math.round(path[i][0] + (path[i + 1][0] - path[i][0]) * f), Math.round(path[i][1] + (path[i + 1][1] - path[i][1]) * f)];
    }
    dist -= seg[i];
  }
  return path[path.length - 1];
}
const packet = (path, t, color) => { const [x, y] = along(path, t); return [rect(x - 1, y - 1, 3, 3, color), px(x, y, 'w')]; };
const wire = (p, color = 'M') => { const o = []; for (let i = 0; i < p.length - 1; i++) o.push(line(...p[i], ...p[i + 1], color)); return o; };
const ease = (t) => t * t * (3 - 2 * t);
const clamp = (t) => Math.min(1, Math.max(0, t));

function background(f, W, H) {
  const ops = [rect(0, 0, W, H, 'n')];
  for (let y = 0; y < H; y += 8) for (let x = 0; x < W; x += 8) ops.push(px(x, y, 'N'));
  ops.push(rect(0, H - 3, W, 3, 'N'));
  const stars = [[8, 4], [44, 9], [93, 3], [151, 6], [188, 10], [123, 12], [66, 17], [172, 20]];
  stars.forEach(([x, y], i) => { if (y < H - 6) ops.push(px(x, y, (f + i * 3) % 8 < 4 ? 'M' : 'c')); });
  return ops;
}

// ---------------------------------------------------------------- icons (x, y is the top-left corner)
const sparkRows = [
  '.....o.....',
  '.....o.....',
  '....ooo....',
  'ooooooooooo',
  '.ooooooooo.',
  '..ooooooo..',
  '...ooooo...',
  '..ooo.ooo..',
  '..oo...oo..',
  '.o.......o.',
];
const sparkIcon = (x, y, f = 0) => [grid(x, y, sparkRows), px(x + 5, y, f % 2 ? 'y' : 'o'), px(x + 5, y + 4, f % 2 ? 'y' : 'w')]; // 11 x 10

const pyIcon = (x, y) => [ // 12 x 12
  rect(x, y, 8, 8, 'P'), rect(x + 4, y + 4, 8, 8, 'Y'),
  line(x + 4, y + 4, x + 4, y + 7, 'k'), line(x + 4, y + 4, x + 7, y + 4, 'k'),
  rect(x + 1, y + 1, 4, 1, 'B'), rect(x + 7, y + 10, 4, 1, 'F'),
  px(x + 2, y + 2, 'w'), px(x + 9, y + 9, 'k'),
];
const scalaRows = [
  '.aaaaaaaa..',
  'aaaaaaaaa..',
  'AAAAAAAAA..',
  '.aaaaaaaa..',
  'aaaaaaaaa..',
  'AAAAAAAAA..',
  '.aaaaaaaa..',
  'aaaaaaaaa..',
];
const scalaIcon = (x, y) => [grid(x, y, scalaRows)]; // 11 x 8
const rIcon = (x, y) => [ellipse(x, y, 16, 12, 'e'), ellipse(x + 2, y + 2, 12, 8, 'u'), { op: 'text', x: x + 5, y: y + 1, text: 'R', color: 'E', scale: 2 }]; // 16 x 12

const folderIcon = (x, y, open = 0) => [ // 20 x 14
  rect(x, y, 8, 3, 'F'), rect(x, y + 2, 20, 12, 'F'),
  rect(x + 1, y + 4 - open, 18, 10 + open, open ? 'u' : 'f'),
  rect(x, y + 6 + (open ? 1 : 0), 20, 8 - (open ? 1 : 0), 'f'),
  rect(x, y + 13, 20, 1, 'F'),
];
const datasetIcon = (x, y, rows = 4, hi = -1) => { // 18 x (4 + 3 * rows)
  const ops = [rect(x, y, 18, 3 + rows * 3 + 1, 'u'), rect(x, y, 18, 3, 'b')];
  for (let r = 0; r < rows; r++) {
    ops.push(rect(x + 1, y + 4 + r * 3, 16, 2, r === hi ? 'y' : (r % 2 ? 'S' : 's')));
    ops.push(px(x + 6, y + 4 + r * 3, 'k'), px(x + 12, y + 4 + r * 3, 'k'));
  }
  ops.push(line(x + 6, y, x + 6, y + 3 + rows * 3, 't'), line(x + 12, y, x + 12, y + 3 + rows * 3, 't'));
  return ops;
};

const berry = ['.l.l.', '.rrr.', 'rRrrr', 'rrrRr', '.rrr.'];
function piSmall(x, y, label, f, { busy = false } = {}) { // 26 x 14
  const ops = [rect(x, y, 26, 14, 'G'), rect(x + 1, y + 1, 24, 12, 'g')];
  for (let i = 0; i < 9; i++) ops.push(px(x + 3 + i * 2, y + 2, 'y'));
  ops.push(rect(x + 9, y + 5, 6, 6, 'S'), rect(x + 10, y + 6, 4, 4, busy ? (f % 2 ? 'y' : 'o') : 's'));
  ops.push(rect(x + 20, y + 4, 5, 3, 's'), rect(x + 20, y + 8, 5, 3, 's'));
  ops.push(grid(x + 2, y + 6, berry));
  ops.push(px(x + 2, y + 12, 'r'), px(x + 4, y + 12, busy ? (f % 2 ? 'l' : 'w') : 'L'));
  if (label) ops.push(text(x + 13, y - 7, label, 'w', 'center'));
  return ops;
}

const checkIcon = (x, y, color = 'l') => [px(x, y + 3, color), px(x + 1, y + 4, color), px(x + 2, y + 5, color), px(x + 3, y + 4, color), px(x + 4, y + 3, color), px(x + 5, y + 2, color), px(x + 6, y + 1, color), px(x + 7, y, color)];
const spinner = (x, y, f, color = 'c') => { // 9 x 9 ring of 8 dots
  const pos = [[4, 0], [7, 1], [8, 4], [7, 7], [4, 8], [1, 7], [0, 4], [1, 1]];
  return pos.map(([dx, dy], i) => px(x + dx, y + dy, ((f - i + 8) % 8) < 3 ? color : 'M'));
};
const clockIcon = (x, y, f) => { // 15 x 15, hand turns once in 24 frames
  const cx = x + 7, cy = y + 7;
  const tips = [[0, -5], [2, -5], [4, -3], [5, -2], [5, 0], [5, 2], [4, 3], [2, 5], [0, 5], [-2, 5], [-4, 3], [-5, 2], [-5, 0], [-5, -2], [-4, -3], [-2, -5]];
  const [tx, ty] = tips[Math.floor((f * 16) / 24) % 16];
  return [ellipse(x, y, 15, 15, 'S'), ellipse(x + 1, y + 1, 13, 13, 'u'),
    px(cx, y + 2, 'k'), px(cx, y + 12, 'k'), px(x + 2, cy, 'k'), px(x + 12, cy, 'k'),
    line(cx, cy, cx + tx, cy + ty, 'a'), line(cx, cy, cx, cy - 3, 'k'), px(cx, cy, 'k')];
};
const terminal = (x, y, w, h, shown, f, title = '') => { // window with a prompt line
  const ops = [rect(x, y, w, h, 'k'), rect(x, y, w, 9, 't'), px(x + 2, y + 4, 'r'), px(x + 5, y + 4, 'y'), px(x + 8, y + 4, 'l')];
  if (title) ops.push(text(x + w - 3, y + 1, title, 'S', 'right'));
  ops.push(text(x + 3, y + 13, '$', 'l'), text(x + 9, y + 13, shown, 'w'));
  if (f % 4 < 2) ops.push(rect(x + 9 + shown.length * 6, y + 13, 4, 6, 'w'));
  return ops;
};
const bigCheck = (x, y, color = 'l') => [ // 14 x 11 chunky check
  line(x, y + 6, x + 4, y + 10, color), line(x + 1, y + 6, x + 5, y + 10, color), line(x + 2, y + 6, x + 6, y + 10, color),
  line(x + 6, y + 10, x + 13, y, color), line(x + 5, y + 10, x + 12, y, color), line(x + 4, y + 10, x + 11, y, color),
];
const sparkle = (x, y, f, seed = 0) => ((f + seed) % 6 < 3) ? [px(x, y, 'w'), px(x - 1, y, 'y'), px(x + 1, y, 'y'), px(x, y - 1, 'y'), px(x, y + 1, 'y')] : [px(x, y, 'y')];

// ---------------------------------------------------------------- recipe builder
function recipe(name, W, H, N, draw, duration = 110) {
  const frames = [];
  for (let f = 0; f < N; f++) {
    const ops = [...background(f, W, H), ...draw(f, N, W, H)];
    frames.push({ name: `f${String(f).padStart(2, '0')}`, duration, ops: ops.filter((o) => (o.op !== 'rect' || (o.w >= 1 && o.h >= 1)) && (o.op !== 'text' || o.text.length > 0)) });
  }
  return { version: 1, name, width: W, height: H, palette, frames, animations: { loop: { frames: frames.map((x) => x.name) } } };
}
const lang = (i, x, y, f) => [ // language icon by index: 0 spark, 1 pyspark, 2 scala, 3 R
  () => sparkIcon(x, y, f), () => pyIcon(x, y), () => scalaIcon(x, y + 2), () => rIcon(x - 2, y)][i]();
const bounce = (f, i) => ((f + i * 3) % 12 < 6 ? -1 : 0);

const scenes = {};

// ---------------------------------------------------------------- hero (200 x 80)
scenes.hero = recipe('evals-hero', 200, 80, 24, (f) => {
  const ops = [];
  const stage = Math.floor(f / 6), t = (f % 6) / 5;
  ops.push(text(4, 4, 'SPARK EVALS', 'w'), text(4, 12, 'PYSPARK  SCALA  R', 'o'));
  // language icons, top right
  [[0, 126], [1, 146], [2, 164], [3, 180]].forEach(([i, x], k) => ops.push(...lang(i, x, 4 + bounce(f, k) , f)));
  // data (left), cluster (middle), monitor (right)
  const toMaster = [[30, 52], [50, 52], [50, 52], [60, 52]];
  const toA = [[86, 49], [96, 49], [96, 38], [106, 38]];
  const toB = [[86, 49], [96, 49], [96, 64], [106, 64]];
  [toMaster, toA, toB].forEach((p) => ops.push(...wire(p)));
  ops.push(...folderIcon(6, 44, stage === 0 ? 0 : 1), ...datasetIcon(10, 24, 3, stage === 0 ? f % 3 : -1), text(16, 62, 'DATA', 'S', 'center'));
  ops.push(...piSmall(60, 42, 'PI1', f, { busy: stage === 1 }));
  ops.push(...piSmall(106, 30, 'PI2', f, { busy: stage === 2 }), ...piSmall(106, 56, 'PI3', f, { busy: stage === 2 }));
  // monitor panel
  ops.push(rect(150, 28, 46, 46, 'k'), rect(150, 28, 46, 5, 't'), text(173, 28, 'YARN', 'c', 'center'));
  const heights = [0, 1, 2].map((i) => stage === 2 ? Math.round(8 + 14 * Math.abs(((f * 3 + i * 7) % 20) - 10) / 10) : stage === 3 ? 6 : 2);
  heights.forEach((h, i) => ops.push(rect(156 + i * 12, 70 - h, 8, h, ['o', 'c', 'v'][i])));
  if (stage === 3) ops.push(...bigCheck(165, 36, 'l'), text(173, 50, 'PASS', 'l', 'center'));
  else ops.push(...spinner(168, 38, f));
  // packets
  if (stage === 0) ops.push(...packet(toMaster, t, 'y'));
  if (stage === 1) { ops.push(...packet(toA, t, 'o'), ...packet(toB, t, 'c')); }
  if (stage === 3) { ops.push(...packet([...toA].reverse(), t, 'l'), ...packet([...toB].reverse(), t, 'l')); ops.push(...sparkle(190, 40, f, 0), ...sparkle(154, 40, f, 2)); }
  return ops;
});

const bugRows = [['..g..g..', '...gg...', '.gggggg.', 'gggkkggg', '.gggggg.', '..g..g..']];

// ---------------------------------------------------------------- section banners (200 x 52)
// Text in the built-in font is 6 px for each letter (width = 6 * letters - 1) and 8 px high.
const H = 52;

// ---------------------------------------------------------------- 1 folder layout
scenes['01-folder-layout'] = recipe('evals-folder-layout', 200, H, 24, (f) => {
  const ops = [];
  const open = f >= 4 ? 1 : 0;
  ops.push(...folderIcon(8, 20, open), text(18, 38, 'EVALS/', 'w', 'center'));
  const items = [
    { label: 'RUNNER', x: 54, draw: (x, y) => [rect(x, y, 14, 14, 'k'), rect(x, y, 14, 3, 't'), text(x + 2, y + 5, '$_', 'l')] },
    { label: 'DATA/', x: 92, draw: (x, y) => [...datasetIcon(x - 2, y, 3)] },
    { label: 'JOBS/', x: 130, draw: (x, y) => [...pyIcon(x - 3, y), ...scalaIcon(x + 10, y + 2)] },
    { label: 'OUT/', x: 168, draw: (x, y) => [rect(x, y + 3, 14, 10, 'u'), ...checkIcon(x + 3, y + 5, 'L')] },
  ];
  items.forEach((it, i) => {
    const t = ease(clamp((f - 5 - i * 3) / 5));
    if (t <= 0) return;
    const x = Math.round(30 + (it.x - 30) * t), y = 12 + Math.round(8 * (1 - t));
    ops.push(...wire([[28, 27], [x + 6, 27]], 'M'), ...it.draw(x, y));
    if (t >= 0.95) ops.push(text(x + 7, 34, it.label, 'S', 'center'));
  });
  return ops;
});

// ---------------------------------------------------------------- 2 datasets and jobs
scenes['02-datasets-jobs'] = recipe('evals-datasets-jobs', 200, H, 24, (f) => {
  const ops = [];
  ops.push(...datasetIcon(8, 8, 4, f % 4), text(17, 29, 'CSV', 'S', 'center'), text(17, 38, 'X10', 'y', 'center'));
  [[84, 6, 'PYSPARK'], [84, 20, 'SCALA'], [84, 34, 'R']].forEach(([x, y, label], i) => {
    const path = [[28, 20], [56, 20], [56, y + 6], [x - 6, y + 6]];
    ops.push(...wire(path), ...packet(path, ((f + i * 4) % 12) / 11, ['Y', 'a', 'E'][i]));
    ops.push(...[pyIcon(x, y - 1), scalaIcon(x, y + 1), rIcon(x - 2, y - 3)][i], text(x + 22, y + 1, label, 'w'));
  });
  ops.push(text(176, 14, '3 JOBS', 'o', 'center'), text(176, 24, 'SAME', 'S', 'center'), text(176, 33, 'RESULT', 'S', 'center'));
  return ops;
});

// ---------------------------------------------------------------- 3 requirements
scenes['03-requirements'] = recipe('evals-requirements', 200, H, 24, (f) => {
  const ops = [];
  const items = [['HADOOP 3.5.0', 8, 10], ['SPARK 4.3.0', 8, 30], ['JAVA 17', 88, 10], ['PYTHON 3.11', 88, 30]];
  items.forEach(([label, x, y], i) => {
    const done = f >= 3 + i * 4;
    ops.push(rect(x, y, 9, 9, done ? 'G' : 'M'), rect(x + 1, y + 1, 7, 7, done ? 'L' : 'N'));
    if (done) ops.push(...checkIcon(x + 1, y + 2, 'w'));
    ops.push(text(x + 14, y + 1, label, done ? 'w' : 'S'));
  });
  ops.push(...sparkIcon(180, 12, f), text(186, 32, 'OK', f >= 17 ? 'l' : 'M', 'center'));
  return ops;
});

// ---------------------------------------------------------------- 4 quick start
scenes['04-quick-start'] = recipe('evals-quick-start', 200, H, 24, (f) => {
  const cmd = './run-evals.sh';
  const ops = [];
  ops.push(...terminal(6, 6, 104, 40, cmd.slice(0, Math.min(cmd.length, Math.max(0, f * 2 - 2))), f, 'BASH'));
  const run = f >= 8;
  ops.push(...spinner(118, 9, f), text(132, 9, run ? 'RUNNING' : 'WAITING', run ? 'o' : 'S'));
  ops.push(rect(118, 24, 74, 7, 'N'), rect(118, 24, run ? Math.round(74 * clamp((f - 8) / 14)) : 0, 7, 'l'));
  ops.push(text(118, 36, 'PY', 'Y'), text(136, 36, 'SC', 'a'), text(154, 36, 'R', 'c'));
  if (f >= 22) ops.push(...checkIcon(176, 36, 'l'));
  return ops;
});

// ---------------------------------------------------------------- 5 runner options
scenes['05-runner-options'] = recipe('evals-runner-options', 200, H, 24, (f) => {
  const ops = [];
  [['--LANG', 6], ['--DOMAIN', 22], ['--DRY-RUN', 38]].forEach(([label, y], i) => {
    const on = ((f + i * 5) % 24) >= 8 && ((f + i * 5) % 24) < 20;
    ops.push(text(6, y, label, on ? 'w' : 'S'));
    ops.push(rect(64, y - 1, 20, 9, on ? 'L' : 'M'), rect(65, y, 18, 7, on ? 'g' : 'N'), rect(on ? 74 : 65, y, 9, 7, on ? 'w' : 'S'));
  });
  [['PYSPARK', 'Y'], ['SCALA', 'a'], ['R', 'E']].forEach(([l, c], i) => {
    const on = ((f + 4 * i) % 12) < 8;
    ops.push(rect(100, 6 + i * 16, 10, 8, on ? c : 'M'), text(114, 6 + i * 16, l, on ? 'w' : 'S'));
  });
  ops.push(...sparkIcon(176, 8, f), text(182, 28, 'QUEUE', 'S', 'center'), text(182, 38, 'DEV', f % 8 < 4 ? 'o' : 'y', 'center'));
  return ops;
});

// ---------------------------------------------------------------- 6 run one job by hand
scenes['06-run-one-job'] = recipe('evals-run-one-job', 200, H, 24, (f) => {
  const cmd = 'spark-submit job.py';
  const ops = [];
  ops.push(...terminal(6, 6, 126, 40, cmd.slice(0, Math.min(cmd.length, Math.max(0, f * 2))), f, 'PI1'));
  const path = [[132, 28], [146, 28]];
  ops.push(...wire(path), ...piSmall(146, 22, 'PI2', f, { busy: f >= 14 }));
  if (f >= 8 && f < 16) ops.push(...packet(path, (f - 8) / 7, 'y'));
  if (f >= 14) ops.push(...pyIcon(180, 8), ...spinner(182, 34, f));
  return ops;
});

// ---------------------------------------------------------------- 7 read the results
scenes['07-read-results'] = recipe('evals-read-results', 200, H, 24, (f) => {
  const ops = [];
  ops.push(rect(6, 3, 134, 47, 'k'), rect(6, 3, 134, 10, 't'), text(10, 4, 'DOMAIN', 'S'), text(74, 4, 'PY', 'Y'), text(98, 4, 'SC', 'a'), text(122, 4, 'R', 'c'));
  ['FINANCE', 'LOGISTICS', 'HELPDESK'].forEach((r, i) => {
    const y = 16 + i * 11;
    ops.push(text(10, y, r, 'w'));
    [76, 100, 122].forEach((x, j) => { if (f >= 2 + i * 4 + j) ops.push(...checkIcon(x, y, 'l')); else ops.push(px(x + 3, y + 3, 'M')); });
  });
  const done = f >= 16;
  ops.push(...(done ? bigCheck(164, 8, 'l') : spinner(167, 8, f)), text(172, 28, done ? 'ALL' : 'WAIT', done ? 'l' : 'o', 'center'), text(172, 38, done ? 'PASS' : '...', done ? 'l' : 'o', 'center'));
  if (done) ops.push(...sparkle(150, 10, f, 0), ...sparkle(192, 14, f, 3), ...sparkle(190, 44, f, 1));
  return ops;
});

// ---------------------------------------------------------------- 8 monitoring
scenes['08-monitoring'] = recipe('evals-monitoring', 200, H, 24, (f) => {
  const ops = [];
  ops.push(rect(4, 3, 88, 47, 'k'), rect(4, 3, 88, 10, 't'), text(8, 4, 'YARN :8088', 'c'));
  ['PI1', 'PI2', 'PI3'].forEach((n, i) => {
    const y = 17 + i * 11;
    const level = Math.round(8 + 46 * (0.5 + 0.5 * Math.sin((f + i * 6) / 3.8)));
    ops.push(text(8, y - 1, n, 'S'), rect(30, y, 58, 6, 'N'), rect(30, y, level, 6, i === 0 ? 'o' : i === 1 ? 'c' : 'v'));
  });
  ops.push(rect(97, 3, 68, 47, 'k'), rect(97, 3, 68, 10, 't'), text(101, 4, 'LIVE JOBS', 'l'));
  let prev = null;
  for (let i = 0; i < 29; i++) {
    const v = 26 + Math.round(8 * Math.sin((f + i) / 2.6) + 3 * Math.sin((f + i) / 1.3));
    const x = 101 + i * 2, y = 54 - v + 8;
    if (prev !== null) ops.push(line(x - 2, prev, x, y, 'l'));
    prev = y;
  }
  ops.push(rect(170, 3, 27, 47, 'k'), rect(170, 3, 27, 10, 't'), text(173, 4, '4040', 'o'), ...sparkIcon(178, 18, f));
  ops.push(text(183, 33, 'LIVE', f % 4 < 2 ? 'l' : 'L', 'center'), ...[0, 1, 2].map((i) => px(176 + i * 6, 44, ((f + i) % 3 === 0) ? 'l' : 'M')));
  return ops;
});

// ---------------------------------------------------------------- 9 Scala and R
scenes['09-scala-and-r'] = recipe('evals-scala-and-r', 200, H, 24, (f) => {
  const ops = [];
  ops.push(...scalaIcon(10, 12 + bounce(f, 0)), text(16, 28, 'SCALA', 'a', 'center'));
  ops.push(rect(60, 8, 80, 26, 'k'), rect(60, 8, 80, 9, 't'), text(64, 9, f % 12 < 6 ? 'job.scala' : 'job.R', 'w'), text(64, 22, f % 12 < 6 ? 'spark-shell' : 'SparkR', 'S'));
  ops.push(...rIcon(172, 10 + bounce(f, 2)), text(180, 28, 'SPARKR', 'c', 'center'));
  ops.push(...wire([[28, 20], [60, 20]]), ...wire([[140, 20], [170, 20]]));
  ops.push(...packet([[28, 20], [60, 20]], (f % 8) / 7, 'a'), ...packet([[170, 20], [140, 20]], (f % 8) / 7, 'c'));
  ops.push(text(100, 40, 'NO BUILD STEP', 'S', 'center'));
  return ops;
});

// ---------------------------------------------------------------- 10 expected run time
scenes['10-run-time'] = recipe('evals-run-time', 200, H, 24, (f) => {
  const ops = [];
  ops.push(...clockIcon(10, 16, f), text(34, 10, 'JOB TIME', 'S'));
  ops.push(rect(34, 22, 100, 7, 'N'), rect(34, 22, Math.round(100 * (f / 23)), 7, 'o'));
  ops.push(text(34, 34, 'SMALL DATA', 'S'));
  ops.push(...piSmall(150, 20, '', f, { busy: true }), text(163, 40, 'MINUTES', 'y', 'center'));
  return ops;
});

// ---------------------------------------------------------------- 11 troubleshooting
scenes['11-troubleshooting'] = recipe('evals-troubleshooting', 200, H, 24, (f) => {
  const ops = [];
  const x = Math.min(14 + Math.round(f * 3.2), 90), y = 14 + (f % 2);
  ops.push(grid(x, y, bugRows[0]), px(x + 1, y + 6 + (f % 2), 'g'), px(x + 6, y + 6 + ((f + 1) % 2), 'g'));
  if (f >= 14) {
    ops.push(ellipse(120, 8, 14, 14, 'S'), ellipse(122, 10, 10, 10, 'c'), line(132, 21, 140, 29, 'S'), line(133, 21, 141, 29, 'S'));
    ops.push(rect(152, 14, 6, 14, 'S'), rect(150, 10, 10, 6, 'S'), rect(153, 10, 4, 3, 'n'));
    ops.push(...bigCheck(176, 14, 'l'));
  } else ops.push(text(140, 16, 'ERROR?', 'r'), px(132 + (f % 3), 24, 'R'));
  ops.push(text(100, 40, 'READ THE LOG  FIX  RUN AGAIN', 'S', 'center'));
  return ops;
});

// ---------------------------------------------------------------- 12 make new data
scenes['12-make-new-data'] = recipe('evals-make-new-data', 200, H, 24, (f) => {
  const ops = [];
  ops.push(...terminal(6, 6, 84, 40, 'generate.py'.slice(0, Math.min(11, f + 1)), f, 'PY'));
  const rows = Math.min(6, 1 + Math.floor(f / 3));
  ops.push(...datasetIcon(110, 8, rows, rows - 1), text(119, 38, 'NEW CSV', 'S', 'center'));
  ops.push(...wire([[90, 26], [108, 26]]), ...packet([[90, 26], [108, 26]], (f % 6) / 5, 'y'));
  ops.push(...sparkle(142, 14, f, 0), ...sparkle(148, 32, f, 2));
  ops.push(text(175, 16, '--SCALE', 'o', 'center'), text(175, 28, 'ROWS', 'S', 'center'));
  return ops;
});

// ---------------------------------------------------------------- 13 what was tested
scenes['13-what-was-tested'] = recipe('evals-what-was-tested', 200, H, 24, (f) => {
  const ops = [];
  ['PI1', 'PI2', 'PI3'].forEach((n, i) => {
    const x = 10 + i * 40, done = f >= 4 + i * 5;
    ops.push(rect(x, 10, 32, 24, done ? 'C' : 'M'), rect(x + 1, 11, 30, 22, 'N'));
    for (let k = 0; k < 4; k++) ops.push(rect(x + 4 + k * 6, 14, 4, 4, done ? 'c' : 'S'));
    ops.push(text(x + 16, 22, n, 'w', 'center'), px(x + 3, 30, ((f + i) % 6 < 3) ? 'l' : 'L'));
    if (done) ops.push(...checkIcon(x + 12, 38, 'l'));
  });
  ops.push(text(168, 12, '30 JOBS', 'o', 'center'), text(168, 24, 'PASS', f >= 20 ? 'l' : 'S', 'center'), text(168, 36, 'DOCKER', 'S', 'center'));
  if (f >= 20) ops.push(...sparkle(194, 10, f, 0), ...sparkle(142, 44, f, 3));
  return ops;
});

for (const [name, r] of Object.entries(scenes)) writeFileSync(join(here, `${name}.pixel.json`), JSON.stringify(r));
console.log(`wrote ${Object.keys(scenes).length} recipes`);
