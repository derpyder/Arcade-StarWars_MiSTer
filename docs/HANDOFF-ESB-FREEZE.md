# ESB freeze — FIXED & SHIPPED (2026-05-29)

**Repo:** `derpyder/Arcade-StarWars_ESB_MiSTer` (private), branch `esb-port`,
local `D:\deck\fpga\starwars\sw\starwars-videodr0me\`.
**Supersedes the earlier "hardware-timing-realm → do SignalTap" conclusion.**

## TL;DR — it was the slapstic; fixed, confirmed on hardware, and shipped

ESB gameplay crashes ~5 vggos in because the **slapstic 137412-101 could not do
ALTERNATE ("devious") banking** — only direct banking. Attract uses only direct
bank-1↔3 (so it boots & renders one correct frame); gameplay uses *alternate*
banking to reach banks 0/2, the first alt-switch fails, the bank stays wrong, and
the 6809 jumps through a bad pointer into non-ROM. Confirmed against MAME.

**Fix:** new `rtl/slapstic101.vhd` (faithful port of MAME's **decapped** type-101)
replacing the old generic `rtl/slapstic.vhd`, stepped once per 6809 bus cycle with
the **full 16-bit address** so it can see the out-of-range `$FFFF` dummy cycle the
alt sequence pivots on. GHDL-verified (11/11). `mod_esb`-gated → SW byte-identical.

## How it was confirmed (MAME is the oracle — reusable method)

1. The old `rtl/slapstic.vhd` is a translation of an **old, UNCONFIRMED** MAME. Its
   type-101 `alt1 = (a&0x007F)==0xFFFF` is the literal `UNKNOWN` placeholder — can
   NEVER match. Decapped MAME (`src/mame/atari/slapstic.{cpp,h}`, in
   `sim/mame-ref/`) uses `alt1=(a&0x1F00)==0x1E00`, `alt2=(a&0x1FFF)==0x1FFF`.
2. Decapped MAME: for 101/102 the **2nd alt access must be OUTSIDE $8000-$9FFF**
   ("hits a 6809 dummy vma access") and MAME taps the **whole address space**. The
   old HDL only ever strobed the slapstic in-range → architecturally incapable.
3. `mame.exe esb -log` over **real gameplay** (user played ~15s): **51 complete
   alt-start/valid/select/commit sequences** + banks 0/2 used. Attract (44s):
   **0** alt, only direct bank-1↔3. → alt banking is gameplay-only = the crash.
4. Mechanism (disasm of bank1 `$9DFE`): `LDA ,X` through a computed pointer, then
   `ASLA` at `$9E00` (opcode addr `$9E00`=alt1; its dummy cycle drives `$FFFF`=alt2).
   Runtime-data-driven → invisible to static analysis, hence MAME-dynamic confirmed.
5. Feasibility: `rtl/cpu/mc6809i.v` defaults `addr_nxt=16'hFFFF` on dummy cycles
   and the wrapper forces `VMA=1` on reads → the `$FFFF` alt2 trigger is already on
   `main_addr`. No CPU-core change needed.

## The fix (files changed)

- **`rtl/slapstic101.vhd`** (NEW) — decapped MAME type-101 state machine
  (idle/active/alt_valid/alt_select/alt_commit/bit_load/bit_set), full 16-bit addr,
  inside/outside aware. Self-documented with the derivation.
- **`rtl/starwars.sv`** — instantiate `slapstic101`; `slap_step = mod_esb &&
  main_vma && ce_dly[3]` steps it once per bus cycle with **full `main_addr`** (no
  in-range gate). Removed `slap_cs_active`/`slap_strobe`/`SLAPSTIC`. Fixed the
  `st_slapcs` SignalTap probe (recomputes in-range locally).
- **`files.qip`** — adds `rtl/slapstic101.vhd` (old `slapstic.vhd` left in, unused).
- **`sim/tb_slapstic101.vhd`** (NEW) — GHDL TB. 11/11 pass incl. the NEGATIVE case:
  without the `$FFFF` dummy there is NO bank switch (reproduces the old bug); with
  it, banks switch correctly (alt→0/2/3, direct→0/1/2/3, power-up 3).
- **`sim/mame-ref/`** (NEW) — the decapped MAME slapstic + starwars driver source
  used as ground truth. Keep for derivation/audit.

GHDL: `C:\Users\mattl\bin\ghdl\bin\ghdl.exe -a --std=08 -frelaxed ../rtl/slapstic101.vhd tb_slapstic101.vhd` then `-e` then `-r tb_slapstic101 --stop-time=20us`.

## Confirmed on hardware + SHIPPED

Confirmed working on hardware (DE10-Nano): ESB renders and keeps animating into
gameplay — no freeze ~5 vggos in. The freeze-debug scaffolding (on-screen overlay
+ SignalTap probe bus) was then removed for the ship build (commit `35d9580`).

**Shipped:**
- Public fork **`derpyder/Arcade-StarWars_MiSTer`** — a real GitHub fork of
  `Videodr0me/Arcade-StarWars_MiSTer`, default branch `esb-port`.
- Public release **`esb-v1.0`**: assets `Arcade-StarWars.rbf` + `MRA.zip` (the
  Empire Strikes Back + Star Wars MRAs, names preserved inside the zip).
- One core runs both Star Wars and Empire Strikes Back via `mod_esb`.

**If a regression ever reappears** at `$9DFE/$9E00`: the slapstic LOGIC is
MAME-verified, so the suspect is cycle-accuracy of our Cavnex 6809 vs MAME (the
`$FFFF` dummy cycle landing in the right cycle). Diagnose with a full-system GHDL
sim of that routine, or SignalTap the bus around `$9E00` and compare the cycle
sequence to MAME's.

## Still VALIDATED CORRECT in sim (do not re-investigate)

| Subsystem | Evidence |
|---|---|
| AVG drawer | MAME-bit-exact (SW ship; 100% match 4 scenes). |
| Memory map | `sim/esb_diff_memmap.py` bit-exact, both bank pages + slapstic bank 3. Our `slap_rom` bank mapping matches MAME `configure_entries(0,4,base+0x14000,0x2000)`. |
| Mathbox | halts on all 256 ESB ucode entries; MAME `run_mproc` ref in `sim/mame-ref/starwars_m.cpp` (divider 15-iter + `ACC+=((A-B)<<1)*C)<<1` consistent with HDL). Walkers render → core transforms OK. |
| Audio | music plays = audio CPU alive. |

## Tools (sim/)

- `sim/mame-ref/` — decapped MAME slapstic.{cpp,h} + starwars.{cpp,h} + starwars_m.cpp (ground truth).
- `tb_slapstic101.vhd` — the new GHDL TB (replaces the old `tb_slapstic.vhd` model).
- MAME 0.287 at `../starwars-mister/.tools/mame0287/`; `esb.zip` verified.
  - Slapstic banking trace: `mame.exe esb -log` → `error.log` logs every transition
    ("direct switch bank N", "alt start/valid/select", "alt/add commit", "bitwise…").
  - Gameplay-input harnesses (`esb_gp*.lua`): UNSOLVED headless — ESB stops kicking
    every game-driven clock during the mode transition, so coin/fire injection is
    unreliable. The reliable path was a human playing `mame.exe esb -log` for ~15s.
- `avg_*` AVG diff harness; `mathbox_halt_check.py`; `esb_*memmap.py`.
