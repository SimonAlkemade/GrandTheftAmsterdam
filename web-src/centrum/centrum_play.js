// ---- on foot: a third-person character -------------------------------------------
// A jointed figure (hips, spine, head; shoulders, elbows; hips, knees, feet)
// animated procedurally: idle, walk, run, jump, swim, climb. Buildings are
// solid walls taken from the footprints; canals can be fallen into, swum in
// and climbed out of at the quay; bridges carry you over.
const play = (() => {
  const geo = {
    torso: new THREE.CapsuleGeometry(0.17, 0.32, 4, 10).scale(1.25, 1, 0.75),
    pelvis: new THREE.BoxGeometry(0.34, 0.16, 0.2),
    head: new THREE.SphereGeometry(0.115, 16, 12).scale(0.92, 1.08, 1),
    hair: new THREE.SphereGeometry(0.122, 14, 10, 0, Math.PI * 2, 0, Math.PI * 0.52).scale(0.95, 1.05, 1.03),
    neck: new THREE.CylinderGeometry(0.045, 0.05, 0.1, 8),
    upperArm: new THREE.CapsuleGeometry(0.048, 0.22, 3, 8).translate(0, -0.15, 0),
    foreArm: new THREE.CapsuleGeometry(0.042, 0.2, 3, 8).translate(0, -0.13, 0),
    hand: new THREE.SphereGeometry(0.045, 8, 6).scale(0.8, 1.1, 0.6).translate(0, -0.28, 0),
    thigh: new THREE.CapsuleGeometry(0.07, 0.3, 3, 8).translate(0, -0.21, 0),
    shin: new THREE.CapsuleGeometry(0.055, 0.32, 3, 8).translate(0, -0.21, 0),
    foot: new THREE.BoxGeometry(0.1, 0.07, 0.24).translate(0, -0.43, -0.05),
  };
  const mat = c => new THREE.MeshStandardMaterial({ color: c, roughness: 0.75 });
  const PAL = {
    skin: [0xf1c7a5, 0xd9a07a, 0xa56a43, 0x6b4128, 0xe8b590].map(mat),
    top: [0x2f4f7f, 0xc0392b, 0xe6e2d8, 0x27ae60, 0x1c1c1c, 0xf39c12, 0x8e44ad, 0x16a085, 0x7f8c8d, 0xd35400].map(mat),
    legs: [0x1f2a44, 0x2b2b2b, 0x4a4a4a, 0x6d5843, 0x1d3557].map(mat),
    hair: [0x2b1d14, 0x5a3a1e, 0xd9b26f, 0x111111, 0x8a8a8a].map(mat),
    shoe: [mat(0x141414), mat(0xf2f2f2), mat(0x6b3a22)],
  };
  const pick = (a, r = Math.random) => a[(r() * a.length) | 0];
  function makeHuman(o = {}) {
    const root = new THREE.Group();
    const add = (parent, g, m, x = 0, y = 0, z = 0) => { const k = new THREE.Mesh(g, m); k.position.set(x, y, z); k.castShadow = true; parent.add(k); return k; };
    const joint = (parent, x, y, z) => { const j = new THREE.Group(); j.position.set(x, y, z); parent.add(j); return j; };
    const skin = o.skin || pick(PAL.skin), top = o.top || pick(PAL.top), legs = o.legs || pick(PAL.legs);
    const shoe = o.shoe || pick(PAL.shoe), hairM = o.hair || pick(PAL.hair);
    const hips = joint(root, 0, 0.93, 0);
    add(hips, geo.pelvis, legs, 0, 0.02, 0);
    const spine = joint(hips, 0, 0.08, 0);
    add(spine, geo.torso, top, 0, 0.26, 0);
    if (o.jacket) { const j = add(spine, geo.torso, o.jacket, 0, 0.27, 0.005); j.scale.set(1.08, 0.95, 1.12); }
    add(spine, geo.neck, skin, 0, 0.55, 0);
    const head = joint(spine, 0, 0.66, 0);
    add(head, geo.head, skin);
    add(head, geo.hair, hairM, 0, 0.02, 0.006);
    const limb = (parent, x, y, g1, m1, g2, m2, g3, m3, kneeY) => {
      const a = joint(parent, x, y, 0); add(a, g1, m1);
      const b = joint(a, 0, kneeY, 0); add(b, g2, m2); add(b, g3, m3);
      return [a, b];
    };
    const sleeve = o.jacket || top;
    const [shL, elL] = limb(spine, -0.235, 0.47, geo.upperArm, sleeve, geo.foreArm, sleeve, geo.hand, skin, -0.3);
    const [shR, elR] = limb(spine, 0.235, 0.47, geo.upperArm, sleeve, geo.foreArm, sleeve, geo.hand, skin, -0.3);
    const [hpL, knL] = limb(hips, -0.095, -0.02, geo.thigh, legs, geo.shin, legs, geo.foot, shoe, -0.44);
    const [hpR, knR] = limb(hips, 0.095, -0.02, geo.thigh, legs, geo.shin, legs, geo.foot, shoe, -0.44);
    shL.rotation.z = 0.08; shR.rotation.z = -0.08;
    return { root, hips, spine, head, shL, shR, elL, elR, hpL, hpR, knL, knR, phase: Math.random() * 6, t: Math.random() * 10 };
  }
  // Pose the rig for a state. speed is metres per second along the ground.
  function animate(f, dt, s, speed) {
    f.t += dt;
    const lerp = (obj, key, v, k = 12) => { obj[key] += (v - obj[key]) * Math.min(1, dt * k); };
    let hip = 0.93, lean = 0, armSwing = 0, legSwing = 0, kneeAmp = 0, elbow = 0.25, spineYaw = 0;
    // Conventions: +x on a hip or shoulder swings the limb forward; +x on an
    // elbow bends the forearm forward; -x on a knee bends the shin back.
    if (s === 'walk' || s === 'run') {
      const run = s === 'run';
      f.phase += dt * (run ? 2.1 : 1.75) * Math.max(1.2, speed) * (run ? 0.95 : 1.15);
      const p = f.phase, sp = Math.sin(p);
      legSwing = sp * (run ? 0.85 : 0.5);
      armSwing = sp * (run ? 0.9 : 0.4);
      kneeAmp = run ? 1.4 : 0.75;
      elbow = run ? 1.35 : 0.35;
      lean = run ? 0.22 : 0.05;
      hip = 0.93 - (run ? 0.06 : 0.02) + Math.abs(Math.cos(p)) * (run ? 0.07 : 0.035);
      spineYaw = Math.sin(p) * (run ? 0.12 : 0.06);
      f.hpL.rotation.x = legSwing; f.hpR.rotation.x = -legSwing;
      // Knees bend as each leg swings forward through the air.
      f.knL.rotation.x = -Math.max(0, Math.sin(p + 0.9)) * kneeAmp - 0.05;
      f.knR.rotation.x = -Math.max(0, Math.sin(p + 0.9 + Math.PI)) * kneeAmp - 0.05;
      f.shL.rotation.x = -armSwing; f.shR.rotation.x = armSwing;
      f.elL.rotation.x = elbow; f.elR.rotation.x = elbow;
      f.spine.rotation.y = spineYaw;
      lerp(f.spine.rotation, 'x', lean);
      f.hips.position.y = hip;
      f.root.rotation.x = 0;
      return;
    }
    if (s === 'jump' || s === 'fall') {
      lerp(f.hpL.rotation, 'x', 0.7); lerp(f.hpR.rotation, 'x', -0.2);
      lerp(f.knL.rotation, 'x', -1.1); lerp(f.knR.rotation, 'x', -0.4);
      lerp(f.shL.rotation, 'x', 1.1, 8); lerp(f.shR.rotation, 'x', 0.9, 8);
      lerp(f.elL.rotation, 'x', 0.5); lerp(f.elR.rotation, 'x', 0.5);
      lerp(f.spine.rotation, 'x', 0.1); f.hips.position.y = 0.93;
      return;
    }
    if (s === 'swim') {
      // Front crawl: the body lies flat, arms windmill, legs flutter.
      f.phase += dt * 2.6;
      const p = f.phase;
      lerp(f.root.rotation, 'x', speed > 0.3 ? 1.25 : 0.25, 4);
      f.shL.rotation.x = p % (Math.PI * 2); f.shR.rotation.x = (p + Math.PI) % (Math.PI * 2);
      f.elL.rotation.x = 0.3; f.elR.rotation.x = 0.3;
      f.hpL.rotation.x = Math.sin(p * 3) * 0.3; f.hpR.rotation.x = -Math.sin(p * 3) * 0.3;
      f.knL.rotation.x = -0.2; f.knR.rotation.x = -0.2;
      f.spine.rotation.x = 0; f.hips.position.y = 0.93;
      return;
    }
    if (s === 'climb') {
      lerp(f.shL.rotation, 'x', 2.8, 10); lerp(f.shR.rotation, 'x', 2.8, 10);
      lerp(f.hpL.rotation, 'x', 1.2, 10); lerp(f.knL.rotation, 'x', -1.6, 10);
      lerp(f.root.rotation, 'x', 0, 8);
      return;
    }
    if (s === 'stagger') {
      lerp(f.spine.rotation, 'x', -0.45, 10); lerp(f.shL.rotation, 'x', 1.2, 10); lerp(f.shR.rotation, 'x', 1.4, 10);
      return;
    }
    // Idle: breathe, sway a little, arms hang.
    const br = Math.sin(f.t * 1.8);
    lerp(f.root.rotation, 'x', 0, 6);
    lerp(f.hpL.rotation, 'x', 0); lerp(f.hpR.rotation, 'x', 0); lerp(f.knL.rotation, 'x', -0.04); lerp(f.knR.rotation, 'x', -0.04);
    lerp(f.shL.rotation, 'x', 0.03 * br); lerp(f.shR.rotation, 'x', -0.03 * br);
    lerp(f.elL.rotation, 'x', 0.15); lerp(f.elR.rotation, 'x', 0.15);
    lerp(f.spine.rotation, 'x', 0.02 * br); f.spine.rotation.y *= 0.9;
    f.hips.position.y = 0.93 + 0.004 * br;
  }

  // ---- collision: building walls as 2D segments in a grid ---------------------------
  const CELL = 10;
  let segGrid = null;
  function buildSegments() {
    segGrid = new Map();
    const put = (ax, az, bx, bz) => {
      const c0 = Math.floor(Math.min(ax, bx) / CELL), c1 = Math.floor(Math.max(ax, bx) / CELL);
      const r0 = Math.floor(Math.min(az, bz) / CELL), r1 = Math.floor(Math.max(az, bz) / CELL);
      for (let c = c0; c <= c1; c++) for (let r = r0; r <= r1; r++) {
        const k = c * 100000 + r;
        if (!segGrid.has(k)) segGrid.set(k, []);
        segGrid.get(k).push(ax, az, bx, bz);
      }
    };
    city.buildings.forEach(bd => {
      const rings = bd.g ? [pairs(bd.g)] : bd.r.map(pairs);
      for (const ring of rings) for (let k = 0; k < ring.length; k++) {
        const a = ring[k], b = ring[(k + 1) % ring.length];
        put(a[0], a[1], b[0], b[1]);
      }
    });
  }
  function collide(p, r) {
    for (let it = 0; it < 3; it++) {
      const c = Math.floor(p.x / CELL), rr = Math.floor(p.z / CELL);
      let moved = false;
      for (let dc = -1; dc <= 1; dc++) for (let dr = -1; dr <= 1; dr++) {
        const list = segGrid.get((c + dc) * 100000 + rr + dr);
        if (!list) continue;
        for (let i = 0; i < list.length; i += 4) {
          const ax = list[i], az = list[i + 1], bx = list[i + 2], bz = list[i + 3];
          const dx = bx - ax, dz = bz - az, l2 = dx * dx + dz * dz || 1;
          const t = Math.max(0, Math.min(1, ((p.x - ax) * dx + (p.z - az) * dz) / l2));
          const qx = ax + dx * t, qz = az + dz * t;
          const ox = p.x - qx, oz = p.z - qz, d = Math.hypot(ox, oz);
          if (d < r && d > 1e-6) { p.x = qx + ox / d * r; p.z = qz + oz / d * r; moved = true; }
        }
      }
      if (!moved) break;
    }
  }
  const blocked = (x, z) => buildingAt(x, z) >= 0;
  const freeSpot = (x, z) => !blocked(x, z) && !(waterAt(x, z) & 1);

  // ---- state -----------------------------------------------------------------------------
  const hero = makeHuman({ top: mat(0xf2efe8), jacket: mat(0x3d5a80), legs: mat(0x1d1f24), shoe: mat(0xf5f5f5), hair: mat(0x2b1d14), skin: mat(0xd9a07a) });
  hero.root.visible = false;
  scene.add(hero.root);
  const P = { x: 0, z: 0, y: 0, vy: 0, heading: 0, speed: 0, state: 'idle', climbT: 0, grounded: true };
  const cam = { yaw: 0, pitch: 0.32, dist: 5.5 };
  const keys = {};
  const stick = { x: 0, y: 0 };
  let running = false, jumpQueued = false, active = false;
  const SWIM_Y = -1.2, BRIDGE_Y = 0.3;
  const groundAt = (x, z) => { const w = waterAt(x, z); return w & 2 ? BRIDGE_Y : w & 1 ? null : 0; };

  // ---- pedestrians -----------------------------------------------------------------------
  const peds = [];
  const pedGroup = new THREE.Group(); scene.add(pedGroup); pedGroup.visible = false;
  function placePed(a, near) {
    for (let k = 0; k < 40; k++) {
      const ang = Math.random() * Math.PI * 2, d = near ? 6 + Math.random() * 50 : 45 + Math.random() * 30;
      const x = P.x + Math.cos(ang) * d, z = P.z + Math.sin(ang) * d;
      if (freeSpot(x, z) && freeSpot(x + 0.6, z) && freeSpot(x, z + 0.6)) {
        Object.assign(a, { x, z, heading: Math.random() * Math.PI * 2, turnT: 2 + Math.random() * 4, stag: 0 });
        return;
      }
    }
  }
  function initPeds() {
    if (peds.length) return;
    for (let i = 0; i < 28; i++) {
      const f = makeHuman();
      pedGroup.add(f.root);
      peds.push({ f, x: 0, z: 0, heading: 0, base: 1.05 + Math.random() * 0.45, turnT: 0, stag: 0 });
    }
  }
  function stepPed(a, dt) {
    if (Math.hypot(a.x - P.x, a.z - P.z) > 85) placePed(a, false);
    if (a.stag > 0) {
      a.stag -= dt;
      animate(a.f, dt, 'stagger', 0);
    } else {
      a.turnT -= dt;
      if (a.turnT <= 0) { a.heading += (Math.random() - 0.5) * 1.2; a.turnT = 2 + Math.random() * 5; }
      // Step aside for the player.
      const dx = a.x - P.x, dz = a.z - P.z, d = Math.hypot(dx, dz);
      if (d < 2.2) { const away = Math.atan2(-dx, -dz) + Math.PI; a.heading += Math.atan2(Math.sin(away - a.heading), Math.cos(away - a.heading)) * dt * 3; }
      const fx = -Math.sin(a.heading), fz = -Math.cos(a.heading);
      if (!freeSpot(a.x + fx * 1.2, a.z + fz * 1.2)) {
        for (const t of [0.6, -0.6, 1.3, -1.3, 2.2, -2.2, Math.PI]) {
          const h = a.heading + t;
          if (freeSpot(a.x - Math.sin(h) * 1.2, a.z - Math.cos(h) * 1.2)) { a.heading = h; break; }
        }
      } else { a.x += fx * a.base * dt; a.z += fz * a.base * dt; }
      animate(a.f, dt, 'walk', a.base);
    }
    // Bumped by the player.
    const dx = a.x - P.x, dz = a.z - P.z, d = Math.hypot(dx, dz);
    if (d < 0.65 && d > 0.01) {
      const push = (0.65 - d) / d;
      a.x += dx * push * 0.7; a.z += dz * push * 0.7; P.x -= dx * push * 0.3; P.z -= dz * push * 0.3;
      if (P.speed > 3.5 && a.stag <= 0) a.stag = 0.9;
    }
    a.f.root.position.set(a.x, groundAt(a.x, a.z) ?? 0, a.z);
    a.f.root.rotation.y = a.heading;
  }

  // ---- input -------------------------------------------------------------------------------
  addEventListener('keydown', e => {
    if (!active || e.target.tagName === 'INPUT') return;
    keys[e.code] = true;
    if (e.code === 'Space') { jumpQueued = true; e.preventDefault(); }
    if (e.code === 'Escape' && document.pointerLockElement !== canvas) stop();
    if (e.code.startsWith('Arrow')) e.preventDefault();
  });
  addEventListener('keyup', e => { keys[e.code] = false; });
  addEventListener('blur', () => { for (const k in keys) keys[k] = false; });
  let dragging = null;
  canvas.addEventListener('pointerdown', e => {
    if (!active) return;
    if (e.pointerType === 'mouse' && !document.pointerLockElement) { try { canvas.requestPointerLock(); } catch (_) {} }
    dragging = { id: e.pointerId, x: e.clientX, y: e.clientY };
  });
  addEventListener('pointermove', e => {
    if (!active) return;
    if (document.pointerLockElement === canvas) { look(e.movementX, e.movementY); return; }
    if (dragging && e.pointerId === dragging.id) { look(e.clientX - dragging.x, e.clientY - dragging.y); dragging.x = e.clientX; dragging.y = e.clientY; }
  });
  addEventListener('pointerup', e => { if (dragging && e.pointerId === dragging.id) dragging = null; });
  canvas.addEventListener('wheel', e => { if (!active) return; cam.dist = THREE.MathUtils.clamp(cam.dist * (e.deltaY > 0 ? 1.12 : 0.89), 2.2, 14); e.preventDefault(); }, { passive: false });
  function look(dx, dy) {
    cam.yaw -= dx * 0.0042;
    cam.pitch = THREE.MathUtils.clamp(cam.pitch + dy * 0.0035, -0.25, 1.25);
  }
  // Touch joystick.
  const stickEl = document.getElementById('stick'), knob = document.getElementById('knob');
  let stickId = null, stickC = null;
  stickEl.addEventListener('pointerdown', e => {
    stickId = e.pointerId; const r = stickEl.getBoundingClientRect(); stickC = [r.left + r.width / 2, r.top + r.height / 2];
    try { stickEl.setPointerCapture(e.pointerId); } catch (_) {}
    moveStick(e); e.stopPropagation();
  });
  stickEl.addEventListener('pointermove', e => { if (e.pointerId === stickId) moveStick(e); });
  const endStick = () => { stickId = null; stick.x = stick.y = 0; knob.style.transform = 'translate(-50%, -50%)'; };
  stickEl.addEventListener('pointerup', endStick); stickEl.addEventListener('pointercancel', endStick);
  function moveStick(e) {
    let dx = e.clientX - stickC[0], dy = e.clientY - stickC[1];
    const l = Math.hypot(dx, dy), m = 46;
    if (l > m) { dx *= m / l; dy *= m / l; }
    stick.x = dx / m; stick.y = dy / m;
    knob.style.transform = `translate(calc(-50% + ${dx}px), calc(-50% + ${dy}px))`;
  }
  document.getElementById('btn-jump').addEventListener('pointerdown', e => { jumpQueued = true; e.stopPropagation(); });
  const runBtn = document.getElementById('btn-run');
  runBtn.addEventListener('pointerdown', e => { running = !running; runBtn.setAttribute('aria-pressed', String(running)); e.stopPropagation(); });

  // ---- radar and area name -------------------------------------------------------------
  const radar = document.getElementById('walk-radar'), rctx = radar.getContext('2d');
  let radarBase = null, namePoints = [];
  function buildRadar() {
    const { W, H, building, water } = mask;
    radarBase = document.createElement('canvas'); radarBase.width = W; radarBase.height = H;
    const g = radarBase.getContext('2d'), img = g.createImageData(W, H);
    for (let i = 0; i < W * H; i++) {
      const c = water[i] & 2 ? [120, 116, 108] : water[i] & 1 ? [86, 140, 176] : building[i] >= 0 ? [214, 214, 208] : [62, 68, 66];
      img.data[4 * i] = c[0]; img.data[4 * i + 1] = c[1]; img.data[4 * i + 2] = c[2]; img.data[4 * i + 3] = 255;
    }
    g.putImageData(img, 0, 0);
    // Named streets and canals, for the area name in the corner.
    // Points every 8 m along each named street: corners alone can be far apart.
    for (const [, , coords, name] of city.roads) {
      if (!name) continue;
      const pts = pairs(coords);
      for (let k = 0; k < pts.length - 1; k++) {
        const [ax, az] = pts[k], [bx, bz] = pts[k + 1], len = Math.hypot(bx - ax, bz - az);
        for (let d = 0; d <= len; d += 8) namePoints.push([ax + (bx - ax) * d / (len || 1), az + (bz - az) * d / (len || 1), name]);
      }
    }
    for (const [name, x, z] of city.waterLabels) namePoints.push([X(x), Z(z), name]);
  }
  function drawRadar() {
    const S = radar.width, R = S / 2, scale = 2.2;   // px per metre
    rctx.save(); rctx.clearRect(0, 0, S, S);
    rctx.beginPath(); rctx.arc(R, R, R, 0, Math.PI * 2); rctx.clip();
    rctx.fillStyle = '#2b302f'; rctx.fillRect(0, 0, S, S);
    rctx.translate(R, R);
    rctx.rotate(cam.yaw);                        // map turns with the camera, as in GTA
    const px = (P.x - mask.ext.x0) / MASK_RES, pz = (P.z - mask.ext.z0) / MASK_RES;
    rctx.drawImage(radarBase, -px * MASK_RES * scale, -pz * MASK_RES * scale, mask.W * MASK_RES * scale, mask.H * MASK_RES * scale);
    rctx.fillStyle = '#f2c14e';
    for (const a of peds) { rctx.globalAlpha = 0.7; rctx.fillRect((a.x - P.x) * scale - 2, (a.z - P.z) * scale - 2, 4, 4); }
    rctx.globalAlpha = 1;
    rctx.restore();
    const nAng = cam.yaw - Math.PI / 2;
    rctx.fillStyle = '#fff'; rctx.font = 'bold 20px system-ui, sans-serif'; rctx.textAlign = 'center'; rctx.textBaseline = 'middle';
    rctx.fillText('N', R + Math.cos(nAng) * (R - 15), R + Math.sin(nAng) * (R - 15));
    // The player: an arrow that turns with the character relative to the camera.
    rctx.save(); rctx.translate(R, R); rctx.rotate(cam.yaw - P.heading);
    rctx.fillStyle = '#ffffff'; rctx.strokeStyle = '#000'; rctx.lineWidth = 3;
    rctx.beginPath(); rctx.moveTo(0, -13); rctx.lineTo(9, 10); rctx.lineTo(0, 5); rctx.lineTo(-9, 10); rctx.closePath(); rctx.stroke(); rctx.fill();
    rctx.restore();
  }
  const areaEl = document.getElementById('area');
  let areaT = 0, lastArea = '';
  function updateArea(dt) {
    areaT -= dt; if (areaT > 0) return; areaT = 0.6;
    let best = null, bd = 30 * 30;
    for (const [x, z, n] of namePoints) { const d = (x - P.x) ** 2 + (z - P.z) ** 2; if (d < bd) { bd = d; best = n; } }
    const name = best || 'Amsterdam Centrum';
    if (name !== lastArea) { lastArea = name; areaEl.textContent = name; areaEl.classList.remove('show'); void areaEl.offsetWidth; areaEl.classList.add('show'); }
  }

  // ---- splash ---------------------------------------------------------------------------
  let audio = null;
  function splash() {
    try {
      audio ||= new AudioContext();
      const len = audio.sampleRate * 0.7, buf = audio.createBuffer(1, len, audio.sampleRate), d = buf.getChannelData(0);
      for (let i = 0; i < len; i++) d[i] = (Math.random() * 2 - 1) * (1 - i / len) ** 2;
      const s = audio.createBufferSource(), f = audio.createBiquadFilter(), g = audio.createGain();
      f.type = 'lowpass'; f.frequency.value = 1100; g.gain.value = 0.3;
      s.buffer = buf; s.connect(f); f.connect(g); g.connect(audio.destination); s.start();
    } catch (_) {}
  }

  // ---- update ---------------------------------------------------------------------------
  const camPos = new THREE.Vector3(), head = new THREE.Vector3();
  function update(dt) {
    // Input relative to the camera.
    let ix = (keys.KeyD || keys.ArrowRight ? 1 : 0) - (keys.KeyA || keys.ArrowLeft ? 1 : 0) + stick.x;
    let iz = (keys.KeyS || keys.ArrowDown ? 1 : 0) - (keys.KeyW || keys.ArrowUp ? 1 : 0) + stick.y;
    const il = Math.hypot(ix, iz);
    if (il > 1) { ix /= il; iz /= il; }
    const wantRun = running || keys.ShiftLeft || keys.ShiftRight || Math.hypot(stick.x, stick.y) > 0.95;
    const swimming = P.state === 'swim';
    const top = swimming ? 1.5 : wantRun ? 6.2 : 1.7;
    const cy = Math.cos(cam.yaw), sy = Math.sin(cam.yaw);
    const mx = ix * cy + iz * sy, mz = -ix * sy + iz * cy;   // camera-relative move
    const want = Math.min(1, Math.hypot(ix, iz)) * top;
    P.speed += (want - P.speed) * Math.min(1, dt * (want > P.speed ? 6 : 9));
    if (Math.hypot(mx, mz) > 0.05) {
      const target = Math.atan2(-mx, -mz);
      let d = target - P.heading; d = Math.atan2(Math.sin(d), Math.cos(d));
      P.heading += d * Math.min(1, dt * 10);
    }
    if (P.state === 'climb') {
      P.climbT += dt;
      P.y = SWIM_Y + (0 - SWIM_Y) * Math.min(1, P.climbT / 0.6);
      if (P.climbT > 0.6) { P.x += -Math.sin(P.heading) * 0.8; P.z += -Math.cos(P.heading) * 0.8; P.y = groundAt(P.x, P.z) ?? 0; P.state = 'idle'; P.grounded = true; }
    } else {
      const fx = -Math.sin(P.heading), fz = -Math.cos(P.heading);
      P.x += fx * P.speed * dt; P.z += fz * P.speed * dt;
      collide(P, 0.32);
      const g = groundAt(P.x, P.z);
      if (swimming) {
        P.y = SWIM_Y;
        // Reach the quay: climb out.
        const ax = P.x + fx * 0.9, az = P.z + fz * 0.9;
        if (P.speed > 0.4 && groundAt(ax, az) !== null && !blocked(ax, az)) { P.state = 'climb'; P.climbT = 0; }
      } else {
        if (jumpQueued && P.grounded) { P.vy = 5.2; P.grounded = false; }
        P.vy -= 15 * dt;
        P.y += P.vy * dt;
        const floor = g === null ? SWIM_Y : g;
        if (P.y <= floor) {
          if (g === null) { P.state = 'swim'; P.y = SWIM_Y; P.vy = 0; splash(); P.speed *= 0.4; }
          else { P.y = floor; P.vy = 0; P.grounded = true; }
        } else if (P.y > floor + 0.05) P.grounded = false;
        if (g !== null && P.grounded && P.y < g) P.y = g;
      }
      if (P.state !== 'swim') P.state = !P.grounded ? (P.vy > 0 ? 'jump' : 'fall') : P.speed > 3.2 ? 'run' : P.speed > 0.25 ? 'walk' : 'idle';
    }
    jumpQueued = false;
    // Swimming flat lifts the body to the surface; treading water keeps the head up.
    hero.root.position.set(P.x, P.y + (P.state === 'swim' ? hero.root.rotation.x / 1.25 * 0.9 : 0), P.z);
    hero.root.rotation.y = P.heading;
    animate(hero, dt, P.state, P.speed);

    for (const a of peds) stepPed(a, dt);

    // Camera: orbit behind the character, pulled in when a building is in the way.
    head.set(P.x, Math.max(P.y, SWIM_Y + 0.8) + 1.55, P.z);
    const cp = Math.cos(cam.pitch), sp = Math.sin(cam.pitch);
    let d = cam.dist;
    for (let s = 0.6; s < cam.dist; s += 0.4) {
      const x = head.x + Math.sin(cam.yaw) * cp * s, y = head.y + sp * s, z = head.z + Math.cos(cam.yaw) * cp * s;
      const id = buildingAt(x, z);
      if (id >= 0 && y < buildingInfo[id].h + 0.5) { d = Math.max(0.8, s - 0.4); break; }
    }
    const want3 = new THREE.Vector3(head.x + Math.sin(cam.yaw) * cp * d, head.y + sp * d, head.z + Math.cos(cam.yaw) * cp * d);
    if (want3.y < 0.3) want3.y = 0.3;
    camPos.lerp(want3, 1 - Math.exp(-dt * 14));
    camera.position.copy(camPos);
    camera.lookAt(head.x, head.y - 0.2, head.z);
    controls.target.set(P.x, 0, P.z);              // labels and shadows follow the player
    drawRadar();
    updateArea(dt);
  }

  // ---- enter / leave ---------------------------------------------------------------------
  const ui = document.getElementById('walk-hud');
  function start() {
    if (!segGrid) { buildSegments(); buildRadar(); }
    // Drop in at the nearest open street to the middle of the view.
    let { x, z } = controls.target;
    outer: for (let r = 0; r < 120; r += 2) for (let a = 0; a < Math.PI * 2; a += 0.4) {
      const tx = x + Math.cos(a) * r, tz = z + Math.sin(a) * r;
      if (freeSpot(tx, tz) && freeSpot(tx + 1, tz) && freeSpot(tx - 1, tz) && freeSpot(tx, tz + 1) && freeSpot(tx, tz - 1)) { x = tx; z = tz; break outer; }
    }
    Object.assign(P, { x, z, y: 0, vy: 0, speed: 0, state: 'idle', grounded: true, heading: azimuth() });
    cam.yaw = azimuth(); cam.pitch = 0.3; cam.dist = 5.5;
    camPos.set(x + Math.sin(cam.yaw) * 5, 3, z + Math.cos(cam.yaw) * 5);
    hero.root.visible = true;
    initPeds(); for (const a of peds) placePed(a, true);
    pedGroup.visible = true;
    controls.enabled = false;
    active = true;
    document.body.classList.add('walking');
    ui.hidden = false;
    showInfo(null);
    camera.near = 0.15; camera.updateProjectionMatrix();
    lastArea = ''; areaT = 0;
  }
  function stop() {
    active = false;
    if (document.pointerLockElement) document.exitPointerLock();
    hero.root.visible = false; pedGroup.visible = false;
    controls.enabled = true;
    document.body.classList.remove('walking');
    ui.hidden = true;
    camera.near = 1; camera.updateProjectionMatrix();
    setView(P.x, P.z, 260, 55, THREE.MathUtils.radToDeg(cam.yaw), false);
  }
  document.getElementById('walk').addEventListener('click', start);
  document.getElementById('walk-exit').addEventListener('click', stop);
  return { start, stop, update, get active() { return active; }, P, cam, keys };
})();

