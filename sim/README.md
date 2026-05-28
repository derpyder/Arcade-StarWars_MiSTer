# GHDL sim of avg.vhd + vector_drawer against MAME-captured frames

What's here:
- `tb_drawer.vhd` — testbench that loads a MAME-captured vector RAM
  snapshot + the AVG state PROM, drives `vggo`, and logs every clk-cycle
  pixel write (`xout, yout, zout, rgbout`).
- `dpram_sim.vhd` — behavioural DPRAM substitute for the Altera
  `altsyncram` primitive (so GHDL can elaborate without `altera_mf`).
- `prep.py` — pulls 16KB of vector RAM from `.tools/mame0287/snap/vec_*.bin`
  and the AVG PROM from `starwars.zip`, writes them as hex files for the
  testbench to load via VHDL `textio`.
- `sweep.py` — runs the sim against the four named scenes (high_score,
  logo, intro, instr) and prints per-scene color counts.
- `render.py` — converts a per-pixel log into a PNG bitmap with the
  same X/Y scaling `starwars.sv` applies (1.75x X, 1.25x Y, Y inverted).
- `run.ps1` — one-shot compile + run for the high-score scene.

## Usage

```powershell
# Single scene
python prep.py high_score          # writes vec_mem.hex + avg_prom.hex
.\run.ps1                          # compile and simulate
python render.py tb_pixel_writes.txt out.png

# All scenes
python sweep.py
for s in high_score logo intro instr; do
    python render.py pixels_$s.txt render_$s.png
done
```

## Bug-hunting workflow

1. Pick a scene whose hardware output is "wrong" per visual inspection
2. Run sim, render to PNG, compare to MAME's snap/starwars/000X.png
3. The diff between MAME-screenshot and our render shows which AVG output
   gets rendered correctly vs wrong by our RTL.
4. To dig deeper: add instrumentation to `tb_drawer.vhd`'s pixel_cap or
   debug_counts processes (e.g., log start/end positions per VCTR via
   the `dbg` signal's draw/done pulses).

## Known issues this caught

- **2026-05-28 / commit e949074** — zero-displacement strokes (starfield
  dots, glyph anchor points) were silently dropped because WALK
  terminated in 1 clk cycle (80ns) -- too short for the FB pipeline.
  Fixed by gating termination on clk_ena.  Verified by running this
  testbench: c7 dot count went from 0 to 38 (vs MAME's 39 expected).
