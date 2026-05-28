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
           yout         : out STD_LOGIC_VECTOR (10 downto 0)
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
    signal delta_x_22   : signed(21 downto 0) := (others => '0');  -- rel_x(13s) * scale_factor(9u)
    signal delta_y_22   : signed(21 downto 0) := (others => '0');
    -- scale (13-bit unsigned) * 4 = 15-bit unsigned, range 0..0x7FFC.
    -- Wrap in a 16-bit signed with a leading '0' so the value stays
    -- positive when interpreted as signed (since scale's MSB can be 1
    -- when scale = 0x1000).
    signal scale_16s    : signed(15 downto 0);

begin

    -- Combinational: 256 - linear_scale.  9-bit unsigned, range 1..256.
    scale_factor <= to_unsigned(256, 9) - ('0' & unsigned(linear_scale));

    -- Combinational: scale (13-bit unsigned, always non-negative) * 4.
    -- Result is 16-bit signed positive (top bit kept 0 via leading '0').
    scale_16s <= signed('0' & scale & "00");

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
                        delta_x_22 <= signed(rel_x) * signed('0' & std_logic_vector(scale_factor));
                        delta_y_22 <= signed(rel_y) * signed('0' & std_logic_vector(scale_factor));
                        itsdone    <= '0';
                        state      <= CMP1;
                    end if;

                when CMP1 =>
                    -- Stage 2: multiply by scale * 4, add to current xpos to
                    -- get target.  Then extract pixel coords + init Bresenham.
                    -- delta_x_22 (22-bit signed) * scale_16s (15-bit signed)
                    --   = 37-bit signed product.  resize to 34 bits, sign-
                    --   preserving; overflow saturates implicitly (NUMERIC_STD
                    --   resize on signed wraps; for SW logo's bounded vectors
                    --   we don't hit overflow in practice).
                    next_target_x := xpos + resize(delta_x_22 * scale_16s, 34);
                    next_target_y := ypos + resize(delta_y_22 * scale_16s, 34);
                    target_x      <= next_target_x;
                    target_y      <= next_target_y;

                    -- Extract pixel coords from top of accumulators.  cur_px
                    -- has 1 sign-headroom bit + 11-bit framebuffer range.
                    cur_px        <= xpos(33) & xpos(30 downto 20);
                    cur_py        <= ypos(33) & ypos(30 downto 20);
                    next_end_px   := next_target_x(33) & next_target_x(30 downto 20);
                    next_end_py   := next_target_y(33) & next_target_y(30 downto 20);
                    end_px        <= next_end_px;
                    end_py        <= next_end_py;

                    -- Bresenham init: dx_abs, dy_abs, sx, sy, err.
                    -- err = dx_abs - dy_abs, the standard 2D Bresenham seed.
                    dx_v := resize(next_end_px - (xpos(33) & xpos(30 downto 20)), 13);
                    dy_v := resize(next_end_py - (ypos(33) & ypos(30 downto 20)), 13);
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

                    state <= WALK;
                    -- (CMP2 state folded into CMP1 for now; multiply pipeline
                    --  depth might force a second register if timing fails.)

                when CMP2 =>
                    -- Reserved for second multiply-pipeline stage if Quartus
                    -- flags timing on the delta_22 * scale_16s product.  Not
                    -- used in current draft; transition straight to WALK.
                    state <= WALK;

                when WALK =>
                    if cur_px = end_px and cur_py = end_py then
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

    -- Output the lower 11 bits of cur_px/cur_py.  Out-of-range pixels
    -- (cur_px outside [-1024, 1023]) wrap; framebuffer write path should
    -- bounds-check before writing.
    xout <= std_logic_vector(cur_px(10 downto 0));
    yout <= std_logic_vector(cur_py(10 downto 0));

end Behavioral;
