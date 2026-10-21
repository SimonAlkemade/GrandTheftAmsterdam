// A wall between two points, cut into a ground floor, the upper storeys and
// a stone cornice. UVs are metric so every bay and storey lines up.
const GROUND_H = 3.8, CORNICE_H = 0.45;
function wallBands(mats, a, b, y0, top, n, run, owner, apex = null) {
  const [ax, az] = a, [bx, bz] = b;
  const len = Math.hypot(bx - ax, bz - az);
  if (len < 0.05) return run;
  const tall = top - y0 > 5;
  const g = tall ? y0 + Math.min(GROUND_H, (top - y0) * 0.45) : y0;
  const c = tall ? top - CORNICE_H : top;
  const P = (x, y, z) => [x, y, z];
  const quad = (bld, y1, y2, uv) => {
    if (y2 - y1 < 0.01) return;
    bld.quad(P(ax, y1, az), P(bx, y1, bz), P(bx, y2, bz), P(ax, y2, az), n, uv(y1, y2), owner);
  };
  const u0 = run, u1 = run + len;
  if (tall) quad(B(mats.ground), y0, g, (y1, y2) => [[u0 / (2 * BAY), 0], [u1 / (2 * BAY), 0], [u1 / (2 * BAY), 1], [u0 / (2 * BAY), 1]]);
  const UB = ATLAS_BAYS * BAY, VF = ATLAS_FLOORS * FLOOR;
  quad(B(mats.upper), g, c, (y1, y2) => [[u0 / UB, (y1 - g) / VF], [u1 / UB, (y1 - g) / VF], [u1 / UB, (y2 - g) / VF], [u0 / UB, (y2 - g) / VF]]);
  if (tall && !apex) quad(B(mats.trim), c, top, (y1, y2) => [[u0 / 2, 0], [u1 / 2, 0], [u1 / 2, 1], [u0 / 2, 1]]);
  if (apex) {                      // a gable end: the triangle above the eave
    const [mx, mz, ridge] = apex;
    const um = (u0 + u1) / 2;
    B(mats.upper).tri([ax, top, az], [bx, top, bz], [mx, ridge, mz], n,
      [u0 / UB, (top - g) / VF], [u1 / UB, (top - g) / VF], [um / UB, (ridge - g) / VF], owner);
    // A stone coping along the two sloping edges, the outline of the gable.
    const cop = B(mats.trim), k = 0.35;
    for (const [px, pz] of [[ax, az], [bx, bz]]) {
      cop.quad([px, top, pz], [mx, ridge, mz], [mx, ridge + k, mz], [px, top + k, pz], n, [[0, 0], [1, 0], [1, 1], [0, 1]], owner);
    }
  }
  return run + len;
}

// ---- buildings -----------------------------------------------------------------
const builders = new Map();
const B = mat => { if (!builders.has(mat)) builders.set(mat, new Builder()); return builders.get(mat); };
const buildingInfo = [];       // per building: { h, kind, ring, gabled }
let hasShop = new Uint8Array(0);
function hash(i) { let x = (i + 1) * 2654435761 >>> 0; x ^= x >>> 15; return x; }
const KIND = ['Building', 'Residential', 'Shop or hotel', 'Office', 'Industrial', 'Houseboat'];
function materialsFor(bd, i, sink) {
  if (sink) return { ground: sink, upper: sink, trim: sink, roof: sink, flat: sink };
  const h = hash(i), s = h % STYLES.length;
  if (bd.k === 5) return { ground: boatMat, upper: boatMat, trim: boatMat, roof: flatRoofMat, flat: flatRoofMat };
  const shop = hasShop[i] || bd.k === 2;
  return {
    ground: shop ? shopGroundMats[(h >>> 4) % shopGroundMats.length] : homeGroundMats[s],
    upper: bd.k === 3 ? officeMat : facadeMats[s],
    trim: trimMats[s],
    roof: roofMats[(h >>> 8) % roofMats.length], flat: flatRoofMat,
  };
}
function buildBuildings(list, filterIdx = null, sink = null) {
  list.forEach((bd, i) => {
    if (filterIdx !== null && i !== filterIdx) return;
    const mats = materialsFor(bd, i, sink);
    const y0 = bd.w ? -1.1 : 0;
    if (bd.g) {
      const c = pairs(bd.g);
      const eave = bd.e, ridge = bd.h;
      const m01 = [(c[0][0] + c[1][0]) / 2, (c[0][1] + c[1][1]) / 2], m23 = [(c[2][0] + c[3][0]) / 2, (c[2][1] + c[3][1]) / 2];
      const ctr = [(c[0][0] + c[2][0]) / 2, (c[0][1] + c[2][1]) / 2];
      const out = (p, q) => { const mx = (p[0] + q[0]) / 2 - ctr[0], mz = (p[1] + q[1]) / 2 - ctr[1], l = Math.hypot(mx, mz) || 1; return [mx / l, 0, mz / l]; };
      let run = 0;
      for (const [p, q] of [[c[1], c[2]], [c[3], c[0]]]) run = wallBands(mats, p, q, y0, eave, out(p, q), run, i);
      for (const [p, q, m] of [[c[0], c[1], m01], [c[2], c[3], m23]]) run = wallBands(mats, p, q, y0, eave, out(p, q), 0, i, [m[0], m[1], ridge]);
      const rb = B(mats.roof);
      const L = Math.hypot(c[2][0] - c[1][0], c[2][1] - c[1][1]);
      for (const [p, q, mA, mB] of [[c[1], c[2], m01, m23], [c[3], c[0], m23, m01]]) {
        const pts = [[p[0], eave, p[1]], [q[0], eave, q[1]], [mB[0], ridge, mB[1]], [mA[0], ridge, mA[1]]];
        const e1 = [q[0] - p[0], 0, q[1] - p[1]], e2 = [mA[0] - p[0], ridge - eave, mA[1] - p[1]];
        let n = [e1[1] * e2[2] - e1[2] * e2[1], e1[2] * e2[0] - e1[0] * e2[2], e1[0] * e2[1] - e1[1] * e2[0]];
        if (n[1] < 0) n = n.map(v => -v);
        const nl = Math.hypot(...n); n = n.map(v => v / nl);
        const s = Math.hypot(mA[0] - p[0], ridge - eave, mA[1] - p[1]);
        rb.quad(...pts, n, [[0, 0], [L / 4, 0], [L / 4, s / 4], [0, s / 4]], i);
      }
      if (filterIdx === null) buildingInfo[i] = { h: ridge, kind: bd.k, ring: c, gabled: true };
    } else {
      const rings = bd.r.map(pairs);
      for (const ring of rings) {
        let run = 0;
        for (let k = 0; k < ring.length; k++) {
          const a = ring[k], b = ring[(k + 1) % ring.length];
          const len = Math.hypot(b[0] - a[0], b[1] - a[1]) || 1;
          // Map rings run counter-clockwise (north up); with scene z = -north
          // the outside of each edge is (-dz, dx). Holes run the other way.
          const n = [-(b[1] - a[1]) / len, 0, (b[0] - a[0]) / len];
          run = wallBands(mats, a, b, y0, y0 + bd.h, n, run, i);
        }
      }
      polygon(B(mats.flat), rings, y0 + bd.h, 6, i);
      if (filterIdx === null) buildingInfo[i] = { h: bd.h, kind: bd.k, ring: rings[0], gabled: false };
    }
  });
}

// Footprints and heights only, before any geometry: the masks and the shop
// lookup need them first.
function indexBuildings(list) {
  list.forEach((bd, i) => {
    buildingInfo[i] = bd.g ? { h: bd.h, kind: bd.k, ring: pairs(bd.g), gabled: true }
                           : { h: bd.h, kind: bd.k, ring: pairs(bd.r[0]), gabled: false };
  });
}

// ---- masks: what is at a point -------------------------------------------------
// Two rasters at one metre per pixel: building index (as an RGB number) and
// water/bridge. Used to find the shops in each building, and by the walking
// character to know where it may stand.
const MASK_RES = 1;
let mask = null;
function buildMasks(c, ext) {
  const W = Math.ceil((ext.x1 - ext.x0) / MASK_RES), H = Math.ceil((ext.z1 - ext.z0) / MASK_RES);
  const toPx = (x, z) => [(x - ext.x0) / MASK_RES, (z - ext.z0) / MASK_RES];
  const trace = (g, ring) => { ring.forEach(([x, z], k) => { const [px, pz] = toPx(x, z); k ? g.lineTo(px, pz) : g.moveTo(px, pz); }); g.closePath(); };
  const bc = makeCanvas(W, H, (g) => {
    g.fillStyle = '#000'; g.fillRect(0, 0, W, H);
    c.buildings.forEach((bd, i) => {
      const id = i + 1;
      g.fillStyle = `rgb(${id >> 16 & 255},${id >> 8 & 255},${id & 255})`;
      g.beginPath();
      if (bd.g) trace(g, pairs(bd.g)); else for (const r of bd.r) trace(g, pairs(r));
      g.fill('evenodd');
    });
  });
  const wc = makeCanvas(W, H, (g) => {
    g.fillStyle = '#000'; g.fillRect(0, 0, W, H);
    g.fillStyle = '#f00';
    for (const rings of c.water) { g.beginPath(); for (const r of rings) trace(g, pairs(r)); g.fill('evenodd'); }
    g.strokeStyle = '#0f0'; g.lineWidth = 7 / MASK_RES; g.lineCap = 'round'; g.globalCompositeOperation = 'lighter';
    for (const coords of c.bridges) { g.beginPath(); pairs(coords).forEach(([x, z], k) => { const [px, pz] = toPx(x, z); k ? g.lineTo(px, pz) : g.moveTo(px, pz); }); g.stroke(); }
  });
  const bd = bc.getContext('2d').getImageData(0, 0, W, H).data, wd = wc.getContext('2d').getImageData(0, 0, W, H).data;
  const building = new Int32Array(W * H), water = new Uint8Array(W * H);
  for (let i = 0; i < W * H; i++) {
    building[i] = ((bd[4 * i] << 16) | (bd[4 * i + 1] << 8) | bd[4 * i + 2]) - 1;
    water[i] = (wd[4 * i] > 128 ? 1 : 0) | (wd[4 * i + 1] > 128 ? 2 : 0);   // 1 water, 2 bridge
  }
  mask = { W, H, ext, building, water, bc, wc };
}
// Building index at a point, checked against the real outline because the
// rasteriser blends colours along edges.
function buildingAt(x, z) {
  if (!mask) return -1;
  const px = Math.floor((x - mask.ext.x0) / MASK_RES), pz = Math.floor((z - mask.ext.z0) / MASK_RES);
  if (px < 0 || pz < 0 || px >= mask.W || pz >= mask.H) return -1;
  for (const [dx, dz] of [[0, 0], [1, 0], [-1, 0], [0, 1], [0, -1]]) {
    const q = (pz + dz) * mask.W + px + dx;
    const id = mask.building[q];
    if (id >= 0 && id < city.buildings.length && buildingInfo[id] && pip(x, z, buildingInfo[id].ring)) return id;
  }
  return -1;
}
function waterAt(x, z) {
  if (!mask) return 0;
  const px = Math.floor((x - mask.ext.x0) / MASK_RES), pz = Math.floor((z - mask.ext.z0) / MASK_RES);
  if (px < 0 || pz < 0 || px >= mask.W || pz >= mask.H) return 0;
  return mask.water[pz * mask.W + px];
}
