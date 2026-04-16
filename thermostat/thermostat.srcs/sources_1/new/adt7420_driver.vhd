library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

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

        CFG_PTR, WAIT_CFG_PTR,
        CFG_VAL, WAIT_CFG_VAL,

        SET_REG, WAIT_SET,
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

    ----------------------------------------------------------------
    -- I2C Master instance
    ----------------------------------------------------------------
    I2C_INST: entity work.i2c_master
        port map (
            clk          => clk,
            rst          => rst,
            addr         => "1001000",
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
        variable raw_13bit : signed(12 downto 0);
        variable tmp       : signed(15 downto 0);
    begin
        if rising_edge(clk) then

            -- defaults
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
                    -- Wait / trigger
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
                    -- Configure sensor (13-bit mode)
                    ----------------------------------------------------------------
                    when CFG_PTR =>
                        m_rw   <= '0';
                        m_din  <= x"03";
                        m_stop <= '0';
                        m_start <= '1';
                        state   <= WAIT_CFG_PTR;

                    when WAIT_CFG_PTR =>
                        if m_busy = '1' then
                            m_start <= '0';
                        elsif m_busy = '0' then
                            if m_nack = '1' then
                                state <= WAIT_1S;
                            else
                                state <= CFG_VAL;
                            end if;
                        end if;

                    when CFG_VAL =>
                        m_rw   <= '0';
                        m_din  <= x"20"; -- 13-bit mode
                        m_stop <= '1';
                        m_start <= '1';
                        state   <= WAIT_CFG_VAL;

                    when WAIT_CFG_VAL =>
                        if m_busy = '1' then
                            m_start <= '0';
                        elsif m_busy = '0' then
                            if m_nack = '1' then
                                state <= WAIT_1S;
                            else
                                configured <= '1';
                                state <= WAIT_1S;
                            end if;
                        end if;

                    ----------------------------------------------------------------
                    -- Set temperature register pointer
                    ----------------------------------------------------------------
                    when SET_REG =>
                        m_rw   <= '0';
                        m_din  <= x"00";
                        m_stop <= '0';
                        m_start <= '1';
                        state   <= WAIT_SET;

                    when WAIT_SET =>
                        if m_busy = '1' then
                            m_start <= '0';
                        elsif m_busy = '0' then
                            if m_nack = '1' then
                                state <= WAIT_1S;
                            else
                                state <= READ_MSB;
                            end if;
                        end if;

                    ----------------------------------------------------------------
                    -- Read MSB
                    ----------------------------------------------------------------
                    when READ_MSB =>
                        m_rw    <= '1';
                        m_stop  <= '0';
                        m_start <= '1';
                        state   <= WAIT_MSB;

                    when WAIT_MSB =>
                        if m_busy = '1' then
                            m_start <= '0';
                        elsif m_busy = '0' then
                            if m_nack = '1' then
                                state <= WAIT_1S;
                            else
                                cap_msb <= m_dout;
                                state <= READ_LSB;
                            end if;
                        end if;

                    ----------------------------------------------------------------
                    -- Read LSB
                    ----------------------------------------------------------------
                    when READ_LSB =>
                        m_rw    <= '1';
                        m_stop  <= '1';
                        m_start <= '1';
                        state   <= WAIT_LSB;

                    when WAIT_LSB =>
                        if m_busy = '1' then
                            m_start <= '0';
                        elsif m_busy = '0' then
                            if m_nack = '1' then
                                state <= WAIT_1S;
                            else
                                cap_lsb <= m_dout;
                                state <= CALC;
                            end if;
                        end if;

                    ----------------------------------------------------------------
                    -- Calculate temperature (°C ×10, rounded)
                    ----------------------------------------------------------------
                    when CALC =>
                        raw_13bit := signed(cap_msb & cap_lsb(7 downto 3));

                        -- multiply by 5
                        tmp := resize(raw_13bit, 16) * 5;

                        -- rounding (symmetric)
                        if tmp >= 0 then
                            tmp := tmp + 4;
                        else
                            tmp := tmp - 4;
                        end if;

                        -- divide by 8 (shift)
                        temp_10x <= to_integer(shift_right(tmp, 3));

                        state <= WAIT_1S;

                    when others =>
                        state <= WAIT_1S;

                end case;
            end if;
        end if;
    end process;

end architecture;