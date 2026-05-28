# ESB — Empire Strikes Back port plan

**Status:** staged. Execute immediately after SW with PROM-driven AVG is hardware-validated.
**Branch:** to be created as `esb-port` off `prom-driven-avg`.
**ROMs:** at `/d/deck/fpga/starwars/sw/starwars-empirestrikesback/esb.zip` (14 files, 139 KB).

---

## Why ESB is a small port (once SW works)

ESB runs on **physically identical hardware** to Star Wars per MAME `esb_main_map` (line 124-129 of `mame_starwars_ref.cpp`). The only architectural differences:

| Component | SW | ESB | What we need |
|---|---|---|---|
| AVG | 136021-105.1l (CRC 82fc3eb2) | **Same file, same CRC** | ✓ Nothing — our PROM-driven AVG already works |
| Mathbox PROMs | 4× 1KB | 4× 1KB, different content but same interface | ✓ Videodr0me's structural mathbox handles automatically |
| Main 6809 | same instruction set | same | ✓ Same core |
| Vector ROM | 136021.105 | **136031-111.1l** | New MRA entry |
| Audio ROMs | 136021-107/-208 | **136031-113/-112** | New MRA entry |
| Audio chain | POKEY×4 + TMS5220 + RIOT | **Same** | ✓ Nothing |
| Main ROM | 32 KB + 16 KB bank | 32 KB + **slapstic + bank2** | **NEW work** |
| Slapstic chip | n/a | **`137412-101` (slapstic 101)** | **NEW work** |
| MRA | starwars.mra | new esb.mra | New file |
| Inputs | yoke + 7 buttons | **identical** | ✓ Reuse |

**~80% of ESB = reusing what we already have.** The remaining 20% is the slapstic chip and the bigger banked-ROM layout.

---

## MAME-derived ESB memory map (line 124-129 + 491-560)

```
ESB main CPU memory map = SW map + these two regions:
  0x8000-0x9fff   bankr(m_slapstic_bank)    // slapstic-protected page
  0xa000-0xffff   bankr("bank2")            // banked ROM (24 KB total per page)

  Slapstic bank: 4 entries × 0x2000 (from ROMs 136031-105 + 136031-106)
  Bank2:         2 entries × 0x1c000-0xa000 = 2 × 24 KB pages
                 Page selector: outlatch q_out_cb<4> (= the existing latchout[4]
                 that drives banking on SW too).
```

ESB's ROM_START allocates 0x22000 (136 KB) for the main CPU region — much bigger than SW's 64 KB. Banking is the only way it fits in the 6809's 64 KB address space.

---

## Slapstic chip (the hard part)

**`137412-101`** (also called "slapstic 101"). Atari's bank-switching copy-protection chip. ~256 bytes of ROM behind a state machine that watches CPU reads at specific addresses and switches the visible page.

### How it works (simplified)

- 4 banks of 8 KB each, all mapped at CPU `$8000-$9FFF`.
- State machine: read sequence to specific "alternate bank select", "bit set 1", "bit set 2", "valid" addresses transitions the state and commits a bank switch.
- Without the right read sequence, reads return junk; the CPU crashes.

### MAME implementation source

`docs/mame_starwars_ref.cpp:359-361`:
```cpp
SLAPSTIC(config, m_slapstic, 101);
m_slapstic->set_range(m_maincpu, AS_PROGRAM, 0x8000, 0x9fff, 0);
m_slapstic->set_bank(m_slapstic_bank);
```

Full MAME slapstic device: `slapstic.cpp` / `slapstic.h` in MAME source.

### FPGA porting options

1. **Pure VHDL port from MAME.** Re-implement the state machine + bank ROM in VHDL. ~200 lines. Most direct.
2. **Find an existing FPGA slapstic core.** Tempest / Major Havoc MiSTer cores might already have one. Check `Tempest_MiSTer` and `Major-Havoc_MiSTer` repos. If found, copy + attribute.
3. **Hardcode the "valid" state.** Skip the state machine, just bank-switch on any write to `$8000`. Works for **playable demo** but fails copy-protection checks the game may do.

**Recommendation: option 2 if found, option 1 if not.** Option 3 is a quick fallback if both fail.

---

## File-by-file work list

### New files

| File | What |
|---|---|
| `rtl/slapstic.vhd` | Slapstic chip emulation (~200 lines, MAME port or existing FPGA core) |
| `releases/Empire Strikes Back.mra` | ESB MRA with the 14-file esb.zip layout |

### Modified files

| File | Change |
|---|---|
| `rtl/starwars.sv` | Add `mod_esb` flag, ESB main memory map (slapstic at $8000-$9FFF, bank2 at $A000-$FFFF). Use mod_esb to gate which mapping wins. |
| `Arcade-StarWars.sv` | Add `mod_esb` define + select between starwars.mra and esb.mra paths |
| `files.qip` | Add slapstic.vhd |

### Reused as-is

Everything else: AVG, mathbox, audio chain, POKEYs, TMS5220, framebuffer, drawer, inputs, ADC.

---

## ESB MRA layout (proposed)

```xml
<rom index="0" md5="none" type="merged|nonmerged" zip="esb.zip">
  <!-- Main CPU ROMs — note ROM_CONTINUE pattern: high half goes to bank2 -->
  <!-- 136031.101: low 8KB at 0x6000, high 8KB at 0x10000 (bank2 page 0) -->
  <part crc="ef1e3ae5" name="136031-101.1f"></part>
  <part crc="62ce5c12" name="136031-102.1jk"></part>
  <part crc="27b0889b" name="136031-203.1kl"></part>
  <part crc="fd5c725e" name="136031-104.1m"></part>

  <!-- Slapstic page ROMs (16KB total = 4 banks × 4KB) -->
  <part crc="ea9e4dce" name="136031-105.3u"></part>
  <part crc="76d07f59" name="136031-106.2u"></part>

  <!-- Vector ROM (4KB) -->
  <part crc="b1f9bd12" name="136031-111.1l"></part>

  <!-- AVG state PROM (SAME as SW, CRC 82fc3eb2) -->
  <part crc="82fc3eb2" name="136021-105.1l"></part>

  <!-- Audio ROMs -->
  <part crc="24ae3815" name="136031-113.1jk"></part>
  <part crc="ca72d341" name="136031-112.1h"></part>

  <!-- Mathbox PROMs (different content than SW but same interface) -->
  <part crc="b8d0f69d" name="136031-110.7h"></part>
  <part crc="6a2a4d98" name="136031-109.7j"></part>
  <!-- ... 136031-108, 136031-107 ... -->
</rom>
```

Note: ESB's ROM_LOAD pattern uses ROM_CONTINUE to split 16KB files into low (CPU window) + high (bank2) halves. The MRA can just concatenate the files; bank2's BRAM addressing picks the right half.

---

## Sequencing (after SW PR lands)

1. **Branch off `prom-driven-avg`** → `esb-port`.
2. **Slapstic chip first** — biggest unknown. Write or import a slapstic.vhd. Standalone testbench if possible.
3. **ESB memory map** in starwars.sv with mod_esb gating.
4. **ESB MRA** with the file layout above.
5. **Mod selector** in Arcade-StarWars.sv: `mod_esb` flag, picks ESB MRA path.
6. **Build + flash + test.** Expected sequence: boot → attract → coin → game start → fly the Snowspeeder.
7. **PR to Videodr0me's repo:** "Add Empire Strikes Back support."

---

## Why this is real upstream value

His README says: *"With enough support, I'd love to dedicate time to tackle other complex vector games like Tempest and The Empire Strikes Back."* Neither is in his core today.

Adding ESB demonstrates the **architectural payoff** of our PROM-driven AVG: the same RTL renders ESB without modification because the AVG state PROM is identical. The slapstic is a separate concern (memory map), not an AVG concern.

A clean ESB PR is one of the strongest "see, the PROM-driven approach was worth it" demonstrations available.
