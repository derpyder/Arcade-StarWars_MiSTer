# ESB integration — deferred work (after slapstic + MRA staged)

**State as of branch `esb-port`:**

- ✓ `rtl/slapstic.vhd` imported from d18c7db's `Gauntlet_FPGA` (GPL-3, MAME-derived, supports type 101).
- ✓ `rtl/slapstic.vhd` added to `files.qip`.
- ✓ `releases/Empire Strikes Back.mra` written with proposed dn_addr layout + file references.
- ⌛ Memory-map integration in `rtl/starwars.sv` not yet done.
- ⌛ `mod_esb` selector in `Arcade-StarWars.sv` not yet done.
- ⌛ Bank2 ROM region (CPU $A000-$FFFF banked) not yet wired.
- ⌛ Slapstic ROM (32 KB, 4 banks × 8 KB) backing storage not yet allocated.

This doc captures the remaining design decisions so next session can execute.

---

## TODO: vector vertex brightening (additive beam overlap)

Where two vector beams cross on a real vector monitor, the phosphor at the
intersection pixel is excited TWICE → brighter dot at the crossing.  Same
effect for endpoints where multiple vectors share a vertex (a wireframe
corner where 3 lines meet renders as a bright "node").

This is **item 4** on Videodr0me's "Known Limitations" list ("Beam
Overlap — not modeled") and #2 of the differentiation wins we tracked
in `docs/M3_HANDOFF.md` from the starwars-mister fork.

With our new Bresenham drawer (one pixel write per clk_ena), the
implementation is:
  - In Videodr0me's `vector_fb_ddram.sv`, change the FB pixel write from
    OVERWRITE to SATURATING-ADD against the current FB pixel value.
  - Same-pixel writes from two vectors → brightness accumulates.
  - Hot vertex pixels naturally render as small bright nodes — exactly
    the real CRT phosphor behavior at line intersections.

Reference photo (user provided): real SW silicon shows bright vertex
"nodes" at every wireframe corner of the STAR WARS title.  Our current
output renders the wireframe lines but corners are not visibly brighter
than line midpoints — the additive blend is what creates the corner
"sparkle."

Implementation tracked as a follow-up after Bresenham bug fix lands.

## Historical cross-reference: Cliff Koch's 1996 conversion

See `docs/esb-conversion-cliff-koch-1996.md`.  Cliff reverse-engineered
a 22V10 PAL slapstic clone for ESB in 1996.  His document confirms:

- **Slapstic type 101 = ESB = Tetris** (same chip per his note).
  d18c7db's `I_SLAP_TYPE => 101` is the right value.
- Per-file ROM placement matches our MRA exactly (136031.101/.102/.203/
  .104 for main CPU; 136031.111 for vector ROM; 136031.112/.113 for
  sound; 136031.107-110 for mathbox PROMs).
- His combined SW+ESB conversion uses an "extra A14 line" to pick
  game at runtime — the silicon-level equivalent of our `mod_esb` flag.
- His PAL pin labels (`pre_1`, `pre_2`, `ltch_8000`, `pg_en`) map onto
  MAME's slapstic state machine — useful as a cross-check if d18c7db's
  implementation ever diverges from real ESB silicon.
- **NOVRAM warning**: NOVRAM byte meanings differ between SW and ESB.
  Our X2212 NVRAM will need either per-game keys or accept that
  switching mods loses high-score/settings persistence.

## What `slapstic.vhd` is and isn't

It's the **address-pattern recognizer** — a small state machine that watches CPU reads at specific magic addresses and outputs a 2-bit bank-select signal. It does **NOT** itself contain the 32 KB of slapstic-protected ROM. That ROM lives in a separate dpram (4 banks × 8 KB), and our integration code multiplexes the 4 banks based on the slapstic's `O_BS` output.

Entity interface:
```vhdl
port(
    I_CK        : in  std_logic;                       -- clock
    I_ASn       : in  std_logic;                       -- address strobe (active low)
    I_CSn       : in  std_logic;                       -- chip select (active low)
    I_A         : in  std_logic_vector(13 downto 0);   -- 14-bit address bus
    O_BS        : out std_logic_vector( 1 downto 0);   -- 2-bit bank select
    I_SLAP_TYPE : in  integer range 0 to 118           -- runtime-selectable type
);
```

For ESB, drive `I_SLAP_TYPE => 101` (the Empire Strikes Back / Tetris slapstic).

---

## Memory map changes needed (in `rtl/starwars.sv`)

Per MAME `esb_main_map` (line 124-129 of `mame_starwars_ref.cpp`):

```
SW main map  +  these ESB-only overrides:
  0x8000-0x9FFF   bankr(m_slapstic_bank)    // slapstic-protected, 4 banks
  0xA000-0xFFFF   bankr("bank2")            // bigger banked ROM, 2 pages
```

`bank2` is selected by `outlatch[4]` (the same `latchout[4]` SW already uses for its bank-switch — see his `bank_select` logic in starwars.sv line 287). So the existing outlatch wiring already drives bank2's page selector. Just need a 24KB-per-page BRAM mapped at $A000-$FFFF when mod_esb=1.

The slapstic interception logic:

```sv
// In starwars.sv (proposed):
wire        slap_cs     = mod_esb && (main_addr[15:13] == 3'b100);  // $8000-$9FFF
wire        slap_asn    = ~main_vma;  // active-low address strobe
wire [1:0]  slap_bs;
wire [7:0]  slap_dout;

slapstic u_slap (
    .I_CK(clk_12),
    .I_ASn(slap_asn),
    .I_CSn(~slap_cs),
    .I_A(main_addr[13:0]),
    .O_BS(slap_bs),
    .I_SLAP_TYPE(101)
);

// Slapstic ROM (32 KB = 4 banks × 8 KB).
rom_download #(.ADDR_WIDTH(15)) slap_rom (
    .clk(clk_12),
    .dn_addr(dn_slap_addr[14:0]),
    .dn_data(dn_data),
    .dn_wr(dn_slap_cs),
    .cpu_addr_a({slap_bs, main_addr[12:0]}),
    .cpu_dout_a(slap_dout)
);

// Route slap_dout into main_din when slap_cs=1.
```

---

## Mod selector in `Arcade-StarWars.sv`

```sv
reg mod_esb = 0;
always @(posedge clk_12) begin
    reg [7:0] mod_byte = 0;
    if (ioctl_wr && (ioctl_index==1)) mod_byte <= ioctl_dout;
    mod_esb <= (mod_byte == 8'h01);  // mod=1 selects ESB
end
```

ESB's MRA `<rom index="1"><part>1</part></rom>` sets ioctl_index=1 with data=1, which sets mod_esb=1.

Pass mod_esb through to STARWARS_TOP → starwars.sv as a new input port.

---

## bank2 wiring

ESB's CPU sees $A000-$FFFF as 24 KB of banked ROM, with 2 pages selectable.  Each page = 24 KB.  Total bank2 ROM = 48 KB.

Per MAME ROM_START(esb), the bank2 data comes from `ROM_CONTINUE` halves of the same files used for the low-half pages.  Mapping:

```
File          MAME maincpu offset    What it is
136031.101    0x6000  (8KB)          CPU $6000-$7FFF (= existing bank ROM)
              0x10000 (8KB)          bank2 page 0 at $A000-$BFFF
136031.102    0xA000  (8KB)          (slapstic page, not bank2 — already covered)
              0x1C000 (8KB)          bank2 page 1 at $C000-$DFFF (or part)
              ...
```

So bank2 is composed of the high halves of 136031.101 / .102 / .203 / .104, plus parts of slapstic ROMs.  Total 48 KB across 2 selectable 24 KB pages.

**This is the most complex part to wire correctly.**  Recommendation: pull the actual maincpu region byte-by-byte from MAME debugger or careful ROM_CONTINUE trace, build a 64KB-per-page (with unused half) BRAM rather than fighting alignment.  Costs an extra M10K but eliminates bugs.

---

## Sequencing checklist

After SW hardware-validates:

1. Verify ESB.zip ROM names match the MRA's `<part name="...">` exactly. May need to update if user's zip has variant names.
2. Compute CRC for 136031.107 and 136031.108 (currently TBD in the MRA — fill in).
3. Implement `mod_esb` selector in Arcade-StarWars.sv.
4. Pass `mod_esb` through STARWARS_TOP into starwars.sv.
5. Add slapstic + slap ROM + bank2 ROM to starwars.sv (gated on mod_esb).
6. Update dn_addr decoders for ESB layout.
7. Quartus A&S.
8. Test with esb.zip on MiSTer SD card under `_Arcade/`.
9. PR to Videodr0me's repo: "Add Empire Strikes Back support."

---

## Quick reference: ESB ROM_START from MAME

```cpp
ROM_START( esb )
    ROM_REGION( 0x22000, "maincpu", 0 )
    ROM_LOAD( "136031-101.1f", 0x6000, 0x2000, CRC(ef1e3ae5) ... )
    ROM_CONTINUE(              0x10000, 0x2000 )
    ROM_LOAD( "136031-102.1jk",0xa000, 0x2000, CRC(62ce5c12) ... )
    ROM_CONTINUE(              0x1c000, 0x2000 )
    ROM_LOAD( "136031-203.1kl",0xc000, 0x2000, CRC(27b0889b) ... )
    ROM_CONTINUE(              0x1e000, 0x2000 )
    ROM_LOAD( "136031-104.1m", 0xe000, 0x2000, CRC(fd5c725e) ... )
    ROM_CONTINUE(              0x20000, 0x2000 )

    ROM_LOAD( "136031-105.3u", 0x14000, 0x4000, CRC(ea9e4dce) ... ) /* slapstic 0+1 */
    ROM_LOAD( "136031-106.2u", 0x18000, 0x4000, CRC(76d07f59) ... ) /* slapstic 2+3 */

    ROM_REGION( 0x1000, "vectorrom", 0 )
    ROM_LOAD( "136031-111.1l", 0x0000, 0x1000, CRC(b1f9bd12) ... )

    ROM_REGION( 0x10000, "audiocpu", 0 )
    ROM_LOAD( "136031-113.1jk",0x4000, 0x2000, CRC(24ae3815) ... )
    ROM_CONTINUE(              0xc000, 0x2000 )
    ROM_LOAD( "136031-112.1h", 0x6000, 0x2000, CRC(ca72d341) ... )
    ROM_CONTINUE(              0xe000, 0x2000 )

    ROM_REGION( 0x100, "avg:prom", 0)
    ROM_LOAD( "136021-109.4b", 0x0000, 0x0100, CRC(82fc3eb2) ... )  /* SAME as SW */

    /* Mathbox PROMs */
    ROM_REGION( 0x1000, "user2", 0 )
    ROM_LOAD( "136031-110.7h", 0x0000, 0x0400, CRC(b8d0f69d) ... )
    ROM_LOAD( "136031-109.7j", 0x0400, 0x0400, CRC(6a2a4d98) ... )
    /* ... 136031-108, 136031-107 — fill in CRC from MAME source */
ROM_END
```

---

## Why the architectural win is real

ESB's vector geometry comes through the **exact same AVG state PROM** as SW (`82fc3eb2`).  Our PROM-driven AVG reads that PROM and dispatches handlers byte-for-byte the way MAME does.  **Zero AVG-side changes** to support ESB.  The slapstic, bank2, and main-ROM layout are all main-CPU-bus issues, downstream of the AVG.

Videodr0me's hardcoded AVG (BW-derived) was tuned for SW opcodes; supporting ESB on his AVG would require carefully validating each SW-specific tweak still applies (mostly true, since SW and ESB use identical AVG instructions).  With our PROM-driven AVG, that validation is *literally the state PROM file* — guaranteed correct by construction.
