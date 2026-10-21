// ---- per-tile rasters: what is at a point --------------------------------------
// Each tile keeps two small rasters at 1.5 m: which of its buildings covers a
// point, and whether it is water or a bridge. They answer the walker ("can I
// stand here?") and decide which buildings get shopfronts. The same pixels
// paint that tile's part of the radar.
const MASK_RES = 1.5;
function buildTileMask(t) {
  const c = t.data, { x0, z0 } = t.ext;
  const W = Math.ceil(TILE / MASK_RES), H = W;
  const toPx = (x, z) => [(x - x0) / MASK_RES, (z - z0) / MASK_RES];
  const trace = (g, ring) => { ring.forEach(([x, z], k) => { const [px, pz] = toPx(x, z); k ? g.lineTo(px, pz) : g.moveTo(px, pz); }); g.closePath(); };
  const bc = makeCanvas(W, H, (g) => {
    g.fillStyle = '#000'; g.fillRect(0, 0, W, H);
    (c.buildings || []).forEach((bd, i) => {
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
    for (const rings of c.water || []) { g.beginPath(); for (const r of rings) trace(g, pairs(r)); g.fill('evenodd'); }
    g.strokeStyle = '#0f0'; g.lineWidth = 7 / MASK_RES; g.lineCap = 'round'; g.globalCompositeOperation = 'lighter';
    for (const coords of c.bridges || []) { g.beginPath(); pairs(coords).forEach(([x, z], k) => { const [px, pz] = toPx(x, z); k ? g.lineTo(px, pz) : g.moveTo(px, pz); }); g.stroke(); }
  });
  const bd = bc.getContext('2d').getImageData(0, 0, W, H).data, wd = wc.getContext('2d').getImageData(0, 0, W, H).data;
  const building = new Int32Array(W * H), water = new Uint8Array(W * H);
  const radar = document.createElement('canvas'); radar.width = W; radar.height = H;
  const rg = radar.getContext('2d'), img = rg.createImageData(W, H);
  for (let i = 0; i < W * H; i++) {
    building[i] = ((bd[4 * i] << 16) | (bd[4 * i + 1] << 8) | bd[4 * i + 2]) - 1;
    water[i] = (wd[4 * i] > 128 ? 1 : 0) | (wd[4 * i + 1] > 128 ? 2 : 0);
    const col = water[i] & 2 ? [120, 116, 108] : water[i] & 1 ? [86, 140, 176] : building[i] >= 0 ? [214, 214, 208] : [62, 68, 66];
    img.data[4 * i] = col[0]; img.data[4 * i + 1] = col[1]; img.data[4 * i + 2] = col[2]; img.data[4 * i + 3] = 255;
  }
  rg.putImageData(img, 0, 0);
  t.mask = { W, H, building, water };
  t.radar = radar;
}
// The building at a point, as its info record (h, ring, tile, idx), or null.
// Checked against the real outline, since the rasteriser blends edge pixels.
function buildingAt(x, z) {
  const t = tileAt(x, z);
  if (!t || !t.mask) return null;
  const px = Math.floor((x - t.ext.x0) / MASK_RES), pz = Math.floor((z - t.ext.z0) / MASK_RES);
  for (const [dx, dz] of [[0, 0], [1, 0], [-1, 0], [0, 1], [0, -1]]) {
    const qx = px + dx, qz = pz + dz;
    if (qx < 0 || qz < 0 || qx >= t.mask.W || qz >= t.mask.H) continue;
    const id = t.mask.building[qz * t.mask.W + qx];
    const b = id >= 0 ? t.info[id] : null;
    if (b && pip(x, z, b.ring)) return b;
  }
  return null;
}
function waterAt(x, z) {
  const t = tileAt(x, z);
  if (!t || !t.mask) return 0;
  const px = Math.floor((x - t.ext.x0) / MASK_RES), pz = Math.floor((z - t.ext.z0) / MASK_RES);
  if (px < 0 || pz < 0 || px >= t.mask.W || pz >= t.mask.H) return 0;
  return t.mask.water[pz * t.mask.W + px];
}

// ---- walls for collision: segments in a 10 m grid, owned by tiles ----------------
const SEG_CELL = 10;
const segGrid = new Map();     // cell -> [{ t, s: [ax, az, bx, bz, ...] }]
function addTileSegments(t) {
  const local = new Map();
  const put = (ax, az, bx, bz) => {
    const c0 = Math.floor(Math.min(ax, bx) / SEG_CELL), c1 = Math.floor(Math.max(ax, bx) / SEG_CELL);
    const r0 = Math.floor(Math.min(az, bz) / SEG_CELL), r1 = Math.floor(Math.max(az, bz) / SEG_CELL);
    for (let c = c0; c <= c1; c++) for (let r = r0; r <= r1; r++) {
      const k = c * 100000 + r;
      if (!local.has(k)) local.set(k, []);
      local.get(k).push(ax, az, bx, bz);
    }
  };
  for (const bd of t.buildings) {
    const rings = bd.g ? [pairs(bd.g)] : bd.r.map(pairs);
    for (const ring of rings) for (let k = 0; k < ring.length; k++) { const a = ring[k], b = ring[(k + 1) % ring.length]; put(a[0], a[1], b[0], b[1]); }
  }
  t.segKeys = [...local.keys()];
  for (const [k, s] of local) { if (!segGrid.has(k)) segGrid.set(k, []); segGrid.get(k).push({ t, s }); }
}
function removeTileSegments(t) {
  for (const k of t.segKeys || []) {
    const list = segGrid.get(k);
    if (!list) continue;
    const kept = list.filter(e => e.t !== t);
    if (kept.length) segGrid.set(k, kept); else segGrid.delete(k);
  }
  t.segKeys = [];
}
