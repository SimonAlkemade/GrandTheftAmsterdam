# Juicy Gunfights: Gunfeel & Explosion FX Spec
*FPS / 3PS · perceived-PSX look on a modern renderer (PBR, SSAO, realtime reflections) · implementation-ready*

> **Status in Grand Theft Amsterdam** (`godot-city/`). Slice 1 is in: the pistol as §6.1
> (Modern Handgun) with the §6.9 third-person adjustments: layered sound synthesized in code
> (`scripts/sfx.gd`), recoil springs and the muzzle (`scripts/gun_fx.gd`), the §7 impact matrix for
> the surfaces the city has (stone, metal, water, flesh) with decals and enemy-local hitstop, and the
> juice budget with the trauma camera and its accessibility settings (`scripts/juice.gd`).
> Not yet: explosions (§9), the other weapon recipes (§6.2–6.8), near-miss cracks, the PSX pass
> (§11), ducking and hearing loss (§10.3), world time dips.

---

## 0. How to read this (for the implementer)

- **Engine-agnostic.** Everything is expressed as data (`WeaponDef`, `ImpactDef`, `ExplosionDef`) plus a small set of runtime systems. Units: meters, seconds, degrees, dB, Hz, Kelvin for color temperature.
- **Three feedback scopes.** Every effect in this document belongs to exactly one scope:
  - **GUN LOCAL** – things attached to the weapon/shooter: fire sound, muzzle flash, shell ejection, viewmodel animation, recoil.
  - **IMPACT** – things spawned where the projectile lands: impact sound, particles, decals, light blip, physics push, enemy reaction.
  - **GLOBAL** – things applied to the player's whole view/mix: camera shake, FOV punch, post-processing, audio ducking, time scale, AI hearing.
- **Every effect is broken down into five channels:** `SOUND`, `PARTICLES`, `VFX/LIGHT` (meshes, sprites, decals, dynamic lights), `POST` (screen-space), `CAMERA`.
- **One scale knob.** Guns scale by *caliber class*; explosions scale by a single `size` slider (§9). All derived values come from formulas, never hand-tuned per size.
- Numbers are **starting points** for tuning, not physics truth. Tune in the order given in §12.

---

## 1. Research digest — what players love and hate

### 1.1 What reliably gets praised
| Finding | Evidence / example | Takeaway for us |
|---|---|---|
| **Layered gun audio** is the #1 driver of "weight" | CoD: Modern Warfare (2019) builds each shot from a transient attack, mechanical layer, tail and LFE, then swaps assets by environment, stance and how long you've been firing; reflections are placed in the world based on nearby geometry, and suppressed shots get their own reflection set. | Build every gun from 4–6 layers, randomize, and make the tail depend on the space. |
| **Environment answers the gun** | F.E.A.R. and its spiritual successor Trepang2 are praised for sparks, dust, debris and smoke filling rooms, and enemies being physically thrown by shots. | Impacts matter as much as the muzzle. Spend particle budget on hits, not on the muzzle. |
| **Enemy reaction sells damage** | Trepang2 reviews single out enemies flung by shotgun blasts, head pops on high-caliber hits, and a gritty distortion on gun sounds. | Flinch / stagger / ragdoll push scaled by damage. Subtle saturation on gun audio. |
| **One iconic "hero" gun** | Doom II's super shotgun remains the benchmark; DUSK makes the player bond with its double-barrel; Boltgun's first weapon feels so good reviewers stopped using the others. | Give every gun one signature. But beware: if the starter is the best-feeling gun, later guns feel like downgrades. |
| **Impact-feel research** | A data-driven study of action-game reviews found hit stop, audio coherence and camera control were the features most strongly tied to players' sense of impact; lacking any one of them can ruin it. | Hitstop (enemy-local), sound that lands *with* the hit, and disciplined camera are non-negotiable. |

### 1.2 What reliably gets criticized
| Complaint | Evidence | Rule we adopt |
|---|---|---|
| **Too much screen shake** | Players argue firing shake hides small details like enemies at the edges; jam feedback mentions nausea when shake stacks with shaders. | Shake is rotational, tiny on fire, bigger only for incoming damage/explosions. Global cap + accessibility slider. |
| **Floaty / weightless guns** | Even a hugely popular indie shooter gets called floaty with weak feedback by some players. | Weight = recoil *recovery* curve + LFE + viewmodel settle, not just kick size. |
| **Repetition** | Audio designers call out "machine-gunning" fatigue from identical samples. | Round-robin + pitch/volume jitter on every layer. |
| **Sound/visual desync** | Jam feedback: bullet sound before contact looked wrong. | Impact audio fires on the *impact frame*, never on the fire frame. |
| **Hitmarkers break immersion (for some)** | Doom Eternal players asked for a toggle; ZDoom mods add them as an option, audio-only mode included. | Hitmarker visual optional; hit *sound* always on. |
| **Hollywood silencers** | Split opinion: realism fans want suppressed guns audible (~tens of meters); cinematic players accept "pfft". Real suppressors cut roughly 20–40 dB and supersonic rounds still crack. | Suppressed = quieter + different, not silent. Subsonic ammo is the "quiet" option (§8.2). |
| **Boomer-shooter sameness** | Players note many retro shooters play alike; circle-strafing trivializes fights. | Feel ≠ design. Juice amplifies good encounters, it cannot rescue flat ones. |

### 1.3 The resulting "good stuff" mix
1. **Audio carries 50% of feel.** Layered, randomized, space-aware, with a player-only LFE layer.
2. **Viewmodel carries the recoil; the camera stays calm.** Big gun motion, small camera motion.
3. **Impacts are loud, chunky and physical.** Sparks/dust/chunks + enemy reaction + short enemy-local hitstop.
4. **Global effects are rare punctuation.** Reserved for big guns, explosions, damage taken, kills.
5. **PSX perception comes from resolution, sampling, snapping and stepped animation** — not from removing modern lighting. Crunchy sprites lit by real dynamic lights and reflected in SSR is the look.

---

## 2. Core principles (the "juice budget")

### 2.1 The budget
Every event has a juice cost. The global layer sums them per frame and **clamps**. This is what stops "overdoing it".

```
JuiceBudget (per frame, global)
  cameraTrauma      max 1.0   (decays 1.5–2.5 /s)
  fovPunch          max 6°
  exposureBump      max +0.6 EV
  chromaticAberr    max 0.004 (UV offset), off by default for guns
  vignetteExtra     max 0.25
  timeScaleDip      min 0.85 (never below, except scripted)
  audioDuck         max -9 dB on non-weapon buses
```

### 2.2 Priorities (highest wins when budget is full)
`Player takes damage` > `Explosion near player` > `Player kill` > `Player heavy shot` > `Player light shot` > `Distant events`

### 2.3 Readability rules
- Crosshair center must stay readable: muzzle flash sprites are **not** drawn over the center 10% of the screen in ADS; smoke from the player's own gun fades at < 0.3 s near camera.
- Camera shake uses **rotation** (pitch/yaw/roll) driven by smooth noise; **no positional shake** in FPS.
- The player's own shots never trigger full-screen post effects except a ≤ 1-frame exposure bump.
- Contrast beats volume: small guns quiet and dry, big guns loud and wide. If everything is 11, nothing is.

### 2.4 Randomization defaults (applies to everything)
| Parameter | Jitter |
|---|---|
| Sound pitch | ±3% (mech ±5%) |
| Sound volume | ±1.5 dB |
| Sound sample choice | round-robin, no repeat of last 2 |
| Particle count | ±20% |
| Particle direction cone | ±10° |
| Recoil yaw per shot | pattern + ±15% noise |
| Muzzle flash sprite | random of 3–4 variants + random roll rotation |

---

## 3. Runtime architecture

### 3.1 Systems
```
WeaponSystem        -> emits FireEvent(weaponDef, muzzleTransform, shooter, isPlayer)
BallisticsSystem    -> hitscan or projectile; emits ImpactEvent(hit, surface, caliberClass, dir, shooter)
ExplosionSystem     -> emits ExplosionEvent(explosionDef, pos, size01)
FeedbackRouter      -> maps events to scopes: GunLocal / Impact / Global
  GunLocalFX        -> viewmodel anim, muzzle, shells, fire audio
  ImpactFX          -> surface lookup, particles, decals, light blip, impact audio, physics, enemy reaction
  GlobalFX          -> JuiceBudget accumulation, camera, post, mix, timescale, AI hearing
PSXPresentation     -> low-res target, dithering, vertex snap, stepped FX time (see §11)
```

### 3.2 Event contracts
```ts
FireEvent     { weapon: WeaponDef, muzzle: Transform, shooter: Entity, isPlayer: bool, shotIndexInBurst: int, time: float }
ImpactEvent   { point: vec3, normal: vec3, dir: vec3, surface: SurfaceType, caliber: CaliberClass,
                victim?: Entity, isHeadshot: bool, isKill: bool, distanceFromShooter: float }
ExplosionEvent{ def: ExplosionDef, pos: vec3, size01: float, instigator?: Entity }
```

### 3.3 Enums
```ts
CaliberClass = { PISTOL_SUB, PISTOL, RIFLE_INTERMEDIATE, RIFLE_FULL, SHOTGUN_PELLET, SHOTGUN_SLUG, HEAVY }
SurfaceType  = { CONCRETE, BRICK, METAL_THIN, METAL_THICK, WOOD, DIRT, SAND, GLASS, WATER, FLESH, FLESH_ARMORED, PLASTIC }
Era          = { CLASSIC, MODERN }
Muzzle       = { BARE, SUPPRESSED, BRAKE, FLASH_HIDER }
```

---

## 4. The shot timeline (what happens, frame by frame)

Assumes 60 Hz sim. "F0" = the frame the trigger registers.

| Time | GUN LOCAL | IMPACT | GLOBAL |
|---|---|---|---|
| **F0 (0 ms)** | Fire audio: transient + body + mech + LFE start *this frame* (no latency!). Muzzle flash sprite ON. Muzzle light ON. Viewmodel recoil impulse applied. | Hitscan resolved. | Camera pitch kick impulse. Exposure bump (1 frame). AI hearing ping. |
| **F1 (16 ms)** | Muzzle flash sprite frame 2 (smaller) or OFF for small guns. Light at 40%. | Impact audio + particles + decal + light blip spawn *(hitscan)*. Enemy hitstop starts. | Hit sound (UI tick) if hit on enemy. |
| **F2–F3** | Flash OFF. Light OFF. Shell ejects (bolt/slide travel visible). Muzzle smoke wisp starts. | Enemy flinch pose. Debris flying. | FOV punch peak (shotgun/heavy only). |
| **50–150 ms** | Viewmodel at max kick, starts spring return. | Hitstop ends (enemy only). Blood/dust puff expanding. | Camera kick recovering. |
| **150–600 ms** | Tail audio (room/outdoor) plays out. Shell lands → casing tink (surface-dependent). | Dust settles, embers die. | Kill confirm sound (+ optional marker). |
| **0.6–3 s** | Barrel smoke on sustained fire; heat shimmer for LMGs. | Decal persists (pool of 64–256 decals, FIFO). | — |

**Projectile weapons:** impact row starts on actual contact, not F1.

---

## 5. Scope definitions & component lists

### 5.1 GUN LOCAL
| Channel | Components |
|---|---|
| SOUND | `transient` (crack, 0–30 ms, the "click of the bang"), `body` (the boom, 30–250 ms, defines caliber/size), `mech` (slide/bolt/pump/hammer, per-weapon signature), `lfe` (sub 30–80 Hz, **player only**), `tail_{indoor,outdoor,tunnel}` (crossfaded by environment probe), `shell_drop` (per surface, delayed by fall time), `dry_fire`, `low_mag_tone` (last 20–30% of mag: rising pitch tick layered on mech), `reload_*` foley. |
| PARTICLES | Muzzle smoke wisp (3–6 sprites, drift up), sparks (optional, classic/cheap ammo), shell casing (mesh particle w/ physics, 1–3 bounces), unburnt powder flecks (shotguns), barrel smoke on sustained fire. |
| VFX / LIGHT | Muzzle flash cards: 1 front "star" quad + 2–3 side "petal" quads (crossed), 1–2 frames. Muzzle point light (short, warm). Tracer (every Nth round for rifles). Heat glow on barrel mesh (emissive ramp) for sustained fire. |
| POST | Exposure bump 1 frame (tiny). Nothing else for light guns. |
| CAMERA | Recoil = **viewmodel** kick (pos + rot, spring) + small **camera** pitch kick (spring) + optional micro shake. |

### 5.2 IMPACT
| Channel | Components |
|---|---|
| SOUND | `impact_{surface}` (short, sharp, spatialized), `ricochet_whine` (10–20% chance on metal/stone at grazing angles), `debris_trickle` (for chunky surfaces), `flesh_hit` (thwack + wet), `armor_hit` (clank), `headshot_sting` (player only, UI bus), `kill_confirm` (UI bus). **Bullet cracks/whizz** for near-miss rounds passing the player (supersonic only). |
| PARTICLES | Surface-specific: sparks, dust puff, chunks (mesh), splinters, dirt spray, glass shards, water splash column, blood mist. Always one **"fast" layer** (sparks/spray, <0.2 s) + one **"slow" layer** (dust/mist, 0.5–1.5 s). |
| VFX / LIGHT | Decal (bullet hole, point-filtered 32–64 px), light blip (sparks on metal only, 50 ms), mesh chips. Enemy: hit flash (emissive white 1–2 frames, optional stylistic), wound decal. |
| POST | None (impacts are world-space). |
| CAMERA | None for the shooter. For the *victim* player: see §5.3 damage taken. |
| PHYSICS / AI | Impulse on rigidbodies (∝ caliber), enemy flinch/stagger/ragdoll push, **enemy-local hitstop** (freeze enemy anim 2–6 frames; not the world). |

### 5.3 GLOBAL
| Channel | Components |
|---|---|
| SOUND | Mix: duck ambience/music on big shots & explosions (sidechain), tinnitus layer (explosions only, close), "hearing loss" low-pass on the world bus after close blasts, room reverb send from environment probe. |
| PARTICLES | Screen-space dust / debris sprites falling in front of camera (explosions only). |
| VFX / LIGHT | Flash of large lights (explosions) affecting whole scene incl. SSR/SSAO. |
| POST | Exposure bump, vignette pulse (damage), desaturation (low health), chromatic aberration pulse (explosions, damage), radial blur (explosions very close only), heat distortion volumes (world-space). |
| CAMERA | Trauma-based shake (§10.1), FOV punch, kick. |
| TIME | Kill hitstop: optional world time dip to 0.85 for 40–60 ms on a *multi-kill* or *heavy weapon kill* only. Never on every kill. |
| GAMEPLAY | AI hearing radius event (`noise = weapon.loudness`). |

---

## 6. Weapon recipes

Each recipe lists: **Character**, **Handling**, then the three scopes broken into channels. Numbers assume FPS; for 3PS see §6.9.

### Shared handling model (implement once)
```
recoil state:
  vmPos, vmRot           // viewmodel offsets, spring-damped to 0
  camPitch, camYaw       // camera kick, spring-damped to 0 (partial: see recoverFrac)
  permanentPitch         // portion of kick NOT recovered -> player must pull down
per shot:
  vmRot  += (kickPitch, kickYaw ± noise, kickRoll ± noise)
  vmPos  += (0, kickUp, -kickBack)
  camPitch += camKick * (1 - recoverFrac); permanentPitch += camKick * recoverFrac? (see param)
spring: critically-damped-ish, stiffness k, damping c (per weapon)
ADS: multiply vm kick by adsVmScale (0.4–0.6), cam kick by adsCamScale (0.8–1.0)
```
Weight = **low stiffness + slightly underdamped overshoot** (the gun "settles"). Snappy = **high stiffness, critically damped**.

---

### 6.1 Modern Handgun (polymer-frame 9mm, optic-ready)
**Character:** clinical, fast, tight. Snappy crack, short dry tail, crisp slide cycle. The "reliable tool".

**Handling**
| Param | Value |
|---|---|
| RPM cap (semi) | 400 |
| Viewmodel kick pitch / back | 6° / 3 cm |
| Camera kick | 0.6°, recoverFrac 0.9 (almost fully returns) |
| Spring k / c | 180 / 22 (snappy) |
| ADS time | 0.15 s |
| Slide lock on empty | yes (visible + distinct mech sound) |

**GUN LOCAL**
- SOUND: transient = sharp 2–4 kHz snap; body = mid 200–800 Hz, 120 ms; mech = polymer slide *tick-clack*, light; lfe = small (-12 dB rel. rifle); tails: indoor slap 0.4 s, outdoor 0.8 s; shell = light brass tink.
- PARTICLES: 3 smoke wisps (0.4 s), 1 shell mesh.
- VFX/LIGHT: small flash (0.12 m star, 2 petals), **1 frame only**; point light 2 m radius, 1 frame, 3200 K.
- POST: exposure +0.1 EV, 1 frame.
- CAMERA: kick only, no shake.

**IMPACT** (caliber `PISTOL`): impact particles at scale 0.6 (§7). Enemy flinch light; no ragdoll push unless kill (push 150 N·s).

**GLOBAL:** AI noise radius 45 m. Nothing else.

---

### 6.2 Classic Handgun (revolver, .357/.44, or 1911-style)
**Character:** heavy, deliberate, theatrical. Big boom, loud tail, mechanical personality (cylinder rotate, hammer cock).

**Handling**
| Param | Value |
|---|---|
| RPM cap | 150 (DA revolver) |
| Viewmodel kick pitch / back | 18° / 6 cm, **wrist flip** (roll 4°) |
| Camera kick | 1.4°, recoverFrac 0.85 |
| Spring k / c | 90 / 11 (**slight overshoot**: settles with a wobble) |
| Signature | hammer visibly cocks between shots; cylinder advances one chamber |

**GUN LOCAL**
- SOUND: transient = wider, less bright; body = big 80–400 Hz boom, 200 ms, **+2 dB saturation**; mech = hammer click *before* the shot on single-action (anticipation!), cylinder ratchet after; lfe = strong; tails long (indoor 0.7 s, outdoor 1.5 s). No shell drop (revolver) → silence after the tail is part of the character.
- PARTICLES: big smoke puff (6 sprites, 0.8 s), **cylinder gap flash sparks** (4–6 sparks sideways), unburnt powder flecks for .44.
- VFX/LIGHT: large flash (0.3 m, round "bloom ball" + 4 petals), **2 frames**; light 4 m, 2 frames, 2600 K (warmer, older powder).
- POST: exposure +0.25 EV 1 frame.
- CAMERA: kick + micro shake trauma +0.08.

**IMPACT** (`PISTOL` → treat as `RIFLE_INTERMEDIATE` for particles): bigger chunks, enemy stagger, ragdoll push 350 N·s on kill.

**GLOBAL:** AI noise 60 m. Optional enemy-local hitstop 4 frames on kill.

---

### 6.3 Suppressed Handgun (modern 9mm + can, or integrally suppressed)
**Character:** precise, intimate, mechanical. The *gun* is now louder than the *shot*.

**Handling:** as 6.1 but camera kick ×0.8, viewmodel kick ×0.9, flash removed.

**GUN LOCAL**
- SOUND: transient replaced by **"pfft/thup"** (low-mid 150–600 Hz, 60 ms, -18 dB vs bare); body largely removed; **mech layer +6 dB** (slide clack is now the star); lfe tiny; tail: short, low-passed (4 kHz), indoor 0.2 s; add `baffle_ping` (very quiet metallic ring, 5% chance). If ammo is **supersonic**: keep a thin sonic crack layer at the *impact/flyby* side (see IMPACT). Subsonic: no crack.
- PARTICLES: **no** muzzle smoke burst; instead a thin wisp from the suppressor end on every 3rd shot; suppressor "first round pop" (first shot after 5 s idle gets a slightly bigger flash/sound, like real first-round pop).
- VFX/LIGHT: flash: tiny 2-frame glow ring at can end only on first-round pop; **no muzzle light** (big stealth readability win).
- POST: none.
- CAMERA: kick only.

**IMPACT:** same as 6.1 but **impact audio becomes the loudest element**. Supersonic: add bullet crack along the path for listeners near it.

**GLOBAL:** AI noise radius 12 m (subsonic) / 20 m (supersonic). Near-miss AI still reacts to impact noise at the hit point (not the shooter) → emergent stealth gameplay.

---

### 6.4 Pump Shotgun (two-handed, 12 ga)
**Character:** the negotiation-ender. Short, huge, physical. The pump rack is half the fun.

**Handling**
| Param | Value |
|---|---|
| RPM | 70 (pump-limited) |
| Pellets | 8–9, spread 5° hip / 3.5° ADS |
| Viewmodel kick | 22° pitch, 10 cm back, shoulder drop 3 cm |
| Camera kick | 2.2°, recoverFrac 1.0 (fully recovers — shotguns shouldn't punish aim) |
| Spring | 70 / 9 (heavy, overshoot) |
| Pump | 0.45 s animation, **fire input buffered** during pump |
| FOV punch | +3° over 40 ms, return 200 ms |

**GUN LOCAL**
- SOUND: transient = wide, slightly compressed blast; body = 60–300 Hz, 250 ms, **heavy saturation**; lfe = max; mech = **pump rack** (two-part *chk-chak*, played by animation event, **sound first, then shell ejects**); tails long, big slap in rooms; shell drop = plastic hull *thop* (not brass).
- PARTICLES: big forward smoke cone (8 sprites, 1 s), powder flecks, wad (tiny mesh, 1), hull ejection on pump.
- VFX/LIGHT: flash 0.45 m, dense cone + 5 petals, **2 frames**; light 5 m, 2 frames, 3000 K.
- POST: exposure +0.35 EV (1 frame); **no** chromatic aberration.
- CAMERA: kick + FOV punch + trauma +0.15 (budget-capped).

**IMPACT** (`SHOTGUN_PELLET`): pellets resolve individually for damage **but FX are clustered**: spawn one "pattern" effect = N small puffs (cap 5) + 1 combined sound at the centroid (prevents 9 overlapping impact sounds). Decals: 9 small holes. Enemy: big knockback 600 N·s on kill, stagger on hit, gib chance at < 4 m.

**GLOBAL:** AI noise 80 m. Enemy-local hitstop 5 frames on kill. Optional 40 ms world time dip to 0.9 on a 2+ kill single shot.

---

### 6.5 Double-Barrel (classic / boomer-shooter hero)
**Character:** ridiculous, joyful, iconic. Two barrels, one enormous shot, and the reload is a performance.

**Handling:** 20 pellets, spread 9°; viewmodel kick 35° + roll 6°, back 14 cm; camera 3°; **reload = break open → shells pop out with a spring *ping* → two shells in → snap shut** (≈1.3 s). Fire is available again the frame the snap sound plays.

**GUN LOCAL:** as 6.4 but body layer ×1.4 duration and +3 dB, **no pump**; the reload trio (*clack-open*, *ping-ping* shells, *snap*) is the signature. Flash 0.6 m twin-cone. Light 6 m.

**IMPACT:** as 6.4 with gib chance up to 7 m. Doom II / DUSK-style: enemies should visibly *fly*.

**GLOBAL:** trauma +0.25, FOV punch +5°. This is the one gun allowed to push the budget on every shot.

---

### 6.6 Modern Assault Rifle (5.56 carbine, optic, brake/flash hider)
**Character:** controlled violence, rhythmic. Consistent recoil pattern, crisp mechanics, "precise machine".

**Handling**
| Param | Value |
|---|---|
| RPM | 750 |
| Recoil pattern | deterministic first 8 shots (up + slight right), then noise-dominant |
| Viewmodel kick | 3.5° per shot, back 1.8 cm |
| Camera kick | 0.35° per shot, recoverFrac 0.6 (player compensates) |
| Spring | 220 / 28 |
| Sustained fire | viewmodel *drift* (slow sine walk 0.3 Hz) after 10 rounds |

**GUN LOCAL**
- SOUND: transient crack bright (3–6 kHz); body medium 150 ms; mech = bolt carrier *chk* per shot (quiet), **full-auto uses a looped-layer approach**: first shot = full one-shot; subsequent shots = shorter one-shots with tails **stolen** (voice-limit tails to 2, fade older), final shot plays a full tail ("tail on release"). Environment tails are critical here. Low-mag tone from 30% mag. Shell = rhythmic brass cascade.
- PARTICLES: small wisps per shot, **barrel smoke builds** after 15 rounds; shell stream.
- VFX/LIGHT: flash 0.2 m, 3 petals, 1 frame, random roll; **flash hider variant**: dimmer 3-prong flash; **brake variant**: side jets (2 lateral cones) and more side dust at the player's feet when prone. Tracer every 4th round. Light 3 m, 1 frame per shot.
- POST: exposure bump every 3rd shot only (avoid strobing).
- CAMERA: kick; trauma +0.02 per shot capped at 0.12 total from sustained fire.

**IMPACT** (`RIFLE_INTERMEDIATE`): full-size surface FX; supersonic cracks for near misses.

**GLOBAL:** AI noise 110 m.

---

### 6.7 Classic Rifle (bolt-action or M1-style full-power rifle)
**Character:** a single, deafening statement. Wood and steel. Every shot is an event.

**Handling:** RPM 40 (bolt) / 180 (semi); viewmodel kick 12°, back 7 cm; camera 1.8°, recoverFrac 0.9; spring 60 / 8 (slow, heavy settle); bolt cycle 0.7 s with rack sounds; M1-style: **en-bloc *ping*** on last round (signature!).

**GUN LOCAL:** body long & deep, massive outdoor tail with **distance echo** (slap-back 0.3–0.8 s from terrain); mech = wood creak + steel bolt; flash 0.35 m, 2 frames; light 4 m, 2500 K; heavy muzzle smoke (older powder: +50% smoke vs modern).

**IMPACT** (`RIFLE_FULL`): big dust/chunks; one-hit ragdoll push 500 N·s; head pop allowed.

**GLOBAL:** trauma +0.1; AI noise 150 m.

---

### 6.8 Suppressed Rifle (delta vs 6.6)
- SOUND: transient becomes a **hard "thwack"** (still loud-ish: -14 dB, not whisper); supersonic crack remains at the bullet path; mech +4 dB; tails low-passed & -10 dB; distant listeners hear mostly the crack and the impact.
- VFX: flash removed; **gas blowback** puff near ejection port (tiny, every shot); light removed.
- GLOBAL: AI noise 35 m (supersonic) / 15 m (subsonic 300 BLK-style with reduced damage & drop).

### 6.9 Third-person adjustments
- Recoil lives on the **character anim** (additive upper-body kick, 60–150 ms) + **camera pitch kick ×0.5** of FPS values.
- Muzzle flash is seen from the side → petals matter more than the front star; scale flash ×1.5 for readability.
- Shake: 3PS tolerates more *positional* shake (camera is detached): allow up to 3 cm positional on explosions.
- Aim point: crosshair from camera ray; projectile origin from muzzle; resolve with "fire from camera if muzzle ray blocked within 1 m" to avoid shots into cover lips.
- Enemy hitstop is more visible in 3PS → keep 2–4 frames max.

---

## 7. Impact matrix (by surface)

Base values for caliber `RIFLE_INTERMEDIATE`. Multiply counts/sizes with `caliberScale`:
`PISTOL_SUB 0.5 · PISTOL 0.6 · RIFLE_INT 1.0 · RIFLE_FULL 1.4 · SHOTGUN_PELLET 0.35 (per pellet, clustered) · SHOTGUN_SLUG 1.6 · HEAVY 2.2`

| Surface | SOUND | PARTICLES (fast / slow) | VFX / LIGHT | Physics |
|---|---|---|---|---|
| CONCRETE / BRICK | sharp *tchk* + grit trickle; ricochet 10% | 6–10 grey chips (mesh, 0.4 s) / dust puff 1 sprite 0.8 s, 0.4 m | crater decal 48 px; no light | – |
| METAL_THIN | high *ting/plink*, resonant | 12–20 sparks (0.15 s, gravity 0.3) / tiny smoke | spark light 50 ms, 1.5 m, 3500 K; bright hole decal | pierce if caliber ≥ RIFLE |
| METAL_THICK | lower *clang*, ricochet 20% | 8 sparks / none | spark light; scuff decal | ricochet vector |
| WOOD | dull *thok* + crackle | 5–8 splinters (long thin quads) / sawdust 1 sprite | splintered decal | small impulse |
| DIRT / SAND | soft *thup* | spray column 8 clods / dust plume 1–2 sprites 1.2 s | no decal (or soft) | – |
| GLASS | *crash* (pane break) or *tik* (bulletproof) | 20–40 shards (mesh, reflective in SSR!) / none | crack decal (spiderweb) | pane shatter state |
| WATER | *plip* + splash | column 0.5–1.2 m (sprite sheet) / ripple ring | no light | – |
| FLESH | wet *thwack* + low body thump (player-heard +3 dB) | blood mist 1–2 sprites 0.4 s (dark red, dithered alpha) / 3–6 droplets | wound decal on body; blood decal on wall behind (raycast 2 m) | flinch; enemy hitstop 2–4 frames |
| FLESH_ARMORED | *clank* + thud | sparks 6 / fabric fibers | spark light small | stagger reduced |
| PLASTIC | hollow *tock* | colored fragments 4 | small hole | – |

**Near-miss (supersonic only):** crack sample at the closest point of the bullet path to each listener within 8 m; plus whiz for subsonic within 2 m.

---

## 8. Comparisons (quick reference)

### 8.1 Modern vs Classic
| Aspect | MODERN | CLASSIC |
|---|---|---|
| Sound | crisp transient, tight body, controlled tails, polymer/aluminum mechs, low-mag tone | fat body, saturated, long tails & echoes, wood/steel mechs, hammer/cylinder/bolt personality |
| Smoke | little (clean powder) | lots (older powder), lingering |
| Flash | small, shaped (hiders), 1 frame | round & bigger, 2 frames, warmer (2500–2700 K) |
| Recoil | fast recovery, high stiffness, pattern-based | slow, overshooting settle, more roll/flip |
| Reload | tactical (mag + bolt release), quick | ritual (strip clips, shells, cylinders), longer, audible stages |
| Wear | clean, matte | patina, scratches, worn bluing (roughness variation shows great in PBR) |
| Optics | red dot / holo reticle glow | iron sights, post & notch |

### 8.2 Bare vs Suppressed
| Aspect | BARE | SUPPRESSED |
|---|---|---|
| Transient | sharp crack | replaced by "thup/thwack" |
| Loudness (relative) | 0 dB | -14 to -20 dB (not silent) |
| Mech layer | normal | +4 to +6 dB (becomes the star) |
| Tail | full, space-aware | short, low-passed, quieter reflections |
| Supersonic crack | yes | yes (unless subsonic ammo) |
| Flash / light | yes | none (first-round pop exception) |
| Smoke | puff | wisp from can end |
| AI noise | 45–150 m | 12–35 m |
| Gameplay cost | none | slightly lower damage/velocity for subsonic, longer weapon (ADS +0.03 s) |

### 8.3 Handgun vs Two-handed Shotgun
| Aspect | HANDGUN | SHOTGUN |
|---|---|---|
| Recoil | quick flip, full recovery, one hand wobble | shoulder push, big back-travel, FOV punch |
| Sound focus | transient + mech | body + LFE + pump |
| Impact | single precise hole, light flinch | clustered pattern, knockback, gibs |
| Global | nothing | trauma, FOV punch, exposure bump |
| Rhythm | tap-tap-tap (up to 400 RPM) | boom… rack… boom |

---

## 9. Explosions

### 9.1 Anatomy (every explosion = these layers; presets change weights, colors, timing)
| # | Layer | Scope |
|---|---|---|
| 1 | **Flash** (1–3 frames, overexposes scene) | Global light + post |
| 2 | **Shockwave** (visible ring/dust skirt, air distortion sphere) | Impact/world + global camera when it reaches the player |
| 3 | **Fireball** (volume of flame sprites) | World |
| 4 | **Smoke** (plume / column / cloud) | World |
| 5 | **Debris** (mesh chunks, fragments with trails, dirt clods) | World + physics |
| 6 | **Embers / sparks** | World |
| 7 | **Ground mark** (scorch / crater decal, burning pool) | World |
| 8 | **Light** (large point light with color & intensity curve; affects SSR/SSAO) | World/global |
| 9 | **Sound** (crack, boom, whump/roar, debris rain, tail, distant rumble) | World + mix |
| 10 | **Camera & post** (trauma, FOV, CA, radial blur, tinnitus, low-pass) | Global |
| 11 | **Gameplay** (radial damage, radial impulse, destruction damage, AI panic, fire hazard) | World |

### 9.2 The size slider
One float `size01 ∈ [0,1]` per explosion. Map it log-linearly to an **equivalent mass M** (kg), then derive a **linear scale S** by cube-root, because fireball diameter and fireball duration in real-world fireball correlations (used for LPG/propane tank ruptures) both grow with the cube root of fuel mass — the widely used form is diameter ≈ 5.8·M^⅓ m and duration ≈ 0.45·M^⅓ s. Blast-effects models for high explosives use a flatter exponent for fireball duration (≈ M^0.25).

```ts
const M_MIN = 0.2   // kg  (grenade, small canister)
const M_MAX = 200   // kg  (car/truck, fuel tanker section, large IED)
function mass(size01)  { return M_MIN * Math.pow(M_MAX / M_MIN, size01) }   // log-lerp
function S(size01)     { return Math.cbrt(mass(size01)) }                    // linear scale
//             size01 = 0     0.25    0.5    0.75    1.0
//             M (kg) = 0.2   1.12    6.3    35.6    200
//             S      = 0.58  1.04    1.85   3.29    5.85
```

**Derived quantities (all presets use these; presets supply the coefficients):**
| Quantity | Formula | Notes |
|---|---|---|
| Fireball radius | `R_fb = k_fb * S` | k_fb per preset |
| Fireball/flash duration | `T_fb = t_fb * S^p` | p = 1.0 fuel (gas/gasoline), 0.75 HE |
| Shock ring max radius | `R_sh = k_sh * S` | |
| Shock ring expand time | `0.12 * S^0.5` s | visually slowed vs reality for readability |
| Damage radius (lethal / hurt) | `k_dmg * S`, `2.5 * k_dmg * S` | gameplay-tuned |
| Particle counts | `base * S^2`, clamp to preset max | area-ish scaling; clamp protects perf |
| Sprite size | `base * S` | |
| Smoke lifetime | `base * S^0.5` | big smoke lingers, not linearly |
| Light peak intensity | `base * S^2` (not S³: clamp exposure) | radius `base * S` |
| Sound gain | `+20·log10(S)` dB, clamp +18 dB | |
| Sound pitch | `S^-0.2` | bigger = lower |
| Audible distance | `base * S` | |
| Sound delay | `distance / 343` s for d > 30 m | shockwave before sound at range = great realism beat |
| Camera trauma at distance d | `clamp01( T0 * S^1.5 / (1 + (d / (k_dmg*S*3))^2) )` | |
| Debris speed | `v0 * S^0.3` | big blasts don't throw *faster*, they throw *more & heavier* |

**Tiers (swap asset sets at thresholds, don't just scale):**
- `size01 < 0.2` → **small** (grenade/canister): 1 fireball flipbook, no column smoke, no screen debris.
- `0.2–0.6` → **medium** (barrel, car): add secondary fireballs, smoke plume, debris meshes.
- `> 0.6` → **large** (tanker, building charge): add rising column/mushroom, ground dust skirt, distant rumble, screen dust, delayed secondary debris rain, structure destruction.

---

### 9.3 Preset A — GAS explosion (deflagration: propane/natural gas cloud, gas canister)
**Look & feel:** a fast, **pale, soft, cloudy** "WHUMP". The flame front *fills a volume* (the cloud) rather than bursting from a point. Light colors, little soot, blown-out windows, lingering pale haze.

| Channel | Spec |
|---|---|
| **SOUND** | `whump` (low 40–150 Hz, soft attack 20–40 ms, not a crack) · `air_rush` (inward suck 150 ms *before*, only size ≥ 0.4 — the cloud igniting) · `glass_burst` (if windows in 1.5·R_sh) · `hiss/jet` loop from ruptured source (burning jet 5–20 s) · tail: medium, dull |
| **PARTICLES** | Flame volume: 20·S² sprites, **pale yellow → blue-white core**, spawned *throughout a sphere/ellipsoid of the gas cloud*, lifetime 0.25–0.5·S s · Cloud: 12·S² light-grey/white puffs (#D8D6CF → #A9A7A0), lifetime 4–8·S^0.5 s, slow outward drift, low-rise · Dust skirt low along ground · Few embers (5) · Paper/insulation flutter bits (light debris, slow fall) |
| **VFX / LIGHT** | Flash: very broad, soft, 3–5 frames, color 5500 K (whitish yellow with slight blue); point light R = 6·S, peak 60·S² (engine units), decay 0.4·S s · Distortion sphere (soft) · Light scorch decal, **no crater** · Burning jet cone at source if pressurized (orange-blue flame card, 5–20 s) |
| **POST** | Exposure bump +0.8 EV (soft ramp 40 ms up, 300 ms down) · mild CA pulse 0.002 · slight bloom lift |
| **CAMERA** | Trauma: low-frequency, *wobbly* shake (noise freq 8 Hz) — feels like a push, not a hit · FOV punch +2° outward |
| **GAMEPLAY** | Wide, moderate pressure: large knockback radius, moderate damage; doors/windows/light props blown outward; structure damage low; can ignite flammables |

Coefficients: `k_fb = 2.2`, `t_fb = 0.35, p = 1.0`, `k_sh = 4.0`, `k_dmg = 1.4`.

---

### 9.4 Preset B — GASOLINE explosion (fuel-air fireball: car, barrel, tanker)
**Look & feel:** the **Hollywood** fireball: bright, huge, **orange rolling fireball that climbs**, dark soot edges turning into a long black smoke column; burning pool afterwards. (Films deliberately use gasoline for this look; real high explosives are much faster and dustier.)

| Channel | Spec |
|---|---|
| **SOUND** | `pop` (initial rupture, 0 ms) → `WHOOMF` (fireball ignition +60–120 ms delay, rich 50–400 Hz, slower attack, long body) · `roar` (fireball burning, 1–2·S s, rumble with crackle) · `debris_clatter` (hood/door/metal, delayed by fall time) · `fire_crackle` loop (burning pool, 20–60 s) · distant: long rolling tail |
| **PARTICLES** | Fireball: 30·S² flame sprites (flipbook 16 frames), color ramp **#FFF3C0 → #FFB347 → #E8591A → #6B2A12 → soot**, emitted in a **toroidal / rising** pattern (velocity up + outward, then curl inward at top → mushroom), **buoyancy +3·S m/s²**; lifetime T_fb ≈ 0.45·S … 1.2·S s (art-directed longer than physics for readability) · Soot: every flame sprite spawns a **black smoke child** at end of life (#1A1714 → #3B3733 alpha fade) · Smoke column: 25·S² sprites, rising 1.5·S^0.5 m/s, lifetime 15–40 s, wind-driven · Embers: 40·S², rise then fall, 2–5 s · Burning debris: 3–8 chunks with fire trail sprites |
| **VFX / LIGHT** | Flash: 2 frames warm white · Main light: R = 10·S, color 1800 K–2200 K orange, **long flickering decay** (noise 6–10 Hz) for T_fb·3, then pool fire light (dimmer, flicker) for the pool lifetime — this lights walls & shows up in SSR (big win on a PSX-look scene) · Heat distortion column above fireball & pool · Scorch decal (dark, large) + **burning pool decal** (animated fire cards on the ground, 20–60 s) |
| **POST** | Exposure bump +0.6 EV, slower decay 600 ms (warm color grade push toward orange for 1 s when on screen and close) · heat haze screen distortion only if camera inside heat column |
| **CAMERA** | Trauma medium; FOV punch +3°; *delayed* second small shake when big debris lands near |
| **GAMEPLAY** | Moderate blast pressure, **high fire damage**, lingering fire hazard area, sets flammables alight; structural damage medium (vehicles, light walls) |

Coefficients: `k_fb = 2.9` (≈ 5.8/2 as radius), `t_fb = 0.45, p = 1.0` (×1.8 art multiplier), `k_sh = 3.0`, `k_dmg = 1.2`.

---

### 9.5 Preset C — MILITARY / INDUSTRIAL (high explosive: grenade, shell, demo charge, IED)
**Look & feel:** **fast, violent, efficient**. A white-hot flash that's gone in a blink, a visible shockwave ring, a column of **grey-brown dust and dirt** rather than fire, lots of fast debris, heavy structural damage. Sound is a *crack* + deep boom. At distance: see it, feel the shock, *then* hear it.

| Channel | Spec |
|---|---|
| **SOUND** | `crack` (0 ms, very sharp broadband transient, loudest element) · `boom` (40–120 Hz body, 300–600 ms) · `sub_thump` (player-feel LFE) · `debris_rain` (dirt, gravel, metal pieces falling 0.5–3 s later) · `structural_groan/collapse` (if destruction) · distance variants: <50 m full, 50–300 m boom+rumble, >300 m low rumble only · **delay by distance/343** · close: **tinnitus + world low-pass** (see §10) |
| **PARTICLES** | Flash core: 1–2 frames, white #FFFFFF → #FFE9B0, radius 0.6·S · Fire: *small*, 8·S² sprites, 0.1–0.3·S^0.75 s (HE fireballs are brief) · Dust/dirt column: 30·S² sprites, **grey-brown #8C7A62 → #5E5448**, fast upward jets (dirt geysers, 5–9 fingers) · Ground dust skirt: ring of 20·S sprites racing outward along the ground at shock speed · Fragments: 40·S² fast streaks (tracer-like quads, 60–120 m/s, 0.1–0.3 s) · Debris meshes: 10·S² chunks (concrete, metal, earth clods), heavy gravity · Smoke: grey #6E6B67, medium lifetime 6–12·S^0.5 s |
| **VFX / LIGHT** | Flash light: R = 12·S, 6500 K, **1–2 frames at max**, very fast decay (80 ms) · Shockwave: expanding distortion sphere + optional **condensation shell** (white translucent sphere, 2–3 frames, only on humid presets / size > 0.6) · Crater decal + scorch ring · Destruction: radial impulse `J = 800·S³` N·s at center falling with 1/r² · Structural damage `D = 1000·S²` to destructibles within `k_dmg·S·2` |
| **POST** | Exposure +1.0 EV for 1 frame then fast recovery · CA pulse 0.004 · radial blur 0.03 only if d < R_dmg · screen dust sprites & debris particles in front of camera if d < 1.5·R_dmg |
| **CAMERA** | **High-frequency hard shake** (noise freq 20–25 Hz) with trauma up to 1.0 close; FOV punch **inward** (-3°, the "slap") then back; for 3PS add positional shove away from blast |
| **GAMEPLAY** | High pressure damage, fragmentation (line-of-sight rays), **highest structural damage**, AI suppression/panic radius 3·k_dmg·S |

Coefficients: `k_fb = 1.1`, `t_fb = 0.9·(M^0.25)/S … use p = 0.75`, `k_sh = 6.0`, `k_dmg = 2.0`.

### 9.6 Explosion timeline (all presets; times × preset speed)
| Time | HE (military) | Gas | Gasoline |
|---|---|---|---|
| −150 ms | – | air rush (big) | – |
| 0 | flash + crack | soft flash (ramping) | rupture pop |
| 0–50 ms | shock ring, fragments | flame volume fills cloud | – |
| 60–120 ms | dirt geysers, debris launch | whump peak | **fireball ignition + WHOOMF** |
| 0.2–1 s | dust column rising, light gone | pale cloud billowing | fireball climbing & rolling, orange light |
| 1–3 s | debris rain, grey smoke | cloud lingers, jets burning | soot column forming, embers |
| 3–60 s | smoke thins | haze thins | **black column + burning pool + crackle** |

---

## 10. Global layer details

### 10.1 Camera: trauma model
Use the well-known *trauma* approach (shake = trauma², sampled from smooth noise, rotation-first):
```ts
trauma = clamp01(trauma + event.trauma)          // add per event (budget-capped)
trauma = max(0, trauma - decay * dt)              // decay 1.5–2.5 /s
shake  = trauma * trauma * userShakeScale         // squared -> small events stay subtle
pitch  = maxPitch * shake * noise(seed+0, t*freq)
yaw    = maxYaw   * shake * noise(seed+1, t*freq)
roll   = maxRoll  * shake * noise(seed+2, t*freq)
// FPS: maxPitch 4°, maxYaw 4°, maxRoll 6°; freq from event (explosion HE 22 Hz, gas 8 Hz, gun 15 Hz)
```
Frequency blending: keep a weighted-average `freq` from active contributors.
**Accessibility:** `userShakeScale` 0–1 slider; `reduceFlashes` toggle (caps exposure bumps at +0.2 EV); `hitmarkerVisual` toggle.

### 10.2 Post stack order
`Scene (PBR + SSAO + SSR)` → `Heat distortion` → `Exposure (with bump)` → `Bloom (low, chunky)` → `Color grade (damage desat, fire warmth)` → `CA pulse` → `Radial blur (rare)` → `Vignette` → **PSX pass** (downsample → color quantize → ordered dither → nearest upscale) → `UI`.
The PSX pass goes *after* all juice so pulses also get dithered/quantized (keeps the look coherent).

### 10.3 Audio mix
- Buses: `PlayerWeapon` (highest priority, never ducked), `Impacts`, `Explosions`, `NPCWeapons`, `World`, `Music`, `UI`.
- Sidechain: `PlayerWeapon` & `Explosions` duck `World`/`Music` by 3–9 dB, attack 5 ms, release 250–600 ms.
- Voice limits: player weapon tails 2, NPC weapon voices 12 (distance-prioritized), impacts 16, explosions 4 full + rumble layer.
- **Close-blast hearing loss** (HE within 1.5·R_dmg, gas/gasoline within 0.8·R_dmg): world bus low-pass 900 Hz ramping back to open over 2–4·S s + tinnitus tone 3.5 kHz at -18 dB fading out. Player weapon bus low-passed too (half strength).
- Environment probe (raycasts every 200 ms): selects `tail_indoor/outdoor/tunnel` and reverb send; outdoor adds a slap-back delay from nearest large surface.

---

## 11. Perceived-PSX treatment (on a modern renderer)

**Keep modern:** PBR materials, dynamic lights, SSAO, SSR, HDR exposure. The contrast between crunchy assets and *correct* light is the style.

| Area | Rule |
|---|---|
| Render target | Internal 480×270 … 640×360 (16:9), nearest-neighbor upscale; viewmodel rendered in the same low-res target (or 1.0–1.5× for legibility). |
| Color | Quantize to 15-bit (5-5-5) after grading; 4×4 Bayer ordered dither before quantize. |
| Geometry | World/NPC vertex snapping in clip space (grid ≈ internal res); **viewmodel snap at half strength** (jitter on the gun is distracting). Optional affine texture warp on world only, off for viewmodel. |
| Textures | 64–256 px, point sampling, no or limited mips; posterize source textures (~15–16 levels). PBR maps at the same low res. |
| FX sprites | Flipbooks 64–128 px per frame, 8–16 frames, **point-sampled**, played at **stepped 12–15 fps** (flip time quantized) while the sim runs at full rate; sprite quad vertices also snapped. |
| Transparency | Smoke/dust/blood mist: **dithered (screen-door) alpha** in the opaque pass → no sorting, no overdraw issues, reads as PSX. Fire, flashes, sparks: additive. |
| Debris | Low-poly meshes (6–40 tris), flat or 32 px textures; physics simulated normally. |
| Decals | 32–64 px, point sampled, snapped to the texel grid of the surface where possible. |
| Lights | Muzzle and explosion lights are real dynamic lights; allow them to show in SSR — puddles and polished floors reflecting a muzzle flash is a cheap wow moment. |
| Audio | Optional "console crunch": resample *body/tail* layers to 22.05–32 kHz and mild bit reduction; **keep transient and LFE clean** (punch lives there). Slight tape-style saturation on player weapon bus (fits the "distortion" players liked). |
| Animation | Viewmodel anims can be keyed on 2s (30 fps holds) for reload flourishes, but **recoil springs stay at full rate** (feel > look). |

---

## 12. Implementation order & tuning checklist

1. **Fire latency:** audio + muzzle + recoil on F0. Measure input→sound < 1 frame.
2. **Audio layers** for one pistol and one shotgun (transient/body/mech/LFE/tails + randomization + env probe).
3. **Recoil springs** (viewmodel + camera), ADS scaling.
4. **Impact matrix** for CONCRETE, METAL, FLESH first; decals; enemy flinch + enemy-local hitstop.
5. **JuiceBudget + trauma camera + accessibility sliders.**
6. **PSX pass** (so all further FX are judged in-look).
7. Remaining weapons from recipes; suppressed variants; near-miss cracks.
8. **Explosion system** with `size01` → M → S; build HE first (simplest fire), then gasoline, then gas.
9. Mix: buses, ducking, hearing loss.
10. Polish pass with the tests below.

**Acceptance tests**
- A/B each gun with *audio off*: can you tell guns apart by feel/visuals alone? And *visuals off*: by sound alone? Both must be yes.
- 30 s full-auto at a wall: no audio fatigue (no audible repeating sample), crosshair region stays readable.
- Shotgun into 5 enemies: ≤ 1 combined impact sound per pattern per surface, framerate stable.
- Explosions at `size01` = 0, 0.25, 0.5, 0.75, 1 side by side: each looks like the *same kind* of event at a different scale; tier swaps are not jarring.
- Explosion at 200 m: flash first, shake/sound arrive ~0.6 s later.
- Shake slider at 0: game remains fully readable and still feels punchy (proves audio/viewmodel carry the feel).

---

## 13. Data schemas (copy into code)

```ts
interface SoundLayer { clips: string[]; gainDb: number; pitchJitter: number; gainJitterDb: number;
                       delayMs?: number; bus: string; spatial: boolean; playerOnly?: boolean }

interface WeaponDef {
  id: string; era: 'CLASSIC'|'MODERN'; muzzle: 'BARE'|'SUPPRESSED'|'BRAKE'|'FLASH_HIDER';
  caliber: CaliberClass; subsonic?: boolean;
  handling: { rpm: number; pellets?: number; spreadHipDeg: number; spreadAdsDeg: number;
              vmKick: { pitch: number; yaw: number; roll: number; up: number; back: number };
              camKickDeg: number; recoverFrac: number; spring: { k: number; c: number };
              adsTime: number; adsVmScale: number; adsCamScale: number; recoilPattern?: [number, number][] };
  gunLocal: {
    sound: { transient: SoundLayer; body: SoundLayer; mech: SoundLayer; lfe: SoundLayer;
             tails: { indoor: SoundLayer; outdoor: SoundLayer; tunnel: SoundLayer };
             shell?: SoundLayer; lowMag?: SoundLayer; dry: SoundLayer; reload: Record<string, SoundLayer> };
    particles: { smokeWisps: number; smokeLife: number; sparks?: number; shellMesh?: string; barrelSmokeAfter?: number };
    vfx: { flashSize: number; flashFrames: number; petals: number; flashVariants: string[];
           light?: { radius: number; kelvin: number; frames: number }; tracerEvery?: number };
    post: { exposureEv: number; everyNthShot?: number };
    camera: { trauma: number; fovPunchDeg?: number; shakeFreq?: number };
  };
  impact: { caliberScaleOverride?: number; knockbackKill: number; hitstopFrames: number; gibRange?: number };
  global: { aiNoiseRadius: number; worldTimeDip?: { scale: number; ms: number; condition: 'multikill'|'heavykill' } };
}

interface ExplosionDef {
  id: 'GAS'|'GASOLINE'|'HE';
  k_fb: number; t_fb: number; p: number; k_sh: number; k_dmg: number;
  colors: { flashKelvin: number; fireRamp: string[]; smokeRamp: string[] };
  layers: { flash: object; shock: object; fireball: object; smoke: object; debris: object;
            embers: object; groundMark: object; light: object; sound: Record<string, SoundLayer>;
            camera: { trauma0: number; freq: number; fovPunchDeg: number }; post: object; gameplay: object };
  tiers: { small: string[]; medium: string[]; large: string[] }; // asset set ids, thresholds 0.2 / 0.6
}
```

---

## 14. Giving guns character (checklist per weapon)
1. **One signature sound** that no other gun has (revolver cylinder, en-bloc ping, double-barrel shell pop, pump rack, suppressor slide clack).
2. **One signature motion**: wrist flip, shoulder punch, bolt throw, break-open, a specific overshoot curve.
3. **A frequency lane**: pistol = high-mid snap, rifle = mid crack, shotgun = low-mid boom, HE = sub. Avoid two guns in the same lane.
4. **A rhythm**: tap-tap / brrrt / boom…rack / BOOM…ritual.
5. **A flaw** with feel: slow pump, long reload, heavy settle, can't ADS while pumping. Flaws make strengths felt.
6. **Material honesty**: polymer rattles, wood creaks, steel rings. PBR roughness wear shows it.
7. **An idle/inspect beat**: the gun is a character on screen 100% of the time.
8. **Don't front-load:** the starter gun should be good but not the best-*feeling*; save the heaviest feedback for later weapons.

---

## Sources
- [Creating Call of Duty: Modern Warfare's sound — A Sound Effect (2019)](https://www.asoundeffect.com/call-of-duty-modern-warfare-sound/)
- [Activision: Weapon sounds in CoD: Modern Warfare](https://blog.activision.com/call-of-duty/2019-07/Modern-Warfare-Initial-Intel-Creating-an-Orchestra-of-Incredible-Audio-Effects-Weapon-Sounds-in-Call-of-Duty-Modern-Warfare)
- [Splice: How to design a weapon sound for video games](https://splice.com/blog/design-weapon-sound-video-games/)
- [Arcella Sound: Modular AAA weapon sound design](https://www.arcellasound.com/post/aaa-weapon-sound-design-architecting-modular-combat-audio-for-xdev-pipelines)
- [Lin et al., features of impact feel in action games (UW)](https://faculty.washington.edu/zkwen/articles/lin22features.pdf)
- [GTFO discussion on screen shake](https://steamcommunity.com/app/493520/discussions/0/2747650363463917024/)
- [itch.io jam feedback on excessive shake & sound timing](https://itch.io/post/11045622)
- [ULTRAKILL "floaty guns" discussion](https://steamcommunity.com/app/1229490/discussions/0/6589424052366040738)
- [Doom Eternal hitmarker toggle discussion](https://steamcommunity.com/app/782330/discussions/0/3821922030303533387/)
- [ZDoom HitMarkers add-on](https://forum.zdoom.org/viewtopic.php?t=60356)
- [Brain Baking: The crazy shotguns in boomer shooters](https://brainbaking.com/post/2025/10/the-crazy-shotguns-in-boomer-shooters/)
- [TechRadar: Warhammer 40,000: Boltgun review](https://techradar.com/reviews/warhammer-40000-boltgun-review)
- [TechRadar: Trepang2 review](https://techradar.com/reviews/trepang2-review) · [SUPERJUMP: Trepang2 review](https://www.superjumpmagazine.com/trepang2-review/) · [NeoGAF Trepang2 thread](https://www.neogaf.com/threads/is-trepang2-any-good.1665012/)
- [SilencerCo: Video game silencer myths](https://silencerco.com/blog/silencing-myths/) · [Silent AF: Do suppressors make guns silent?](https://silentaf.us/blogs/do-suppressors-actually-make-guns-silent/) · [Hunt: Showdown suppressor discussion](https://steamcommunity.com/app/594650/discussions/8/3821914054517678654)
- [fxguide: Hurt Locker practical explosions](https://www.fxguide.com/fxfeatured/hurt_locker_special_effects_physical_bombs/) · [FotoKem VFX: explosion layers](https://fotokem.com/vfx/) · [Rebelway explosion references](https://www.rebelway.net/explosion-reference-footage/)
- [BLEVE fireball correlations (D = 5.8·M^⅓, t = 0.45·M^⅓)](https://midstreamcalculator.com/calculators/safety-relief/bleve-fireball.html) · [Gexcon: BLEVE fireball](https://knowledge.gexcon.com/docs/bleve-fireball) · [HExCAT fireball model (M^0.25)](https://image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/12213739)
- [David Colson: Building a PS1-style renderer](https://www.david-colson.com/2021/11/30/ps1-style-renderer.html) · [MenacingMecha: Godot PSX style demo](https://menacingmecha.itch.io/godot-psx-style-demo) · [RetroPSX URP](https://github.com/Natteens/retropsx-urp) · [N2H: Let's Go Retro VFX breakdown](https://n2h-games.itch.io/stealth-game-prototype/devlog/849811/vfx-breakdown-lets-go-retro)
- Trauma-based camera shake: Squirrel Eiserloh, "Math for Game Programmers: Juicing Your Cameras With Math", GDC 2016.
