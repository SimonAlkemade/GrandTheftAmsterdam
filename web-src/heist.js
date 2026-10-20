// ---- the heist: "De Gouden Kat" -------------------------------------------
// Drive to the coffeeshop, take the week's takings, lose the politie, reach
// the lock-up. Police and the GPS route both follow breadth-first distance
// fields on a 1 m navigation grid built from the drive mode's collision map.
const heist = (() => {
  const NAV = 1.0;                                  // metres per nav cell
  const SHOP_NEAR = [-90, -110], LOCKUP_NEAR = [165, -150];
  const STASH = 18450;                              // euro, in the bag
  const $ = id => document.getElementById(id);
  const ui = {
    objective: $('objective'), stars: $('stars'), health: $('health-fill'), timer: $('mission-timer'),
    grab: $('grab'), grabFill: $('grab-fill'), grabBtn: $('grab-btn'), card: $('mission-card'),
    result: $('mission-result'), resultTitle: $('result-title'), resultText: $('result-text'),
    resultStats: $('result-stats'), mhud: $('mission-hud'),
  };
  let nav = null, nw = 0, nh = 0, M = null;
  let shop = null, lockup = null, shopField = null, lockupField = null, playerField = null;
  let state = 'off', t0 = 0, elapsed = 0, health = 100, wanted = 0, grabT = 0, lostT = 0, bustT = 0;
  let fieldT = 0, spawnT = 0, routeT = 0, route = [], sirenT = 0, siren = null;
  const cops = [];
  // Your partner: dark clothes, balaclava, and a sports bag on the way out.
  const black = new THREE.MeshStandardMaterial({ color: 0x15171a, roughness: 0.9 });
  const robber = life.makeFigure({ shirt: black, legs: new THREE.MeshStandardMaterial({ color: 0x23262b, roughness: 0.9 }), mask: black });
  const bag = new THREE.Mesh(life.geo.bag, new THREE.MeshStandardMaterial({ color: 0x1f6b3a, roughness: 0.7 }));
  bag.position.set(0, -0.72, 0); bag.rotation.y = Math.PI / 2; bag.castShadow = true;
  robber.armR.add(bag);
  robber.root.visible = false; scene.add(robber.root);
  let rob = null, grabQueued = false;
  // A press is latched until the next frame reads it, so a quick tap is never lost.
  addEventListener('keydown', e => { if (e.code === 'KeyE' && drive.active) grabQueued = true; });

  // ---- nav grid and distance fields ---------------------------------------
  function buildNav() {
    M = drive.map();
    const step = Math.round(NAV / M.RES);
    nw = Math.floor(M.gw / step); nh = Math.floor(M.gh / step);
    nav = new Uint8Array(nw * nh);
    // A nav cell is drivable when no building or water lies within ~1.2 m of it.
    const pad = Math.round(1.2 / M.RES);
    for (let r = 0; r < nh; r++) for (let c = 0; c < nw; c++) {
      let ok = 1;
      const r0 = r * step, c0 = c * step;
      for (let dr = -pad; dr <= pad + step - 1 && ok; dr++) for (let dc = -pad; dc <= pad + step - 1; dc++) {
        const rr = r0 + dr, cc = c0 + dc;
        if (rr < 0 || cc < 0 || rr >= M.gh || cc >= M.gw || M.grid[rr * M.gw + cc] !== 0) { ok = 0; break; }
      }
      nav[r * nw + c] = ok;
    }
  }
  // Nav rows run from the south edge, like the collision grid.
  const toCell = (x, z) => [Math.floor((x - M.gmin.x) / NAV), Math.floor((M.gmin.z + M.gh * M.RES - z) / NAV)];
  const toWorld = (c, r) => [M.gmin.x + (c + 0.5) * NAV, M.gmin.z + M.gh * M.RES - (r + 0.5) * NAV];
  const inNav = (c, r) => c >= 0 && r >= 0 && c < nw && r < nh && nav[r * nw + c] === 1;
  function nearestNav(x, z, maxR = 12) {
    const [c0, r0] = toCell(x, z);
    for (let rad = 0; rad <= maxR; rad++)
      for (let dr = -rad; dr <= rad; dr++) for (let dc = -rad; dc <= rad; dc++)
        if (Math.max(Math.abs(dr), Math.abs(dc)) === rad && inNav(c0 + dc, r0 + dr)) return [c0 + dc, r0 + dr];
    return null;
  }
  function bfs(c, r) {
    const dist = new Int32Array(nw * nh).fill(-1);
    if (!inNav(c, r)) return dist;
    const q = new Int32Array(nw * nh);
    let head = 0, tail = 0;
    dist[r * nw + c] = 0; q[tail++] = r * nw + c;
    while (head < tail) {
      const i = q[head++], ci = i % nw, ri = (i / nw) | 0, d = dist[i] + 1;
      if (ci > 0 && nav[i - 1] && dist[i - 1] < 0) { dist[i - 1] = d; q[tail++] = i - 1; }
      if (ci < nw - 1 && nav[i + 1] && dist[i + 1] < 0) { dist[i + 1] = d; q[tail++] = i + 1; }
      if (ri > 0 && nav[i - nw] && dist[i - nw] < 0) { dist[i - nw] = d; q[tail++] = i - nw; }
      if (ri < nh - 1 && nav[i + nw] && dist[i + nw] < 0) { dist[i + nw] = d; q[tail++] = i + nw; }
    }
    return dist;
  }
  // Follow a field downhill from (x, z): returns world points, every few cells.
  function descend(field, x, z, steps, every = 3) {
    const start = nearestNav(x, z, 6);
    if (!start) return [];
    let [c, r] = start;
    const out = [];
    for (let k = 0; k < steps; k++) {
      const d = field[r * nw + c];
      if (d <= 0) break;
      let best = null, bd = d;
      for (const [dc, dr] of [[1, 0], [-1, 0], [0, 1], [0, -1], [1, 1], [1, -1], [-1, 1], [-1, -1]]) {
        const nc = c + dc, nr = r + dr;
        if (nc < 0 || nr < 0 || nc >= nw || nr >= nh) continue;
        const v = field[nr * nw + nc];
        if (v >= 0 && v < bd && (dc === 0 || dr === 0 || (inNav(c + dc, r) && inNav(c, r + dr)))) { bd = v; best = [nc, nr]; }
      }
      if (!best) break;
      [c, r] = best;
      if (k % every === 0) out.push(toWorld(c, r));
    }
    return out;
  }
  function fieldFrom(x, z) {
    const p = nearestNav(x, z, 20);
    return p ? bfs(p[0], p[1]) : (playerField || new Int32Array(nw * nh).fill(-1));
  }

  // ---- choosing the shop and the lock-up --------------------------------------
  function nearBuilding(c, r, within) {
    const [x, z] = toWorld(c, r);
    let best = null;
    for (let a = 0; a < 16; a++) {
      const ang = a / 16 * Math.PI * 2, dx = Math.cos(ang), dz = Math.sin(ang);
      for (let d = 0.5; d <= within; d += 0.5) {
        if (drive.cell(x + dx * d, z + dz * d) >= 2) { if (!best || d < best.d) best = { d, dx, dz }; break; }
      }
    }
    return best;
  }
  function choosePlaces() {
    const spawnField = fieldFrom(drive.st.x, drive.st.z);
    let bestShop = null, bs = Infinity;
    for (let r = 0; r < nh; r += 2) for (let c = 0; c < nw; c += 2) {
      const d = spawnField[r * nw + c];
      if (d < 160 || d > 520) continue;
      const [x, z] = toWorld(c, r);
      const score = Math.hypot(x - SHOP_NEAR[0], z - SHOP_NEAR[1]);
      if (score < bs) { const b = nearBuilding(c, r, 3.5); if (b) { bs = score; bestShop = { c, r, x, z, face: b }; } }
    }
    shop = bestShop;
    shopField = bfs(shop.c, shop.r);
    let bestLock = null, bl = Infinity;
    for (let r = 0; r < nh; r += 2) for (let c = 0; c < nw; c += 2) {
      const d = shopField[r * nw + c];
      if (d < 220) continue;
      const [x, z] = toWorld(c, r);
      const score = Math.hypot(x - LOCKUP_NEAR[0], z - LOCKUP_NEAR[1]);
      if (score < bl) { const b = nearBuilding(c, r, 3.5); if (b) { bl = score; bestLock = { c, r, x, z, face: b }; } }
    }
    lockup = bestLock || { ...shop };
    lockupField = bfs(lockup.c, lockup.r);
    placeSign();
  }

  // ---- props: sign, beacons -------------------------------------------------
  function textTexture(lines, w, h, bg, fg, font) {
    const cv = document.createElement('canvas'); cv.width = w; cv.height = h;
    const g = cv.getContext('2d');
    g.fillStyle = bg; g.fillRect(0, 0, w, h);
    g.fillStyle = fg; g.textAlign = 'center'; g.textBaseline = 'middle';
    lines.forEach(([txt, size, y]) => { g.font = `${size}px ${font}`; g.fillText(txt, w / 2, y); });
    const t = new THREE.CanvasTexture(cv); t.colorSpace = THREE.SRGBColorSpace; t.anisotropy = 4;
    return t;
  }
  const props = new THREE.Group(); scene.add(props);
  let signs = [];
  function placeSign() {
    for (const s of signs) props.remove(s);
    signs = [];
    const mk = (spot, lines, colour, glow) => {
      const g = new THREE.Group();
      const tex = textTexture(lines, 1024, 256, colour, glow, '"Anton", Impact, sans-serif');
      const board = new THREE.Mesh(new THREE.BoxGeometry(3.6, 0.9, 0.12),
        new THREE.MeshStandardMaterial({ map: tex, emissive: 0xffffff, emissiveMap: tex, emissiveIntensity: 0.55, roughness: 0.5 }));
      g.add(board);
      const strip = new THREE.Mesh(new THREE.BoxGeometry(3.6, 0.06, 0.2),
        new THREE.MeshStandardMaterial({ color: 0x0a0a0a, emissive: glow, emissiveIntensity: 1.4 }));
      strip.position.y = -0.5; g.add(strip);
      const { d, dx, dz } = spot.face;
      g.position.set(spot.x + dx * (d - 0.15), M.streetY + 3.4, spot.z + dz * (d - 0.15));
      g.rotation.y = Math.atan2(-dx, -dz);     // face the street
      props.add(g); signs.push(g);
    };
    mk(shop, [['COFFEESHOP', 120, 92], ['· DE GOUDEN KAT ·', 64, 196]], '#123d2a', '#f2c14e');
    mk(lockup, [['GARAGE  ·  VERHUUR', 104, 128]], '#2b2f33', '#e9edf0');
  }
  const beaconMat = new THREE.MeshBasicMaterial({ color: 0xf2c14e, transparent: true, opacity: 0.28, depthWrite: false, side: THREE.DoubleSide });
  const beacon = new THREE.Mesh(new THREE.CylinderGeometry(2.6, 2.6, 40, 32, 1, true), beaconMat);
  const ring = new THREE.Mesh(new THREE.TorusGeometry(2.6, 0.12, 8, 48).rotateX(Math.PI / 2),
    new THREE.MeshBasicMaterial({ color: 0xf2c14e }));
  beacon.add(ring); ring.position.y = -19.8;
  beacon.visible = false; props.add(beacon);
  function setTarget(spot) {
    if (!spot) { beacon.visible = false; return; }
    beacon.visible = true;
    beacon.position.set(spot.x, M.streetY + 20, spot.z);
  }

  // ---- police cars --------------------------------------------------------
  const politieTex = textTexture([['POLITIE', 150, 128]], 1024, 256, '#f4f6f8', '#123c8c', '"Anton", Impact, sans-serif');
  function makeCop() {
    const g = new THREE.Group();
    const white = new THREE.MeshStandardMaterial({ color: 0xf2f4f6, metalness: 0.4, roughness: 0.35 });
    const blue = new THREE.MeshStandardMaterial({ color: 0x14398f, roughness: 0.4 });
    const orange = new THREE.MeshStandardMaterial({ color: 0xf26a1b, roughness: 0.4 });
    const glassM = new THREE.MeshStandardMaterial({ color: 0x0d1418, metalness: 0.8, roughness: 0.08 });
    const side = new THREE.MeshStandardMaterial({ color: 0xffffff, map: politieTex });
    const dark = new THREE.MeshStandardMaterial({ color: 0x1a1c1e, roughness: 0.6 });
    const add = (geo, mat, x, y, z) => { const m = new THREE.Mesh(geo, mat); m.position.set(x, y, z); m.castShadow = true; g.add(m); return m; };
    add(new THREE.BoxGeometry(1.84, 0.62, 4.5), white, 0, 0.62, 0);
    add(new THREE.BoxGeometry(1.86, 0.16, 4.52), blue, 0, 0.5, 0);
    add(new THREE.BoxGeometry(1.86, 0.08, 1.2), orange, 0, 0.66, 0.9);
    add(new THREE.PlaneGeometry(2.2, 0.55).rotateY(Math.PI / 2), side, 0.935, 0.8, -0.2);
    add(new THREE.PlaneGeometry(2.2, 0.55).rotateY(-Math.PI / 2), side, -0.935, 0.8, -0.2);
    add(new THREE.BoxGeometry(1.64, 0.56, 2.2), glassM, 0, 1.2, 0.2);
    add(new THREE.BoxGeometry(1.5, 0.08, 2.0), white, 0, 1.5, 0.22);
    const lb = new THREE.MeshStandardMaterial({ color: 0x1030ff, emissive: 0x1a3cff, emissiveIntensity: 0 });
    const lr = new THREE.MeshStandardMaterial({ color: 0x1030ff, emissive: 0x1a3cff, emissiveIntensity: 0 });
    add(new THREE.BoxGeometry(0.55, 0.14, 0.32), lb, -0.32, 1.62, 0.1);
    add(new THREE.BoxGeometry(0.55, 0.14, 0.32), lr, 0.32, 1.62, 0.1);
    for (const [x, z] of [[-0.88, -1.4], [0.88, -1.4], [-0.88, 1.4], [0.88, 1.4]])
      add(new THREE.CylinderGeometry(0.34, 0.34, 0.26, 14).rotateZ(Math.PI / 2), dark, x, 0.34, z);
    scene.add(g);
    return { g, lights: [lb, lr], x: 0, z: 0, heading: 0, speed: 0, stuck: 0, alive: true, path: [], pathT: 0 };
  }
  function spawnCop(minD, maxD) {
    // A reachable spot the right road distance from the player, out of sight behind.
    const cands = [];
    for (let r = 0; r < nh; r += 3) for (let c = 0; c < nw; c += 3) {
      const d = playerField[r * nw + c];
      if (d >= minD && d <= maxD) cands.push([c, r]);
    }
    if (!cands.length) return;
    const [c, r] = cands[(Math.random() * cands.length) | 0];
    const cop = cops.find(k => !k.alive) || makeCop();
    const [x, z] = toWorld(c, r);
    Object.assign(cop, { x, z, speed: 0, stuck: 0, alive: true, pathT: 0 });
    cop.heading = Math.atan2(-(drive.st.x - x), -(drive.st.z - z));
    cop.g.visible = true;
    if (!cops.includes(cop)) cops.push(cop);
  }
  function clearCops() { for (const c of cops) { c.alive = false; c.g.visible = false; } }

  function copStep(cop, dt) {
    const p = drive.st;
    cop.pathT -= dt;
    if (cop.pathT <= 0) { cop.path = descend(playerField, cop.x, cop.z, 14, 2); cop.pathT = 0.25; }
    const dToPlayer = Math.hypot(p.x - cop.x, p.z - cop.z);
    let tx, tz;
    if (dToPlayer < 14 || !cop.path.length) { tx = p.x + p.vx * 0.4; tz = p.z + p.vz * 0.4; }  // ram
    else { const q = cop.path[Math.min(cop.path.length - 1, 4)]; tx = q[0]; tz = q[1]; }
    const want = Math.atan2(-(tx - cop.x), -(tz - cop.z));
    let diff = want - cop.heading;
    diff = Math.atan2(Math.sin(diff), Math.cos(diff));
    cop.heading += THREE.MathUtils.clamp(diff, -2.4 * dt, 2.4 * dt) * Math.min(1, Math.abs(cop.speed) / 3 + 0.3);
    const top = 20.5 * (1 - Math.min(0.65, Math.abs(diff) / 1.4));
    cop.speed += THREE.MathUtils.clamp(top - cop.speed, -14 * dt, 7.5 * dt);
    const [fx, fz] = drive.fwd(cop.heading);
    const nx = cop.x + fx * cop.speed * dt, nz = cop.z + fz * cop.speed * dt;
    if (!drive.blockedAt(nx, nz, cop.heading)) { cop.x = nx; cop.z = nz; cop.stuck = Math.max(0, cop.stuck - dt); }
    else { cop.speed *= -0.3; cop.stuck += dt; cop.heading += 0.6 * dt * Math.sign(diff || 1); }
    if (drive.cell(cop.x, cop.z) === 1 || cop.stuck > 2.5) {          // in the canal, or wedged
      cop.alive = false; cop.g.visible = false;
      if (drive.cell(cop.x, cop.z) === 1) { drive.splash(); drive.say('SPLASH', 'One politie car fewer', 1.6); }
      return;
    }
    // Contact with the player: push apart, hurt the car.
    const dx = p.x - cop.x, dz = p.z - cop.z, d = Math.hypot(dx, dz);
    if (d < 2.7 && d > 0.01) {
      const push = (2.7 - d) / d;
      if (!drive.blockedAt(p.x + dx * push * 0.6, p.z + dz * push * 0.6, p.heading)) { p.x += dx * push * 0.6; p.z += dz * push * 0.6; }
      cop.x -= dx * push * 0.4; cop.z -= dz * push * 0.4;
      const rel = Math.abs(cop.speed - (p.vx * fx + p.vz * fz));
      p.vx += dx / d * rel * 0.25; p.vz += dz / d * rel * 0.25;
      cop.speed *= 0.5;
      hurt(Math.min(12, 2 + rel * 0.6));
      drive.st.shake = Math.min(0.6, 0.15 + rel * 0.03);
    }
    cop.g.position.set(cop.x, M.streetY, cop.z);
    cop.g.rotation.y = cop.heading;
    const on = Math.floor(performance.now() / 160) % 2;
    cop.lights[0].emissiveIntensity = on ? 3 : 0.1;
    cop.lights[1].emissiveIntensity = on ? 0.1 : 3;
  }

  // ---- siren --------------------------------------------------------------
  function sirenTick(dt) {
    const a = drive.audio();
    const near = cops.filter(c => c.alive).reduce((m, c) => Math.min(m, Math.hypot(c.x - drive.st.x, c.z - drive.st.z)), Infinity);
    if (!a) return;
    if (!siren) {
      const o = a.ctx.createOscillator(), g = a.ctx.createGain();
      o.type = 'triangle'; g.gain.value = 0; o.connect(g); g.connect(a.ctx.destination); o.start();
      siren = { o, g };
    }
    // The Dutch two-tone: high, low, high, low.
    sirenT += dt;
    const hi = Math.floor(sirenT / 0.62) % 2 === 0;
    siren.o.frequency.setTargetAtTime(hi ? 587 : 440, a.ctx.currentTime, 0.01);
    const vol = drive.soundOn() && isFinite(near) ? 0.07 * Math.max(0, 1 - near / 160) : 0;
    siren.g.gain.setTargetAtTime(vol, a.ctx.currentTime, 0.1);
  }
  function jingle(notes) {
    const a = drive.audio();
    if (!a || !drive.soundOn()) return;
    notes.forEach(([f, t, d]) => {
      const o = a.ctx.createOscillator(), g = a.ctx.createGain();
      o.type = 'square'; o.frequency.value = f; g.gain.value = 0.05;
      o.connect(g); g.connect(a.ctx.destination);
      o.start(a.ctx.currentTime + t); o.stop(a.ctx.currentTime + t + d);
    });
  }

  // ---- HUD ------------------------------------------------------------------
  function objective(html) { ui.objective.innerHTML = html; }
  function setWanted(n) { wanted = n; ui.stars.innerHTML = '★★★★★'.split('').map((s, i) => `<span class="${i < n ? 'on' : ''}">${s}</span>`).join(''); }
  function hurt(v) {
    if (state === 'off' || state === 'over') return;
    health = Math.max(0, health - v);
    ui.health.style.width = `${health}%`;
    if (health <= 0) fail('WASTED', 'The car gave up before the politie did.');
  }
  const fmt = s => `${Math.floor(s / 60)}:${String(Math.floor(s % 60)).padStart(2, '0')}`;

  // ---- flow -------------------------------------------------------------------
  function begin() {
    ui.card.hidden = true;
    if (!nav) buildNav();
    drive.placeAtSpawn();
    if (!shop) choosePlaces();
    playerField = fieldFrom(drive.st.x, drive.st.z);
    clearCops();
    Object.assign(drive.st, { vx: 0, vz: 0 });
    state = 'toShop'; t0 = performance.now(); health = 100; grabT = 0; lostT = 0; bustT = 0; spawnT = 0;
    ui.health.style.width = '100%';
    setWanted(0);
    setTarget(shop);
    ui.mhud.hidden = false;
    drive.holdRespawn = true; drive.lockReset = true;
    objective('Drive to <b>Coffeeshop De Gouden Kat</b>. Follow the purple route.');
    drive.say('DE GOUDEN KAT', 'The coffeeshop keeps the week’s takings in the back', 2.6);
  }
  // ---- the robbery: out of the car, into the shop, back with the bag -------
  function startRobbery() {
    const p = drive.st, [fx, fz] = drive.fwd(p.heading);
    const side = { x: p.x - fz * 1.3, z: p.z + fx * 1.3 };
    const f = shop.face;
    const door = { x: shop.x + f.dx * (f.d - 0.35), z: shop.z + f.dz * (f.d - 0.35) };
    const leg = Math.hypot(door.x - side.x, door.z - side.z);
    rob = { t: 0, side, door, leg, inside: 1.6, run: 3.4, car: { x: p.x, z: p.z, h: p.heading } };
    rob.total = 0.35 + leg / rob.run * 2 + rob.inside + 0.35;
    state = 'robbing';
    ui.grabBtn.hidden = true; ui.grab.hidden = false;
    ui.grab.firstElementChild.textContent = 'YOUR PARTNER IS INSIDE';
    objective('Keep the engine running…');
    robber.root.visible = true; bag.visible = false;
  }
  function robberyStep(dt) {
    const p = drive.st, r = rob;
    Object.assign(p, { x: r.car.x, z: r.car.z, heading: r.car.h, vx: 0, vz: 0 });    // the car waits
    r.t += dt;
    ui.grabFill.style.width = `${Math.min(100, r.t / r.total * 100)}%`;
    const tIn = 0.35 + r.leg / r.run, tOut = tIn + r.inside;
    const place = (a, b, k, face) => {
      robber.root.position.set(a.x + (b.x - a.x) * k, M.streetY, a.z + (b.z - a.z) * k);
      robber.root.rotation.y = Math.atan2(-(face.x - a.x), -(face.z - a.z));
    };
    if (r.t < 0.35) {                                       // climbing out
      place(r.side, r.side, 0, r.door);
      robber.root.scale.setScalar(0.6 + r.t / 0.35 * 0.4);
      life.walkCycle(robber, dt, 0.5);
    } else if (r.t < tIn) {                                 // running in
      robber.root.scale.setScalar(1);
      place(r.side, r.door, (r.t - 0.35) / (tIn - 0.35), r.door);
      life.walkCycle(robber, dt, r.run);
    } else if (r.t < tOut) {                                // inside
      robber.root.visible = false;
      if (!r.shout && r.t > tIn + r.inside * 0.4) { r.shout = true; drive.say('', 'Shouting from inside the shop…', 1); }
    } else if (r.t < r.total - 0.35) {                      // running out with the bag
      robber.root.visible = true; bag.visible = true;
      place(r.door, r.side, (r.t - tOut) / (r.total - 0.35 - tOut), r.side);
      life.walkCycle(robber, dt, r.run);
      robber.armR.rotation.x = 0.15;                        // the heavy arm hangs
    } else if (r.t < r.total) {                             // in the car
      robber.root.scale.setScalar(Math.max(0.01, 1 - (r.t - (r.total - 0.35)) / 0.35));
    } else {
      robber.root.visible = false; robber.root.scale.setScalar(1);
      ui.grab.hidden = true;
      grabbed();
    }
  }

  function grabbed() {
    life.setPanic({ x: shop.x, z: shop.z });
    state = 'escape';
    drive.say('ALARM!', 'Politie are on their way', 2);
    jingle([[880, 0, 0.12], [660, 0.14, 0.12], [880, 0.28, 0.12]]);
    setWanted(3);
    setTarget(lockup);
    objective('Lose the <b class="cop">politie</b>, then get to the <b>lock-up</b>.');
    playerField = fieldFrom(drive.st.x, drive.st.z);
    spawnCop(60, 110); spawnCop(90, 150);
    spawnT = 0;
  }
  function pass() {
    state = 'over';
    life.setPanic(null);
    const s = (performance.now() - t0) / 1000;
    jingle([[523, 0, 0.16], [659, 0.17, 0.16], [784, 0.34, 0.16], [1047, 0.51, 0.45]]);
    showResult('MISSION PASSED', 'The bag is in the lock-up and nobody followed you home.',
      [['Time', fmt(s)], ['Takings', `€ ${STASH.toLocaleString('nl-NL')}`], ['Car condition', `${Math.round(health)}%`]], 'pass');
  }
  function fail(title, why) {
    if (state === 'over') return;
    state = 'over';
    life.setPanic(null);
    robber.root.visible = false;
    jingle([[392, 0, 0.25], [330, 0.27, 0.25], [262, 0.54, 0.6]]);
    showResult(title, why, [['Time', fmt((performance.now() - t0) / 1000)]], 'fail');
  }
  function showResult(title, text, stats, kind) {
    clearCops();
    setTarget(null);
    ui.resultTitle.textContent = title;
    ui.resultTitle.className = kind;
    ui.resultText.textContent = text;
    ui.resultStats.innerHTML = stats.map(([k, v]) => `<dt>${k}</dt><dd>${v}</dd>`).join('');
    ui.result.hidden = false;
    ui.grab.hidden = true; ui.grabBtn.hidden = true;
    drive.holdRespawn = false;
  }
  function end() {
    state = 'off';
    life.setPanic(null);
    robber.root.visible = false;
    clearCops(); setTarget(null);
    ui.mhud.hidden = true; ui.result.hidden = true; ui.card.hidden = true;
    ui.grab.hidden = true; ui.grabBtn.hidden = true;
    drive.holdRespawn = false; drive.lockReset = false; drive.drawOnRadar = null;
    if (siren) siren.g.gain.value = 0;
  }

  drive.on('fall', () => { if (state !== 'off' && state !== 'over') setTimeout(() => fail('WASTED', 'The car is at the bottom of the canal.'), 1600); });
  drive.on('crash', v => { if (v > 4) hurt((v - 4) * 2.2); });
  drive.on('stop', end);

  drive.hooks.push((dt, speed) => {
    if (state === 'off') return;
    sirenTick(dt);
    if (state === 'over') return;
    const p = drive.st;
    elapsed = (performance.now() - t0) / 1000;
    ui.timer.textContent = fmt(elapsed);
    fieldT -= dt;
    if (fieldT <= 0 && state === 'escape') { playerField = fieldFrom(p.x, p.z); fieldT = 0.4; }
    // GPS route to whatever we are heading for.
    routeT -= dt;
    if (routeT <= 0) { route = descend(state === 'escape' ? lockupField : shopField, p.x, p.z, 900, 4); routeT = 0.3; }

    if (state === 'toShop' || state === 'grabbing') {
      const d = Math.hypot(p.x - shop.x, p.z - shop.z);
      const atDoor = d < 7 && Math.abs(speed) < 3;
      ui.grabBtn.hidden = !atDoor;
      const press = grabQueued;
      grabQueued = false;
      if (atDoor) {
        if (state !== 'grabbing') objective('Press <kbd>E</kbd> or <b>GRAB</b>. Your partner goes in for the bag.');
        state = 'grabbing';
        if (press) startRobbery();
      } else if (state === 'grabbing') {
        state = 'toShop';
        objective('Stop at the door of <b>De Gouden Kat</b>.');
      }
      return;
    }
    if (state === 'robbing') { robberyStep(dt); return; }
    if (state === 'escape' || state === 'home') {
      const live = cops.filter(c => c.alive);
      for (const c of live) copStep(c, dt);
      const near = live.reduce((m, c) => Math.min(m, Math.hypot(c.x - p.x, c.z - p.z)), Infinity);
      if (state === 'escape') {
        // More cars join while the chase is on.
        spawnT += dt;
        if (spawnT > 22 && live.length < 4 && near < 90) { spawnCop(100, 150); spawnT = 0; setWanted(Math.min(5, wanted + 1)); }
        if (live.length < 2 && near < 120 && spawnT > 6) { spawnCop(90, 140); spawnT = 0; }
        // Busted: boxed in and nearly stopped.
        if (near < 7 && Math.abs(speed) < 2) { bustT += dt; if (bustT > 2.2) return fail('BUSTED', 'The politie boxed you in. The bag goes in an evidence locker.'); }
        else bustT = Math.max(0, bustT - dt * 2);
        // Lost them: everyone far away for a while.
        if (near > 95) {
          lostT += dt;
          setWanted(Math.max(1, Math.ceil(3 - lostT / 2.5)));
          if (lostT > 7) {
            state = 'home'; clearCops(); setWanted(0);
            drive.say('LOST THEM', '', 1.6);
            objective('Get the bag to the <b>lock-up</b>.');
          }
        } else if (lostT > 0) { lostT = 0; setWanted(Math.max(wanted, 3)); }
      }
      const dHome = Math.hypot(p.x - lockup.x, p.z - lockup.z);
      if (dHome < 8) {
        if (state === 'home' && Math.abs(speed) < 4) return pass();
        if (state === 'escape') objective('Not with the <b class="cop">politie</b> on your tail. <b>Lose them first.</b>');
      } else if (state === 'escape' && near > 20) {
        objective('Lose the <b class="cop">politie</b>, then get to the <b>lock-up</b>.');
      }
    }
  });

  // Radar overlay: route, target blip, police.
  function radar(ctx, to, R) {
    if (state === 'off') return;
    if (route.length > 1) {
      ctx.strokeStyle = '#b26cf0'; ctx.lineWidth = 7; ctx.lineCap = 'round'; ctx.lineJoin = 'round';
      ctx.beginPath();
      const [sx, sz] = to(drive.st.x, drive.st.z); ctx.moveTo(sx, sz);
      for (const q of route) { const [a, b] = to(q[0], q[1]); ctx.lineTo(a, b); }
      ctx.stroke();
    }
    const target = state === 'escape' || state === 'home' ? lockup : (state === 'over' ? null : shop);
    const clamp = ([a, b]) => { const l = Math.hypot(a, b), m = R - 14; return l > m ? [a / l * m, b / l * m] : [a, b]; };
    if (target) {
      const [a, b] = clamp(to(target.x, target.z));
      ctx.fillStyle = '#f2c14e'; ctx.strokeStyle = '#000'; ctx.lineWidth = 3;
      ctx.beginPath(); ctx.arc(a, b, 11, 0, Math.PI * 2); ctx.fill(); ctx.stroke();
    }
    const flash = Math.floor(performance.now() / 250) % 2;
    for (const c of cops) if (c.alive) {
      const [a, b] = clamp(to(c.x, c.z));
      ctx.fillStyle = flash ? '#2f5cff' : '#ff3b30';
      ctx.beginPath(); ctx.arc(a, b, 8, 0, Math.PI * 2); ctx.fill();
    }
  }

  // ---- buttons ------------------------------------------------------------
  $('heist-start').addEventListener('click', () => {
    drive.quietStart = true;
    drive.start();
    drive.quietStart = false;
    drive.drawOnRadar = radar;
    ui.card.hidden = false;
    ui.mhud.hidden = true;
    $('card-go').focus();
  });
  $('card-go').addEventListener('click', begin);
  $('card-free').addEventListener('click', () => { ui.card.hidden = true; end(); drive.say('FREE ROAM'); });
  $('result-retry').addEventListener('click', () => { ui.result.hidden = true; drive.drawOnRadar = radar; begin(); });
  $('result-free').addEventListener('click', () => { end(); drive.placeAtSpawn(); drive.say('FREE ROAM'); });
  const gb = ui.grabBtn;
  gb.addEventListener('pointerdown', e => { e.preventDefault(); grabQueued = true; });
  return { state: () => state, begin, debug: () => ({ shop, lockup, cops, route, health, wanted, rob }) };
})();
window.__heist = heist;
