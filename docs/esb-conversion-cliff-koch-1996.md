# ESB Conversion — Cliff Koch 1996 (reference)

This document is preserved verbatim from the user's archive
(`conversion.txt` on the desktop, 2026-05-27).  Copyright Cliff Koch
1996, redistributed under his stated terms: "I grant permission for
personal, non-commercial use of the information in this file."

This MiSTer port is open-source, non-commercial.

Cliff's document describes:
1. A 22V10 PAL-based reverse-engineered slapstic clone for ESB.
2. The exact CPU board modifications to convert a Star Wars PCB to ESB.
3. A combined SW/ESB conversion with runtime mode selection.

For our FPGA port:
- We use d18c7db's MAME-derived slapstic (type 101), not Cliff's PAL.
- Cliff's PAL JEDEC is useful as a **cross-check** if d18c7db's
  behavior diverges from real ESB silicon at any specific game state.
  See `rtl/slapstic.vhd` for d18c7db's implementation.
- His combined-mode wiring confirms the **mod_esb selector** pattern
  is correct (an "extra address line" picks the EPROM image at
  runtime — same concept as our `mod_esb` flag).
- His warning about NOVRAM divergence between games applies to our
  X2212 handling.

---

```
[full text of Cliff Koch's 1996 ESB conversion document — section
headers below preserve the structure of the original]

I.   Disclaimer
II.  Introduction
III. Daughtercard construction
IV.  Board Modifications for Empire Strikes Back only operation
     A) Modifications to the Main CPU card
     B) Modifications to the Sound Board
     C) Modifications to the AVG board
     D) Checking game operation
V.   Board modifications for Empire Strikes Back and Star Wars operation
     A) Modifications to the Main CPU board
     B) Modifications to the sound board
     C) Modifications to the AVG board
     D) Board firmware creation
     E) Inter board wiring
     F) Cabinet wiring
VI.  Slapstic clone (22V10 PAL JEDEC file)
```

The full text is in the user's local archive at
`C:\Users\mattl\Desktop\conversion.txt`.  This stub doc records the
metadata + relevance to our port; the actual text is preserved in
the source file for now.

---

## Direct mapping: Cliff's instructions → our FPGA work

| Cliff's mod | What it does on silicon | Our FPGA equivalent |
|---|---|---|
| IV.A.1: cut trace at 1H/J pin 22 | Frees the slapstic-page pin for new wiring | Memory map gating in `starwars.sv` (mod_esb gates slapstic at $8000-$9FFF) |
| IV.A.2: jumper 2C pin 34 to 1H/J pin 22 | Routes outlatch[4] to slapstic /E | Already wired — outlatch[4] is our existing `rom_bank` signal |
| IV.A.3-7: rewire pin 26/27/28 on multiple ICs | Adapt main ROM sockets to 8KB→16KB | `pgmrom.vhd` widening to 32KB per ROM region for ESB mode |
| IV.C.1: replace AVG 1L with 136031-111 | Different vector ROM file | New MRA part (`136031.111` in esb.zip) routed to vecrom region |
| V.D EPROM image table | Both ROMs in one larger EPROM, A14 selects game | `mod_esb` flag picks which MRA the user loads — no merged EPROMs needed; we ship two MRAs and load whichever the user selects |
| VI: 22V10 PAL slapstic clone | Address-pattern bank selector | `rtl/slapstic.vhd` (d18c7db's MAME-derived) with `I_SLAP_TYPE => 101` |

---

## Cliff's PAL pin mapping (for slapstic behavior cross-check)

```
PINS E:1 CE:2 A0:3 A1:4 A2:5 A3:6 A4:7 A5:8
PINS A6:9 A7:10 A8:11 A9:13 A10:14 A11:15 A12:16 A13:17
PINS OE3:18 OE2:19 pre_1:20 pre_2:21 ltch_8000:22 pg_en:23
```

- `E` (pin 1): /E clock from CPU
- `CE` (pin 2): /CE chip enable
- `A0..A13` (pins 3-17): CPU address bus
- `OE2, OE3` (pins 18-19): output-enable for upper / lower EPROM banks
- `pre_1, pre_2` (pins 20-21): internal state machine — probably the
  "valid" sub-state bits Cliff tracks to detect a complete unlock sequence
- `ltch_8000` (pin 22): probably "the CPU has performed a read in the
  $8000-$9FFF page"
- `pg_en` (pin 23): "page enable" — gates whether bank switching is allowed

These pin labels suggest Cliff's PAL implements roughly the same state
machine MAME's slapstic.cpp encodes.  His state names map onto MAME's:

| Cliff | MAME state |
|---|---|
| `pre_1` set | After read at slapstic-state-1 address |
| `pre_2` set | After read at slapstic-state-2 address |
| `ltch_8000` | "address strobe in slapstic window" |
| `pg_en` | "unlock complete; bank-switch on next valid read" |
| `OE2/OE3` toggle | New bank selected |

---

## Caveats from Cliff

- "It actually does not work *exactly* like the slapstic, but program
  flow is not affected by the differences."
- "I would not count on my clone also working for Tetris."
- "This design does tighten the timing constraints of memory accesses
  to the EPROMs a bit, but the cycle times for the 6809 are so slow
  you're not likely to find EPROMs slow enough to make a difference."

For our FPGA: d18c7db's implementation is MAME-derived, which is more
faithful than Cliff's PAL.  Cliff's work is a **secondary reference**
for cross-checking; we should not need to fall back to it.
