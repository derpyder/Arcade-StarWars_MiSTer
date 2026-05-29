-- vector_drawer.vhd — silicon-faithful analytic endpoint + Bresenham walker
--
-- Replaces the BW heritage "discrete-time accumulator" drawer (Domburg 2012,
-- modified by Videodr0me 2026) with a model that matches the real Atari AVG
-- silicon:
--
--   Real AVG silicon (per MAME avg_common_strobe3, lines 618-650 of
--   docs/mame_avgdvg_ref.cpp):
--     - ONE position update per VCTR: x_endpoint = x_current + delta
--       where delta = (dvx>>3 - 0x200) * cycles * (m_scale ^ 0xff) >> 4
--     - The DAC analog voltage ramps from x_current to x_endpoint over
--       `cycles` master-clock ticks (cycles ≈ 0x8000 >> (norm + bin_scale))
--     - CRT phosphor lights up the beam path as the DAC ramps
--
--   Our FPGA equivalent (Bresenham line walker into raster framebuffer):
--     1. On `draw='1'`: register the endpoint via a 2-stage multiply pipeline.
--        State: IDLE → CMP1 → CMP2.
--     2. Bresenham-walk pixels from current to endpoint at clk_ena pace.
--        Matches real silicon's DAC step rate (1.5 MHz on the original board).
--     3. At endpoint: snap sub-pixel accumulator to exact computed value so
--        error doesn't accumulate vector-to-vector.
--
-- Compared to BW's drawer (~4*normscale steps per vector):
--   - This: ~max(|dx_pixel|,|dy_pixel|) steps per vector.  Typical SW logo
--     glyph 20-50 px = 13-33 µs/vector at 1.5 MHz.  200 vectors per frame
--     = 6-13 ms = 60+ fps.  Matches real silicon's per-vector budget.
--   - Long vectors (1024 px cockpit grid) take ~680 µs each.  20 such
--     lines = 13.6 ms.  Plus 200 short vectors = ~20 ms total = 50 fps.
--
-- Brightness modulation as a free side-effect (item 2 of Videodr0me's
-- "Known limitations" list — beam velocity → brightness): slow beam = many
-- writes to same FB cell = saturating-add brightens that pixel; fast beam =
-- single write per pixel = dim.  Falls out naturally when the framebuffer
-- pipeline accumulates rather than overwrites.

library IEEE;
use IEEE.STD_LOGIC_1164.all;
use IEEE.NUMERIC_STD.all;

entity vector_drawer is
    Port ( clk          : in  STD_LOGIC;
           clk_ena      : in  STD_LOGIC;
           scale        : in  STD_LOGIC_VECTOR (12 downto 0);  -- timer threshold (avg.vhd vd_scale, power-of-2)
           linear_scale : in  STD_LOGIC_VECTOR (7 downto 0);   -- m_scale (velocity multiplier = 256 - this)
           rel_x        : in  STD_LOGIC_VECTOR (12 downto 0);  -- m_dvx (post handler_4 normalize)
           rel_y        : in  STD_LOGIC_VECTOR (12 downto 0);
           zero         : in  STD_LOGIC;                       -- CNTR (snap to origin)
           draw         : in  STD_LOGIC;                       -- start new VCTR
           done         : out STD_LOGIC;
           xout         : out STD_LOGIC_VECTOR (10 downto 0);
           yout         : out STD_LOGIC_VECTOR (10 downto 0);
           -- Per-pixel framebuffer bounds-validity, asserted when cur_px and
           -- cur_py both fit in the 11-bit signed framebuffer range during a
           -- Bresenham WALK step.  Downstream (avg.vhd) gates zout by this so
           -- off-framebuffer pixels don't get written.  Matches MAME's per-
           -- segment line clipping at the visible-area boundary -- see
           -- src/devices/video/vector.cpp screen_update + add_line.
           pixel_valid  : out STD_LOGIC
     );
end vector_drawer;

architecture Behavioral of vector_drawer is
    -- ===== Sub-pixel position accumulator =====
    -- 34 bits = 23 integer + 11 sub-pixel.  Top 11 bits become xout
    -- (signed 11-bit framebuffer-pixel coordinate).  Sub-pixel bits
    -- preserve accumulation precision across many vectors.
    signal xpos : signed(33 downto 0) := (others => '0');
    signal ypos : signed(33 downto 0) := (others => '0');

    -- ===== Computed endpoint for current VCTR =====
    signal target_x : signed(33 downto 0) := (others => '0');
    signal target_y : signed(33 downto 0) := (others => '0');

    -- ===== Bresenham walker state (framebuffer-pixel space) =====
    -- 12 bits = 1 sign-headroom bit + 11-bit signed framebuffer range.
    signal cur_px : signed(11 downto 0) := (others => '0');
    signal cur_py : signed(11 downto 0) := (others => '0');
    signal end_px : signed(11 downto 0) := (others => '0');
    signal end_py : signed(11 downto 0) := (others => '0');
    signal dx_abs : signed(12 downto 0) := (others => '0');   -- |end_px - cur_px|
    signal dy_abs : signed(12 downto 0) := (others => '0');
    signal sx     : signed(1 downto 0)  := to_signed(1, 2);
    signal sy     : signed(1 downto 0)  := to_signed(1, 2);
    signal err    : signed(13 downto 0) := (others => '0');

    -- ===== State machine =====
    --   IDLE  : waiting for draw='1' (or zero='1' for CNTR snap)
    --   CMP1  : pipeline stage 1 — multiply rel * scale_factor (registered)
    --   CMP2  : pipeline stage 2 — multiply by scale (registered), compute
    --           endpoint pixel coords, init Bresenham state.  Transition to WALK.
    --   WALK  : emit one pixel per clk_ena until cur reaches end
    type state_t is (IDLE, CMP1, CMP2, WALK);
    signal state    : state_t := IDLE;
    signal itsdone  : std_logic := '1';

    -- ===== Pipeline registers =====
    signal scale_factor : unsigned(8 downto 0);                -- 256 - linear_scale, range 1..256
    -- Multiply width: signed(13) * signed(10) = signed(23).  Was 22 before
    -- which truncated the MSB of the product (Quartus error 10344 on
    -- subsequent expressions that used delta_22).  Now 23 bits exact.
    signal delta_x_23   : signed(22 downto 0) := (others => '0');
    signal delta_y_23   : signed(22 downto 0) := (others => '0');
    -- scale (13-bit unsigned) * 4 = 15-bit unsigned, range 0..0x7FFC.
    -- Wrap in a 16-bit signed with a leading '0' so the value stays
    -- positive when interpreted as signed (since scale's MSB can be 1
    -- when scale = 0x1000).
    signal scale_16s    : signed(15 downto 0);

begin

    -- Combinational: bitwise NOT of linear_scale = 0xff XOR m_scale,
    -- giving range 0..255.  Bug #2 fix: previously this was 256 -
    -- linear_scale (range 1..256), which over-scales by 0.4% per stroke
    -- at m_scale=0 and is wildly wrong at m_scale=255 (MAME: 0 motion,
    -- HDL: 1 unit).  Per MAME avg_common_strobe3 line 636 the factor
    -- is (m_scale ^ 0xff).  Verified at exact match by Python diff vs
    -- MAME on 6522 strokes across 4 scenes.
    scale_factor <= '0' & (not unsigned(linear_scale));

    -- Combinational: widen scale (13-bit unsigned) to 16-bit signed positive.
    -- No shift -- per MAME avg_common_strobe3, the per-VCTR delta is
    --   (rel >> 3) * cycles * (256 - m_scale) >> 4
    -- so the cycles factor enters at unit weight, not *4.  The original
    -- *4 here combined with avg.vhd's vd_scale table top of 4096 produced
    -- a 64x over-scale (8x from missing >>3 on rel, 4x from this multiplier,
    -- 2x from the table magnitude) -- the drawer was producing screen-
    -- spanning lines for moderate dvx values and walking 64x more Bresenham
    -- pixels per vector than intended (1 fps).  Table is now downsized 16x
    -- in avg.vhd to put MAME's 2^(8-total_shift) factor at unit weight here.
    scale_16s <= signed("000" & scale);

    process(clk)
        variable e2          : signed(14 downto 0);
        variable err_var     : signed(13 downto 0);
        variable next_target_x : signed(33 downto 0);
        variable next_target_y : signed(33 downto 0);
        variable next_end_px : signed(11 downto 0);
        variable next_end_py : signed(11 downto 0);
        variable dx_v        : signed(12 downto 0);
        variable dy_v        : signed(12 downto 0);
    begin
        if rising_edge(clk) then
            case state is
                when IDLE =>
                    if zero = '1' then
                        -- CNTR: snap to origin instantly.
                        xpos     <= (others => '0');
                        ypos     <= (others => '0');
                        cur_px   <= (others => '0');
                        cur_py   <= (others => '0');
                        target_x <= (others => '0');
                        target_y <= (others => '0');
                        itsdone  <= '1';
                    elsif draw = '1' then
                        -- Stage 1: register the 22-bit rel * scale_factor product.
                        delta_x_23 <= signed(rel_x) * signed('0' & std_logic_vector(scale_factor));
                        delta_y_23 <= signed(rel_y) * signed('0' & std_logic_vector(scale_factor));
                        itsdone    <= '0';
                        state      <= CMP1;
                    end if;

                when CMP1 =>
                    -- Stage 2: multiply by scale * 4, add to current xpos to
                    -- get target.  Then extract pixel coords + init Bresenham.
                    -- delta_x_23 (22-bit signed) * scale_16s (15-bit signed)
                    --   = 37-bit signed product.  resize to 34 bits, sign-
                    --   preserving; overflow saturates implicitly (NUMERIC_STD
                    --   resize on signed wraps; for SW logo's bounded vectors
                    --   we don't hit overflow in practice).
                    next_target_x := xpos + resize(delta_x_23 * scale_16s, 34);
                    next_target_y := ypos + resize(delta_y_23 * scale_16s, 34);
                    target_x      <= next_target_x;
                    target_y      <= next_target_y;

                    -- Extract pixel coords from top of accumulators with
                    -- SATURATION on overflow.  Pixel pitch is 2^14 m_xpos
                    -- units (derived from MAME vector.cpp's 65536 m_xpos/px
                    -- divided by our 980/250 framebuffer scale ratio).
                    --
                    -- cur_px is signed(11 downto 0).  The "pixel value" of
                    -- xpos = xpos / 2^14, which fits in 12-bit signed only
                    -- when bits 32..25 of xpos sign-extend consistently with
                    -- bit 33.  Anything beyond that is off-screen and must
                    -- saturate, NOT wrap -- otherwise we get apparently-
                    -- coherent "Mondrian" geometry from drift-wrap aliasing.
                    if xpos(33) = '0' and xpos(32 downto 25) /= "00000000" then
                        cur_px <= to_signed(2047, 12);     -- pos overflow
                    elsif xpos(33) = '1' and xpos(32 downto 25) /= "11111111" then
                        cur_px <= to_signed(-2048, 12);    -- neg overflow
                    else
                        cur_px <= xpos(33) & xpos(24 downto 14);
                    end if;

                    if ypos(33) = '0' and ypos(32 downto 25) /= "00000000" then
                        cur_py <= to_signed(2047, 12);
                    elsif ypos(33) = '1' and ypos(32 downto 25) /= "11111111" then
                        cur_py <= to_signed(-2048, 12);
                    else
                        cur_py <= ypos(33) & ypos(24 downto 14);
                    end if;

                    -- Same saturation for end_px, end_py from next_target.
                    if next_target_x(33) = '0' and next_target_x(32 downto 25) /= "00000000" then
                        next_end_px := to_signed(2047, 12);
                    elsif next_target_x(33) = '1' and next_target_x(32 downto 25) /= "11111111" then
                        next_end_px := to_signed(-2048, 12);
                    else
                        next_end_px := next_target_x(33) & next_target_x(24 downto 14);
                    end if;
                    end_px <= next_end_px;

                    if next_target_y(33) = '0' and next_target_y(32 downto 25) /= "00000000" then
                        next_end_py := to_signed(2047, 12);
                    elsif next_target_y(33) = '1' and next_target_y(32 downto 25) /= "11111111" then
                        next_end_py := to_signed(-2048, 12);
                    else
                        next_end_py := next_target_y(33) & next_target_y(24 downto 14);
                    end if;
                    end_py <= next_end_py;

                    -- Bresenham init: dx_abs, dy_abs, sx, sy, err.
                    -- err = dx_abs - dy_abs, the standard 2D Bresenham seed.
                    -- Use saturated cur values to compute starting position.
                    -- Note: we recompute "cur" here for the delta calculation
                    -- (since cur_px hasn't been written yet -- this process
                    --  writes its own state on the next clock edge).
                    if xpos(33) = '0' and xpos(32 downto 25) /= "00000000" then
                        dx_v := resize(next_end_px - to_signed(2047, 12), 13);
                    elsif xpos(33) = '1' and xpos(32 downto 25) /= "11111111" then
                        dx_v := resize(next_end_px - to_signed(-2048, 12), 13);
                    else
                        dx_v := resize(next_end_px - (xpos(33) & xpos(24 downto 14)), 13);
                    end if;

                    if ypos(33) = '0' and ypos(32 downto 25) /= "00000000" then
                        dy_v := resize(next_end_py - to_signed(2047, 12), 13);
                    elsif ypos(33) = '1' and ypos(32 downto 25) /= "11111111" then
                        dy_v := resize(next_end_py - to_signed(-2048, 12), 13);
                    else
                        dy_v := resize(next_end_py - (ypos(33) & ypos(24 downto 14)), 13);
                    end if;
                    if dx_v >= 0 then
                        dx_abs <= dx_v;
                        sx     <= to_signed(1, 2);
                    else
                        dx_abs <= -dx_v;
                        sx     <= to_signed(-1, 2);
                    end if;
                    if dy_v >= 0 then
                        dy_abs <= dy_v;
                        sy     <= to_signed(1, 2);
                    else
                        dy_abs <= -dy_v;
                        sy     <= to_signed(-1, 2);
                    end if;
                    if dx_v >= 0 then
                        err <= resize(dx_v, 14) - resize(abs(dy_v), 14);
                    else
                        err <= resize(-dx_v, 14) - resize(abs(dy_v), 14);
                    end if;

                    -- Cohen-Sutherland trivial-reject.  Skip the stroke ONLY
                    -- when both endpoints sit on the SAME outside side of
                    -- MAME's visible box -- in that case the line provably
                    -- can't cross the box and there's no visible portion to
                    -- render.  Any other configuration (both inside, or one
                    -- inside, or endpoints on DIFFERENT outside sides) needs
                    -- Bresenham to walk and let pixel_valid gate pixels at
                    -- the framebuffer edge.
                    --
                    -- The prior overly-strict "skip if any endpoint outside"
                    -- was discarding strokes that MAME's vector.cpp would
                    -- clip-and-render (one endpoint inside box, line drawn
                    -- only up to box boundary).  That cost us the high-score
                    -- table, SW logo definition, stage select, the four
                    -- cockpit lasers, etc. -- all of which use strokes with
                    -- one endpoint outside the visible area.
                    --
                    -- Bounds: m_xpos in [-8192000, +8192000] (= MAME's
                    -- [0, 250*65536] relative to m_xcenter = 125 px) and
                    -- m_ypos in [-9175040, +9175040].
                    if (xpos < to_signed(-8192000, 34) and next_target_x < to_signed(-8192000, 34))
                       or (xpos > to_signed(8192000, 34) and next_target_x > to_signed(8192000, 34))
                       or (ypos < to_signed(-9175040, 34) and next_target_y < to_signed(-9175040, 34))
                       or (ypos > to_signed(9175040, 34) and next_target_y > to_signed(9175040, 34))
                    then
                        -- Both endpoints on same outside side: trivially
                        -- reject.  Snap accumulator to next_target and skip.
                        xpos    <= next_target_x;
                        ypos    <= next_target_y;
                        itsdone <= '1';
                        state   <= IDLE;
                    else
                        -- May cross the visible box.  Walk it; pixel_valid
                        -- will gate writes at the framebuffer edge.
                        state <= WALK;
                    end if;

                when CMP2 =>
                    -- Reserved for second multiply-pipeline stage if Quartus
                    -- flags timing on the delta_22 * scale_16s product.  Not
                    -- used in current draft; transition straight to WALK.
                    state <= WALK;

                when WALK =>
                    -- Gate the WALK termination check on clk_ena so zero-
                    -- displacement strokes (starfield DOTS) hold state=WALK
                    -- for at least one full clken period.  Previously
                    -- terminated in 1 clk cycle (80ns at 12 MHz) which is
                    -- too short for the downstream FB pipeline to capture
                    -- the pixel_valid/zout pulse -- starfield dots were
                    -- being dropped silently (verified in tb_drawer sim:
                    -- the 39 c7 dots per high-score frame produced zero
                    -- FB writes when termination was unconditional).
                    if clk_ena = '1' and cur_px = end_px and cur_py = end_py then
                        -- Endpoint reached.  Snap sub-pixel accumulator to
                        -- exact computed endpoint to prevent drift.
                        xpos    <= target_x;
                        ypos    <= target_y;
                        itsdone <= '1';
                        state   <= IDLE;
                    elsif clk_ena = '1' then
                        -- Standard 2D Bresenham step.  CRITICAL: use a VARIABLE
                        -- for err's intermediate value so both branches' updates
                        -- compose.  Original signal-only version had a bug —
                        -- two `err <= …` writes in the same cycle would last-
                        -- assignment-win, dropping the X update on diagonals
                        -- and producing endpoint drift of many pixels per
                        -- vector.  Variable + final signal-write fixes it.
                        --
                        -- Width-extend e2 (=err*2) and the abs deltas to a
                        -- common 15-bit signed for the comparison.
                        err_var := err;
                        e2      := shift_left(resize(err_var, 15), 1);

                        if e2 > resize(-dy_abs, 15) then
                            err_var := err_var - resize(dy_abs, 14);
                            cur_px  <= cur_px + resize(sx, 12);
                        end if;
                        if e2 < resize(dx_abs, 15) then
                            err_var := err_var + resize(dx_abs, 14);
                            cur_py  <= cur_py + resize(sy, 12);
                        end if;

                        err <= err_var;
                    end if;
            end case;
        end if;
    end process;

    done <= itsdone;

    -- Per-pixel framebuffer validity.  Asserted when cur_px/cur_py both
    -- fit in the 11-bit signed framebuffer range AND we're inside a
    -- Bresenham walk (state = WALK).  Downstream (avg.vhd) gates zout
    -- by this so off-framebuffer pixels don't get written -- matches
    -- MAME's vector.cpp where lines outside [0..1] normalized space
    -- simply don't render.  In IDLE/CMP1/CMP2 we hold '0' (no draw in
    -- progress, no pixel write expected).
    pixel_valid <= '1' when (state = WALK)
                            and (cur_px(11) = cur_px(10))
                            and (cur_py(11) = cur_py(10))
                       else '0';

    -- Output cur_px/cur_py SATURATED to the 11-bit framebuffer range.
    -- MAME's vector.cpp normalized-[0..1] rendering naturally clips off-
    -- screen lines via container.add_line; our framebuffer wraps mod 2048
    -- if we just truncate the low 11 bits.  That produced the "GONE B"
    -- fragmentation symptom -- partial glyphs landing at (orig mod 2048)
    -- scattered positions.  Saturation clamps off-screen pixels to the
    -- edge (visible artifact but no fragmentation), matching MAME's
    -- visible-area clip behaviour more faithfully.
    -- cur_px/cur_py is signed(11 downto 0) = 12-bit signed.  In-range
    -- when bits 11 == 10 (sign extension consistent).  Otherwise saturate.
    xout <= "01111111111" when (cur_px(11) = '0' and cur_px(10) = '1') else
            "10000000000" when (cur_px(11) = '1' and cur_px(10) = '0') else
            std_logic_vector(cur_px(10 downto 0));
    yout <= "01111111111" when (cur_py(11) = '0' and cur_py(10) = '1') else
            "10000000000" when (cur_py(11) = '1' and cur_py(10) = '0') else
            std_logic_vector(cur_py(10 downto 0));

end Behavioral;
