// ---- street life: pedestrians and cyclists ---------------------------------
// Simple jointed figures with procedural walk and pedal cycles. They wander
// the streets around the car, dive aside when it comes at them, fall over
// (and get back up) when it doesn't miss, and run when the alarm goes off.
const life = (() => {
  const N_WALK = 26, N_BIKE = 10;
  const geo = {
    torso: new THREE.BoxGeometry(0.42, 0.6, 0.24),
    head: new THREE.SphereGeometry(0.13, 12, 10),
    hair: new THREE.SphereGeometry(0.138, 12, 8, 0, Math.PI * 2, 0, Math.PI * 0.55),
    leg: new THREE.BoxGeometry(0.16, 0.9, 0.18).translate(0, -0.45, 0),
    shoe: new THREE.BoxGeometry(0.17, 0.08, 0.28).translate(0, -0.9, -0.04),
    arm: new THREE.BoxGeometry(0.12, 0.6, 0.14).translate(0, -0.3, 0),
    hand: new THREE.SphereGeometry(0.06, 8, 6).translate(0, -0.62, 0),
    wheel: new THREE.TorusGeometry(0.33, 0.035, 6, 24).rotateY(Math.PI / 2),
    tube: new THREE.CylinderGeometry(0.025, 0.025, 1, 6),
    bag: new THREE.BoxGeometry(0.5, 0.26, 0.26),
  };
  const mat = c => new THREE.MeshStandardMaterial({ color: c, roughness: 0.8 });
  const palettes = {
    skin: [0xf1c7a5, 0xd9a07a, 0xa56a43, 0x6b4128, 0xe8b590].map(mat),
    shirt: [0x2f4f7f, 0xc0392b, 0xe6e2d8, 0x27ae60, 0x1c1c1c, 0xf39c12, 0x8e44ad, 0x16a085, 0x7f8c8d, 0xd35400].map(mat),
    legs: [0x1f2a44, 0x2b2b2b, 0x4a4a4a, 0x6d5843, 0x1d3557].map(mat),
    hair: [0x2b1d14, 0x5a3a1e, 0xd9b26f, 0x111111, 0x8a8a8a].map(mat),
    shoe: [mat(0x111111), mat(0xf2f2f2)],
    bike: [0x111111, 0x1d4e89, 0x9b2226, 0x2d6a4f, 0x6c757d].map(mat),
  };
  const pick = a => a[(Math.random() * a.length) | 0];

  function makeFigure(o = {}) {
    const root = new THREE.Group();
    const hips = new THREE.Group(); hips.position.y = 0.95; root.add(hips);
    const add = (parent, g, m, shadow = false) => { const x = new THREE.Mesh(g, m); x.castShadow = shadow; parent.add(x); return x; };
    const shirt = o.shirt || pick(palettes.shirt), legsM = o.legs || pick(palettes.legs), skin = o.skin || pick(palettes.skin);
    const torso = add(hips, geo.torso, shirt, true); torso.position.y = 0.32;
    const head = add(hips, geo.head, o.mask || skin); head.position.y = 0.78;
    if (!o.mask) { const h = add(hips, geo.hair, pick(palettes.hair)); h.position.y = 0.79; }
    const limb = (x, y, g, m, extra, em) => {
      const p = new THREE.Group(); p.position.set(x, y, 0); hips.add(p);
      add(p, g, m, true); if (extra) add(p, extra, em);
      return p;
    };
    const shoe = pick(palettes.shoe);
    const legL = limb(-0.11, 0.02, geo.leg, legsM, geo.shoe, shoe);
    const legR = limb(0.11, 0.02, geo.leg, legsM, geo.shoe, shoe);
    const armL = limb(-0.28, 0.58, geo.arm, shirt, geo.hand, skin);
    const armR = limb(0.28, 0.58, geo.arm, shirt, geo.hand, skin);
    return { root, hips, legL, legR, armL, armR, phase: Math.random() * 6 };
  }
  function walkCycle(f, dt, speed, raise = 0) {
    const k = Math.min(1.2, speed / 1.4);
    f.phase += dt * (2.2 + speed * 2.3);
    const s = Math.sin(f.phase);
    f.legL.rotation.x = s * 0.65 * k; f.legR.rotation.x = -s * 0.65 * k;
    f.armL.rotation.x = -s * 0.6 * k + raise; f.armR.rotation.x = s * 0.6 * k + raise;
    f.hips.position.y = 0.95 + Math.abs(Math.cos(f.phase)) * 0.05 * k;
    f.hips.rotation.x = 0.06 * k;
  }

  function makeBike() {
    const fig = makeFigure();
    const bike = new THREE.Group();
    const frameM = pick(palettes.bike);
    const add = (g, m, x, y, z, rx = 0, rz = 0, sy = 1) => { const t = new THREE.Mesh(g, m); t.position.set(x, y, z); t.rotation.set(rx, 0, rz); t.scale.y = sy; bike.add(t); return t; };
    const wf = add(geo.wheel, palettes.bike[0], 0, 0.36, -0.55), wb = add(geo.wheel, palettes.bike[0], 0, 0.36, 0.55);
    add(geo.tube, frameM, 0, 0.62, 0, Math.PI / 2, 0, 1.0);
    add(geo.tube, frameM, 0, 0.5, 0.25, -0.9, 0, 0.7);
    add(geo.tube, frameM, 0, 0.62, -0.5, 0.25, 0, 0.6);
    add(geo.tube, frameM, 0, 0.9, -0.5, Math.PI / 2, Math.PI / 2, 0.55);     // handlebar
    fig.root.add(bike);
    // Sit upright on the saddle, hands on the bars: the classic Dutch omafiets pose.
    fig.hips.position.y = 1.0; fig.hips.position.z = 0.15;
    fig.armL.rotation.x = fig.armR.rotation.x = 1.0;
    return { ...fig, bike, wheels: [wf, wb] };
  }
  function pedalCycle(f, dt, speed) {
    f.phase += dt * speed * 2.2;
    const s = Math.sin(f.phase);
    f.legL.rotation.x = 1.15 + s * 0.45; f.legR.rotation.x = 1.15 - s * 0.45;
    f.hips.position.y = 1.0;
    for (const w of f.wheels) w.rotation.x -= dt * speed / 0.33;
  }

  // ---- agents ---------------------------------------------------------------
  const agents = [];
  const group = new THREE.Group(); group.visible = false; scene.add(group);
  let panic = null;                       // { x, z } of the alarm, while it rings
  let lastBell = 0;

  function clear(x, z, r = 0.7) {
    for (const [a, b] of [[0, 0], [r, 0], [-r, 0], [0, r], [0, -r]]) if (drive.cell(x + a, z + b) !== 0) return false;
    return true;
  }
  function place(a, near) {
    const p = drive.st;
    for (let tries = 0; tries < 40; tries++) {
      const ang = Math.random() * Math.PI * 2;
      const d = near ? 8 + Math.random() * 60 : 55 + Math.random() * 40;
      const x = p.x + Math.cos(ang) * d, z = p.z + Math.sin(ang) * d;
      if (clear(x, z, a.bike ? 1.2 : 0.7)) {
        Object.assign(a, { x, z, heading: Math.random() * Math.PI * 2, state: 'move', t: 0, turnT: 1 + Math.random() * 4 });
        a.f.root.rotation.set(0, a.heading, 0);
        return true;
      }
    }
    return false;
  }
  function init() {
    if (agents.length) return;
    for (let i = 0; i < N_WALK + N_BIKE; i++) {
      const bike = i >= N_WALK;
      const f = bike ? makeBike() : makeFigure();
      group.add(f.root);
      const a = { f, bike, x: 0, z: 0, heading: 0, state: 'move', t: 0, turnT: 0, base: bike ? 4.6 + Math.random() * 1.5 : 1.1 + Math.random() * 0.5 };
      place(a, true);
      agents.push(a);
    }
  }

  function step(a, dt) {
    const car = drive.st, cs = Math.hypot(car.vx, car.vz);
    const rx = a.x - car.x, rz = a.z - car.z, d = Math.hypot(rx, rz);
    if (d > 115) { place(a, false); return; }
    a.t += dt;
    if (a.state === 'down') {
      // Knocked flat: lie there a moment, then get up and carry on.
      const k = a.t < 0.35 ? a.t / 0.35 : a.t < 2.4 ? 1 : Math.max(0, 1 - (a.t - 2.4) / 0.5);
      a.f.root.rotation.set(-k * Math.PI / 2 * (a.bike ? 0.6 : 1), a.heading, 0);
      if (a.t < 0.35) { a.x += a.dx * dt * 5; a.z += a.dz * dt * 5; }
      if (a.t > 2.9) { a.state = 'move'; a.t = 0; a.f.root.rotation.set(0, a.heading, 0); }
      a.f.root.position.set(a.x, drive.map().streetY, a.z);
      return;
    }
    // Car coming straight at us? Hit, or dive aside.
    const along = (car.vx * rx + car.vz * rz) / (cs || 1), lateral = Math.abs(car.vx * rz - car.vz * rx) / (cs || 1);
    const approaching = cs > 4 && along > 0 && lateral < 2.6;
    if (d < 1.4 && cs > 3 && a.state !== 'dodge') {
      a.state = 'down'; a.t = 0; a.dx = rx / (d || 1); a.dz = rz / (d || 1);
      if (cs > 8) drive.say('WATCH IT!', '', 1);
      return;
    }
    if (a.state === 'move' && approaching && d < 9) {
      const side = Math.sign(car.vx * rz - car.vz * rx) || 1;      // which side of the car's path we're on
      const n = Math.hypot(car.vx, car.vz);
      a.dx = (-car.vz / n) * side; a.dz = (car.vx / n) * side;
      a.state = 'dodge'; a.t = 0;
    }
    let speed = a.base * (panic && !a.bike ? 2.6 : 1);
    if (a.state === 'dodge') {
      const T = a.bike ? 0.5 : 0.55;
      const k = Math.min(1, a.t / T);
      const nx = a.x + a.dx * dt * (a.bike ? 6 : 5.5), nz = a.z + a.dz * dt * (a.bike ? 6 : 5.5);
      if (drive.cell(nx, nz) === 0) { a.x = nx; a.z = nz; }
      a.f.root.position.set(a.x, drive.map().streetY + Math.sin(k * Math.PI) * 0.45, a.z);
      a.f.root.rotation.set(0, a.heading, Math.sin(k * Math.PI) * 0.5 * Math.sign(a.dx || 1));
      if (!a.bike) walkCycle(a.f, dt, 3, 2.6 * Math.sin(k * Math.PI));   // arms up as they jump
      if (a.t > T) { a.state = 'move'; a.t = 0; a.f.root.rotation.set(0, a.heading, 0); }
      return;
    }
    // Wander: walk straight, turn away from walls and water, drift a little.
    if (panic && !a.bike) {
      const away = Math.atan2(-(a.x - panic.x), -(a.z - panic.z)) + Math.PI;
      if (Math.hypot(a.x - panic.x, a.z - panic.z) < 70) a.heading += Math.atan2(Math.sin(away - a.heading), Math.cos(away - a.heading)) * Math.min(1, dt * 2);
    }
    a.turnT -= dt;
    if (a.turnT <= 0) { a.heading += (Math.random() - 0.5) * 0.8; a.turnT = 2 + Math.random() * 5; }
    const fx = -Math.sin(a.heading), fz = -Math.cos(a.heading);
    const look = a.bike ? 3.2 : 1.2;
    if (!clear(a.x + fx * look, a.z + fz * look, a.bike ? 0.6 : 0.35)) {
      for (const turn of [0.5, -0.5, 1.1, -1.1, 1.8, -1.8, Math.PI]) {
        const h = a.heading + turn * (Math.random() < 0.5 ? 1 : -1);
        if (clear(a.x - Math.sin(h) * look, a.z - Math.cos(h) * look, 0.5)) { a.heading = h; break; }
      }
      speed *= 0.3;
    }
    a.x += -Math.sin(a.heading) * speed * dt; a.z += -Math.cos(a.heading) * speed * dt;
    if (drive.cell(a.x, a.z) !== 0) { place(a, false); return; }
    a.f.root.position.set(a.x, drive.map().streetY, a.z);
    a.f.root.rotation.set(0, a.heading, a.bike ? Math.sin(a.f.phase * 0.5) * 0.03 : 0);
    if (a.bike) {
      pedalCycle(a.f, dt, speed);
      // A ring of the bell when the car gets close. Very Amsterdam.
      if (d < 7 && performance.now() - lastBell > 2500) { bell(); lastBell = performance.now(); }
    } else walkCycle(a.f, dt, speed, panic ? 0.5 : 0);
  }
  function bell() {
    const au = drive.audio();
    if (!au || !drive.soundOn()) return;
    const t = au.ctx.currentTime;
    for (const [dly, f] of [[0, 2093], [0.12, 2093]]) {
      const o = au.ctx.createOscillator(), g = au.ctx.createGain();
      o.type = 'sine'; o.frequency.value = f;
      g.gain.setValueAtTime(0.05, t + dly); g.gain.exponentialRampToValueAtTime(0.0005, t + dly + 0.35);
      o.connect(g); g.connect(au.ctx.destination); o.start(t + dly); o.stop(t + dly + 0.4);
    }
  }

  drive.on('start', () => { init(); for (const a of agents) place(a, true); group.visible = true; });
  drive.on('stop', () => { group.visible = false; panic = null; });
  drive.hooks.push(dt => { if (group.visible) for (const a of agents) step(a, dt); });
  return {
    makeFigure, walkCycle, geo,
    setPanic(p) { panic = p; },
  };
})();
