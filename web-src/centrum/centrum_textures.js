// ---- textures (drawn once, tileable) ------------------------------------------
function makeCanvas(w, h, draw) {
  const c = document.createElement('canvas'); c.width = w; c.height = h;
  draw(c.getContext('2d'), w, h);
  return c;
}
function texOf(canvas, color = true, repeat = true) {
  const t = new THREE.CanvasTexture(canvas);
  if (color) t.colorSpace = THREE.SRGBColorSpace;
  if (repeat) t.wrapS = t.wrapT = THREE.RepeatWrapping;
  t.anisotropy = 8;
  return t;
}
function canvasTex(w, h, draw, repeat = true) { return texOf(makeCanvas(w, h, draw), true, repeat); }
function rng(seed) { let s = seed >>> 0; return () => ((s = (s * 1664525 + 1013904223) >>> 0) / 4294967296); }
function shade(hex, k) { const c = new THREE.Color(hex); c.multiplyScalar(k); return `#${c.getHexString()}`; }

// Upper floors: one tile is 4 window bays by 3 storeys, so neighbouring
// windows differ (curtains, plants, lights on) instead of repeating one.
const ATLAS_BAYS = 4, ATLAS_FLOORS = 3, PX_BAY = 128, PX_FLOOR = 176;
const glowMats = [];           // materials whose windows light up at night
function facadeSet(o, seed) {
  const W = ATLAS_BAYS * PX_BAY, H = ATLAS_FLOORS * PX_FLOOR;
  const r = rng(seed);
  const color = makeCanvas(W, H, () => {}), bump = makeCanvas(W, H, () => {}), glow = makeCanvas(W, H, () => {});
  const g = color.getContext('2d'), b = bump.getContext('2d'), e = glow.getContext('2d');
  g.fillStyle = o.wall; g.fillRect(0, 0, W, H);
  b.fillStyle = '#808080'; b.fillRect(0, 0, W, H);
  e.fillStyle = '#000'; e.fillRect(0, 0, W, H);
  if (o.brick) {                       // running bond, 6 px courses (about 6 cm)
    for (let y = 0; y < H; y += 6) for (let x = (y / 6) % 2 ? -10 : 0; x < W; x += 20) {
      g.fillStyle = shade(o.wall, 0.84 + r() * 0.3); g.fillRect(x + 1, y + 1, 18, 4);
      b.fillStyle = '#909090'; b.fillRect(x + 1, y + 1, 18, 4);
    }
  } else {
    for (let i = 0; i < 9000; i++) { g.fillStyle = shade(o.wall, 0.93 + r() * 0.12); g.fillRect(r() * W, r() * H, 3, 3); }
  }
  for (let f = 0; f < ATLAS_FLOORS; f++) {
    if (o.bands) { g.fillStyle = o.trim; g.fillRect(0, f * PX_FLOOR + PX_FLOOR - 7, W, 7); b.fillStyle = '#b0b0b0'; b.fillRect(0, f * PX_FLOOR + PX_FLOOR - 7, W, 7); }
    for (let k = 0; k < ATLAS_BAYS; k++) {
      const ww = PX_BAY * (o.winW || 0.5), wh = PX_FLOOR * 0.62;
      const x = k * PX_BAY + (PX_BAY - ww) / 2, y = f * PX_FLOOR + PX_FLOOR * 0.15;
      // Recess shadow, lintel and sill.
      g.fillStyle = 'rgba(0,0,0,0.35)'; g.fillRect(x - 3, y - 3, ww + 6, wh + 6);
      b.fillStyle = '#202020'; b.fillRect(x - 2, y - 2, ww + 4, wh + 4);
      g.fillStyle = o.trim; g.fillRect(x - 7, y - 14, ww + 14, 10); g.fillRect(x - 7, y + wh + 2, ww + 14, 7);
      b.fillStyle = '#c8c8c8'; b.fillRect(x - 7, y - 14, ww + 14, 10); b.fillRect(x - 7, y + wh + 2, ww + 14, 7);
      // Glass: sky at the top fading to the dark room, sometimes a curtain or a plant.
      const grd = g.createLinearGradient(0, y, 0, y + wh);
      grd.addColorStop(0, '#6f8798'); grd.addColorStop(0.45, '#33424c'); grd.addColorStop(1, '#151c21');
      g.fillStyle = grd; g.fillRect(x, y, ww, wh);
      const roll = r();
      if (roll < 0.3) { g.fillStyle = ['#e9e1cf', '#c9b79c', '#8a2f2f', '#2f4f6f'][(r() * 4) | 0]; g.fillRect(x, y, ww * 0.28, wh); g.fillRect(x + ww * 0.72, y, ww * 0.28, wh); }
      else if (roll < 0.45) { g.fillStyle = 'rgba(240,235,220,0.75)'; g.fillRect(x, y + wh * 0.55, ww, wh * 0.45); }
      if (r() < 0.25) { g.fillStyle = '#3f6b33'; g.beginPath(); g.ellipse(x + ww * (0.3 + r() * 0.4), y + wh - 10, 10, 9, 0, 0, Math.PI * 2); g.fill(); }
      if (r() < 0.38) {                                           // a light that's on at night
        const warm = ['#ffd58a', '#ffe7b8', '#ffc670', '#fff1d6'][(r() * 4) | 0];
        e.fillStyle = warm; e.fillRect(x + 2, y + 2, ww - 4, wh - 4);
      }
      // Frame and glazing bars.
      g.fillStyle = o.frame; b.fillStyle = '#e0e0e0';
      for (const [rx, ry, rw, rh] of [[x, y, ww, 5], [x, y + wh - 5, ww, 5], [x, y, 5, wh], [x + ww - 5, y, 5, wh], [x, y + wh * 0.5 - 3, ww, 6], [x + ww / 2 - 2, y, 4, wh]]) {
        g.fillRect(rx, ry, rw, rh); b.fillRect(rx, ry, rw, rh);
      }
      if (o.panes) for (const fy of [0.25, 0.75]) { g.fillRect(x, y + wh * fy - 1, ww, 2); }
      e.fillStyle = '#000';
      for (const [rx, ry, rw, rh] of [[x, y + wh * 0.5 - 3, ww, 6], [x + ww / 2 - 2, y, 4, wh]]) e.fillRect(rx, ry, rw, rh);
      if (o.shutters && r() < 0.6) {
        g.fillStyle = o.shutters;
        g.fillRect(x - ww * 0.42, y, ww * 0.38, wh); g.fillRect(x + ww * 1.04, y, ww * 0.38, wh);
      }
    }
  }
  const mat = new THREE.MeshStandardMaterial({
    map: texOf(color), bumpMap: texOf(bump, false), bumpScale: 1.2, roughness: 0.82,
    emissive: 0xffffff, emissiveMap: texOf(glow), emissiveIntensity: 0,
  });
  glowMats.push(mat);
  return mat;
}
// Ground floor: one tile is 2 bays wide and the full ground-floor height.
function groundSet(o, seed) {
  const W = 2 * PX_BAY, H = 200;
  const r = rng(seed);
  const color = makeCanvas(W, H, () => {}), bump = makeCanvas(W, H, () => {}), glow = makeCanvas(W, H, () => {});
  const g = color.getContext('2d'), b = bump.getContext('2d'), e = glow.getContext('2d');
  g.fillStyle = o.wall; g.fillRect(0, 0, W, H); b.fillStyle = '#808080'; b.fillRect(0, 0, W, H); e.fillStyle = '#000'; e.fillRect(0, 0, W, H);
  if (o.shop) {
    // Sign band, glass shopfront, stone plinth.
    g.fillStyle = o.sign; g.fillRect(0, 8, W, 30);
    g.fillStyle = 'rgba(255,255,255,0.85)';
    for (let i = 0; i < 6; i++) g.fillRect(28 + i * 34 + r() * 6, 18, 20 + r() * 8, 10);
    e.fillStyle = '#ffffff'; e.fillRect(0, 8, W, 30);
    const grd = g.createLinearGradient(0, 44, 0, H - 22);
    grd.addColorStop(0, '#7b93a2'); grd.addColorStop(1, '#1c262c');
    g.fillStyle = grd; g.fillRect(6, 44, W - 12, H - 66);
    e.fillStyle = '#ffe2a8'; e.fillRect(6, 44, W - 12, H - 66);
    g.fillStyle = o.frame;
    for (const x of [6, W / 2 - 4, W - 14]) { g.fillRect(x, 44, 8, H - 66); }
    g.fillRect(6, 44, W - 12, 6);
    g.fillStyle = '#c9c1ad'; g.fillRect(0, H - 22, W, 22);
    b.fillStyle = '#202020'; b.fillRect(6, 44, W - 12, H - 66);
    // Goods in the window.
    for (let i = 0; i < 10; i++) { g.fillStyle = `hsl(${r() * 360},40%,${35 + r() * 30}%)`; g.fillRect(14 + r() * (W - 40), H - 60 - r() * 30, 10 + r() * 14, 14 + r() * 20); }
  } else {
    if (o.brick) for (let y = 0; y < H; y += 6) for (let x = (y / 6) % 2 ? -10 : 0; x < W; x += 20) {
      g.fillStyle = shade(o.wall, 0.84 + r() * 0.3); g.fillRect(x + 1, y + 1, 18, 4);
    }
    // A front door with a fanlight, and a basement window beside it.
    const dx = 26, dw = 64;
    g.fillStyle = 'rgba(0,0,0,0.4)'; g.fillRect(dx - 4, 20, dw + 8, H - 26);
    g.fillStyle = o.door; g.fillRect(dx, 52, dw, H - 58);
    g.fillStyle = shade(o.door, 1.25); g.fillRect(dx + 8, 62, dw / 2 - 12, H - 84); g.fillRect(dx + dw / 2 + 4, 62, dw / 2 - 12, H - 84);
    g.fillStyle = '#3b4d58'; g.fillRect(dx, 22, dw, 26); e.fillStyle = '#ffd58a'; if (r() < 0.6) e.fillRect(dx, 22, dw, 26);
    g.fillStyle = o.frame; g.fillRect(dx, 46, dw, 6); g.fillRect(dx + dw / 2 - 2, 22, 4, 26);
    g.fillStyle = '#d6cdb8'; g.fillRect(dx - 10, H - 8, dw + 20, 8);
    b.fillStyle = '#202020'; b.fillRect(dx, 22, dw, H - 28);
    const wx = PX_BAY + 24, ww = 80;
    g.fillStyle = 'rgba(0,0,0,0.35)'; g.fillRect(wx - 3, 40, ww + 6, 110);
    g.fillStyle = '#26323a'; g.fillRect(wx, 43, ww, 104);
    if (r() < 0.5) { e.fillStyle = '#ffd58a'; e.fillRect(wx + 2, 45, ww - 4, 100); }
    g.fillStyle = o.frame; g.fillRect(wx, 43, ww, 5); g.fillRect(wx, 142, ww, 5); g.fillRect(wx, 43, 5, 104); g.fillRect(wx + ww - 5, 43, 5, 104); g.fillRect(wx + ww / 2 - 2, 43, 4, 104); g.fillRect(wx, 93, ww, 4);
    b.fillStyle = '#202020'; b.fillRect(wx, 43, ww, 104);
    g.fillStyle = '#c9c1ad'; g.fillRect(0, H - 14, W, 14);
  }
  const mat = new THREE.MeshStandardMaterial({
    map: texOf(color), bumpMap: texOf(bump, false), bumpScale: 1.2, roughness: 0.8,
    emissive: 0xffffff, emissiveMap: texOf(glow), emissiveIntensity: 0,
  });
  glowMats.push(mat);
  return mat;
}
function plainTex(base, grain, seed, size = 256) {
  return canvasTex(size, size, (g, w, h) => {
    const r = rng(seed);
    g.fillStyle = base; g.fillRect(0, 0, w, h);
    for (let i = 0; i < w * h / 6; i++) { g.fillStyle = shade(base, 1 - grain + r() * grain * 2); g.fillRect(r() * w, r() * h, 2, 2); }
  });
}
function tilesTex(base, seed) {
  return canvasTex(256, 256, (g, w, h) => {
    const r = rng(seed);
    for (let y = 0; y < h; y += 16) for (let x = (y / 16) % 2 ? -12 : 0; x < w; x += 24) {
      g.fillStyle = shade(base, 0.8 + r() * 0.35); g.fillRect(x, y, 23, 15);
      g.fillStyle = 'rgba(0,0,0,0.25)'; g.fillRect(x, y + 12, 23, 3);
    }
  });
}
function cobbleTex(base, seed) {
  return canvasTex(256, 256, (g, w, h) => {
    const r = rng(seed);
    g.fillStyle = shade(base, 0.6); g.fillRect(0, 0, w, h);
    for (let y = 0; y < h; y += 16) for (let x = (y / 16) % 2 ? -8 : 0; x < w; x += 16) {
      g.fillStyle = shade(base, 0.85 + r() * 0.3); g.fillRect(x + 1, y + 1, 14, 14);
    }
  });
}
const std = (o) => new THREE.MeshStandardMaterial({ roughness: 0.85, ...o });
// Facade styles: brick in Amsterdam's range, painted plaster, and the grey of
// the 19th century. Each gets matching ground floors.
const STYLES = [
  { wall: '#8e3b2a', frame: '#efebe2', trim: '#d8cfba', brick: true, door: '#1f3d2e', panes: true },
  { wall: '#6a3a2a', frame: '#efebe2', trim: '#d8cfba', brick: true, door: '#1b1c1e', bands: true },
  { wall: '#4b3026', frame: '#efebe2', trim: '#cfc6b0', brick: true, door: '#6b1f1a', panes: true },
  { wall: '#a5572f', frame: '#efebe2', trim: '#e0d8c4', brick: true, door: '#1f3d2e', shutters: '#24452f' },
  { wall: '#e6e1d4', frame: '#2a2d2e', trim: '#ffffff', brick: false, door: '#1b1c1e', bands: true },
  { wall: '#7d8584', frame: '#efebe2', trim: '#e9e6df', brick: false, door: '#23384f', panes: true },
  { wall: '#c9b48a', frame: '#efebe2', trim: '#efe7d2', brick: true, door: '#4a2e1f' },
];
const facadeMats = STYLES.map((s, i) => facadeSet(s, 11 + i));
const homeGroundMats = STYLES.map((s, i) => groundSet({ ...s, shop: false }, 31 + i));
const shopGroundMats = ['#1d3c5a', '#7a1e1e', '#20462f', '#2b2b2b', '#a4572a', '#5b2b6b'].map((sign, i) =>
  groundSet({ wall: '#3a3735', frame: '#1e1f20', sign, shop: true }, 51 + i));
const trimMats = STYLES.map(s => std({ color: s.trim, roughness: 0.7 }));
const officeMat = std({
  map: canvasTex(256, 256, (g, w, h) => {
    g.fillStyle = '#9aa3a8'; g.fillRect(0, 0, w, h);
    const grd = g.createLinearGradient(0, 0, 0, h); grd.addColorStop(0, '#6d8696'); grd.addColorStop(1, '#202a31');
    g.fillStyle = grd; g.fillRect(8, 8, w - 16, h - 16);
    g.fillStyle = '#9aa3a8'; g.fillRect(w / 2 - 3, 0, 6, h); g.fillRect(0, h / 2 - 3, w, 6);
  }), roughness: 0.25, metalness: 0.3,
});
const boatMat = groundSet({ wall: '#2f4f3f', frame: '#e9e4d6', door: '#7a3b22', brick: false, shop: false }, 71);
const roofMats = [std({ map: tilesTex('#3e3c3c', 51) }), std({ map: tilesTex('#7d3526', 52) }), std({ map: tilesTex('#3a4350', 53) })];
const flatRoofMat = std({ map: plainTex('#55585a', 0.12, 54) });
const MAT = {
  ground: std({ map: cobbleTex('#9a948a', 61) }),
  road: std({ map: plainTex('#3d4042', 0.08, 62), roughness: 0.95 }),
  bike: std({ color: 0x9c3f33, roughness: 0.9 }),
  walk: std({ map: cobbleTex('#b3aa9b', 63) }),
  plaza: std({ map: cobbleTex('#c2b8a5', 64) }),
  tram: std({ color: 0x5f6266 }),
  rail: std({ color: 0x55504a }),
  rails: std({ color: 0x2a2c2e, metalness: 0.6, roughness: 0.4 }),
  water: new THREE.MeshStandardMaterial({ color: 0x2b4a4f, roughness: 0.08, metalness: 0.1, envMapIntensity: 1.2 }),
  quay: std({ color: 0xcfc6b2 }),
  bridge: std({ map: cobbleTex('#a99f8e', 65) }),
  bridgeSide: std({ color: 0x6d3b2c }),
  park: std({ map: plainTex('#5d8a45', 0.12, 66) }),
  grass: std({ map: plainTex('#6f9a4e', 0.1, 67) }),
  garden: std({ map: plainTex('#4f7a3c', 0.14, 68) }),
  flower: std({ color: 0xb8607a }),
  play: std({ color: 0xc7a46a }),
  pitch: std({ color: 0x4f8d4a }),
};
const lampGlass = new THREE.MeshStandardMaterial({ color: 0xfff3d0, emissive: 0xffd58a, emissiveIntensity: 0 });

