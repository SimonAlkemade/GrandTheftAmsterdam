// ---- drive mode -------------------------------------------------------------
// An arcade car on a 2D collision map. The map is rendered once from above
// after the city loads: buildings white, water blue, street black, at half a
// metre per pixel. Buildings stop the car; water under its centre drops it in
// the canal.
const drive = (() => {
  const RES = 0.5;                       // metres per collision cell
  const SPAWN = { x: 103.3, z: 84.2, toward: [101.4, 144.5] };
  const hud = document.getElementById('drive-hud');
  const radar = document.getElementById('radar');
  const rctx = radar.getContext('2d');
  const kmhEl = document.getElementById('kmh');
  const banner = document.getElementById('banner');
  let grid = null, gw = 0, gh = 0, gmin = null, gmax = null, mapImage = null;
  let streetY = 1.1, waterY = -0.3;

  // ---- the car -----------------------------------------------------------
  const car = new THREE.Group();
  const paint = new THREE.MeshStandardMaterial({ color: 0xb3261e, metalness: 0.55, roughness: 0.32 });
  const trim = new THREE.MeshStandardMaterial({ color: 0x1a1c1e, roughness: 0.6 });
  const glass = new THREE.MeshStandardMaterial({ color: 0x0d1418, metalness: 0.8, roughness: 0.08 });
  const chrome = new THREE.MeshStandardMaterial({ color: 0xd8dde0, metalness: 1, roughness: 0.25 });
  const lamp = new THREE.MeshStandardMaterial({ color: 0xfff6d8, emissive: 0xfff2c0, emissiveIntensity: 1.6 });
  const tail = new THREE.MeshStandardMaterial({ color: 0x8a0d0d, emissive: 0xff1a1a, emissiveIntensity: 0.6 });
  const part = (geo, mat, x, y, z) => { const m = new THREE.Mesh(geo, mat); m.position.set(x, y, z); m.castShadow = true; car.add(m); return m; };
  const body = new THREE.Group(); car.add(body);
  const bpart = (geo, mat, x, y, z) => { const m = part(geo, mat, x, y, z); car.remove(m); body.add(m); return m; };
  bpart(new THREE.BoxGeometry(1.78, 0.62, 4.15), paint, 0, 0.62, 0);
  bpart(new THREE.BoxGeometry(1.6, 0.56, 2.1), glass, 0, 1.2, 0.25);
  bpart(new THREE.BoxGeometry(1.5, 0.08, 1.9), paint, 0, 1.5, 0.28);
  bpart(new THREE.BoxGeometry(1.82, 0.22, 0.2), trim, 0, 0.42, -2.08);
  bpart(new THREE.BoxGeometry(1.82, 0.22, 0.2), trim, 0, 0.42, 2.08);
  bpart(new THREE.BoxGeometry(0.42, 0.14, 0.05), lamp, -0.6, 0.72, -2.08);
  bpart(new THREE.BoxGeometry(0.42, 0.14, 0.05), lamp, 0.6, 0.72, -2.08);
  bpart(new THREE.BoxGeometry(0.4, 0.14, 0.05), tail, -0.62, 0.74, 2.08);
  bpart(new THREE.BoxGeometry(0.4, 0.14, 0.05), tail, 0.62, 0.74, 2.08);
  bpart(new THREE.BoxGeometry(1.0, 0.1, 0.06), chrome, 0, 0.58, -2.1);
  const wheels = [];
  const wheelGeo = new THREE.CylinderGeometry(0.34, 0.34, 0.26, 18).rotateZ(Math.PI / 2);
  for (const [x, z, front] of [[-0.86, -1.32, 1], [0.86, -1.32, 1], [-0.86, 1.32, 0], [0.86, 1.32, 0]]) {
    const pivot = new THREE.Group(); pivot.position.set(x, 0.34, z); car.add(pivot);
    const w = new THREE.Mesh(wheelGeo, trim); w.castShadow = true; pivot.add(w);
    const hub = new THREE.Mesh(new THREE.CylinderGeometry(0.16, 0.16, 0.27, 10).rotateZ(Math.PI / 2), chrome); w.add(hub);
    wheels.push({ pivot, w, front });
  }
  car.visible = false;
  scene.add(car);

  // ---- state ---------------------------------------------------------------
  const st = {
    x: 0, z: 0, y: 0, heading: 0, vx: 0, vz: 0, vy: 0, steer: 0,
    falling: false, fallT: 0, safe: [], safeT: 0, camFar: false, roll: 0, pitch: 0, shake: 0,
  };
  const keys = { up: false, down: false, left: false, right: false, hand: false };
  const camPos = new THREE.Vector3(), camLook = new THREE.Vector3();

  // ---- collision map --------------------------------------------------------
  function buildMap() {
    const box = new THREE.Box3();
    for (const m of buildings) box.expandByObject(m);
    scene.traverse(o => { if (o.isMesh && o.material && o.material.name === 'water') box.expandByObject(o); });
    gmin = box.min.clone(); gmax = box.max.clone();
    gw = Math.min(2048, Math.ceil((gmax.x - gmin.x) / RES));
    gh = Math.min(2048, Math.ceil((gmax.z - gmin.z) / RES));
    const rt = new THREE.WebGLRenderTarget(gw, gh);
    const cam = new THREE.OrthographicCamera(gmin.x, gmin.x + gw * RES, -gmin.z, -(gmin.z + gh * RES), 1, 3000);
    cam.position.set(0, 1500, 0); cam.up.set(0, 0, -1); cam.lookAt(0, 0, 0);
    const white = new THREE.MeshBasicMaterial({ color: 0xffffff });
    const blue = new THREE.MeshBasicMaterial({ color: 0x0000ff });
    const black = new THREE.MeshBasicMaterial({ color: 0x000000 });
    const saved = [];
    const isBuilding = new Set(buildings);
    scene.traverse(o => {
      if (!o.isMesh || o === sky) return;
      saved.push([o, o.material]);
      o.material = isBuilding.has(o) ? white : (o.material.name === 'water' ? blue : black);
    });
    const vis = [sky.visible, car.visible, scene.fog, scene.background];
    sky.visible = false; car.visible = false; scene.fog = null; scene.background = new THREE.Color(0x000000);
    const tm = renderer.toneMapping; renderer.toneMapping = THREE.NoToneMapping;
    renderer.setRenderTarget(rt);
    renderer.render(scene, cam);
    const px = new Uint8Array(gw * gh * 4);
    renderer.readRenderTargetPixels(rt, 0, 0, gw, gh, px);
    renderer.setRenderTarget(null);
    renderer.toneMapping = tm;
    [sky.visible, car.visible, scene.fog, scene.background] = vis;
    for (const [o, m] of saved) o.material = m;
    rt.dispose();
    // Row 0 of the read-back is the bottom of the view: the south edge (max z).
    grid = new Uint8Array(gw * gh);
    const img = new ImageData(gw, gh);
    const colours = [[58, 64, 62], [86, 140, 176], [208, 210, 204]];
    for (let r = 0; r < gh; r++) {
      for (let c = 0; c < gw; c++) {
        const i = (r * gw + c) * 4;
        const v = px[i] > 128 && px[i + 1] > 128 ? 2 : (px[i + 2] > 128 ? 1 : 0);
        grid[r * gw + c] = v;
        const j = ((gh - 1 - r) * gw + c) * 4;     // image rows run north to south
        const col = colours[v];
        img.data[j] = col[0]; img.data[j + 1] = col[1]; img.data[j + 2] = col[2]; img.data[j + 3] = 255;
      }
    }
    mapImage = document.createElement('canvas');
    mapImage.width = gw; mapImage.height = gh;
    mapImage.getContext('2d').putImageData(img, 0, 0);
    // Street level: the ground's top surface; the water sits 1.4 m below it.
    const down = new THREE.Raycaster(new THREE.Vector3(SPAWN.x, 200, SPAWN.z), new THREE.Vector3(0, -1, 0));
    const ground = []; scene.traverse(o => { if (o.isMesh && o.material.name === 'ground_cobble') ground.push(o); });
    const hit = down.intersectObjects(ground, false)[0];
    if (hit) streetY = hit.point.y;
    waterY = streetY - 1.4;
  }

  function cell(x, z) {
    const c = Math.floor((x - gmin.x) / RES), r = Math.floor((gmin.z + gh * RES - z) / RES);
    if (c < 0 || r < 0 || c >= gw || r >= gh) return 3;    // edge of the model: a wall
    return grid[r * gw + c];
  }
  const fwd = h => [-Math.sin(h), -Math.cos(h)];
  function blockedAt(x, z, h) {
    const [fx, fz] = fwd(h), rx = -fz, rz = fx;
    for (const [a, b] of [[2.05, 0.88], [2.05, -0.88], [-2.05, 0.88], [-2.05, -0.88], [0, 0.9], [0, -0.9], [1, 0.9], [-1, 0.9], [1, -0.9], [-1, -0.9]]) {
      const v = cell(x + fx * a + rx * b, z + fz * a + rz * b);
      if (v >= 2) return true;
    }
    return false;
  }
  function streetCell(x, z) { return cell(x, z) === 0; }

  function placeAtSpawn() {
    let { x, z } = SPAWN;
    const h = Math.atan2(-(SPAWN.toward[0] - x), -(SPAWN.toward[1] - z));
    // Nearest clear patch of street, spiralling out from the preset.
    outer: for (let rad = 0; rad < 60; rad += 1) {
      for (let a = 0; a < Math.PI * 2; a += Math.PI / 12) {
        const tx = x + Math.cos(a) * rad, tz = z + Math.sin(a) * rad;
        if (streetCell(tx, tz) && !blockedAt(tx, tz, h)) { x = tx; z = tz; break outer; }
      }
    }
    Object.assign(st, { x, z, y: streetY, heading: h, vx: 0, vz: 0, vy: 0, falling: false, safe: [{ x, z, heading: h }] });
    const [fx, fz] = fwd(h);
    camPos.set(x - fx * 8, streetY + 3.5, z - fz * 8);
  }

  // ---- sound ------------------------------------------------------------------
  let audio = null, soundOn = true;
  function startAudio() {
    if (audio || !soundOn) return;
    try {
      const ctx = new AudioContext();
      const gain = ctx.createGain(); gain.gain.value = 0.0;
      const filter = ctx.createBiquadFilter(); filter.type = 'lowpass'; filter.frequency.value = 700;
      const o1 = ctx.createOscillator(); o1.type = 'sawtooth';
      const o2 = ctx.createOscillator(); o2.type = 'square';
      o1.connect(filter); o2.connect(filter); filter.connect(gain); gain.connect(ctx.destination);
      o1.start(); o2.start();
      audio = { ctx, gain, o1, o2, filter };
    } catch (e) { audio = null; }
  }
  function engine(speed, throttle) {
    if (!audio) return;
    const t = audio.ctx.currentTime;
    const gearSpeed = speed % 7.5;                          // fake gear changes
    const f = 38 + gearSpeed * 9 + speed * 1.5 + throttle * 12;
    audio.o1.frequency.setTargetAtTime(f, t, 0.05);
    audio.o2.frequency.setTargetAtTime(f * 0.5, t, 0.05);
    audio.filter.frequency.setTargetAtTime(400 + throttle * 900 + speed * 20, t, 0.08);
    audio.gain.gain.setTargetAtTime(soundOn ? 0.05 + throttle * 0.05 : 0, t, 0.08);
  }
  function horn() {
    if (!audio || !soundOn) return;
    const t = audio.ctx.currentTime;
    for (const f of [392, 494]) {
      const o = audio.ctx.createOscillator(), g = audio.ctx.createGain();
      o.type = 'square'; o.frequency.value = f; g.gain.value = 0.06;
      o.connect(g); g.connect(audio.ctx.destination); o.start(t); o.stop(t + 0.45);
    }
  }
  function splash() {
    if (!audio || !soundOn) return;
    const ctx = audio.ctx, len = ctx.sampleRate * 0.9;
    const buf = ctx.createBuffer(1, len, ctx.sampleRate), d = buf.getChannelData(0);
    for (let i = 0; i < len; i++) d[i] = (Math.random() * 2 - 1) * Math.pow(1 - i / len, 2);
    const src = ctx.createBufferSource(), f = ctx.createBiquadFilter(), g = ctx.createGain();
    f.type = 'lowpass'; f.frequency.value = 900; g.gain.value = 0.35;
    src.buffer = buf; src.connect(f); f.connect(g); g.connect(ctx.destination); src.start();
  }

  // ---- banner -------------------------------------------------------------
  let bannerTimer = 0;
  function say(big, small = '', secs = 2.2) {
    banner.innerHTML = '';
    banner.append(big);
    if (small) { const s = document.createElement('small'); s.textContent = small; banner.append(s); }
    banner.classList.add('show');
    clearTimeout(bannerTimer);
    bannerTimer = setTimeout(() => banner.classList.remove('show'), secs * 1000);
  }

  // ---- input --------------------------------------------------------------
  const keyMap = { KeyW: 'up', ArrowUp: 'up', KeyS: 'down', ArrowDown: 'down', KeyA: 'left', ArrowLeft: 'left', KeyD: 'right', ArrowRight: 'right', Space: 'hand' };
  addEventListener('keydown', e => {
    if (!api.active) return;
    if (keyMap[e.code]) { keys[keyMap[e.code]] = true; e.preventDefault(); }
    else if (e.code === 'KeyH') horn();
    else if (e.code === 'KeyC') st.camFar = !st.camFar;
    else if (e.code === 'KeyR') { placeAtSpawn(); say('RESET'); }
    else if (e.code === 'Escape') api.stop();
  });
  addEventListener('keyup', e => { if (keyMap[e.code]) keys[keyMap[e.code]] = false; });
  addEventListener('blur', () => { for (const k in keys) keys[k] = false; });
  for (const b of document.querySelectorAll('.pad button')) {
    const k = b.dataset.key;
    const on = e => { e.preventDefault(); keys[k] = true; b.classList.add('on'); try { b.setPointerCapture(e.pointerId); } catch (_) {} };
    const off = () => { keys[k] = false; b.classList.remove('on'); };
    b.addEventListener('pointerdown', on);
    b.addEventListener('pointerup', off); b.addEventListener('pointercancel', off); b.addEventListener('lostpointercapture', off);
    b.addEventListener('contextmenu', e => e.preventDefault());
  }
  document.getElementById('drive-start').addEventListener('click', () => api.start());
  document.getElementById('drive-exit').addEventListener('click', () => api.stop());
  const soundBtn = document.getElementById('sound-toggle');
  soundBtn.addEventListener('click', () => {
    soundOn = !soundOn;
    soundBtn.textContent = soundOn ? 'Sound on' : 'Sound off';
    soundBtn.setAttribute('aria-pressed', String(soundOn));
    if (soundOn) startAudio();
    if (audio) audio.gain.gain.value = 0;
  });

  // ---- physics --------------------------------------------------------------
  const MAX_FWD = 24, MAX_REV = 7;
  function step(dt) {
    const [fx, fz] = fwd(st.heading);
    let speed = st.vx * fx + st.vz * fz;                    // along the car
    const throttle = keys.up ? 1 : 0;
    if (!st.falling) {
      let a = 0;
      if (keys.up) a += speed < MAX_FWD ? 8.5 * (1 - Math.max(0, speed) / (MAX_FWD * 1.15)) : 0;
      if (keys.down) a += speed > 0.5 ? -16 : (speed > -MAX_REV ? -5 : 0);
      a -= speed * 0.12 + Math.sign(speed) * 0.4 * (Math.abs(speed) > 0.05 ? 1 : 0);   // drag + rolling
      speed += a * dt;
      if (!keys.up && !keys.down && Math.abs(speed) < 0.15) speed = 0;
      // Steering: none at a standstill, sharp at town speeds, calmer flat out.
      const target = (keys.left ? 1 : 0) - (keys.right ? 1 : 0);
      st.steer += (target - st.steer) * Math.min(1, dt * 8);
      const grip = Math.min(1, Math.abs(speed) / 5) * (1 - 0.45 * Math.min(1, Math.abs(speed) / MAX_FWD));
      st.heading += st.steer * 1.9 * grip * Math.sign(speed) * dt * (keys.hand ? 1.35 : 1);
      // Sideways slip decays fast with grip, slowly on the handbrake: drifting.
      const [nfx, nfz] = fwd(st.heading);
      let lx = st.vx - fx * (st.vx * fx + st.vz * fz), lz = st.vz - fz * (st.vx * fx + st.vz * fz);
      const keep = Math.exp(-(keys.hand ? 1.2 : 9) * dt);
      if (keys.hand) speed *= Math.exp(-0.5 * dt);
      st.vx = nfx * speed + lx * keep; st.vz = nfz * speed + lz * keep;
      st.roll += ((-(lx * -nfz + lz * nfx)) * 0.05 + st.steer * speed * 0.004 - st.roll) * Math.min(1, dt * 6);
      st.pitch += ((keys.down && speed > 1 ? -0.035 : keys.up ? 0.02 : 0) - st.pitch) * Math.min(1, dt * 5);
      // Move, sliding along walls one axis at a time.
      const nx = st.x + st.vx * dt, nz = st.z + st.vz * dt;
      if (!blockedAt(nx, nz, st.heading)) { st.x = nx; st.z = nz; }
      else if (!blockedAt(nx, st.z, st.heading)) { st.x = nx; st.vz *= -0.2; bump(Math.abs(st.vz)); }
      else if (!blockedAt(st.x, nz, st.heading)) { st.z = nz; st.vx *= -0.2; bump(Math.abs(st.vx)); }
      else { bump(Math.hypot(st.vx, st.vz)); st.vx *= -0.3; st.vz *= -0.3; }
      if (blockedAt(st.x, st.z, st.heading)) st.heading -= st.steer * 0.04;   // unstick after a spin
      // Off the quay?
      if (cell(st.x, st.z) === 1) {
        st.falling = true; st.fallT = 0; st.vy = 0;
      } else {
        st.safeT += dt;
        if (st.safeT > 0.8) {
          st.safeT = 0;
          if (cell(st.x, st.z) === 0 && Math.abs(speed) > 0.5) {
            st.safe.push({ x: st.x, z: st.z, heading: st.heading });
            if (st.safe.length > 4) st.safe.shift();
          }
        }
      }
    } else {
      st.fallT += dt;
      st.vy -= 9.8 * dt;
      st.y += st.vy * dt;
      st.x += st.vx * dt * 0.6; st.z += st.vz * dt * 0.6;
      st.pitch += (0.5 - st.pitch) * dt * 2;
      if (st.y < waterY && st.fallT < 10) { splash(); say('SPLASH', 'Amsterdam fishes 15,000 bikes out of its canals a year. Now one car.', 2.4); st.fallT = 10; }
      if (st.y < waterY - 1.2) { st.vy = Math.max(st.vy, -0.6); st.vx *= 0.9; st.vz *= 0.9; }
      if (st.fallT > 12.2) {
        const s = st.safe[0] || st.safe[st.safe.length - 1];
        Object.assign(st, { x: s.x, z: s.z, heading: s.heading, y: streetY, vx: 0, vz: 0, vy: 0, falling: false, pitch: 0, roll: 0, safe: [s] });
      }
    }
    return { speed, throttle };
  }
  function bump(v) { if (v > 3) { st.shake = Math.min(0.6, v * 0.04); if (v > 9) say('CRASH', '', 1.2); } }

  // ---- radar ------------------------------------------------------------------
  function drawRadar() {
    const W = radar.width, R = W / 2, scale = 2.4;          // radar px per metre
    rctx.save();
    rctx.clearRect(0, 0, W, W);
    rctx.beginPath(); rctx.arc(R, R, R, 0, Math.PI * 2); rctx.clip();
    rctx.fillStyle = '#2b302f'; rctx.fillRect(0, 0, W, W);
    rctx.translate(R, R);
    rctx.rotate(st.heading);
    const px = (st.x - gmin.x) / RES, pz = (st.z - gmin.z) / RES;
    rctx.imageSmoothingEnabled = true;
    rctx.drawImage(mapImage, -px * RES * scale, -pz * RES * scale, gw * RES * scale, gh * RES * scale);
    rctx.restore();
    // North marker on the rim, and the player arrow fixed pointing up.
    const nAng = st.heading - Math.PI / 2;
    rctx.fillStyle = '#fff'; rctx.font = 'bold 22px system-ui, sans-serif'; rctx.textAlign = 'center'; rctx.textBaseline = 'middle';
    rctx.fillText('N', R + Math.cos(nAng) * (R - 16), R + Math.sin(nAng) * (R - 16));
    rctx.fillStyle = '#f2c14e'; rctx.strokeStyle = '#000'; rctx.lineWidth = 3;
    rctx.beginPath(); rctx.moveTo(R, R - 14); rctx.lineTo(R + 10, R + 11); rctx.lineTo(R, R + 5); rctx.lineTo(R - 10, R + 11); rctx.closePath();
    rctx.stroke(); rctx.fill();
  }

  // ---- api ----------------------------------------------------------------
  const api = {
    active: false,
    start() {
      if (!grid) buildMap();
      api.active = true;
      document.body.classList.add('driving');
      hud.hidden = false;
      select(null);
      controls.enabled = false;
      placeAtSpawn();
      car.visible = true;
      camera.fov = 62; camera.updateProjectionMatrix();
      // A tighter shadow box that follows the car keeps shadows crisp up close.
      Object.assign(sun.shadow.camera, { left: -70, right: 70, top: 70, bottom: -70 });
      sun.shadow.camera.updateProjectionMatrix();
      startAudio();
      if (audio && audio.ctx.state === 'suspended') audio.ctx.resume();
      say('WELCOME TO AMSTERDAM', 'Mind the canals');
    },
    stop() {
      api.active = false;
      document.body.classList.remove('driving');
      hud.hidden = true;
      car.visible = false;
      controls.enabled = true;
      camera.fov = 55; camera.updateProjectionMatrix();
      Object.assign(sun.shadow.camera, { left: -260, right: 260, top: 260, bottom: -260 });
      sun.shadow.camera.updateProjectionMatrix();
      sun.target.position.set(0, 0, 0);
      setTime(parseFloat(document.getElementById('time').value));
      if (audio) audio.gain.gain.value = 0;
      for (const k in keys) keys[k] = false;
      goTo('overview');
    },
    update(dt) {
      const { speed, throttle } = step(dt);
      // Car pose.
      car.position.set(st.x, st.y, st.z);
      car.rotation.set(0, st.heading, 0);
      body.rotation.set(st.pitch, 0, st.roll);
      for (const w of wheels) {
        w.w.rotation.x -= speed * dt / 0.34;
        if (w.front) w.pivot.rotation.y = st.steer * 0.45;
      }
      // Chase camera.
      const [fx, fz] = fwd(st.heading);
      const back = st.camFar ? 13 : 7.5, up = st.camFar ? 6 : 3.2;
      const want = new THREE.Vector3(st.x - fx * back, Math.max(st.y, streetY) + up, st.z - fz * back);
      const k = 1 - Math.exp(-dt * (st.falling ? 2 : 5));
      camPos.lerp(want, k);
      // Keep the camera out of walls: pull it in along the line to the car.
      for (let i = 0; i < 6 && cell(camPos.x, camPos.z) >= 2; i++) camPos.lerp(car.position, 0.35);
      camLook.set(st.x + fx * 4, Math.max(st.y, waterY) + 1.2, st.z + fz * 4);
      camera.position.copy(camPos);
      if (st.shake > 0) {
        camera.position.x += (Math.random() - 0.5) * st.shake; camera.position.y += (Math.random() - 0.5) * st.shake;
        st.shake = Math.max(0, st.shake - dt * 2);
      }
      camera.lookAt(camLook);
      const fovWant = 62 + Math.min(14, Math.abs(speed) * 0.6);
      camera.fov += (fovWant - camera.fov) * Math.min(1, dt * 3); camera.updateProjectionMatrix();
      // Shadows follow the car so they stay sharp near it.
      sun.target.position.set(st.x, 0, st.z);
      sun.position.copy(sun.target.position).add(sky.material.uniforms.sunPosition.value.clone().multiplyScalar(600));
      kmhEl.textContent = Math.round(Math.abs(speed) * 3.6);
      drawRadar();
      engine(Math.abs(speed), throttle);
    },
  };
  return api;
})();
window.__drive = drive;
