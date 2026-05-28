# Star Wars Arcade — Videodr0me-baseline Fork — Session Handoff

**Date:** 2026-05-27
**Branches:** `esb-port` (current; includes prom-driven-avg + ESB scaffold + drawer rewrite)
**Strategic context:** see `docs/M3_HANDOFF.md` (8 sessions of MAME archaeology on the prior `starwars-mister` fork).

This is the handoff after the major architectural pivot: using Videodr0me's working playable core as the baseline and layering in our distinct contributions on top.  Star Wars is rendering on real MiSTer hardware; ESB scaffold staged; next-priorities are frame rate + visual polish + sound validation, then ESB integration.

---

## WINS

### W1 — Playable SW core with MAME-faithful PROM-driven AVG

Our AVG implementation replaces Videodr0me's "ToDo: use the ROM" BW-hardcoded FSM with a byte-for-byte port of MAME's `avg_starwars_device` (`docs/mame_avgdvg_ref.cpp` lines 430-934).  It reads the actual 256x4 silicon state PROM (`136021-109.4b`, CRC `82fc3eb2`) loaded at dn 0x11000-0x110FF.

**Verified on hardware (2026-05-27):**
- Boot through main CPU + mathbox + AVG without crashes.
- Attract sequence advancing through game states (state 0 → 11 → 12 → ...).
- **High scores screen** renders pristinely.  All text glyphs sharp (red "SCORE / PRINCESS LEIA'S REBEL FORCE", blue score list, green copyright, yellow "1 COIN 1 PLAY").
- **STAR WARS logo** renders recognizably — 3D wireframe title + "PULL TRIGGER TO START / 2 CREDITS" prompt.
- Coin input works (counter incremented to 2 CREDITS).
- Starfield renders correctly (small short vectors at low intensity → 1-pixel dots).

### W2 — Eight latent bugs found via MAME cross-check

All from the previous `starwars-mister` fork, now baked into our PROM-driven AVG:

1. **mc6809 DEC/INC V-flag bug** — Grabulosaure core set V=1 on $00↔$FF wrap incorrectly.  Fix: explicit "input was $80 / $7F" check.  Upstream-able to Grabulosaure mc6809.
2. **vd_done handshake** — AVG must wait for drawer completion before fetching next instruction.  MAME does this implicitly via cycle scheduler; FPGA needs explicit sync.  3-state machine: W_IDLE / W_JUST_STARTED / W_DRAWING.
3. **prom_addr[7] = ~m_halt** (MAME line 1234) — state_latch's halt bit wires from m_halt every iteration.  Original scaffold stored bit 4 but never set it, so AVG walked past HALT.
4. **handler_4 normalize** — constant-deflection-speed shifting math (MAME lines 510-522).  Combinational 16-iter shift.
5. **int_latch=0 still steps beam** — MAME handler_7 always advances; intensity=0 is downstream gate.  Was incorrectly snap-to-origin.
6. **Full 4-bit m_color** carried through pipeline.  Adapted to Videodr0me's 3-bit RGB output at the entity boundary.
7. **handler_3 dvx[12] = m_data[4]** — sign bit lives in int_latch[0] which equals m_data[4].  Cross-checked.
8. **m_timer math folded into vd_scale** — MAME's `cycles = 2^(15-norm-bin_scale)` multiplier captured via `total_shift = norm_count + bin_scale` in the scale decode (no m_timer register needed).

### W3 — Silicon-faithful vector drawer (rewrite)

Replaced BW heritage discrete-time accumulator drawer with **analytic endpoint + Bresenham walker** matching real silicon's DAC integration model:

- **One multiply per VCTR**: `delta = SIGNED(rel) * UNSIGNED(256-linear_scale) * (scale*4)`.  Direct port of MAME's `avg_common_strobe3` formula.
- **Bresenham pixel walk** at clken (1.5 MHz, matching real silicon's DAC step rate).
- **34-bit sub-pixel accumulator** preserved across vectors (no inter-vector drift).
- **Endpoint snap** at end of walk — exact arithmetic, not iterative approximation.

Frame budget at this design: ~max(|dx|, |dy|) clken ticks per vector.  Typical SW logo glyph 20-50 px = 13-33 µs/vector.

### W4 — Cherry-picks: drawer, POKEY, A6532, TMS5220, slapstic (ESB)

From Videodr0me's repo (his improved drawer was the M3 starting point; his POKEY has poly5 LFSR fix + audio clip removal; his A6532 + TMS5220 are MAME-derived).  From d18c7db's `Gauntlet_FPGA`: SLAPSTIC.vhd for ESB (supports type 101).  Cliff Koch's 1996 ESB conversion doc as cross-reference.

### W5 — ESB scaffold staged

`docs/ESB_PLAN.md`, `docs/ESB_INTEGRATION.md`, `docs/esb-conversion-cliff-koch-1996.md`, `releases/Empire Strikes Back.mra`, `rtl/slapstic.vhd`, files.qip entries.  Not yet built as ESB; build still produces SW.  See ESB section below.

---

## LOSSES

### L1 — Frame rate slow (1-2 fps observed)

Even with the analytic-endpoint Bresenham rewrite, frame rate is sluggish.  Real silicon does ~60 fps with the same vector count.  Cause is not yet pinpointed:
- Bresenham per-pixel walk at 1.5 MHz is fundamentally bounded by `max(|dx|, |dy|)` per vector.  For 1024-px cockpit grid lines: 680 µs per vector × 20 lines = 13.6 ms just for the grid.  Plus ~200 logo vectors at average ~50 px = 6.6 ms.  Total ~20 ms = 50 fps theoretical.
- Observed: ~1 fps, suggesting either (a) drawer is taking >>20 ms/frame, or (b) AVG is dispatching more vectors than expected (possibly looping/not properly halting), or (c) the vd_done handshake adds significant overhead per vector.

### L2 — Vector wobble (logo wireframe)

The 3D STAR WARS logo has visible misalignment: line endpoints overshoot/undershoot, corners don't meet cleanly.  Text glyphs in high-score table render pristinely.

**Cause identified, fix in flight:**
- Bresenham `err` signal in `WALK` state had a double-update bug (two `err <= ...` writes in same cycle, last-assignment-wins drops the X-axis update on diagonal vectors).  Fix landed in commit `da3a28a`: use a VARIABLE `err_var` for intermediate updates, single signal write at end.
- Additional width fix landed in commit `0820567`: `delta_22 → delta_23` (signed 13×10 = 23-bit, not 22).

The wobble should clear up after the user pulls these fixes and rebuilds.

### L3 — Vector vertex brightening not implemented

Real silicon's CRT phosphor at line intersections is excited TWICE → brighter pixel at corners.  Our framebuffer writes overwrite, so corners are no brighter than line midpoints.

Tracked as task VTX-1.  Implementation: change `vector_fb_ddram.sv` pixel write from OVERWRITE to SATURATING-ADD.  Same-pixel writes from multiple vectors accumulate brightness.  This is Videodr0me's "Known Limitation" #4 (Beam Overlap, not modeled) — addressing it is a clean upstream PR opportunity.

### L4 — Audio status: not yet validated

We instantiated audio_cpu + 4× POKEY + RIOT + TMS5220 in the prior `starwars-mister` fork, but Option D pivoted to Videodr0me's already-working audio chain.  His audio works on his published RBF; integration into our PROM-driven AVG build is presumed working but not explicitly validated.

User noted "no sounds" on an earlier build (likely the prior `starwars-mister/playable/option-d` build, where audio was being snooped from main CPU's $4400 writes — and main CPU was stuck in the AVG-broken boot path).  With the AVG now producing real attract-mode geometry, main CPU should be writing real sound commands to $4400, and Videodr0me's audio chain should be playing.  **Needs hardware confirmation: turn up audio + listen during attract.**

### L5 — Build width errors recurring

Quartus error 10344 fired twice on width mismatches in the new drawer.  Both fixed:
1. `scale_15s` declared 15-bit but assigned a 17-bit concat (commit `da3a28a`).
2. `delta_22` truncating a 23-bit multiply product (commit `0820567`).

If a third width error fires on rebuild, it's likely the multiply chain's final product width vs 34-bit accumulator resize — easy fix; the structure is right.

---

## PROGRESS

### Branch tree (this fork)

```
* esb-port              — current; includes everything below + ESB scaffold
  prom-driven-avg       — drawer rewrite + width fixes (W3, L5 fixes)
  main                  — Videodr0me's original
```

### Commit log (esb-port branch, top-down)

```
0820567 vector_drawer: widen delta_22 → delta_23 (Quartus 10344 fix #2)
da3a28a vector_drawer: fix Bresenham err double-update + scale width error
4946423 vector_drawer: rewrite as silicon-faithful analytic endpoint + Bresenham
e9705ff avg: un-gate vector_drawer clk_ena for 8x frame rate (since reverted)
f079e40 docs: cite Cliff Koch's 1996 ESB conversion as cross-reference
27e9348 ESB scaffolding — slapstic + MRA + integration plan
4ff3efd docs/ESB_PLAN.md — Empire Strikes Back port plan (staged)
c2d6b68 PROM-driven AVG (improvement #1) ported from starwars-mister
6c0a11e Tweak PLL, outlatch -> PRNG reset, ce_1m5 gate latch  ← (Videodr0me's last commit)
```

### Validation timeline

| Date | Result | Photo evidence |
|---|---|---|
| 2026-05-27 (session start) | Black screen, OSD only | (no photo) |
| 2026-05-27 (after MRA swap to Videodr0me's) | Wireframe lines + green/blue + starfield, scaling broken | (chaos pattern photo) |
| 2026-05-27 (after Bresenham rewrite, first) | "STAR WARS" + Death Star + starfield + green grid lines, 1 fps, slowly scrolling | (logo-with-grid-lines photo) |
| 2026-05-27 (after drawer ungate hack) | Same content, ~8 fps, geometry slightly different | (not photographed in detail) |
| 2026-05-27 (after Bresenham proper rewrite) | High-score table PRISTINE, logo recognizable with wobble | (2 photos: HS table + logo) |

---

## NEXT-PRIORITY WORK

### N1 — Verify the latest drawer fix works (commit `0820567`)

User pulls `esb-port` branch HEAD, rebuilds, flashes.  Expected:
- Quartus 10344 errors gone (both width fixes landed).
- SW logo + high-score table render with sharper corners (Bresenham `err` fix).
- Frame rate may still be slow — that's L1.

### N2 — Fix frame rate (L1)

Hypotheses ranked by likely impact:

1. **AVG vector count blow-up** — our PROM-driven FSM might be dispatching more vectors per frame than expected (maybe not halting cleanly, maybe re-running attract code).  Diagnostic: add a vector counter, log to dbg port.
2. **vd_done handshake too conservative** — currently `W_JUST_STARTED → W_DRAWING → wait for vd_done=1` adds 1+ clken delay per vector.  Maybe collapsible.
3. **Long-vector domination** — cockpit grid lines are 1024 px = 680 µs each.  20 such lines = 13.6 ms.  Could we render long lines in fewer pixel steps?  e.g., walk at clk_12 (12 MHz) for long vectors, clken (1.5 MHz) for short.  Hybrid.
4. **Mathbox bottleneck** — our functional emulation might dispatch matrix programs more slowly than real silicon.  Diagnostic: profile mbx_busy duty cycle.

Recommendation: instrument first (option 1), don't blindly optimize.

### N3 — Fix vector vertex brightening (L3, task VTX-1)

`vector_fb_ddram.sv` pixel write: change from OVERWRITE to SATURATING-ADD.

```sv
// Inside the FB write path (pseudocode):
wire [7:0] fb_old = ddram_read_data;
wire [8:0] fb_sum = fb_old + new_pixel_intensity;
wire [7:0] fb_new = fb_sum[8] ? 8'hFF : fb_sum[7:0];  // saturate at 255
ddram_write_data <= fb_new;
```

Where 2 vectors cross or share endpoints, pixel intensity accumulates → bright vertex node.  Real CRT phosphor behavior.

### N4 — Sound validation (L4)

User listens during attract on next build.  If silent:
- Check Videodr0me's audio_cpu reset path — does it release after boot?
- Check soundlatch writes from main CPU at $4400.
- Check POKEY clock-enable (his is at ce_1m5 = 1.5 MHz).
- AUDIO_L/R routing in Arcade-StarWars.sv.

### N5 — ESB integration (tasks ESB-3, also gated on N1-N4 first)

Pre-staged in `docs/ESB_INTEGRATION.md`:
- `mod_esb` flag in Arcade-StarWars.sv (picked from ioctl_index=1 byte).
- Slapstic + bank2 wiring in starwars.sv (gated on mod_esb).
- Update dn_addr decoders for ESB layout.
- Test with `esb.zip` + the staged MRA.

Slapstic chip is d18c7db's MAME-derived implementation (rtl/slapstic.vhd, GPL-3, supports type 101 = ESB/Tetris).  Already in files.qip.

---

## CONTRIBUTIONS UPSTREAM-READY

After SW frame-rate + audio are clean, we can open PRs to Videodr0me's repo:

1. **PR #1: PROM-driven AVG** — addresses his explicit "ToDo: use the ROM" comment.  Same RTL renders Tempest, Major Havoc, Quantum by swapping PROM file.
2. **PR #2: mc6809 V-flag bug fix** — if his Cavnex 6809 has the bug.  (Need to verify; he uses different core.)
3. **PR #3: Empire Strikes Back support** — adds mod_esb + slapstic + ESB MRA.  Demonstrates the PROM-driven AVG's extensibility.  Cliff Koch 1996 reference doc cited.
4. **PR #4: Vector vertex brightening** — saturating-add framebuffer.  Addresses his "Known Limitation #4 — Beam Overlap not modeled."

---

## FILES TOUCHED THIS FORK

```
rtl/avg/avg.vhd                  ← replaced his BW-hardcoded with our PROM-driven
rtl/avg/vector_drawer.vhd        ← rewrote as silicon-faithful Bresenham
rtl/dpram.vhd                    ← imported from starwars-mister
rtl/slapstic.vhd                 ← imported from d18c7db, ESB type 101 supported
rtl/starwars.sv                  ← widened avg_dn_addr from 16→17 bits
files.qip                        ← added dpram + slapstic
releases/Empire Strikes Back.mra ← new ESB MRA
docs/ESB_PLAN.md                 ← scope + sequencing
docs/ESB_INTEGRATION.md          ← remaining integration work
docs/esb-conversion-cliff-koch-1996.md ← historical reference
docs/HANDOFF.md                  ← this file
```

---

## RESUME ENTRY POINT FOR FRESH SESSION

1. Read `docs/HANDOFF.md` (this file).
2. Read `docs/M3_HANDOFF.md` (in the sibling `starwars-mister/` fork) for deep MAME archaeology background.
3. `git checkout esb-port`.
4. Current state: `git log --oneline -10` shows the 9 commits ahead of Videodr0me's `main`.
5. Build: `quartus_sh.exe --flow compile Arcade-StarWars` from this repo root.
6. Test on hardware: copy `output_files/Arcade-StarWars.rbf` + `releases/Star Wars (Rev 2).mra` to MiSTer `_Arcade/`.
7. Pickup work: see "NEXT-PRIORITY WORK" section above, ranked by impact.

The architectural payoff (PROM-driven AVG that generalizes to ESB and other AVG-class games) is the SHIP.  Frame rate, sound, and vertex brightening are POLISH.  ESB is the SECOND TITLE that demonstrates the architecture.
