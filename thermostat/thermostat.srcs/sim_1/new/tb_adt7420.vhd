-- Testbench for adt7420_reader
-- Inspired by https://github.com/aslak3/i2c-controller testbench style.
--
-- Contains a behavioural I2C-slave model of the ADT7420:
--   * Responds to 7-bit address 0x48
--   * Registers: 0x00 temp MSB, 0x01 temp LSB, 0x03 configuration
--   * Auto-increments address pointer on each byte
--   * `slave_temp_raw` is the 16-bit code returned on reads; the TB
--     preloads it with values corresponding to 22.1 C, -5.3 C, 125.0 C.
--
-- The reader's generics are overridden so reads happen every 2 ms of
-- simulated time (instead of 1 s) to keep simulation runs short.
--
-- ---------------------------------------------------------------------
-- Bus wiring:
-- The reader's scl/sda are inout. The i2c_controller drives them as
-- 'Z' (idle) or '0' (drive low). We use std_logic resolution with:
--   1) a weak 'H' pull-up per line (concurrent signal assignment)
--   2) the slave driver (drives 'Z' or '0')
-- Resolved result:  H + Z + Z = H (idle high);  H + Z + 0 = 0 (low).
-- ---------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_adt7420 is
end entity;

architecture behavioral of tb_adt7420 is

    -- ----------------------------------------------------------------
    -- Top-level signals
    -- ----------------------------------------------------------------
    signal clk              : STD_LOGIC := '0';
    signal rst              : STD_LOGIC := '1';
    signal sensor_addr      : STD_LOGIC_VECTOR (6 downto 0) := "1001000";  -- 0x48
    signal resolution_16bit : STD_LOGIC := '0';
    signal temperature      : STD_LOGIC_VECTOR (15 downto 0);
    signal temp_valid       : STD_LOGIC;
    signal read_error       : STD_LOGIC;

    -- Bus signals (resolved)
    signal scl : STD_LOGIC;
    signal sda : STD_LOGIC;

    -- Slave drivers (drive 'Z' or '0')
    signal slave_sda_drv : STD_LOGIC := 'Z';
    -- (no clock stretching for ADT7420; slave never drives SCL)

    -- Slave register values (preloaded by stimulus)
    -- Default: 22.1 C in 13-bit format:
    --   22.1 / 0.0625 = 353.6 -> code13 = 354 (0x162)
    --   Stored in 16-bit register as (code13 << 3) = 0x0B10
    signal slave_temp_raw   : STD_LOGIC_VECTOR (15 downto 0) := x"0B10";
    signal slave_config_reg : STD_LOGIC_VECTOR (7 downto 0)  := x"00";

    -- Debug / visibility
    signal dbg_last_ptr   : STD_LOGIC_VECTOR (7 downto 0) := x"FF";
    signal dbg_read_count : integer := 0;

begin

    ----------------------------------------------------------------
    -- Clock: 100 MHz (period 10 ns) - matches target FPGA
    ----------------------------------------------------------------
    clk_gen : process
    begin
        clk <= '0';
        wait for 5 ns;
        clk <= '1';
        wait for 5 ns;
    end process;

    ----------------------------------------------------------------
    -- Bus pull-ups (weak 'H').  Only ONE concurrent driver per line
    -- from the testbench side, the slave drives via slave_sda_drv.
    ----------------------------------------------------------------
    scl <= 'H';
    sda <= 'H';
    sda <= slave_sda_drv;

    ----------------------------------------------------------------
    -- DUT
    ----------------------------------------------------------------
    dut : entity work.adt7420_reader
        generic map (
            CLOCK_FREQ_HZ    => 100_000_000,
            READ_INTERVAL_MS => 2          -- 2 ms between reads (plenty of margin)
        )
        port map (
            clock            => clk,
            reset            => rst,
            sensor_address   => sensor_addr,
            resolution_16bit => resolution_16bit,
            temperature      => temperature,
            temp_valid       => temp_valid,
            error            => read_error,
            scl              => scl,
            sda              => sda
        );

    ----------------------------------------------------------------
    -- STIMULUS
    --   1. Reset.
    --   2. Verify three temperatures are read correctly:
    --        22.1 C, -5.3 C, 125.0 C (all in 13-bit mode).
    --   3. Run a few more cycles for waveform inspection, then finish.
    ----------------------------------------------------------------
    stim_proc : process
    begin
        rst <= '1';
        resolution_16bit <= '0';
        slave_temp_raw   <= x"0B10";             -- 22.1 C
        wait for 1 us;
        rst <= '0';
        report "[TB] Reset released at " & time'image(now);

        -- Reading 1
        wait until rising_edge(temp_valid);
        report "Reading 1 (13-bit, 22.1 C): temperature = "
            & integer'image(to_integer(signed(temperature))) & " tenths C";
        assert to_integer(signed(temperature)) = 221
            report "Expected 221, got " &
                   integer'image(to_integer(signed(temperature)))
            severity warning;

        -- Reading 2: -5.3 C
        slave_temp_raw <= x"FD58";
        wait until rising_edge(temp_valid);
        report "Reading 2 (13-bit, -5.3 C): temperature = "
            & integer'image(to_integer(signed(temperature))) & " tenths C";
        assert to_integer(signed(temperature)) = -53
            or to_integer(signed(temperature)) = -54
            report "Expected -53 or -54, got " &
                   integer'image(to_integer(signed(temperature)))
            severity warning;

        -- Reading 3: 125.0 C
        slave_temp_raw <= x"3E80";
        wait until rising_edge(temp_valid);
        report "Reading 3 (13-bit, 125.0 C): temperature = "
            & integer'image(to_integer(signed(temperature))) & " tenths C";
        assert to_integer(signed(temperature)) = 1250
            report "Expected 1250, got " &
                   integer'image(to_integer(signed(temperature)))
            severity warning;

        report "+++All good";
        -- Let another couple of read cycles happen so the periodic
        -- waveform is easy to inspect, then finish cleanly.
        wait for 5 ms;
        report "Ending simulation.";
        std.env.finish;
    end process;

    ----------------------------------------------------------------
    -- Watchdog: if nothing happens within 10 ms of simulated time,
    -- print the bus state and stop.  This saves you from watching a
    -- dead sim run all the way to the user-specified stop time.
    ----------------------------------------------------------------
    watchdog_proc : process
    begin
        wait for 50 ms;
        report "[TB] WATCHDOG: 50 ms elapsed without reaching finish. "
             & "Bus at last check: scl=" & std_logic'image(scl)
             & " sda="  & std_logic'image(sda)
             & " temp_valid=" & std_logic'image(temp_valid)
             & " read_error=" & std_logic'image(read_error)
            severity failure;
        wait;
    end process;

    ----------------------------------------------------------------
    -- ADT7420 SLAVE MODEL (bit-level, address 0x48)
    ----------------------------------------------------------------
    slave_proc : process

        -- Drive an ACK (pull SDA low during the 9th clock)
        procedure drive_ack is
        begin
            wait until falling_edge(scl);
            slave_sda_drv <= '0';
            wait until falling_edge(scl);
            slave_sda_drv <= 'Z';
        end procedure;

        -- Sample 8 bits MSB-first on rising SCL edges.
        -- abort_reason:
        --   0 = completed normally (no abort)
        --   1 = STOP detected  (SDA rising while SCL high)
        --   2 = RESTART detected (SDA falling while SCL high)
        procedure sample_byte (variable b            : out STD_LOGIC_VECTOR (7 downto 0);
                               variable abort_reason : out integer) is
            variable tmp      : STD_LOGIC_VECTOR (7 downto 0) := (others => '0');
            variable sda_prev : STD_LOGIC;
        begin
            abort_reason := 0;
            for i in 7 downto 0 loop
                loop
                    sda_prev := sda;
                    wait on scl, sda;
                    if (scl = '1' or scl = 'H') then
                        if ((sda_prev = '1' or sda_prev = 'H') and sda = '0') then
                            abort_reason := 2;  -- RESTART
                            return;
                        elsif (sda_prev = '0' and (sda = '1' or sda = 'H')) then
                            abort_reason := 1;  -- STOP
                            return;
                        end if;
                    end if;
                    exit when (scl'event and (scl = '1' or scl = 'H'));
                end loop;
                if (sda = '0') then
                    tmp(i) := '0';
                else
                    tmp(i) := '1';
                end if;
            end loop;
            b := tmp;
        end procedure;

        -- Drive a byte MSB-first.  I2C data bit timing:
        --   - slave places bit on SDA during SCL-low phase
        --   - master samples bit during SCL-high phase
        --   - SDA must be stable while SCL is high
        --
        -- On entry we may be called in two situations:
        --  (a) Just after sending/receiving the address byte's ACK
        --      (scl has just been released after the ACK's falling edge,
        --       so scl is currently LOW).
        --  (b) Just after the previous data byte's ACK rising edge
        --      (scl is currently HIGH).
        --
        -- To handle both, we immediately synchronize to the next
        -- falling edge of SCL if we're currently high, then proceed.
        procedure drive_byte (b            : STD_LOGIC_VECTOR (7 downto 0);
                              variable ack : out boolean) is
        begin
            -- Synchronize: ensure we are in the low phase that precedes
            -- bit 7.  If scl is high now, wait for its falling edge.
            if not (scl = '0' or scl = 'L') then
                wait until falling_edge(scl);
            end if;

            -- Now scl is low.  For each bit, place it, wait until the
            -- next falling edge (end of this bit's cycle), then move on.
            for i in 7 downto 0 loop
                if b(i) = '0' then
                    slave_sda_drv <= '0';
                else
                    slave_sda_drv <= 'Z';
                end if;
                wait until falling_edge(scl);  -- end of bit i
            end loop;

            -- Release for the master's ACK/NAK bit (which occupies the
            -- next full clock cycle).
            slave_sda_drv <= 'Z';
            -- Master drives ACK on SDA during this SCL-low, then SCL
            -- rises and we sample.
            wait until rising_edge(scl);
            if sda = '0' or sda = 'L' then
                ack := true;
            else
                ack := false;
            end if;
            -- Wait for the falling edge at the end of the ACK cycle so
            -- that the caller is left at the start of the NEXT scl-low
            -- phase (or before STOP/RESTART).
            wait until falling_edge(scl);
        end procedure;

        variable byte_v   : STD_LOGIC_VECTOR (7 downto 0);
        variable abort_v  : integer;  -- 0=none, 1=STOP, 2=RESTART
        variable ack_v    : boolean;
        variable pointer  : unsigned (7 downto 0) := (others => '0');
        variable is_read  : boolean;
        variable sda_prev : STD_LOGIC;

    begin
        -- Idle first, let reset and bus settle before looking for edges.
        slave_sda_drv <= 'Z';
        wait for 2 us;

        main_loop : loop
            -- Wait for START: SDA falls while SCL is high.
            loop
                sda_prev := sda;
                wait on sda;
                exit when (sda_prev = '1' or sda_prev = 'H') and
                          (sda = '0') and
                          (scl = '1' or scl = 'H');
            end loop;
            report "[SLAVE] START";

            start_seen : loop
                sample_byte(byte_v, abort_v);
                if abort_v = 1 then
                    report "[SLAVE] STOP during address";
                    exit start_seen;
                elsif abort_v = 2 then
                    report "[SLAVE] RESTART during address";
                    next main_loop;
                end if;

                if (byte_v(7 downto 1) = "1001000") then
                    drive_ack;
                    is_read := (byte_v(0) = '1');
                    if (byte_v(0) = '1') then
                        report "[SLAVE] Addressed, RW=1 (read)";
                    else
                        report "[SLAVE] Addressed, RW=0 (write)";
                    end if;

                    if (is_read) then
                        read_loop : loop
                            case to_integer(pointer) is
                                when 16#00# =>
                                    drive_byte(slave_temp_raw(15 downto 8), ack_v);
                                    dbg_read_count <= dbg_read_count + 1;
                                when 16#01# =>
                                    drive_byte(slave_temp_raw(7 downto 0),  ack_v);
                                when 16#03# =>
                                    drive_byte(slave_config_reg, ack_v);
                                when others =>
                                    drive_byte(x"00", ack_v);
                            end case;
                            pointer := pointer + 1;
                            exit read_loop when not ack_v;
                        end loop;
                        -- Wait for STOP or RESTART
                        loop
                            sda_prev := sda;
                            wait on sda, scl;
                            if (scl = '1' or scl = 'H') then
                                if (sda_prev = '0' and (sda = '1' or sda = 'H')) then
                                    report "[SLAVE] STOP after read";
                                    exit start_seen;
                                elsif ((sda_prev = '1' or sda_prev = 'H') and sda = '0') then
                                    report "[SLAVE] RESTART after read";
                                    next main_loop;
                                end if;
                            end if;
                        end loop;
                    else
                        -- Write: first data byte is the pointer
                        sample_byte(byte_v, abort_v);
                        if abort_v = 1 then
                            report "[SLAVE] STOP during pointer";
                            exit start_seen;
                        elsif abort_v = 2 then
                            report "[SLAVE] RESTART during pointer";
                            next main_loop;
                        end if;
                        drive_ack;
                        pointer      := unsigned(byte_v);
                        dbg_last_ptr <= byte_v;
                        report "[SLAVE] Ptr <= " &
                               integer'image(to_integer(unsigned(byte_v)));

                        write_loop : loop
                            sample_byte(byte_v, abort_v);
                            exit write_loop when abort_v /= 0;
                            drive_ack;
                            if (to_integer(pointer) = 16#03#) then
                                slave_config_reg <= byte_v;
                                report "[SLAVE] CFG  <= " &
                                       integer'image(to_integer(unsigned(byte_v)));
                            end if;
                            pointer := pointer + 1;
                        end loop;
                        -- write_loop exited: handle STOP vs RESTART
                        if abort_v = 1 then
                            report "[SLAVE] STOP after write";
                            exit start_seen;
                        elsif abort_v = 2 then
                            report "[SLAVE] RESTART after write";
                            next main_loop;
                        end if;
                    end if;
                else
                    report "[SLAVE] Addr mismatch, ignoring";
                    -- wait for STOP
                    loop
                        sda_prev := sda;
                        wait on sda;
                        exit when (sda_prev = '0') and
                                  (sda = '1' or sda = 'H') and
                                  (scl = '1' or scl = 'H');
                    end loop;
                    exit start_seen;
                end if;
            end loop;
        end loop;
    end process;

end architecture;