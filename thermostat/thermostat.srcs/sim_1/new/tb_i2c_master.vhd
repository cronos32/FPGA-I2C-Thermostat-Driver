-- ============================================================
-- Testbench: tb_i2c_master
-- Tests: write transaction, read transaction
-- Slave model: properly timed ACK + drives 0xA5 on read
-- ============================================================
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_i2c_master is
end tb_i2c_master;

architecture tb of tb_i2c_master is

    -- Use a small CLK_DIV to keep simulation fast
    constant CLK_DIV_TB : integer := 20;  -- SCL period = 20 * 4 * 5 ns = 400 ns → ~2.5 MHz

    component i2c_master
        generic ( CLK_DIV : integer := 250 );
        port (
            clk, rst     : in    std_logic;
            addr         : in    std_logic_vector(6 downto 0);
            rw           : in    std_logic;
            data_in      : in    std_logic_vector(7 downto 0);
            data_out     : out   std_logic_vector(7 downto 0);
            start        : in    std_logic;
            stop_on_done : in    std_logic;
            busy, nack   : out   std_logic;
            scl, sda     : inout std_logic
        );
    end component;

    signal clk          : std_logic := '0';
    signal rst          : std_logic := '1';
    signal addr         : std_logic_vector(6 downto 0) := (others => '0');
    signal rw           : std_logic := '0';
    signal data_in      : std_logic_vector(7 downto 0) := (others => '0');
    signal data_out     : std_logic_vector(7 downto 0);
    signal start_sig    : std_logic := '0';
    signal stop_on_done : std_logic := '0';
    signal busy         : std_logic;
    signal nack         : std_logic;
    signal scl          : std_logic;
    signal sda          : std_logic;

    -- Slave drives this byte on read transactions
    signal slave_read_data : std_logic_vector(7 downto 0) := x"A5";

    constant TbPeriod  : time := 10 ns;  -- 100 MHz
    signal TbSimEnded  : std_logic := '0';

    -- Quarter-period of SCL in simulation time (for slave timing)
    constant SCL_Q : time := TbPeriod * (CLK_DIV_TB / 2);

begin

    -- External pull-ups (weak '1' on open-drain bus)
    scl <= 'H';
    sda <= 'H';

    dut : i2c_master
    generic map ( CLK_DIV => CLK_DIV_TB )
    port map (
        clk          => clk,
        rst          => rst,
        addr         => addr,
        rw           => rw,
        data_in      => data_in,
        data_out     => data_out,
        start        => start_sig,
        stop_on_done => stop_on_done,
        busy         => busy,
        nack         => nack,
        scl          => scl,
        sda          => sda
    );

    -- Clock generator
    clk <= not clk after TbPeriod/2 when TbSimEnded /= '1' else '0';

    ----------------------------------------------------------------
    -- I2C Slave model
    -- Handles both write and read transactions correctly.
    -- ACK is asserted AFTER SCL falls for the 8th data bit and
    -- released BEFORE SCL rises for the ACK bit.
    ----------------------------------------------------------------
    p_slave : process
        variable is_read  : boolean;
        variable rx_byte  : std_logic_vector(7 downto 0);
    begin
        sda <= 'Z';

        slave_loop : loop
            -- Wait for START condition: SDA falls while SCL is high
            wait until falling_edge(sda) and (to_x01(scl) = '1');

            -- ---- Receive 8 address+RW bits ----
            -- Wait for 8 falling edges on SCL (bits clocked in on rising edge)
            -- On the last (8th) falling edge SCL goes low → master releases SDA for ACK
            is_read := false;
            for i in 7 downto 0 loop
                wait until rising_edge(scl);
                if i = 0 then
                    -- bit 0 is the R/W bit
                    is_read := (to_x01(sda) = '1');
                end if;
            end loop;

            -- ---- Send ACK for address byte ----
            -- SCL is high after sampling, wait for it to fall
            wait until falling_edge(scl);
            sda <= '0';                        -- pull SDA low: ACK
            wait until falling_edge(scl);      -- ACK bit clocked; release after
            sda <= 'Z';

            -- ---- Data phase ----
            if is_read then
                -- Master reads: slave drives 8 bits MSB-first
                for i in 7 downto 0 loop
                    wait until falling_edge(scl);   -- SCL low: safe to change SDA
                    if slave_read_data(i) = '0' then
                        sda <= '0';
                    else
                        sda <= 'Z';                 -- open-drain high
                    end if;
                end loop;
                -- Release SDA before master samples ACK/NACK
                wait until falling_edge(scl);
                sda <= 'Z';
                -- Master sends ACK/NACK; we just wait for it
                wait until falling_edge(scl);

            else
                -- Master writes: slave receives 8 bits (just count them)
                for i in 7 downto 0 loop
                    wait until rising_edge(scl);
                    rx_byte(i) := to_x01(sda);
                end loop;
                report "Slave received data byte: 0x" &
                    to_hstring(std_logic_vector'(rx_byte(7) & rx_byte(6) &
                               rx_byte(5) & rx_byte(4) & rx_byte(3) &
                               rx_byte(2) & rx_byte(1) & rx_byte(0)));

                -- ---- Send ACK for data byte ----
                wait until falling_edge(scl);
                sda <= '0';
                wait until falling_edge(scl);
                sda <= 'Z';
            end if;

        end loop slave_loop;
    end process p_slave;

    ----------------------------------------------------------------
    -- Stimuli process
    ----------------------------------------------------------------
    stimuli : process
    begin
        -- ---- Reset ----
        rst <= '1';
        wait for 5 * TbPeriod;
        rst <= '0';
        wait for 5 * TbPeriod;

        ---- TEST 1: Write transaction ----
        report "=== TEST 1: Write 0xAB to addr 0x48 ===";
        addr         <= "1001000";  -- 0x48
        rw           <= '0';
        data_in      <= x"AB";
        stop_on_done <= '1';

        start_sig <= '1';
        wait until rising_edge(clk) and busy = '1';
        start_sig <= '0';

        wait until busy = '0';
        wait for 10 * TbPeriod;

        -- Check: no NACK expected
        assert nack = '0'
            report "TEST 1 FAILED: unexpected NACK on write" severity error;
        report "TEST 1 PASSED: write complete, nack=" & std_logic'image(nack);

        ---- TEST 2: Read transaction ----
        report "=== TEST 2: Read from addr 0x48, expect 0xA5 ===";
        addr         <= "1001000";
        rw           <= '1';
        stop_on_done <= '1';

        start_sig <= '1';
        wait until rising_edge(clk) and busy = '1';
        start_sig <= '0';

        wait until busy = '0';
        wait for 10 * TbPeriod;

        assert data_out = x"A5"
            report "TEST 2 FAILED: expected 0xA5, got 0x" &
                   to_hstring(data_out) severity error;
        report "TEST 2 PASSED: data_out=0x" & to_hstring(data_out);

        ---- Done ----
        report "=== All I2C master tests complete ===";
        TbSimEnded <= '1';
        wait;
    end process stimuli;

end tb;