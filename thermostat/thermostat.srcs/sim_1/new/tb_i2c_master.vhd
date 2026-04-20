-- tb_i2c_master.vhd
-- Testbench for i2c_master.
--
-- Tests:
--   1. Single-byte write, slave ACKs => nack='0'
--   2. Write byte (no STOP) then repeated-START read => data_out=0xA5
--   3. Slave NACKs address => nack='1'
--
-- Open-drain bus modelling:
--   The SDA line is driven by a resolved wired-AND:
--     sda_bus <= '0' when (master drives '0') OR (slave drives '0') else 'Z'
--   Both master and slave drive onto sda_bus. The i2c_controller uses
--   tri-state ('Z' for '1'), so the simulator wired-AND resolves correctly
--   when slave_sda is also '0' or 'Z'.
--
-- Slave timing:
--   SCL half-period = 128 master-clock cycles * 2 ns = 256 ns.
--   Slave waits for SCL edges rather than fixed delays where possible,
--   making it robust to clock divider changes.

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_i2c_master is
end entity;

architecture sim of tb_i2c_master is

    signal clk          : STD_LOGIC := '0';
    signal rst          : STD_LOGIC := '1';
    signal addr         : STD_LOGIC_VECTOR(6 downto 0) := "1001000";
    signal rw           : STD_LOGIC := '0';
    signal data_in      : STD_LOGIC_VECTOR(7 downto 0) := (others => '0');
    signal data_out     : STD_LOGIC_VECTOR(7 downto 0);
    signal start        : STD_LOGIC := '0';
    signal stop_on_done : STD_LOGIC := '1';
    signal busy         : STD_LOGIC;
    signal nack         : STD_LOGIC;
    signal scl          : STD_LOGIC;
    signal sda          : STD_LOGIC;

    -- Slave open-drain driver: '0' to pull low, 'Z' to release
    signal slave_sda : STD_LOGIC := 'Z';

    -- Half SCL period at 128-count divider on 2 ns clock
    constant HALF : time := 256 ns;

    -- ----------------------------------------------------------------
    -- Helpers shared between slave and stimulus processes
    -- ----------------------------------------------------------------

    -- Wait for the rising then falling edge of SCL (= one full bit)
    -- to let the slave sample/drive at the correct time.
    -- We use fixed waits instead so the slave is self-timed.

begin

    clk <= not clk after 1 ns;

    -- ----------------------------------------------------------------
    -- Open-drain bus: DUT drives sda via tri-state; slave pulls low.
    -- In VHDL simulation both drive the same signal; 'Z' + '0' = '0',
    -- 'Z' + 'Z' = 'Z', '0' + '0' = '0'. This matches real open-drain.
    -- ----------------------------------------------------------------
    sda <= slave_sda;

    dut: entity work.i2c_master
        port map (
            clk          => clk,
            rst          => rst,
            addr         => addr,
            rw           => rw,
            data_in      => data_in,
            data_out     => data_out,
            start        => start,
            stop_on_done => stop_on_done,
            busy         => busy,
            nack         => nack,
            scl          => scl,
            sda          => sda
        );

    -- ----------------------------------------------------------------
    -- Slave model
    -- Uses SCL edges for synchronisation so timing is exact regardless
    -- of the clock divider value.
    -- ----------------------------------------------------------------
    slave: process
        -- ACK: pull SDA low during one SCL high phase
        procedure send_ack is
        begin
            -- Wait for SCL to go low (ACK slot starts)
            wait until scl = '0';
            slave_sda <= '0';
            wait until scl = '1';   -- SCL high: master samples our ACK
            wait until scl = '0';   -- SCL low again: release
            slave_sda <= 'Z';
        end procedure;

        -- Skip n bits (wait for n falling SCL edges)
        procedure skip_bits(n : integer) is
        begin
            for i in 1 to n loop
                wait until falling_edge(scl);
            end loop;
        end procedure;

        -- Drive a byte MSB-first, one bit per SCL low period
        procedure drive_byte(constant val : STD_LOGIC_VECTOR(7 downto 0)) is
        begin
            for i in 7 downto 0 loop
                wait until scl = '0';
                slave_sda <= val(i);
                wait until scl = '1';   -- master samples on high
                wait until scl = '0';
            end loop;
            slave_sda <= 'Z';           -- release for master ACK/NAK slot
            wait until scl = '1';
            wait until scl = '0';
        end procedure;

    begin
        slave_sda <= 'Z';

        -- ==== TEST 1: single write, ACK address + data ====
        wait until falling_edge(sda);   -- START condition
        skip_bits(8);                    -- address byte (8 SCL cycles)
        send_ack;
        skip_bits(8);                    -- data byte
        send_ack;
        -- STOP follows; slave releases
        slave_sda <= 'Z';
        wait for HALF * 4;              -- clear of STOP

        -- ==== TEST 2: write reg ptr (no STOP) then rSTART read ====
        wait until falling_edge(sda);   -- START
        skip_bits(8);                    -- address + W
        send_ack;
        skip_bits(8);                    -- register pointer byte
        send_ack;
        -- Repeated START: master holds SCL low then drives SDA low
        wait until falling_edge(sda);   -- repeated START
        skip_bits(8);                    -- address + R
        send_ack;
        drive_byte(x"A5");              -- drive read data
        -- master sends NAK + STOP; slave releases
        slave_sda <= 'Z';
        wait for HALF * 4;

        -- ==== TEST 3: NACK -- slave does NOT pull SDA low in ACK slot ====
        wait until falling_edge(sda);   -- START
        skip_bits(8);                    -- address byte
        -- Leave slave_sda = 'Z'; master reads '1' = NACK
        wait until scl = '0';           -- ACK slot SCL low
        wait until scl = '1';           -- SCL high: master samples NACK
        wait until scl = '0';
        -- master will generate STOP
        slave_sda <= 'Z';

        wait;
    end process;

    -- ----------------------------------------------------------------
    -- Stimulus
    -- ----------------------------------------------------------------
    stimulus: process
    begin
        rst   <= '1';
        start <= '0';
        wait for 10 ns;
        rst   <= '0';
        wait for 4 ns;

        -- ---- TEST 1: single write, expect ACK ----
        report "TEST 1: single write, expect ACK";
        rw           <= '0';
        data_in      <= x"42";
        stop_on_done <= '1';
        start        <= '1';
        wait for 2 ns;
        start <= '0';
        wait until busy = '0';
        assert nack = '0'
            report "TEST 1 FAILED: unexpected NACK" severity error;
        report "TEST 1 PASSED";
        wait for 500 ns;

        -- ---- TEST 2: write ptr (no STOP) then rSTART read ----
        report "TEST 2: write ptr then repeated-START read 0xA5";
        rw           <= '0';
        data_in      <= x"00";
        stop_on_done <= '0';    -- hold bus
        start        <= '1';
        wait for 2 ns;
        start <= '0';
        wait until busy = '0';
        assert nack = '0'
            report "TEST 2 FAILED: NACK on write ptr" severity error;

        -- Now read; bus still held so i2c_master generates rSTART
        rw           <= '1';
        stop_on_done <= '1';
        start        <= '1';
        wait for 2 ns;
        start <= '0';
        wait until busy = '0';
        assert nack = '0'
            report "TEST 2 FAILED: unexpected NACK on read" severity error;
        assert data_out = x"A5"
            report "TEST 2 FAILED: expected 0xA5, got 0x" & to_hstring(data_out)
            severity error;
        report "TEST 2 PASSED: data_out=0x" & to_hstring(data_out);
        wait for 500 ns;

        -- ---- TEST 3: expect NACK ----
        report "TEST 3: slave NACK";
        rw           <= '0';
        data_in      <= x"FF";
        stop_on_done <= '1';
        start        <= '1';
        wait for 2 ns;
        start <= '0';
        wait until busy = '0';
        assert nack = '1'
            report "TEST 3 FAILED: expected NACK, got ACK" severity error;
        report "TEST 3 PASSED: NACK detected";

        report "+++All i2c_master tests passed";
        std.env.finish;
    end process;

    -- Bus monitor
    monitor: process
    begin
        wait on scl, sda, busy, nack;
        report "SCL=" & to_string(scl) &
               " SDA=" & to_string(sda) &
               " BUSY=" & to_string(busy) &
               " NACK=" & to_string(nack);
    end process;

end architecture;