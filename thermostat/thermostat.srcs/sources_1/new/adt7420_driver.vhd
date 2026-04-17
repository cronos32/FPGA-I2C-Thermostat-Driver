library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- ADT7420 Driver
-- Assumes 100 MHz system clock (timer counts to 100_000_000 for 1 s).
-- Sensor is configured in 13-bit mode (reg 0x03 = 0x20).
-- Temperature register (0x00) returns 2 bytes, MSB first:
--   Bits [15:3] = signed 13-bit value, LSB = 0.0625 °C
-- Output temp_10x = temperature × 10  (e.g. 245 → 24.5 °C)

entity adt7420_driver is
    port (
        clk, rst : in    std_logic;
        temp_10x : out   integer range -10000 to 10000;
        scl, sda : inout std_logic
    );
end entity;

architecture rtl of adt7420_driver is

    type state_t is (
        WAIT_1S,

        CFG_PTR,  WAIT_CFG_PTR,
        CFG_VAL,  WAIT_CFG_VAL,

        SET_REG,  WAIT_SET,
        READ_MSB, WAIT_MSB,
        READ_LSB, WAIT_LSB,

        CALC
    );

    signal state : state_t := WAIT_1S;
    signal timer : integer range 0 to 100_000_001 := 0;

    signal configured : std_logic := '0';

    signal m_start, m_stop, m_busy, m_rw : std_logic := '0';
    signal m_din, m_dout                 : std_logic_vector(7 downto 0) := (others => '0');
    signal m_nack                        : std_logic;

    signal cap_msb, cap_lsb : std_logic_vector(7 downto 0) := (others => '0');

begin

    I2C_INST: entity work.i2c_master
        port map (
            clk          => clk,
            rst          => rst,
            addr         => "1001000",  -- ADT7420 default I2C address 0x48
            rw           => m_rw,
            data_in      => m_din,
            data_out     => m_dout,
            start        => m_start,
            stop_on_done => m_stop,
            busy         => m_busy,
            nack         => m_nack,
            scl          => scl,
            sda          => sda
        );

    ----------------------------------------------------------------
    -- FSM
    ----------------------------------------------------------------
    process(clk)
        -- 13-bit signed raw value from sensor (bits 15 downto 3 of 16-bit register)
        variable raw_13bit : signed(12 downto 0);
        -- Extended for multiplication without overflow
        variable tmp       : signed(19 downto 0);
    begin
        if rising_edge(clk) then

            -- Pulse-only signals: clear every cycle, set explicitly below
            m_start <= '0';
            m_stop  <= '0';

            if rst = '1' then
                state       <= WAIT_1S;
                timer       <= 0;
                configured  <= '0';
                cap_msb     <= (others => '0');
                cap_lsb     <= (others => '0');
                temp_10x    <= 0;

            else
                case state is

                    ----------------------------------------------------------------
                    -- Wait 1 s between reads; skip wait for first-time config
                    ----------------------------------------------------------------
                    when WAIT_1S =>
                        if configured = '0' then
                            state <= CFG_PTR;
                        elsif timer = 100_000_000 then
                            timer <= 0;
                            state <= SET_REG;
                        else
                            timer <= timer + 1;
                        end if;

                    ----------------------------------------------------------------
                    -- Write config register pointer (0x03)
                    ----------------------------------------------------------------
                    when CFG_PTR =>
                        m_rw    <= '0';
                        m_din   <= x"03";
                        m_stop  <= '0';
                        m_start <= '1';
                        state   <= WAIT_CFG_PTR;

                    when WAIT_CFG_PTR =>
                        if m_busy = '1' then
                            m_start <= '0';
                        else
                            if m_nack = '1' then
                                state <= WAIT_1S;   -- retry after 1 s
                            else
                                state <= CFG_VAL;
                            end if;
                        end if;

                    ----------------------------------------------------------------
                    -- Write config value: 0x20 = 13-bit mode, continuous conversion
                    ----------------------------------------------------------------
                    when CFG_VAL =>
                        m_rw    <= '0';
                        m_din   <= x"20";
                        m_stop  <= '1';             -- generate STOP after this byte
                        m_start <= '1';
                        state   <= WAIT_CFG_VAL;

                    when WAIT_CFG_VAL =>
                        if m_busy = '1' then
                            m_start <= '0';
                        else
                            if m_nack = '1' then
                                state <= WAIT_1S;
                            else
                                configured <= '1';
                                state      <= WAIT_1S;
                            end if;
                        end if;

                    ----------------------------------------------------------------
                    -- Point sensor at temperature register (0x00)
                    ----------------------------------------------------------------
                    when SET_REG =>
                        m_rw    <= '0';
                        m_din   <= x"00";
                        m_stop  <= '0';
                        m_start <= '1';
                        state   <= WAIT_SET;

                    when WAIT_SET =>
                        if m_busy = '1' then
                            m_start <= '0';
                        else
                            if m_nack = '1' then
                                state <= WAIT_1S;
                            else
                                state <= READ_MSB;
                            end if;
                        end if;

                    ----------------------------------------------------------------
                    -- Read MSB (repeated-start; no STOP yet)
                    ----------------------------------------------------------------
                    when READ_MSB =>
                        m_rw    <= '1';
                        m_stop  <= '0';
                        m_start <= '1';
                        state   <= WAIT_MSB;

                    when WAIT_MSB =>
                        if m_busy = '1' then
                            m_start <= '0';
                        else
                            if m_nack = '1' then
                                state <= WAIT_1S;
                            else
                                cap_msb <= m_dout;
                                state   <= READ_LSB;
                            end if;
                        end if;

                    ----------------------------------------------------------------
                    -- Read LSB (STOP after this byte)
                    ----------------------------------------------------------------
                    when READ_LSB =>
                        m_rw    <= '1';
                        m_stop  <= '1';
                        m_start <= '1';
                        state   <= WAIT_LSB;

                    when WAIT_LSB =>
                        if m_busy = '1' then
                            m_start <= '0';
                        else
                            if m_nack = '1' then
                                state <= WAIT_1S;
                            else
                                cap_lsb <= m_dout;
                                state   <= CALC;
                            end if;
                        end if;

                    ----------------------------------------------------------------
                    -- Assemble 13-bit signed value and convert to temp × 10
                    --
                    -- ADT7420 13-bit register layout (16-bit word, MSB first):
                    --   Byte 0 (MSB): bits [15:8]
                    --   Byte 1 (LSB): bits [ 7:0],  bits [2:0] are always 0
                    --   Raw 13-bit value = word[15:3]
                    --   Resolution = 0.0625 °C / LSB
                    --
                    -- temp_10x = raw_13bit × 0.0625 × 10
                    --          = raw_13bit × 0.625
                    --          = raw_13bit × 5 / 8
                    --
                    -- Example: 25.0 °C → raw = 25/0.0625 = 400 = 0x190
                    --   word = 0x0C80, bits[15:3] = 0x190 = 400
                    --   temp_10x = 400 × 5 / 8 = 250  → 25.0 °C ✓
                    ----------------------------------------------------------------
                    when CALC =>
                        -- Reconstruct 13-bit signed integer from two captured bytes
                        -- word[15:8] = cap_msb,  word[7:0] = cap_lsb
                        -- raw_13bit  = word[15:3] = cap_msb[7:0] & cap_lsb[7:3]
                        raw_13bit := signed(cap_msb & cap_lsb(7 downto 3));

                        -- Multiply by 5 then arithmetic-right-shift by 3 (÷8)
                        tmp := resize(raw_13bit, 20) * 5;
                        temp_10x <= to_integer(tmp(19 downto 3)); -- shift right 3 = ÷8

                        state <= WAIT_1S;

                    when others =>
                        state <= WAIT_1S;

                end case;
            end if;
        end if;
    end process;

end architecture;