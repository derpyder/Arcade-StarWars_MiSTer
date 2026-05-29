# ESB bring-up — freeze debug handoff (2026-05-29)

**Repo:** `derpyder/Arcade-StarWars_ESB_MiSTer` (private), branch `esb-port`,
local `D:\deck\fpga\starwars\sw\starwars-videodr0me\`. HEAD `d72ba1e`.
**Read this + `docs/HANDOFF.md` (SW ship) + `docs/ESB_INTEGRATION.md`.**

## TL;DR — ESB is ~95% there

ESB boots, and **renders a complete, correct, full-color Hoth wave-1 gameplay
frame** (score, 3 SHIELDS gauge, "1 WAVE / PROBOTS 6", red mission text, HUD
box, two Probots, two 3D walkers, starfield, laser). Photo proof:
`output_files/freeze.JPG`. **Music + SFX work.** Then it **crashes ~5 vggos
into gameplay** (deterministic, even with no input), leaving the clean frame
frozen while music keeps playing. The entire rendering + audio stack works.
One CPU-progress crash remains.

## What's fixed (all on esb-port, pushed)

- **Slapstic strobe** (`starwars.sv`): one-pulse-per-access via `ce_dly[3]`
  (the wrapper latches addr at phase 2; strobe at phase ~3-4). Got it
  booting/rendering. The earlier `~main_vma` strobe miscounted.
- **ESB audio ROM** (`starwars.sv` `esb_aud_rom`, 32KB): 113/112 low+high
  split; audio 6809 reset vector ($FFFE) lands in 112 high. Fixed no-sound.
- **AVG drawer math** (inherited from SW ship): SVEC cycles, `scale_factor =
  m_scale^0xff`, high-total_shift, bit-14 pitch — MAME-bit-exact rendering.
- **Memory map**: `mod_esb` selector, `esb_main_rom` (64KB, bank1/bank2 page
  via `outlatch[4]`), slapstic + slap_rom. Reverted: the BUG-3 vggo-aligned EOF.

## What's VALIDATED CORRECT in sim (do not re-investigate)

Everything checkable in clean-stimulus sim is proven correct:

| Subsystem | Evidence |
|---|---|
| Slapstic **params** | verified vs authoritative MAME `slapstic101` (svn2github/mameplus) — bankstart 3, banks 80/90/a0/b0, alt/bit tables ALL match. The d18c7db "(NOT confirmed)" was unfounded. |
| Slapstic **logic** | `sim/tb_slapstic.vhd` — power-up, basic banking, AND alternate/devious banking (alt bank 0/1/2/3) all pass. |
| Mathbox | `sim/mathbox_halt_check.py` — all 256 ESB microcode entries reach HALT (no hang). Microcode differs from SW but our PROM-driven increment-only model handles it. |
| AVG | MAME-faithful decoder halts on ESB vector dump (2364 strokes, incl. 45 white). |
| Memory map | `sim/esb_diff_memmap.py` — bit-exact to MAME, both bank pages + slapstic bank 3. |
| `$4401` latch flags | match MAME (bit7=sound pending, bit6=main pending). |
| Audio | music plays = audio CPU alive. |

## The crash — what we know

- Deterministic, **~vggo 5 from wave-select** (ESB runs ~20 vggo/s, so ~0.25s
  into gameplay), no input needed.
- The PC lands in **non-ROM** (overlay read $0400 then $4xxx across runs).
- Renders a full correct frame FIRST, then dies → it's a **bad computed jump**
  at gameplay start, not a render bug.
- Music continues, frame frozen → the main 6809 is dead/looping; audio CPU fine.

**Since everything sim-checkable is clean, the bug is hardware-timing-realm**
(a wrong pointer/jump-target produced only under real timing/sequences). The
two things sim CANNOT reach: (a) the slapstic STROBE delivering a wrong access
*sequence* during devious banking on real HW (logic is right, but my TB used
clean stimulus); (b) the mathbox computing a wrong RESULT (not hang) for an
ESB-specific op used as a pointer — the one validation gap (only "halts" proven,
not "correct value").

## NEXT STEP — SignalTap (set up, awaiting a build)

Commit `d72ba1e` added `(* keep *)` probe nodes + a crash trigger in
`starwars.sv`. **The next action is: build WITH SignalTap, capture the crash.**

SignalTap setup (clk = `clk_12`, depth 8K):
- **Trigger:** `st_crash_fetch` rising (= `main_opfetch & main_vma &
  main_addr<$6000` = PC left ROM). Trigger position ~90% pre-trigger.
- **Probes:** `st_addr[15:0]`, `st_data[7:0]`, `st_rw`, `st_vma`, `st_opf`,
  `st_slapbs[1:0]`, `st_slapcs`, `st_bank2`, `st_mathrun`.
- Run ESB: coin → fire-once-to-select-wave → hands off.

Readout: `st_addr` at trigger = jump target; the samples just before show the
`JMP`/`RTS` that did it + `st_data` (the bad opcode/pointer it followed) +
`st_slapbs`/`st_bank2` (which bank was active). That names the bad pointer's
source. (`st_crash_fetch` never fires for SW — SW never fetches <$6000 — so
SignalTap-on is inert for Star Wars.)

## On-screen overlay (already in the build, mod_esb-gated, SW byte-identical)

Bottom-of-screen bars: cols 0-15 = `frame_ctr` (vggo count, **resets on fire =
wave-select**), cols 16-19 = `last_pc[15:12]` (PC high nibble). **Caveat:** the
`opfetch` PC capture is UNRELIABLE (catches operand/LIC addresses, not a clean
PC) — that's why we pivoted to SignalTap. The frame_ctr (N) IS reliable.

## Tools (sim/)

- `avg_starwars_mame.py` / `avg_starwars_hdl.py` / `diff_decoders.py` — MAME vs
  HDL AVG diff (found the 3 SW drawer bugs; 100% match across 4 scenes).
- `tb_slapstic.vhd` — slapstic type-101 validation (basic + alt). `-fsynopsys`.
- `mathbox_halt_check.py` — ESB microcode halt analysis.
- `esb_memmap.py` / `esb_diff_memmap.py` / `esb_find_regions.py` — memory-map
  diff vs MAME dumps.
- `esb_play.lua` — MAME gameplay-input harness. **UNSOLVED:** reliably driving
  MAME into ESB *gameplay* headlessly (coin/fire injection finicky). If you
  crack this, you can trace MAME's gameplay at vggo 5 and diff our subsystems.
- MAME 0.287 at `../starwars-mister/.tools/mame0287/`; `esb.zip` verified;
  `esb_freeze.txt` = 4s attract PC trace.

## Gotchas (hard-won)

- The overlay can't show POST-freeze state (frame pipeline stops with the CPU).
- `opfetch`(=LIC) ≠ clean PC — unreliable for PC capture. Use SignalTap.
- ESB 6809 runs ENTIRELY from ROM ($6xxx-$Exxx) — 0 RAM execution (MAME-confirmed
  over 4s). The "runs from RAM" is the AVG reading vectors from vector RAM, NOT
  the 6809.
- ESB ~20 vggo/s (not 60).
- GHDL: `--std=08 -frelaxed -fsynopsys`.
- Quartus auto-rewrites `Arcade-StarWars.qsf` during builds → `git checkout` it
  before commits (it's just a version-bump).
- `mod_esb`-gated debug is verified SW-byte-identical; keep it that way.
