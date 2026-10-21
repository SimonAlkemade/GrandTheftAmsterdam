// ---- instanced street furniture --------------------------------------------------
function instanced(geo, mat, positions, setup) {
  const n = positions.length / 2;
  const m = new THREE.InstancedMesh(geo, mat, Math.max(1, n));
  m.count = n;
  const o = new THREE.Object3D();
  const r = rng(n * 7 + 3);
  for (let i = 0; i < n; i++) {
    o.position.set(X(positions[2 * i]), 0, Z(positions[2 * i + 1]));
    o.rotation.set(0, r() * Math.PI * 2, 0); o.scale.setScalar(1);
    if (setup) setup(o, r, i);
    o.updateMatrix(); m.setMatrixAt(i, o.matrix);
  }
  m.castShadow = true; m.receiveShadow = true;
  return m;
}
// Shared by every tile, so loading and unloading tiles never rebuilds them.
let KIT = null;
function furnitureKit() {
  if (KIT) return KIT;
  const wheel = new THREE.TorusGeometry(0.33, 0.035, 5, 14);
  KIT = {
    green: std({ color: 0x1f3a2c, roughness: 0.6 }), black: std({ color: 0x1b1d1f, roughness: 0.6 }),
    bark: std({ color: 0x4b3a2c }), leaves: std({ color: 0xffffff, roughness: 0.9, flatShading: true }),
    wood: std({ color: 0x5a3f2a }), bikeMat: std({ color: 0xffffff, roughness: 0.6 }), bollard: std({ color: 0x6b2a1d }),
    trunk: new THREE.CylinderGeometry(0.22, 0.32, 5, 6).translate(0, 2.5, 0),
    crown: new THREE.IcosahedronGeometry(4.2, 1).scale(1, 1.15, 1).translate(0, 8, 0),
    lamp: mergeGeometries([new THREE.CylinderGeometry(0.07, 0.11, 4.5, 6).translate(0, 2.25, 0), new THREE.CylinderGeometry(0.27, 0.27, 0.06, 6).translate(0, 4.95, 0)]),
    lampHead: new THREE.CylinderGeometry(0.22, 0.12, 0.42, 6).translate(0, 4.72, 0),
    bench: mergeGeometries([
      new THREE.BoxGeometry(1.8, 0.08, 0.45).translate(0, 0.45, 0), new THREE.BoxGeometry(1.8, 0.45, 0.06).translate(0, 0.75, -0.22),
      new THREE.BoxGeometry(0.08, 0.45, 0.4).translate(-0.8, 0.22, 0), new THREE.BoxGeometry(0.08, 0.45, 0.4).translate(0.8, 0.22, 0)]),
    bike: mergeGeometries([
      wheel.clone().translate(-0.55, 0.36, 0), wheel.clone().translate(0.55, 0.36, 0),
      new THREE.BoxGeometry(1.0, 0.05, 0.05).translate(0, 0.62, 0), new THREE.BoxGeometry(0.05, 0.4, 0.05).translate(-0.2, 0.75, 0),
      new THREE.BoxGeometry(0.05, 0.05, 0.55).translate(0.5, 0.95, 0)]),
    bin: new THREE.CylinderGeometry(0.28, 0.28, 0.95, 8).translate(0, 0.48, 0),
    signal: mergeGeometries([new THREE.CylinderGeometry(0.06, 0.06, 3.2, 6).translate(0, 1.6, 0), new THREE.BoxGeometry(0.3, 0.8, 0.25).translate(0, 2.9, 0.1)]),
    post: new THREE.CylinderGeometry(0.1, 0.12, 0.85, 8).translate(0, 0.43, 0),
  };
  return KIT;
}
function buildFurniture(c, trees, furniture) {
  const K = furnitureKit(), col = new THREE.Color();
  const has = k => c[k] && c[k].length;
  if (has('trees')) {
    const treeSetup = (o, r) => { const s = 0.75 + r() * 0.55; o.scale.set(s, s * (0.9 + r() * 0.3), s); };
    trees.add(instanced(K.trunk, K.bark, c.trees, treeSetup));
    const crowns = instanced(K.crown, K.leaves, c.trees, treeSetup);
    const r = rng(c.trees.length);
    for (let i = 0; i < c.trees.length / 2; i++) crowns.setColorAt(i, col.setHSL(0.24 + r() * 0.06, 0.38 + r() * 0.15, 0.3 + r() * 0.1));
    trees.add(crowns);
  }
  if (has('lamps')) furniture.add(instanced(K.lamp, K.green, c.lamps), instanced(K.lampHead, lampGlass, c.lamps));
  if (has('benches')) furniture.add(instanced(K.bench, K.wood, c.benches));
  if (has('bikes')) {
    const bikePos = [];
    for (let i = 0; i < c.bikes.length; i += 2) for (let k = -1; k <= 1; k++) bikePos.push(c.bikes[i] + k * 7, c.bikes[i + 1]);
    const bikes = instanced(K.bike, K.bikeMat, bikePos, (o) => { o.rotation.y = 0; });
    for (let i = 0; i < bikePos.length / 2; i++) bikes.setColorAt(i, col.set([0x1b1b1b, 0x2c4a6e, 0x7a1e1e, 0x2f5d3a, 0xd9d4c7][i % 5]));
    furniture.add(bikes);
  }
  if (has('bins')) furniture.add(instanced(K.bin, K.green, c.bins));
  if (has('signals')) furniture.add(instanced(K.signal, K.black, c.signals));
  if (has('bollards')) furniture.add(instanced(K.post, K.bollard, c.bollards));
}

// ---- canal names lying on the water ---------------------------------------------
function canalName(group, name, x, z, angDeg) {
  const len = name.length;
  const tex = canvasTex(64 * len + 80, 128, (g, w, h) => {
    g.font = 'italic 600 84px "Bricolage Grotesque", Georgia, serif';
    g.fillStyle = 'rgba(220,236,240,0.85)'; g.textAlign = 'center'; g.textBaseline = 'middle';
    g.fillText(name, w / 2, h / 2);
  }, false);
  const w = len * 2.6 + 4, h = 5.2;
  const m = new THREE.Mesh(new THREE.PlaneGeometry(w, h), new THREE.MeshBasicMaterial({ map: tex, transparent: true, depthWrite: false }));
  m.rotation.set(-Math.PI / 2, 0, THREE.MathUtils.degToRad(angDeg + (Math.abs(angDeg) > 90 ? 180 : 0)));
  m.position.set(x, 0.08, z);
  m.renderOrder = 5;
  group.add(m);
}

// ---- tiles: the city arrives in 1.5 km squares around wherever you look ----------
let INDEX = null, TILE = 1500, searchIndex = [];
const tileMap = new Map();            // "i_j" -> tile
const layerOn = { buildings: true, streets: true, trees: true, furniture: true };
const SHOPPY = /shop|store|restaurant|cafe|coffee|bar|pub|bakery|boutique|retail|market|pharmacy|food|hotel|gallery|salon|butcher|deli|ice_cream|fashion|clothing|jewelry|book|florist|optician/;
const tileKeyAt = (x, z) => `${Math.floor(x / TILE)}_${Math.floor(-z / TILE)}`;
const tileAt = (x, z) => tileMap.get(tileKeyAt(x, z));
// Every loaded tile's places, for labels.
function* allPlaces() { for (const t of tileMap.values()) if (t.ready) yield* t.places; }

function buildTile(t) {
  const c = t.data;
  const [i, j] = c.tile;
  t.ext = { x0: i * TILE, x1: (i + 1) * TILE, z0: -(j + 1) * TILE, z1: -j * TILE };
  t.group = new THREE.Group();
  t.layers = { buildings: new THREE.Group(), streets: new THREE.Group(), trees: new THREE.Group(), furniture: new THREE.Group() };
  for (const [k, g] of Object.entries(t.layers)) { g.visible = layerOn[k]; t.group.add(g); }
  const list = c.buildings || [];
  t.buildings = list;                  // kept for collision, picking and highlighting
  buildingInfo = t.info = [];
  indexBuildings(list);
  const tag = () => t.info.forEach((b, k) => { b.tile = t; b.idx = k; });
  tag();
  buildTileMask(t);
  t.places = (c.places || []).map(([name, cat, x, z, major, addr, web]) => ({ name, cat, x: X(x), z: Z(z), major, addr, web }));
  // Shops get shopfronts on the ground floor.
  hasShop = t.hasShop = new Uint8Array(list.length);
  for (const p of t.places) if (SHOPPY.test(p.cat)) { const b = buildingAt(p.x, p.z); if (b && b.tile === t) t.hasShop[b.idx] = 1; }
  builders.clear();
  buildBuildings(list);
  tag();                               // buildBuildings wrote fresh records
  for (const [mat, b] of builders) {
    const mesh = new THREE.Mesh(b.geometry(), mat);
    mesh.castShadow = mesh.receiveShadow = true;
    mesh.userData.tile = t;
    t.layers.buildings.add(mesh);
  }
  builders.clear();
  const add = (b, mat, order = 0, shadow = true) => { const m = new THREE.Mesh(b.geometry(), mat); m.receiveShadow = shadow; m.renderOrder = order; return m; };
  const ground = new Builder();
  polygon(ground, [[[t.ext.x0, t.ext.z0], [t.ext.x1, t.ext.z0], [t.ext.x1, t.ext.z1], [t.ext.x0, t.ext.z1]]], 0, 3);
  t.group.add(add(ground, MAT.ground));
  const gb = {};
  for (const [cls, rings] of c.green || []) polygon(gb[cls] ||= new Builder(), rings.map(pairs), 0.03, 4);
  for (const [cls, b] of Object.entries(gb)) t.group.add(add(b, MAT[cls] || MAT.grass));
  const pb = new Builder();
  for (const [, rings] of c.plazas || []) polygon(pb, rings.map(pairs), 0.02, 3);
  t.group.add(add(pb, MAT.plaza));
  const wb = new Builder(), qb = new Builder();
  for (const rings of c.water || []) {
    const rs = rings.map(pairs);
    polygon(wb, rs, 0.05, 20);
    for (const r of rs) ribbon(qb, [...r, r[0]], 0.6, 0.12, 2);
  }
  t.group.add(add(wb, MAT.water, 1, false), add(qb, MAT.quay));
  const rb = { road: new Builder(), bike: new Builder(), walk: new Builder(), tram: new Builder(), rail: new Builder(), rails: new Builder() };
  const LEVEL = { walk: 0.07, road: 0.09, bike: 0.11, tram: 0.13, rail: 0.13 };
  t.names = [];
  for (const [layer, w, coords, name] of c.roads || []) {
    const pts = pairs(coords);
    ribbon(rb[layer], pts, w, LEVEL[layer]);
    if (layer === 'tram' || layer === 'rail') { const o = ribbon(new Builder(), pts, 1.435, 0); if (o) for (const line of [o.L, o.R]) ribbon(rb.rails, line, 0.12, 0.16); }
    if (name) for (let k = 0; k < pts.length - 1; k++) {       // street names every 8 m, for the walker
      const [ax, az] = pts[k], [bx, bz] = pts[k + 1], len = Math.hypot(bx - ax, bz - az) || 1;
      for (let d = 0; d <= len; d += 8) t.names.push([ax + (bx - ax) * d / len, az + (bz - az) * d / len, name]);
    }
  }
  for (const [k, b] of Object.entries(rb)) t.layers.streets.add(add(b, MAT[k], 2));
  const bdk = new Builder(), bsd = new Builder();
  for (const coords of c.bridges || []) {
    const o = ribbon(bdk, pairs(coords), 7, 0.3);
    if (o) { side(bsd, o.L, 0.3, 1.1); side(bsd, o.R, 0.3, 1.1); }
  }
  t.layers.streets.add(add(bdk, MAT.bridge, 3), add(bsd, MAT.bridgeSide, 3));
  for (const [name, x, z, ang] of c.waterLabels || []) { canalName(t.group, name, X(x), Z(z), -ang); t.names.push([X(x), Z(z), name]); }
  buildFurniture(c, t.layers.trees, t.layers.furniture);
  addTileSegments(t);
  scene.add(t.group);
  t.data = null;                       // the geometry has it now; keep memory down
  t.ready = true;
}
function disposeTile(t) {
  if (t.group) {
    t.group.traverse(o => {
      if (o.isInstancedMesh) o.dispose();
      else if (o.isMesh) { o.geometry.dispose(); if (o.material.map && o.material.isMeshBasicMaterial) { o.material.map.dispose(); o.material.dispose(); } }
    });
    scene.remove(t.group);
  }
  removeTileSegments(t);
  if (selection && selection.userData.tile === t) showInfo(null);
  tileMap.delete(t.key);
}

// Which tiles to have: everything within reach of the view, nearest first.
let fetching = 0;
const buildQueue = [];
function wantedRadius() { return play.active ? 1100 : THREE.MathUtils.clamp(dist() * 0.95, 1000, 2800); }
function tickTiles() {
  if (!INDEX) return;
  const t0 = controls.target, R = wantedRadius();
  const want = [];
  for (const [i, j] of INDEX.tiles) {
    const cx = (i + 0.5) * TILE, cz = -(j + 0.5) * TILE;
    const d = Math.hypot(cx - t0.x, cz - t0.z) - TILE * 0.71;
    if (d < R) want.push([Math.max(0, d), `${i}_${j}`]);
  }
  want.sort((a, b) => a[0] - b[0]);
  for (const [, key] of want) {
    if (fetching >= 3) break;
    if (tileMap.has(key)) continue;
    const t = { key, ready: false };
    tileMap.set(key, t);
    fetching++;
    fetch(`tiles/${key}.json`).then(r => { if (!r.ok) throw new Error(r.status); return r.json(); })
      .then(data => { t.data = data; buildQueue.push(t); })
      .catch(() => { tileMap.delete(key); })
      .finally(() => { fetching--; });
  }
  // Let go of tiles well outside the view.
  for (const t of [...tileMap.values()]) {
    if (!t.ready) continue;
    const [i, j] = t.key.split('_').map(Number);
    const d = Math.hypot((i + 0.5) * TILE - t0.x, -(j + 0.5) * TILE - t0.z) - TILE * 0.71;
    if (d > R + 1600) disposeTile(t);
  }
  status();
}
function buildOne() {
  // Build the queued tile nearest to the view; one per frame keeps it smooth.
  if (!buildQueue.length) return;
  const t0 = controls.target;
  buildQueue.sort((a, b) => {
    const [ai, aj] = a.key.split('_').map(Number), [bi, bj] = b.key.split('_').map(Number);
    return Math.hypot((ai + 0.5) * TILE - t0.x, -(aj + 0.5) * TILE - t0.z) - Math.hypot((bi + 0.5) * TILE - t0.x, -(bj + 0.5) * TILE - t0.z);
  });
  const t = buildQueue.shift();
  if (tileMap.get(t.key) !== t) return;
  try { buildTile(t); } catch (e) { console.error('tile', t.key, e); tileMap.delete(t.key); }
  status();
}
const statusEl = () => document.getElementById('tiles-status');
function status() {
  const el = statusEl(); if (!el) return;
  const ready = [...tileMap.values()].filter(t => t.ready);
  const n = ready.reduce((a, t) => a + t.info.length, 0);
  const pending = tileMap.size - ready.length;
  el.textContent = pending ? `Loading ${pending} more area${pending > 1 ? 's' : ''}… ${n.toLocaleString()} buildings shown` : `${n.toLocaleString()} buildings shown · ${INDEX.total.toLocaleString()} in the city`;
}

// The whole city as one map image, under the 3D tiles: visible from any height.
function overviewPlane() {
  const b = pairs(INDEX.bounds), xs = b.map(p => p[0]), zs = b.map(p => p[1]);
  const x0 = Math.min(...xs), x1 = Math.max(...xs), z0 = Math.min(...zs), z1 = Math.max(...zs);
  const tex = new THREE.TextureLoader().load('overview.jpg');
  tex.colorSpace = THREE.SRGBColorSpace; tex.anisotropy = 8;
  const m = new THREE.Mesh(new THREE.PlaneGeometry(x1 - x0, z1 - z0).rotateX(-Math.PI / 2),
    new THREE.MeshStandardMaterial({ map: tex, roughness: 1, fog: false }));
  m.position.set((x0 + x1) / 2, -0.15, (z0 + z1) / 2);
  m.receiveShadow = true;
  scene.add(m);
}

async function load() {
  const res = await fetch('index.json');
  if (!res.ok) throw new Error(`index.json: ${res.status}`);
  INDEX = await res.json();
  ORIGIN = INDEX.origin; TILE = INDEX.tile;
  INDEX.total = INDEX.tiles.reduce((a, t) => a + t[2], 0);
  overviewPlane();
  const [sx, sz] = [X(INDEX.start[0]), Z(INDEX.start[1])];
  setView(sx, sz, 1400, 52, -25, false);
  sun.shadow.camera.far = 3000;
  loadText.textContent = 'Loading the streets around the Dam…';
  // Wait for the first few tiles so the opening view is not empty.
  tickTiles();
  const t0 = performance.now();
  while (performance.now() - t0 < 25000) {
    buildOne();
    const ready = [...tileMap.values()].filter(t => t.ready).length;
    if (ready >= 4 || (ready > 0 && !fetching && !buildQueue.length)) break;
    await new Promise(r => setTimeout(r, 30));
  }
  setInterval(tickTiles, 400);
}
