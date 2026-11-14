// Builds the two Pixelbolt recipes for the README art.
// Run: node build-recipes.mjs   (writes hero.pixel.json and dataflow.pixel.json beside this file)
// Render: node <Pixelbolt>/bin/pixelbolt.js gif hero.pixel.json --out ../hero.gif --scale 5
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
};

const rect = (x, y, w, h, color) => ({ op: 'rect', x, y, w, h, color, filled: true });
const px = (x, y, color) => ({ op: 'pixel', x, y, color });
const line = (x, y, x2, y2, color) => ({ op: 'line', x, y, x2, y2, color });
const text = (x, y, t, color, align = 'left') => ({ op: 'text', x, y, text: t, color, align });
const grid = (x, y, rows) => ({ op: 'grid', x, y, rows });

const berry = [
  '.l.ll.l.',
  '..llll..',
  '.rrrrrr.',
  'rrRrrRrr',
  'rrrrrrrr',
  'rRrrrRrr',
  '.rrRrrr.',
  '..rrrr..',
];

// Position along a polyline at t in [0,1]
function along(path, t) {
  const seg = [];
  let total = 0;
  for (let i = 0; i < path.length - 1; i++) {
    const d = Math.abs(path[i + 1][0] - path[i][0]) + Math.abs(path[i + 1][1] - path[i][1]);
    seg.push(d); total += d;
  }
  let dist = Math.min(Math.max(t, 0), 1) * total;
  for (let i = 0; i < seg.length; i++) {
    if (dist <= seg[i] || i === seg.length - 1) {
      const f = seg[i] ? dist / seg[i] : 0;
      return [
        Math.round(path[i][0] + (path[i + 1][0] - path[i][0]) * f),
        Math.round(path[i][1] + (path[i + 1][1] - path[i][1]) * f),
      ];
    }
    dist -= seg[i];
  }
  return path[path.length - 1];
}

const packet = (path, t, color) => {
  const [x, y] = along(path, t);
  return [rect(x - 1, y - 1, 3, 3, color), px(x, y, 'w')];
};

// A Raspberry Pi board seen from above, 36 x 20, at (x, y)
function piBoard(x, y, label, frame, { busy = false, tint = 'g' } = {}) {
  const ops = [];
  ops.push(rect(x, y, 36, 20, 'G'));
  ops.push(rect(x + 1, y + 1, 34, 18, tint));
  // GPIO header
  for (let i = 0; i < 17; i++) { ops.push(px(x + 3 + i * 2, y + 2, 'k')); ops.push(px(x + 3 + i * 2, y + 3, 'y')); }
  // SoC and RAM
  ops.push(rect(x + 11, y + 7, 8, 8, 'S'));
  ops.push(rect(x + 12, y + 8, 6, 6, 's'));
  ops.push(rect(x + 21, y + 8, 5, 5, 'k'));
  // USB and ethernet
  ops.push(rect(x + 30, y + 5, 6, 5, 's'));
  ops.push(rect(x + 30, y + 11, 6, 5, 's'));
  ops.push(rect(x + 31, y + 6, 4, 3, 'S'));
  ops.push(rect(x + 31, y + 12, 4, 3, 'S'));
  // logo
  ops.push(grid(x + 2, y + 8, berry));
  // LEDs: power red (steady), activity green (blinks)
  ops.push(px(x + 2, y + 17, 'r'));
  ops.push(px(x + 4, y + 17, busy ? (frame % 2 ? 'l' : 'w') : (frame % 6 < 3 ? 'l' : 'L')));
  if (busy) ops.push(rect(x + 12, y + 8, 6, 6, frame % 2 ? 'y' : 'o'));
  ops.push(text(x + 18, y - 7, label, 'w', 'center'));
  return ops;
}

// Person at a desk. typing: 0|1 hand position, cheer: raised arm
function person(frame, cheer) {
  const ops = [];
  const bob = frame % 8 < 4 ? 0 : 1;
  // chair
  ops.push(rect(6, 54, 4, 16, 'D'));
  ops.push(rect(4, 70, 12, 2, 'D'));
  // body
  ops.push(rect(11, 48 + bob, 10, 13, 'b'));
  ops.push(rect(11, 48 + bob, 10, 2, 'B'));
  // head
  ops.push(rect(13, 40 + bob, 7, 7, 'p'));
  ops.push(rect(12, 38 + bob, 9, 3, 'm'));
  ops.push(rect(12, 41 + bob, 2, 4, 'm'));
  ops.push(px(18, 43 + bob, 'k'));
  // headphones
  ops.push(rect(12, 40 + bob, 1, 5, 'o'));
  ops.push(rect(13, 38 + bob, 7, 1, 'o'));
  // arm
  if (cheer) {
    ops.push(line(20, 52, 26, 44 + (frame % 2), 'p'));
    ops.push(rect(25, 42 + (frame % 2), 3, 3, 'p'));
  } else {
    const hy = 56 + (frame % 2);
    ops.push(line(20, 52, 33, hy, 'p'));
    ops.push(line(20, 53, 33, hy + 1, 'p'));
  }
  return ops;
}

function desk(frame, screenMode, progress) {
  const ops = [];
  ops.push(rect(0, 60, 50, 3, 'd'));
  ops.push(rect(0, 63, 50, 1, 'D'));
  ops.push(rect(3, 64, 3, 12, 'D'));
  ops.push(rect(44, 64, 3, 12, 'D'));
  // laptop
  ops.push(rect(32, 47, 15, 11, 'k'));
  ops.push(rect(33, 48, 13, 9, 'M'));
  ops.push(rect(30, 58, 19, 2, 'S'));
  if (screenMode === 'code') {
    for (let i = 0; i < 4; i++) {
      const w = 3 + ((i * 5 + frame) % 7);
      ops.push(rect(34, 49 + i * 2, Math.min(w, 11), 1, i % 2 ? 'c' : 'y'));
    }
  } else if (screenMode === 'wait') {
    ops.push(rect(34, 52, 11, 2, 'N'));
    ops.push(rect(34, 52, Math.max(1, Math.round(11 * progress)), 2, 'l'));
  } else {
    ops.push(text(39, 51, 'OK', 'l', 'center'));
    ops.push(rect(34, 55, 11, 1, 'l'));
  }
  return ops;
}

function background(frame, w, h) {
  const ops = [rect(0, 0, w, h, 'n')];
  for (let y = 0; y < h; y += 8) for (let x = 0; x < w; x += 8) ops.push(px(x, y, 'N'));
  ops.push(rect(0, h - 4, w, 4, 'N'));
  // twinkling stars
  const stars = [[8, 8], [40, 14], [96, 6], [150, 10], [186, 18], [120, 20], [60, 26]];
  stars.forEach(([x, y], i) => ops.push(px(x, y, (frame + i * 3) % 8 < 4 ? 'M' : 'c')));
  return ops;
}

// ------------------------------------------------------------ hero
function hero() {
  const W = 200, H = 80, N = 24;
  const frames = [];
  const jobPath = [[46, 52], [58, 52], [58, 42], [70, 42]];
  const forkA = [[106, 42], [124, 42], [124, 26], [140, 26]];
  const forkB = [[106, 42], [124, 42], [124, 58], [140, 58]];
  const backA = [...forkA].reverse();
  const backB = [...forkB].reverse();
  const backJob = [...jobPath].reverse();
  for (let f = 0; f < N; f++) {
    const stage = Math.floor(f / 6); // 0 submit, 1 split, 2 process, 3 return
    const t = (f % 6) / 5;
    const ops = [];
    ops.push(...background(f, W, H));
    ops.push(text(4, 4, 'RASPBERRY PI 4 CLUSTER', 'w'));
    ops.push(text(4, 12, 'HADOOP + SPARK + YARN', 'o'));
    // wires
    const wire = (p) => { for (let i = 0; i < p.length - 1; i++) ops.push(line(...p[i], ...p[i + 1], 'M')); };
    [jobPath, forkA, forkB].forEach(wire);
    // desk, person
    ops.push(...desk(f, stage === 0 ? 'code' : stage === 3 ? 'ok' : 'wait', stage === 2 ? (f - 12) / 5 : stage === 3 ? 1 : 0));
    ops.push(...person(f, stage === 3));
    // boards
    ops.push(...piBoard(70, 32, 'PI1 MASTER', f, { busy: stage === 1 || stage === 3, tint: 'g' }));
    ops.push(...piBoard(140, 16, 'PI2 WORKER', f, { busy: stage === 2, tint: 'g' }));
    ops.push(...piBoard(140, 48, 'PI3 WORKER', f, { busy: stage === 2, tint: 'g' }));
    // progress bars
    const prog = stage === 2 ? t : stage === 3 ? 1 : 0;
    [[140, 38], [140, 70]].forEach(([x, y]) => {
      ops.push(rect(x, y, 36, 2, 'N'));
      if (prog > 0) ops.push(rect(x, y, Math.max(1, Math.round(36 * prog)), 2, 'l'));
    });
    // packets
    if (stage === 0) ops.push(...packet(jobPath, t, 'y'));
    if (stage === 1) { ops.push(...packet(forkA, t, 'o')); ops.push(...packet(forkB, t, 'c')); }
    if (stage === 3) {
      ops.push(...packet(backA, t * 0.5, 'l'));
      ops.push(...packet(backB, t * 0.5, 'l'));
      if (t > 0.5) ops.push(...packet(backJob, (t - 0.5) * 2, 'l'));
    }
    if (stage === 2) { ops.push(px(158, 12, f % 2 ? 'y' : 'o')); ops.push(px(158, 76, f % 2 ? 'o' : 'y')); }
    frames.push({ name: `f${String(f).padStart(2, '0')}`, duration: 110, ops });
  }
  return { version: 1, name: 'pi-cluster-hero', width: W, height: H, palette, frames,
           animations: { loop: { frames: frames.map((f) => f.name) } } };
}

// ------------------------------------------------------------ data flow
function dataflow() {
  const W = 200, H = 76, N = 24;
  const frames = [];
  const nodes = [[64, 30, 'PI1'], [110, 30, 'PI2'], [156, 30, 'PI3']];
  const blockColors = ['o', 'c', 'v'];
  for (let f = 0; f < N; f++) {
    const stage = Math.floor(f / 6); // 0 split, 1 replicate, 2 compute, 3 merge
    const t = (f % 6) / 5;
    const ops = [];
    ops.push(...background(f, W, H));
    ops.push(text(100, 4, 'DATA IN, RESULT OUT', 'w', 'center'));
    // source file
    ops.push(rect(6, 28, 20, 26, 's'));
    ops.push(rect(7, 29, 18, 24, 'w'));
    ops.push(rect(20, 28, 6, 6, 'S'));
    blockColors.forEach((c, i) => ops.push(rect(10, 34 + i * 6, 12, 4, stage === 0 && t > 0.3 ? 'N' : c)));
    ops.push(text(16, 56, 'HDFS', 'c', 'center'));
    // nodes
    nodes.forEach(([x, y, label], i) => {
      ops.push(...piBoard(x, y, label, f, { busy: stage === 2, tint: 'g' }));
      // block slots under each board
      const held = stage === 0 ? (t > 0.9 ? 1 : 0) : stage === 1 ? (t > 0.5 ? 2 : 1) : 2;
      for (let k = 0; k < 3; k++) {
        const has = k < held;
        const color = blockColors[(i + k) % 3];
        ops.push(rect(x + 4 + k * 10, y + 24, 8, 5, has ? color : 'N'));
      }
    });
    // split: blocks fly to nodes
    if (stage === 0) {
      nodes.forEach(([x, y], i) => {
        const [bx, by] = along([[26, 36 + i * 6], [x - 4, 36 + i * 6], [x - 4, y + 10]], t);
        ops.push(rect(bx - 1, by - 1, 4, 4, blockColors[i]));
      });
    }
    // replicate: copies hop to the next node
    if (stage === 1) {
      nodes.forEach(([x, y], i) => {
        const to = nodes[(i + 1) % 3];
        if (i === 2) return;
        const [bx, by] = along([[x + 36, y + 26], [to[0] - 4, y + 26], [to[0] + 6, y + 26]], t);
        ops.push(rect(bx - 1, by - 1, 4, 4, blockColors[i]));
      });
    }
    // compute: partial result bars grow above nodes
    const bars = stage === 2 ? t : stage === 3 ? 1 : 0;
    nodes.forEach(([x], i) => {
      const hgt = Math.round((6 + i * 3) * bars);
      ops.push(rect(x + 14, 22 - hgt, 8, hgt, blockColors[i]));
    });
    // merge: bars become one result chart on the right-bottom
    if (stage === 3) {
      const lit = Math.round(t * 5);
      for (let i = 0; i < 3; i++) ops.push(rect(94 + i * 12, 70 - Math.round((4 + i * 3) * t), 8, Math.round((4 + i * 3) * t), blockColors[i]));
      if (lit >= 4) ops.push(text(150, 66, 'DONE', 'l', 'center'));
    }
    frames.push({ name: `f${String(f).padStart(2, '0')}`, duration: 110, ops });
  }
  return { version: 1, name: 'pi-cluster-dataflow', width: W, height: H, palette, frames,
           animations: { loop: { frames: frames.map((f) => f.name) } } };
}

// Drop empty rectangles (a bar at zero height)
const clean = (r) => { r.frames.forEach((f) => { f.ops = f.ops.filter((o) => o.op !== 'rect' || (o.w >= 1 && o.h >= 1)); }); return r; };
writeFileSync(join(here, 'hero.pixel.json'), JSON.stringify(clean(hero())));
writeFileSync(join(here, 'dataflow.pixel.json'), JSON.stringify(clean(dataflow())));
console.log('recipes written');
