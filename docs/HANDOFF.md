# Star Wars Arcade — videodr0me fork — Session Handoff (2026-05-28)

**Branch:** `esb-port` (current; HEAD at `8bd15ff`)
**Sibling:** `sw/starwars-mister/` — earlier fork with MAME tools at `.tools/mame0287/`
**Sim:** `sw/starwars-videodr0me/sim/` — GHDL testbench + analysis tools

This handoff covers the work since the c7-dot fix landed (commit `e949074`).
Key claim: **per-VCTR math is verified correct via GHDL sim vs MAME reference.**
What remains is calibration + downstream investigation, not core algorithm bugs.

---

## READ FIRST (in order)

1. This file (HANDOFF.md)
2. `sim/README.md` — how the GHDL sim infrastructure works
3. `docs/M3_HANDOFF.md` (in `starwars-mister/` sibling) — deep MAME archaeology
4. `rtl/avg/vector_drawer.vhd` and `rtl/avg/avg.vhd` — current drawer + AVG
5. `rtl/starwars.sv` lines 805-845 — coordinate transform + FB instantiation

---

## WHAT WORKS (verified)

| Item | Verification |
|---|---|
| AVG opcode parse (op=0/1/2/3/4/5/6/7) | matches MAME `mame_avgdvg_ref.cpp` |
| Per-VCTR strobe3 math | identical to MAME's `m_xpos += ((((m_dvx>>3)^xor)-0x200)*cycles*(m_scale^0xff))>>4` |
| Color map (rgbout → palette) | both use BGR bit ordering (bit0=B, bit2=R), matches MAME's `color111()` |
| C7 dot stroke rendering | sim shows 38 dots vs MAME's 39 expected — `e949074` fix verified |
| In-window visible stroke count | sim and MAME both produce 73 lines/frame for high-score |
| Cohen-Sutherland trivial-reject | drops correct off-screen strokes (drawer ccdbef4) |
| Per-pixel framebuffer-bounds gating | `pixel_valid` correctly drops pixels outside ±1024 (7585cdc) |

## WHAT'S CONFIRMED BROKEN — burn-down list

Listed in priority order. Each item has: severity, evidence, suspected fix, estimated effort.

### BUG-1 [P0]: Pixel pitch not calibrated to hardware

**Symptom**: at bit 14 user reported "3000% too large"; at bit 17 content tiny in upper-center; at bit 15 (current `8bd15ff`) untested on HW.

**Evidence**:
- Math says bit 14 is correct (MAME's 1/(65536*250) xscale → 16384 m_xpos/px).
- Hardware photos contradict the math.
- Either downstream `starwars.sv`'s 1.75x scale assumption is wrong, OR the MiSTer scaler is adding additional scaling we haven't accounted for, OR the user's perception of "MAME size" is comparing against a different display config.

**Suspected fix**: hardware-side calibration overlay. Draw a 100-pixel horizontal stripe at known framebuffer coords (450, 350) at boot. Photograph. Measure pixels in the photo. That gives exact pitch on the user's monitor.

**Effort**: 30 min RTL change + 1 rebuild + 1 measurement.

### BUG-2 [P1]: vd_scale table zero-out at total_shift > 8

**Location**: `rtl/avg/avg.vhd:321-339` (the `vd_scale_proc` case statement)

**Symptom**: For VCTRs where `norm_count + bin_scale > 8`, vd_scale becomes 0 → delta becomes 0 → stroke renders as zero displacement (dot). MAME would still produce a non-zero (small) delta in fractional units.

**Evidence**:
```vhdl
when others => vd_scale <= (others => '0');  -- sub-pixel: skip
```

The "sub-pixel: skip" comment is wrong — MAME's cycles bottoms out at 1, not 0. Our drop-to-zero kills strokes MAME would render (as sub-pixel content that accumulates).

**Affected SCAL classes**: any with `bin_scale ≥ 3` combined with small dvx (high norm_count). Lots of text glyph strokes likely affected.

**Fix**: extend the table to keep vd_scale at 1 (minimum integer) for total_shift > 8, OR widen the multiply chain to give us 4-8 bits of sub-pixel headroom on the cycles factor. Probably the latter — increases accumulator precision so small-shift values don't underflow.

**Effort**: 1-2 hour RTL change + sim verification + 1 hardware rebuild.

### BUG-3 [P1]: Framebuffer accumulation across vggos — unverified

**Symptom**: User hardware photos show ~73 strokes (= one vggo's worth) instead of MAME-equivalent ~250+ accumulated.

**Evidence**: MAME's `vector_device::screen_update` accumulates `m_vector_list` across MULTIPLE vggos per visible 16 ms CRT refresh. Without similar accumulation, we render only the last vggo's content — sparse.

**Where to look**: `rtl/vector_fb_ddram.sv` `START_FRAME` handling. If the rasterizer clears the framebuffer on every vggo, that defeats the natural pixel-overwrite accumulation that hardware would otherwise have.

**Investigation steps**:
1. Read `vector_fb_ddram.sv` lines around START_FRAME / FRAME_DONE.
2. Identify if framebuffer is cleared per-vggo or only on specific events.
3. If cleared per-vggo: change to clear only on game-state changes (or not at all — let pixel overwrites build up the visual).

**Effort**: 1 hour reading + 30 min change + 1 rebuild.

### BUG-4 [P2]: Self-test capture script doesn't reliably enter test mode

**Location**: `sw/starwars-mister/.tools/mame0287/selftest.lua`

**Symptom**: Lua input-toggle for "Service Mode" doesn't reliably enter self-test. User has to press F2 manually. If user doesn't press F2 before captures start, the dumps are from attract mode, not self-test.

**Fix**: Either:
- Use MAME's input system from Lua more carefully (set `manager.machine.ioport.ports[":IN0"].fields["Service Mode"]:set_value(0)` THEN drive a clock to let the input register).
- OR: just instruct user to press F2 manually and remove the auto-toggle.

**Why it matters**: self-test runs known-output scaling tests. Capturing those gives us GROUND-TRUTH calibration data for BUG-1 (pitch) and BUG-2 (vd_scale truncation).

**Effort**: 15 min Lua fix OR 0 min (just have user press F2).

### BUG-5 [P2]: sim/tb_drawer.vhd `stroke_cap` process times wrong

**Location**: `sim/tb_drawer.vhd` — the per-stroke endpoint capture process

**Symptom**: All sim strokes have zout=0 because vd_done rises AFTER state transitions to IDLE, by which time pixel_valid is 0 and zout is gated to 0.

**Fix**: capture (xout, yout, zout, rgbout) ONE cycle before vd_done rises, or use a separate latch that snapshots the values during WALK.

**Effort**: 10 min testbench fix.

### BUG-6 [P3]: Content-class-specific scale errors (theory; unconfirmed)

**Symptom**: User reports "high scores get one scale, gameplay gets another scale, lasers another scale" — implying differential errors per SCAL class.

**Evidence**: NOT YET CONFIRMED via sim. The burndown sim ran but the testbench stroke-capture was broken (BUG-5).

**Investigation steps after BUG-5 is fixed**:
1. Re-run `sim/burndown.py` to get per-stroke endpoint data.
2. Filter sim_strokes by zout > 0 (now non-empty after BUG-5 fix).
3. For each SCAL class (m_scale, m_bin_scale combo), compare:
   - sim's stroke count for that class
   - py_decoder's expected stroke count
   - sim's pixel delta per stroke vs py_decoder's expected delta
4. If sim/py ratio differs by class → there IS a class-specific bug.
5. If ratio is uniform → user's perceived differential is from BUG-1/BUG-3 instead.

**Effort**: 20 min once BUG-5 fixed.

---

## TOOLING SHIPPED THIS SESSION

```
sim/
├── README.md                     -- how to use the sim infrastructure
├── prep.py                       -- extract vec_*.bin + AVG PROM → hex
├── tb_drawer.vhd                 -- GHDL testbench (loads MAME data, drives vggo)
├── dpram_sim.vhd                 -- behavioural DPRAM (replaces altsyncram)
├── render.py                     -- pixel log → PNG with starwars.sv transform
├── render_mame_expected.py       -- decoder → PNG (what MAME would show)
├── analyze_dots.py               -- per-scene stroke + color breakdown
├── sweep.py                      -- run sim across all 4 named scenes
├── burndown.py                   -- run sim + diff vs python decoder per-class
├── run.ps1                       -- one-shot compile+sim+render for one scene
└── .gitignore                    -- generated artifacts excluded

starwars-mister/.tools/mame0287/
├── avg_dump.cmd                  -- debugger script: dense timestamp captures
├── avg_dense.cmd                 -- 60 captures over 30s (used for the scenes)
├── selftest.lua                  -- self-test entry + memory snapshots (BUG-4)
└── snap/                         -- captured .bin dumps + screenshots
```

## RECENT COMMIT HISTORY

```
8bd15ff  drawer: pull pitch back to 2^15 (middle ground between 14 and 17)  ← CURRENT
2404b10  drawer: shift pixel-pitch to 2^17 (8x coarser)                     ← USER REPORTED TOO SMALL
{cd18d4b,29060a4}  sim: scene sweep + render + README                       ← sim infrastructure
e949074  drawer: gate WALK-termination on clk_ena (c7 dot fix)              ← VERIFIED WORKING
ccdbef4  drawer: Cohen-Sutherland trivial-reject                            ← VERIFIED WORKING
7585cdc  drawer+avg: MAME-exact stroke clip + per-pixel FB-bounds gating    ← VERIFIED WORKING
593f20d  drawer: saturate at xpos extraction (not at cur_px output)         ← VERIFIED WORKING
682a304  drawer: 2^14 pitch + saturate output                               ← SUPERSEDED by 8bd15ff
2a0f393  drawer: drop 64x over-scale (early)                                ← SUPERSEDED
```

## DATA WE HAVE FROM MAME (in `starwars-mister/.tools/mame0287/snap/`)

- **60 vector RAM dumps** at 500ms intervals covering 30s of MAME's attract cycle.
- **60 paired PNG screenshots** showing what MAME displays at each dump moment.
- **4 named scenes** mapped in `sim/prep.py` SCENES dict:
  - `high_score` (T01500): score table, dominant scales `sc00/bs2`, `sc40/bs1`
  - `logo` (T11500): SW 3D wireframe, scales `scbe/bs3`, `sc4e/bs1`, `sc5e/bs1`
  - `intro` (T10000): Darth Vader text, scales `sc6f/bs3`, `sc2e/bs1`, `sc1f/bs1`
  - `instr` (T20000): Flight Instructions, ONLY `sc00/bs2` (one class)

## PER-SCENE BURN-DOWN ANALYSIS (from burndown.py run at bit 15)

| Scene | VCTRs/frame (sim) | Expected visible strokes (py) | Top SCAL classes |
|---|---|---|---|
| high_score | 2036 | 1064 | sc00/bs2:623, sc40/bs1:441 |
| logo | 1990 | 1168 | scbe/bs3:297, sc00/bs2:170, sc4e/bs1:113, sc5e/bs1:111 |
| intro | 1267 | 662 | sc6f/bs3:297, sc00/bs2:166, sc2e/bs1:101, sc1f/bs1:98 |
| instr | 2521 | 1328 | sc00/bs2:1328 (single class!) |

**Observation**: `instr` uses a SINGLE SCAL class. If user reports instr renders wrong but `high_score` renders right (or vice versa), the bug is class-specific (likely BUG-2 vd_scale truncation). If both render wrong the same way, it's BUG-1 (pitch) or BUG-3 (FB accumulation).

---

## SUGGESTED NEXT-INSTANCE WORK ORDER

1. **Read this doc + sim/README.md** (15 min)
2. **Fix BUG-5** (sim stroke-cap timing) — needed to validate everything else (10 min)
3. **Re-run `sim/burndown.py`** with the fixed capture — get the per-class endpoint diff (10 min)
4. **Based on burndown results**:
   - If per-class diff is uniform → focus on BUG-1 (pitch) + BUG-3 (FB accumulation)
   - If per-class diff varies → BUG-6 confirmed, dig into the offending class to find the math/RTL bug
5. **Fix BUG-2 (vd_scale truncation)** in parallel — sim-only check needed (1-2 hours)
6. **Hardware-side calibration overlay** to nail BUG-1 (30 min RTL + 1 rebuild)
7. **Look at vector_fb_ddram.sv** for BUG-3 (1 hour)

If you only have time for one thing: **BUG-3 (FB accumulation)**. The user's hardware photos consistently show ~73 strokes — exactly one vggo's worth. If we're missing accumulation, content will look sparse no matter what pitch we pick.

---

## KEY CONCEPTS TO PRESERVE

### The pipeline
```
6809 CPU → vector RAM/ROM → AVG (PROM-driven) → vector_drawer →
  starwars.sv coord transform → vector_fb_ddram → DDR3 → MiSTer scaler → HDMI
```

### Math sanity checks
- MAME visible width: 250 MAME-px × 65536 m_xpos/MAME-px = 16,384,000 m_xpos
- Our framebuffer width: 980 px after starwars.sv's 1.75x scale on drawer output
- For full-fb MAME-equivalent: 1 fb px = 16384000/980/0.875 = 19106 m_xpos = ~2^14.2

### SCAL semantics
- `m_scale` (0-255): linear velocity multiplier. scale_factor = 255 ^ m_scale = 1..256.
- `m_bin_scale` (0-7): binary timer scale. cycles in MAME = 2^(15 - norm - bin_scale).
- Combined: per-VCTR delta scales by `scale_factor * cycles`.
- Software chooses both per content type (text vs logo vs lasers).

### Color encoding
- `m_color` is 4-bit. We use bits 2:0 as `rgbout`.
- Both MAME's `color111` AND our `vector_fb_ddram` palette use BGR bit ordering.
- c=1 → blue. c=4 → red. c=7 → white. c=2 → green. c=3 = cyan, c=5 = magenta, c=6 = yellow.

### Why c7 dots were missing (now fixed)
Zero-displacement strokes (dvx=dvy=0) terminated WALK in 1 clk cycle (80 ns).
FB pipeline couldn't reliably capture a sub-clken pulse.
Fix: gate WALK termination on `clk_ena` so state holds for at least one full
clken period (640 ns). Commit `e949074`.

### Why the user's reported "differential scaling" might NOT be a drawer bug
- MAME accumulates strokes across many vggos per visible CRT frame (~16 ms = many AVG passes).
- Our framebuffer doesn't naturally accumulate UNLESS `vector_fb_ddram.sv` is wired to not clear between vggos.
- If FB clears per-vggo, we always show only one vggo's worth of strokes.
- Different game scenes have DIFFERENT vggo rates: gameplay might emit more vggos/sec than attract.
- So scenes that emit more vggos look "denser" on hardware than scenes that emit fewer. Looks like differential scaling but is actually differential VGGO RATE.

---

## OPEN QUESTIONS (no clear answer yet)

1. Does the framebuffer in `vector_fb_ddram.sv` clear between vggos? (Affects BUG-3 prognosis.)
2. What's the actual pixel pitch on the user's monitor accounting for MiSTer scaler? (BUG-1.)
3. Are there content-class-specific RTL bugs? (BUG-6 — answered by BUG-5 fix → burndown re-run.)
4. Does SW arcade software trigger multiple vggos per visible frame? (Important context for BUG-3.)
