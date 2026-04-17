-- ============================================================
-- Testbench: tb_adt7420_driver
--
-- Includes a behavioural model of the ADT7420 sensor that:
--   1. Accepts the write to config register (0x03 = 0x20)
--   2. Accepts the write to set register pointer (0x00)
--   3. Responds to read requests with a 16-bit temperature value
--      (MSB first, 13-bit format: bits[15:3] = raw13, bits[2:0] = 0)
--
-- Simulated temperature: 25.0 °C
--   raw13 = 25.0 / 0.0625 = 400 = 0x190
--   16-bit word = raw13 << 3 = 0x190 << 3 = 0x0C80
--   MSB = 0x0C, LSB = 0x80
--   Expected temp_10x = 400 * 5 / 8 = 250
--
-- The CLK_DIV generic of i2c_master is overridden to 20 so the
-- simulation runs in microseconds rather than real-time seconds.
-- The WAIT_1S timer in adt7420_driver is counted in full at
-- 100 MHz, so we use a generous wait_for in the stimuli process.
-- ============================================================
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_adt7420_driver is
    -- Use a small CLK_DIV override. Because adt7420_driver instantiates
    -- i2c_master with default generics, and generics cannot be overridden
    -- from outside in structural instantiation, we provide a version of
    -- the driver whose i2c_master is configured for fast simulation.
    -- To speed up simulation also set SIM_SPEEDUP to true which replaces
    -- the 100 000 000-cycle wait with a 1000-cycle wait.
end tb_adt7420_driver;

architecture tb of tb_adt7420_driver is

    ----------------------------------------------------------------
    -- Fast simulation shim:
    -- We instantiate adt7420_driver directly. The 1-second timer
    -- (100 000 000 cycles @ 100 MHz) is the main simulation bottleneck.
    -- Solution: override CLK_DIV in i2c_master to 20 inside a wrapped
    -- version. Since we can't change generic from TB for sub-instances,
    -- we add a generic to adt7420_driver_sim below — a local copy that
    -- uses a generic for the i2c CLK_DIV and an accelerated timer.
    ----------------------------------------------------------------

    -- We use a local fast entity (see architecture below for declaration)
    component adt7420_driver_sim
        generic (
            CLK_DIV  : integer := 20;    -- fast I2C for simulation
            WAIT_MAX : integer := 1000   -- 1000 cycles instead of 100 000 000
        );
        port (
            clk, rst : in    std_logic;
            temp_10x : out   integer range -10000 to 10000;
            scl, sda : inout std_logic
        );
    end component;

    signal clk      : std_logic := '0';
    signal rst      : std_logic := '1';
    signal temp_10x : integer range -10000 to 10000;
    signal scl      : std_logic;
    signal sda      : std_logic;

    constant TbPeriod  : time    := 10 ns;    -- 100 MHz
    signal TbSimEnded  : std_logic := '0';

    ----------------------------------------------------------------
    -- ADT7420 sensor temperature to simulate
    -- 25.0 °C → raw13 = 400, word = 0x0C80
    ----------------------------------------------------------------
    constant TEMP_MSB : std_logic_vector(7 downto 0) := x"0C";
    constant TEMP_LSB : std_logic_vector(7 downto 0) := x"80";

    -- Expected output: 400 * 5 / 8 = 250  (= 25.0 °C × 10)
    constant EXPECTED_TEMP_10X : integer := 250;

begin

    -- External I2C pull-ups
    scl <= 'H';
    sda <= 'H';

    dut : adt7420_driver_sim
        generic map (
            CLK_DIV  => 20,
            WAIT_MAX => 1000
        )
        port map (
            clk      => clk,
            rst      => rst,
            temp_10x => temp_10x,
            scl      => scl,
            sda      => sda
        );

    -- Clock generator
    clk <= not clk after TbPeriod/2 when TbSimEnded /= '1' else '0';

    ----------------------------------------------------------------
    -- ADT7420 Sensor Model
    --
    -- Transaction sequence expected from driver:
    --   [1] WRITE 0x48, data=0x03 (set config register pointer)
    --   [2] WRITE 0x48, data=0x20, STOP (write config value)
    --   [3] WRITE 0x48, data=0x00 (set temperature register pointer)
    --   [4] READ  0x48 → MSB, no STOP
    --   [5] READ  0x48 → LSB, STOP
    --
    -- The slave model loops indefinitely, responding to each
    -- transaction in sequence.
    ----------------------------------------------------------------
    p_sensor_model : process
        variable addr_rw   : std_logic_vector(7 downto 0);
        variable data_byte : std_logic_vector(7 downto 0);
        variable is_read   : boolean;
        variable tx_byte   : std_logic_vector(7 downto 0);

        -- Track which read byte we are on (MSB=0, LSB=1)
        variable read_phase : integer := 0;

        procedure send_ack is
        begin
            -- SCL is currently high after the 8th bit was sampled.
            -- Wait for SCL to fall (master pulls it low for ACK bit).
            wait until falling_edge(scl);
            sda <= '0';                    -- assert ACK (low)
            wait until rising_edge(scl);   -- ACK clocked by master
            wait until falling_edge(scl);  -- SCL falls again: release SDA
            sda <= 'Z';
        end procedure;

        procedure recv_bits (
            signal sda_bus : inout std_logic;
            variable result : out std_logic_vector(7 downto 0)
        ) is
        begin
            for i in 7 downto 0 loop
                wait until rising_edge(scl);
                result(i) := to_x01(sda_bus);
            end loop;
        end procedure;

        procedure send_bits (
            constant tx : in std_logic_vector(7 downto 0)
        ) is
        begin
            for i in 7 downto 0 loop
                wait until falling_edge(scl);
                if tx(i) = '0' then
                    sda <= '0';
                else
                    sda <= 'Z';
                end if;
            end loop;
            -- release before master drives ACK/NACK
            wait until falling_edge(scl);
            sda <= 'Z';
        end procedure;

    begin
        sda <= 'Z';
        read_phase := 0;

        sensor_loop : loop
            -- Wait for I2C START: SDA falls while SCL is high
            wait until falling_edge(sda) and (to_x01(scl) = '1');

            -- Receive address byte (7-bit addr + R/W)
            recv_bits(sda, addr_rw);
            is_read := (addr_rw(0) = '1');

            -- ACK the address
            send_ack;

            if not is_read then
                -- ---- WRITE transaction: receive one data byte ----
                recv_bits(sda, data_byte);
                report "Sensor model: received write byte 0x" & to_hstring(data_byte);
                send_ack;
                -- No action needed; we just acknowledge all writes

            else
                -- ---- READ transaction: send temperature byte ----
                if read_phase = 0 then
                    report "Sensor model: sending temperature MSB 0x" & to_hstring(TEMP_MSB);
                    send_bits(TEMP_MSB);
                    read_phase := 1;
                else
                    report "Sensor model: sending temperature LSB 0x" & to_hstring(TEMP_LSB);
                    send_bits(TEMP_LSB);
                    read_phase := 0;
                end if;

                -- Wait for master to send ACK or NACK (we ignore it)
                wait until falling_edge(scl);
            end if;

        end loop sensor_loop;
    end process p_sensor_model;

    ----------------------------------------------------------------
    -- Stimuli
    ----------------------------------------------------------------
    stimuli : process
    begin
        -- Reset
        rst <= '1';
        wait for 10 * TbPeriod;
        rst <= '0';

        -- Wait long enough for: config sequence + 1x WAIT_MAX + read sequence
        -- WAIT_MAX=1000 cycles @ 100 MHz = 10 us
        -- I2C transactions are much shorter with CLK_DIV=20
        -- Generous margin: 5 ms simulation time
        wait for 5 ms;

        -- Check result
        report "temp_10x = " & integer'image(temp_10x) &
               "  (expected " & integer'image(EXPECTED_TEMP_10X) & ")";

        assert temp_10x = EXPECTED_TEMP_10X
            report "FAILED: temp_10x mismatch! Got " & integer'image(temp_10x) &
                   ", expected " & integer'image(EXPECTED_TEMP_10X)
            severity error;

        if temp_10x = EXPECTED_TEMP_10X then
            report "PASSED: temperature correctly decoded as " &
                   integer'image(temp_10x / 10) & "." &
                   integer'image(temp_10x mod 10) & " C";
        end if;

        TbSimEnded <= '1';
        wait;
    end process stimuli;

end tb;


-- ============================================================
-- Fast simulation version of adt7420_driver
-- Adds CLK_DIV and WAIT_MAX generics for testbench use.
-- Logic is identical to adt7420_driver; only the constants differ.
-- ============================================================
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity adt7420_driver_sim is
    generic (
        CLK_DIV  : integer := 20;
        WAIT_MAX : integer := 1000
    );
    port (
        clk, rst : in    std_logic;
        temp_10x : out   integer range -10000 to 10000;
        scl, sda : inout std_logic
    );
end entity;

architecture rtl of adt7420_driver_sim is

    type state_t is (
        WAIT_1S,
        CFG_PTR,  WAIT_CFG_PTR,
        CFG_VAL,  WAIT_CFG_VAL,
        SET_REG,  WAIT_SET,
        READ_MSB, WAIT_MSB,
        READ_LSB, WAIT_LSB,
        CALC
    );

    signal state      : state_t := WAIT_1S;
    signal timer      : integer range 0 to 100_000_001 := 0;
    signal configured : std_logic := '0';

    signal m_start, m_stop, m_busy, m_rw : std_logic := '0';
    signal m_din, m_dout                 : std_logic_vector(7 downto 0) := (others => '0');
    signal m_nack                        : std_logic;
    signal cap_msb, cap_lsb             : std_logic_vector(7 downto 0) := (others => '0');

begin

    I2C_INST: entity work.i2c_master
        generic map ( CLK_DIV => CLK_DIV )
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

    process(clk)
        variable raw_13bit : signed(12 downto 0);
        variable tmp       : signed(19 downto 0);
    begin
        if rising_edge(clk) then
            m_start <= '0';
            m_stop  <= '0';

            if rst = '1' then
                state      <= WAIT_1S;
                timer      <= 0;
                configured <= '0';
                cap_msb    <= (others => '0');
                cap_lsb    <= (others => '0');
                temp_10x   <= 0;
            else
                case state is
                    when WAIT_1S =>
                        if configured = '0' then
                            state <= CFG_PTR;
                        elsif timer = WAIT_MAX then
                            timer <= 0;
                            state <= SET_REG;
                        else
                            timer <= timer + 1;
                        end if;

                    when CFG_PTR =>
                        m_rw <= '0'; m_din <= x"03"; m_stop <= '0'; m_start <= '1';
                        state <= WAIT_CFG_PTR;
                    when WAIT_CFG_PTR =>
                        if m_busy = '1' then m_start <= '0';
                        else
                            if m_nack = '1' then state <= WAIT_1S;
                            else state <= CFG_VAL; end if;
                        end if;

                    when CFG_VAL =>
                        m_rw <= '0'; m_din <= x"20"; m_stop <= '1'; m_start <= '1';
                        state <= WAIT_CFG_VAL;
                    when WAIT_CFG_VAL =>
                        if m_busy = '1' then m_start <= '0';
                        else
                            if m_nack = '1' then state <= WAIT_1S;
                            else configured <= '1'; state <= WAIT_1S; end if;
                        end if;

                    when SET_REG =>
                        m_rw <= '0'; m_din <= x"00"; m_stop <= '0'; m_start <= '1';
                        state <= WAIT_SET;
                    when WAIT_SET =>
                        if m_busy = '1' then m_start <= '0';
                        else
                            if m_nack = '1' then state <= WAIT_1S;
                            else state <= READ_MSB; end if;
                        end if;

                    when READ_MSB =>
                        m_rw <= '1'; m_stop <= '0'; m_start <= '1';
                        state <= WAIT_MSB;
                    when WAIT_MSB =>
                        if m_busy = '1' then m_start <= '0';
                        else
                            if m_nack = '1' then state <= WAIT_1S;
                            else cap_msb <= m_dout; state <= READ_LSB; end if;
                        end if;

                    when READ_LSB =>
                        m_rw <= '1'; m_stop <= '1'; m_start <= '1';
                        state <= WAIT_LSB;
                    when WAIT_LSB =>
                        if m_busy = '1' then m_start <= '0';
                        else
                            if m_nack = '1' then state <= WAIT_1S;
                            else cap_lsb <= m_dout; state <= CALC; end if;
                        end if;

                    when CALC =>
                        raw_13bit := signed(cap_msb & cap_lsb(7 downto 3));
                        tmp       := resize(raw_13bit, 20) * 5;
                        temp_10x  <= to_integer(tmp(19 downto 3));
                        state     <= WAIT_1S;

                    when others => state <= WAIT_1S;
                end case;
            end if;
        end if;
    end process;

end architecture;