# Vector-CRT aesthetic pipeline (VIS) on Star Wars / ESB / Tempest — plan

**Status:** planned. Gate on ESB gameplay being confirmed solid first
(project rule: razor-sharp → clock-correct → **pretty third**).
**Goal:** beam-overlap vertex brightening + soft bloom glow + phosphor
persistence on the SW/ESB core — and, by construction, on Tempest later.

This is the "pretty" pass the user has wanted since the start. Two specific
asks drove it: (1) additive brighter pixels where vector beams converge at
corners/vertices, (2) reuse the bloom work from the Black Widow VIS sessions.

---

## The reusable asset: Black Widow VIS pipeline (hardware-validated)

`D:\deck\fpga\vis\workdir-bw\` is a complete vector-CRT post-FX pipeline,
already on hardware. It is the single most valuable thing to pull from.

**Architecture (RGB565, multi-channel DDR3):**

| Channel | Purpose |
|---|---|
| `ch0` | Phosphor decay walker — sweeps FB ~every 30 ms, decays each pixel unless its "freshness" bit is set |
| `ch1` | AVG pixel writer — **read-modify-write**, merges each paint into its DDR3 word slot without stomping the other 3 pixels |
| `ch2` | Bloom — H-pass → V-pass Gaussian → energy-preserving composite, continuous |

**DDR3 layout** (`0x30000000`): main FB 512×512×16bpp RGB565 (blue LSB =
freshness marker) + ¼-res bloom_h / bloom_v / composite buffers.

**Milestone status (from workdir-bw README):**
- VIS-1 Wu anti-aliased drawer — ✅ hw
- VIS-2a DDR3 FB + fb_writer + dual-channel ddram — ✅ hw
- VIS-3 phosphor decay walker (freshness bit, single-word RMW) — ✅ hw
- VIS-4 M1-M4 bloom (¼-res 5-tap Gaussian H+V + energy-preserving cross-add
  composite `out = sharp + α·max(0, blurred − sharp)`) — ✅ verified
- VIS-4 M5 OSD bloom-intensity selector — ⏳ next
- VIS-5 barrel distortion (HDMI scaler) — ⏳ planned (papers archived)

**Key design choices already settled (don't relitigate):**
- Freshness marker in blue LSB: paint ORs `16'h0001`; walker tests bit 0
  ("just painted, don't decay yet"). Decouples decay rate from flicker.
- fb_writer is RMW, not append-and-flush (the v1 accumulator stomped text
  strokes + diagonals; v2 RMW fixed it).
- Energy-preserving cross-add: only adds light *to* a pixel from brighter
  neighbors — no halation on bright elements, no widening of dark trails.
- Bloom at ¼-res (128×128, 5-tap stride-4 Gaussian = ~16px effective kernel):
  real beam-spot halos at tractable DDR3 bandwidth.

---

## The key realization: overlap is a one-line change in the RGB pipeline

The user's #1 ask — **additive brightening where beams converge** — is trivial
*if* we're on the BW VIS RGB framebuffer:

- BW `fb_writer` ch1 already does RMW and currently **OR-merges** the new pixel
  into the existing word.
- Change OR-merge → **saturating-ADD** (per RGB565 channel, clamp at max).
- Now two beams crossing the same pixel add their light → bright vertex node.
  Two *different-colored* beams add → physically-correct color-mix (red+blue →
  magenta-ish, clamped). The current SW/ESB 8bpp indexed FB **cannot** do this
  color-mix — another reason RGB is the right substrate.

So overlap + bloom + phosphor are all the *same* port: bring the BW VIS RGB
multi-channel FB onto SW/ESB, then overlap is OR→add, bloom and decay are
already built.

---

## The architecture fork (decided: port the RGB VIS FB)

| | Incremental (keep indexed FB) | **Port BW VIS RGB FB (recommended)** |
|---|---|---|
| Overlap | add RMW to `vector_fb_ddram`; intensity-add only, **no color-mix** | OR→saturating-add in fb_writer; **full color-mix** |
| Bloom | build a new RGB bloom pipeline from scratch | **already built (VIS-4)** |
| Phosphor | build new | **already built (VIS-3)** |
| Color fidelity | limited (8bpp palette) | RGB565, native |
| Risk | medium (new RMW + new bloom) | medium (FB swap), but reuses proven RTL |
| Benefits | SW+ESB | SW+ESB+Tempest (all vector cores) |

**Decision:** port the BW VIS RGB multi-channel framebuffer to replace
`vector_fb_ddram.sv` on SW/ESB. It brings all three effects, uses
hardware-validated RTL, and gives proper color — which SW/ESB/Tempest all need.

### What has to change vs the BW VIS baseline

- **Resolution**: BW VIS FB is 512×512. SW/ESB is 980×700. Scale the main FB
  (980×700×16bpp ≈ 1.37 MB) + the ¼-res bloom buffers (245×175). Check DDR3
  budget (HPS region has room; current indexed triple-buffer uses ~2.1 MB).
- **AVG→RGB565**: the drawer currently outputs `{color[2:0], intensity[4:0]}`
  (palette index). Feed the AVG color+intensity into RGB565 directly instead
  (color picks R/G/B channels, intensity scales). For ESB/Tempest this is the
  same color path — and Tempest's color RAM maps cleanly to RGB565.
- **MISTER_FB format**: switch from 8bpp-indexed (`FB_FORMAT=00011`) to RGB565
  (`FB_FORMAT` per sys_top, and drop the palette write logic).
- **Triple-buffer vs walker**: BW VIS uses a single FB + decay walker (no
  triple buffer). This *also subsumes the ESB flicker/accumulation work* — the
  walker model accumulates naturally and decays, which is closer to real CRT
  behavior than the triple-buffer swap. Reconcile with the current per-frame
  swap (the BW model may simply replace it).
- **Multi-channel DDR3 arbiter**: port `ddram.v` (BW VIS version) with ch0/ch1/
  ch2, replacing the single-channel `vector_fb_ddram` DDR3 path.

---

## Phased plan (after ESB gameplay confirmed)

**VIS-0 — port the RGB multi-channel FB**
- Bring BW VIS `ddram.v` (multi-channel) + `fb_writer.sv` (RMW) into the
  SW/ESB core, scaled to 980×700 RGB565. Feed AVG color+intensity → RGB565.
- Switch MISTER_FB to RGB565; drop the indexed palette path.
- Gate: SW renders in RGB565 at parity with the current indexed output.

**VIS-1 — beam-overlap brightening (the #1 ask)**
- fb_writer OR-merge → per-channel saturating-add. Convergence pixels brighten;
  colored crossings mix. Tune the add weight.
- Gate: vertex nodes visibly brighter than line midpoints (the reference
  photo of real SW silicon shows this on every wireframe corner).

**VIS-2 — phosphor decay (persistence trails)**
- Port the ch0 decay walker + freshness-bit (blue LSB OR on paint).
- Gate: moving vectors leave a short, tunable trail; static content stable.

**VIS-3 — bloom**
- Port ch2 (¼-res Gaussian H/V + energy-preserving composite). Display from
  the composite buffer.
- Gate: bright elements glow; thin lines stay sharp.

**VIS-4 — OSD selectors**
- Bloom intensity (Off/Subtle/Standard/Heavy) + decay/trail length + overlap
  weight, as OSD options (extend the existing CONF_STR).

**VIS-5 — barrel distortion (optional, later)**
- HDMI-scaler-stage curved-glass warp (papers in `vis/`). Note: this overlaps
  the separate `vis_warp` framework work — coordinate, don't duplicate.

---

## Why this benefits all three games at once

The VIS pipeline sits downstream of the AVG (operates on the rasterized FB),
so it is game-agnostic. Port it once onto the shared FB and SW, ESB, and
Tempest all get overlap + bloom + phosphor. Tempest especially is a showcase
(the tube + the dynamic color cycling under bloom).

## Sequencing / risk notes

- **Gate on ESB working.** Don't start VIS-0 until ESB gameplay is confirmed
  (audio/freeze fix tested, bank2 alt-page if needed). Pretty is third.
- **The FB swap is the risky step** (replacing the triple-buffer indexed FB
  with the RGB multi-channel + walker). Validate SW still renders before
  layering effects. Keep the indexed FB on a branch as fallback.
- **DDR3 bandwidth** is the real constraint (walker + RMW writer + bloom all
  contend). BW VIS proved it works at 512×512; re-check the budget at 980×700.
- Reuse the sim-first discipline where possible: the AVG→RGB565 mapping can be
  modeled/rendered in Python (extend the existing render_*.py tools) before HW.
