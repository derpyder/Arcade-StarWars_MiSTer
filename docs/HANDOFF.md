# Star Wars (Atari 1983) — SHIPPED. Now ESB.

**Branch:** `esb-port` @ `534f2cb` (pushed to `derpyder/Arcade-StarWars_MiSTer`)
**Hardware status:** stable on MiSTer with sound and clean frame rate. All scenes (attract, high-score table, gameplay, intro, instructions) render at MAME-equivalent fidelity.

This handoff retires the prior bug-list-driven handoff (b1649c3) and points the next instance at ESB.

---

## What landed

### Math fidelity (commit `6645f2a`)

Three bugs in the per-VCTR drawer math, all found by a Python diff between a faithful port of MAME's `avg_starwars_device` and a Python model of our HDL pipeline:

1. **SVEC opcode cycles** (`m_op=2` / OP1=1): MAME's `cycles = 2^(8 - total_shift)` vs the VCTR `2^(15 - total_shift)` — a 128× difference. Without compensation every short-vector glyph (= all small text) rendered at 128× MAME's size. This was the "3000% UI text" symptom. Fix: bump effective `total_shift` by 7 for SVEC in `vd_scale_proc`.
2. **scale_factor off-by-one**: MAME uses `m_scale ^ 0xff` (0..255); ours used `256 - m_scale` (1..256). Off-by-one drift, ~0.4% per stroke at `m_scale=0`, infinite ratio at `m_scale=255`. Fix: bitwise NOT.
3. **vd_scale truncation at total_shift > 11**: MAME keeps producing cycles 8,4,2,1 at ts=12..15; we zeroed out, dropping ~5% of strokes. Fix: pre-shift `rel_x`/`rel_y` by `(ts-11)` and use `vd_scale=1`.

Plus: pitch calibrated to `2^14` (matches MAME's coordinate system after the `starwars.sv` 1.75×/1.25× transform), `rel_x/y` now passed through `>>3` truncation at the AVG output to match MAME's `(m_dvx >> 3) ^ 0x200 - 0x200`, and `vd_scale` table widened 8× to absorb that.

**Verification:** `sim/diff_decoders.py` shows per-VCTR exact match (6522/6522 strokes, 0 divergence units) across all four captured attract scenes.

### What we tried and reverted

**BUG-3 vggo-aligned EOF wiring** (`79f320d`, reverted in `534f2cb`).

Theory was: `FRAME_DONE = avg_halted` swaps per-vggo and we should accumulate multiple vggos per CRT frame to match MAME's `vector_device` behavior. Wired `FRAME_DONE` to local-vblank-aligned `(vbl_pending && avg_halted)` instead. Plus a triple-buffer same-cycle race fix in `vector_fb_ddram.sv` for the new wiring.

**Hardware result:** 3-4 Hz black flash, constant but non-uniform.

Reverted both. Returns to Videodr0me's tested wiring (per-vggo swap). With the math fixes in place each vggo now produces correct content, so per-vggo swap looks fine — no accumulation needed because MAME-equivalent content is computed per stroke, not via cross-vggo overlay.

**Lesson preserved:** Videodr0me's triple-buffer pipeline was designed and tested for per-vggo EOF rate. Drop the swap rate by 4× and the timing characteristics they didn't validate emerge. Don't reroute `FRAME_DONE` without a sim of the consequent buffer dynamics.

### Sim infrastructure (commits `9d8b953`, `d8b5fac`)

```
sim/
├── avg_starwars_mame.py        MAME-faithful Python AVG decoder
│                               (port of avg_starwars_device + PROM state
│                                machine + 8 handlers).  Per-vg_add_point_buf
│                                trace output with full state.
├── avg_starwars_hdl.py         Python emulator of our HDL pipeline.
│                                Shared AVG state machine with mame port;
│                                different strobe3 math.  Updated through 3
│                                diff iterations to model the post-fix HDL.
├── diff_decoders.py            Per-VCTR diff -> CSV sorted by divergence.
│                                Found and validated all 3 math bugs.
├── render_mame_faithful.py     PNG of MAME-equivalent expected output.
├── render_hdl_emulated.py      PNG of what our HDL produces.
├── tb_drawer.vhd               GHDL testbench, stroke-cap latching fix.
├── tb_fb_race.py               Event-driven model of vector_fb_ddram's
│                                triple-buffer state machine.  Probes for
│                                vbl_edge + EOF race firing -- in our model
│                                the race never fires at any tested rate.
├── scan_empty_vggos.py         Checks captured vec dumps for vggos that
│                                produce zero visible strokes (= would feed
│                                an empty buffer to the swap).
├── prep.py                     MAME data extractor (unchanged).
└── (PNG/CSV outputs in .gitignore)
```

The diff workflow — `python diff_decoders.py <vec_T*.bin> <label>` then read `diff_<label>_worst.csv` — is the reusable tool. It works on any captured vec dump and any HDL math change.

---

## Open mystery (parked)

The 3-4 Hz black flash from the BUG-3-fixed build never got root-caused. Sim of the triple-buffer state machine didn't reproduce it. Plausible candidates I couldn't disprove without SignalTap:

- DDRAM contention stretching clears into FB_VBL windows
- FRAME_DONE = avg_halted glitching under specific AVG state transitions
- Scaler-side FB_VBL timing relative to ready_buf invalidation

Not relevant for the shipped build (per-vggo wiring works), but worth knowing if anyone re-attempts the vggo-aligned approach.

---

## ESB pivot

The next phase has its own docs already drafted in earlier sessions:

- `docs/ESB_PLAN.md` — staged plan, MAME-derived memory map, the slapstic 101 design notes
- `docs/ESB_INTEGRATION.md` — integration sequencing
- `docs/esb-conversion-cliff-koch-1996.md` — historical conversion reference

ESB is ~80% reuse of what we just shipped (same hardware: AVG, mathbox, audio chain, inputs). The new work is concentrated in two areas:

1. **Slapstic chip** (`137412-101`) — Atari's bank-switching copy-protection state machine
2. **Larger banked-ROM layout** — `0x8000-0x9fff` slapstic-protected + `0xa000-0xffff` bank2 (24 KB pages)

**Read `docs/ESB_PLAN.md` first.** It already enumerates the MAME memory map, the ROM file mapping, the slapstic decode, and which Star Wars pieces are reused vs. replaced.

ROMs are at `/d/deck/fpga/starwars/sw/starwars-empirestrikesback/esb.zip` (14 files, 139 KB).

The Star Wars math + sim infrastructure transfers directly — same AVG (`136021-105.1l`, same CRC), same drawer, same coord transform, same render pipeline. The MAME-faithful decoder and HDL emulator will validate ESB-specific drawer behavior the same way they validated SW.
