import re
D = '/tmp/claude-0/-home-user-backrooms/4fcfcea5-6b8b-5c78-b895-55bb3a2d14b8/scratchpad/'
s = open(D + 'gta-amsterdam/out/centrum/index.html').read()


def rep(old, new, count=1):
    global s
    assert s.count(old) == count, (s.count(old), old[:90])
    s = s.replace(old, new)


def between(start, end, new):
    global s
    i = s.index(start)
    j = s.index(end, i)
    s = s[:i] + new + s[j:]


# Data and tiles.
between('// ---- masks: what is at a point', '// ---- streets, water, green', open(D + 'city_masks.js').read() + '\n')
between('// ---- instanced street furniture', '// ---- camera helpers', open(D + 'city_tiles.js').read() + '\n')
rep('const buildingInfo = [];       // per building: { h, kind, ring, gabled }', 'let buildingInfo = [];         // the tile being built: { h, kind, ring, gabled, tile, idx }')

# Picking across tiles.
rep('''  const hit = ray.intersectObjects(groups.buildings.visible ? groups.buildings.children : [], false)[0];
  if (!hit) { showInfo(null); return; }
  const owner = hit.object.geometry.userData.owner[hit.faceIndex];
  if (owner >= 0) selectBuilding(owner);''', '''  const meshes = [];
  for (const t of tileMap.values()) if (t.ready && t.layers.buildings.visible) meshes.push(...t.layers.buildings.children);
  const hit = ray.intersectObjects(meshes, false)[0];
  if (!hit) { showInfo(null); return; }
  const owner = hit.object.geometry.userData.owner[hit.faceIndex];
  if (owner >= 0) selectBuilding(hit.object.userData.tile, owner);''')
rep('''function selectBuilding(i) {
  if (selection) { scene.remove(selection); selection.geometry.dispose(); }
  buildBuildings(city.buildings, i, selMat);''', '''function selectBuilding(t, i) {
  if (selection) { scene.remove(selection); selection.geometry.dispose(); }
  buildingInfo = t.info; hasShop = t.hasShop;
  builders.clear();
  buildBuildings(t.buildings, i, selMat);''')
rep('''  selection = new THREE.Mesh(b.geometry(), selMat); selection.renderOrder = 10;''', '''  selection = new THREE.Mesh(b.geometry(), selMat); selection.renderOrder = 10; selection.userData.tile = t;''')
rep('''  const info = buildingInfo[i];
  const inside = places.filter(p => pip(p.x, p.z, info.ring));''', '''  const info = t.info[i];
  const inside = t.places.filter(p => pip(p.x, p.z, info.ring));''')

# Labels from every loaded tile.
rep('''  if (document.getElementById('l-labels').checked && places.length) {''', '''  if (document.getElementById('l-labels').checked && tileMap.size) {''')
rep('''    for (const p of places) {
      const dd = Math.hypot(p.x - t.x, p.z - t.z);''', '''    for (const p of allPlaces()) {
      const dd = Math.hypot(p.x - t.x, p.z - t.z);''')

# Search: the whole city's names, fetched the first time you search.
rep('''q.addEventListener('input', () => {
  const s = q.value.trim().toLowerCase();''', '''let searchLoading = null;
function loadSearch() {
  return searchLoading ||= fetch('search.json').then(r => r.json()).then(d => {
    for (const [name, cat, x, z] of d.places) searchIndex.push({ name, kind: pretty(cat) || 'Place', x: X(x), z: Z(z), place: { name, cat, x: X(x), z: Z(z) } });
    for (const [name, kind, x, z] of d.streets) searchIndex.push({ name, kind, x: X(x), z: Z(z) });
  });
}
q.addEventListener('focus', () => { loadSearch(); });
q.addEventListener('input', async () => {
  await loadSearch();
  const s = q.value.trim().toLowerCase();''')

# Layers, per tile.
rep('''toggle('l-buildings', on => { groups.buildings.visible = on; if (selection) selection.visible = on; });
toggle('l-trees', on => { trees.visible = on; });
toggle('l-streets', on => { groups.streets.visible = on; });
toggle('l-furniture', on => { furniture.visible = on; });''', '''const setLayer = (k, on) => { layerOn[k] = on; for (const t of tileMap.values()) if (t.ready) t.layers[k].visible = on; };
toggle('l-buildings', on => { setLayer('buildings', on); if (selection) selection.visible = on; });
toggle('l-trees', on => setLayer('trees', on));
toggle('l-streets', on => setLayer('streets', on));
toggle('l-furniture', on => setLayer('furniture', on));''')

# The walker: global wall segments, tile radars, tile street names.
between('  // ---- collision: building walls as 2D segments in a grid', '  function collide(p, r) {', '')
rep('''      const c = Math.floor(p.x / CELL), rr = Math.floor(p.z / CELL);
      let moved = false;
      for (let dc = -1; dc <= 1; dc++) for (let dr = -1; dr <= 1; dr++) {
        const list = segGrid.get((c + dc) * 100000 + rr + dr);
        if (!list) continue;
        for (let i = 0; i < list.length; i += 4) {''', '''      const c = Math.floor(p.x / SEG_CELL), rr = Math.floor(p.z / SEG_CELL);
      let moved = false;
      for (let dc = -1; dc <= 1; dc++) for (let dr = -1; dr <= 1; dr++) {
        const entries = segGrid.get((c + dc) * 100000 + rr + dr);
        if (!entries) continue;
        for (const { s: list } of entries) for (let i = 0; i < list.length; i += 4) {''')
rep('''  const blocked = (x, z) => buildingAt(x, z) >= 0;''', '''  const blocked = (x, z) => !!buildingAt(x, z);''')
rep('''      const id = buildingAt(x, z);
      if (id >= 0 && y < buildingInfo[id].h + 0.5) { d = Math.max(0.8, s - 0.4); break; }''', '''      const hit = buildingAt(x, z);
      if (hit && y < hit.h + 0.5) { d = Math.max(0.8, s - 0.4); break; }''')
between('  function buildRadar() {', '  function drawRadar() {', '')
rep('''    const px = (P.x - mask.ext.x0) / MASK_RES, pz = (P.z - mask.ext.z0) / MASK_RES;
    rctx.drawImage(radarBase, -px * MASK_RES * scale, -pz * MASK_RES * scale, mask.W * MASK_RES * scale, mask.H * MASK_RES * scale);''', '''    for (const t of tileMap.values()) {
      if (!t.ready || !t.radar) continue;
      rctx.drawImage(t.radar, (t.ext.x0 - P.x) * scale, (t.ext.z0 - P.z) * scale, TILE * scale, TILE * scale);
    }''')
rep('''    for (const [x, z, n] of namePoints) { const d = (x - P.x) ** 2 + (z - P.z) ** 2; if (d < bd) { bd = d; best = n; } }''', '''    for (const t of tileMap.values()) {
      if (!t.ready || Math.abs((t.ext.x0 + t.ext.x1) / 2 - P.x) > TILE || Math.abs((t.ext.z0 + t.ext.z1) / 2 - P.z) > TILE) continue;
      for (const [x, z, n] of t.names) { const d = (x - P.x) ** 2 + (z - P.z) ** 2; if (d < bd) { bd = d; best = n; } }
    }''')
rep('''    if (!segGrid) { buildSegments(); buildRadar(); }
''', '')
rep('''  let radarBase = null, namePoints = [];''', '')
rep("    const name = best || 'Amsterdam Centrum';", "    const name = best || 'Amsterdam';")

# Loop: build a tile per frame, fog that ends where the loaded city ends.
rep('''  if (!play.active) controls.update();''', '''  if (!play.active) controls.update();
  buildOne();
  {
    const R = wantedRadius(), d0 = play.active ? 0 : dist();
    scene.fog.near = d0 + R * 0.45; scene.fog.far = d0 + R * 1.15;
  }''')

# A city, not a quarter: zoom out to all of it.
rep('controls.maxDistance = 3500;', 'controls.maxDistance = 26000;')
rep('const camera = new THREE.PerspectiveCamera(45, 1, 1, 12000);', 'const camera = new THREE.PerspectiveCamera(45, 1, 1, 80000);')
rep('sky.scale.setScalar(10000);', 'sky.scale.setScalar(70000);')

# Words.
rep('<title>Amsterdam Centrum 3D</title>', '<title>Amsterdam 3D</title>')
rep('<h1>Amsterdam Centrum 3D</h1><p id="load-text">Loading the city…</p>', '<h1>Amsterdam 3D</h1><p id="load-text">Loading the city…</p>')
rep('''    <h1>Amsterdam Centrum 3D</h1>
    <p class="sub">Press <b>🚶</b> to walk the streets. 2.2 × 2 km of the city centre. Building footprints and heights, canals, streets, bridges, trees, street furniture and 7,100 places from OpenStreetMap via Overture Maps. Facades and roof pitches are generated.</p>''', '''    <h1>Amsterdam 3D</h1>
    <p class="sub">The whole city: 285,000 buildings, every canal, street, bridge and tree, and 37,000 places, from OpenStreetMap via Overture Maps. Areas load in 3D around where you look. Press <b>🚶</b> to walk. Facades and roof pitches are generated.</p>
    <p class="sub" id="tiles-status" role="status">Loading…</p>''')
rep('aria-label="3D map of central Amsterdam"', 'aria-label="3D map of Amsterdam"')
# Exact matches from the street map (streets, canals) first: they come from
# OSM geometry, while some business listings carry a wrong location.
rep('''    .sort((a, b) => (a.name.toLowerCase().startsWith(s) ? 0 : 1) - (b.name.toLowerCase().startsWith(s) ? 0 : 1) || a.name.length - b.name.length)''',
    '''    .sort((a, b) => {
      const rank = e => (e.name.toLowerCase() === s ? 0 : e.name.toLowerCase().startsWith(s) ? 2 : 4) + (e.place ? 1 : 0);
      return rank(a) - rank(b) || a.name.length - b.name.length;
    })''')
rep('window.__city = { buildingInfo, camera, controls, setView, ray, groups, THREE };', 'window.__city = { tileMap, camera, controls, setView, ray, THREE };')
open(D + 'gta-amsterdam/out/city/index.html', 'w').write(s)
left = [m for m in re.findall(r'\b(city\.[a-zA-Z]+|groups\.[a-z]+|\bplaces\b(?!\.)|namePoints|radarBase|mask\.)', s)]
print('patched; leftovers:', sorted(set(left)))
