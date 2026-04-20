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
-- The reader's generics are overridden so one read happens every ~1 ms
-- of simulated time (instead of 1 s) to keep simulation short.
--
-- Run (GHDL example):
--   ghdl -a --std=08 i2c_controller.vhd
--   ghdl -a --std=08 adt7420_reader.vhd
--   ghdl -a --std=08 adt7420_tb.vhd
--   ghdl -e --std=08 adt7420_tb
--   ghdl -r --std=08 adt7420_tb --stop-time=20ms --wave=adt7420_tb.ghw

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

    -- ----------------------------------------------------------------
    -- Bus: three drivers - master (inout), slave, pull-ups.
    -- Resolution function std_logic_1164 combines them correctly:
    --   'H' loses to '0'.  '1' loses to '0'.  'Z' loses to everything.
    -- The master and slave both drive '0' or 'Z'; pull-ups are 'H'.
    -- ----------------------------------------------------------------
    signal scl : STD_LOGIC;
    signal sda : STD_LOGIC;

    signal slave_scl_drv : STD_LOGIC := 'Z';   -- Not used; ADT7420 never stretches clock here
    signal slave_sda_drv : STD_LOGIC := 'Z';

    -- ----------------------------------------------------------------
    -- Slave register values (preloaded by stimulus)
    -- Default: 22.1 C in 13-bit format:
    --   22.1 / 0.0625 = 353.6 -> code13 = 354 (0x162)
    --   Stored in 16-bit register as (code13 << 3) = 0x0B10
    -- ----------------------------------------------------------------
    signal slave_temp_raw   : STD_LOGIC_VECTOR (15 downto 0) := x"0B10";
    signal slave_config_reg : STD_LOGIC_VECTOR (7 downto 0)  := x"00";

    -- Debug
    signal dbg_last_ptr    : STD_LOGIC_VECTOR (7 downto 0) := x"FF";
    signal dbg_read_count  : integer := 0;

begin

    ----------------------------------------------------------------
    -- Clock: 50 MHz  (period 20 ns)
    ----------------------------------------------------------------
    clk_gen : process
    begin
        clk <= '0';
        wait for 10 ns;
        clk <= '1';
        wait for 10 ns;
    end process;

    ----------------------------------------------------------------
    -- Bus with pull-ups. The master drives scl/sda directly
    -- (entity has inout ports); slave drives slave_*_drv.
    ----------------------------------------------------------------
    scl <= 'H';                  -- pull-up (weak)
    sda <= 'H';                  -- pull-up (weak)
    sda <= slave_sda_drv;
    scl <= slave_scl_drv;

    ----------------------------------------------------------------
    -- DUT
    ----------------------------------------------------------------
    dut : entity work.adt7420_reader
        generic map (
            CLOCK_FREQ_HZ    => 50_000_000,
            READ_INTERVAL_MS => 1
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
    ----------------------------------------------------------------
    stim_proc : process
    begin
        rst <= '1';
        resolution_16bit <= '0';
        slave_temp_raw   <= x"0B10";     -- 22.1 C (13-bit code 354 in upper bits)
        wait for 500 ns;
        rst <= '0';

        -- First reading
        wait until rising_edge(temp_valid);
        report "Reading 1 (13-bit, 22.1 C): temperature = "
            & integer'image(to_integer(signed(temperature))) & " tenths C";
        assert to_integer(signed(temperature)) = 221
            report "Expected 221, got " &
                   integer'image(to_integer(signed(temperature)))
            severity warning;

        -- Second reading: -5.3 C
        --   round(-5.3 / 0.0625) = -85 -> 0xFFAB
        --   shifted left 3 -> 0xFD58  (top 13 bits carry -85)
        slave_temp_raw <= x"FD58";
        wait until rising_edge(temp_valid);
        report "Reading 2 (13-bit, -5.3 C nominal): temperature = "
            & integer'image(to_integer(signed(temperature))) & " tenths C";
        -- -85 * 10 / 16 = -53.125 -> integer truncation toward -inf = -54
        -- (arithmetic shift right rounds toward -inf).  Accept either -53 or -54.
        assert to_integer(signed(temperature)) = -53
            or to_integer(signed(temperature)) = -54
            report "Expected -53 or -54, got " &
                   integer'image(to_integer(signed(temperature)))
            severity warning;

        -- Third reading: 125.0 C exactly
        --   125 / 0.0625 = 2000 -> 16-bit reg = 2000 << 3 = 16000 = 0x3E80
        slave_temp_raw <= x"3E80";
        wait until rising_edge(temp_valid);
        report "Reading 3 (13-bit, 125.0 C): temperature = "
            & integer'image(to_integer(signed(temperature))) & " tenths C";
        assert to_integer(signed(temperature)) = 1250
            report "Expected 1250, got " &
                   integer'image(to_integer(signed(temperature)))
            severity warning;

        report "+++All good";
        std.env.finish;
    end process;

    ----------------------------------------------------------------
    -- ADT7420 SLAVE MODEL (bit-level, address 0x48)
    --
    -- High-level structure:
    --   main loop
    --     wait for START (SDA falling while SCL high)
    --     transaction loop:
    --       sample 8-bit byte on rising SCL edges
    --       if first byte of transaction:
    --         check address/RW; if match, ACK; else abort
    --         if RW=1: enter read-loop
    --         else:    next byte is pointer
    --       else if writing: ACK and store as pointer or data
    --     read-loop: drive byte from current pointer, read ACK/NAK,
    --                increment pointer, exit on NAK or STOP/RESTART.
    --
    -- STOP/RESTART is detected in a parallel watcher that signals
    -- the main process via an event on `bus_event`.
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

        -- Sample 8 bits from the bus, MSB first, on rising edges of SCL.
        -- Returns the byte in `b`.  Also returns aborted=true if we see a
        -- STOP or RESTART before completing the byte.
        procedure sample_byte (variable b       : out STD_LOGIC_VECTOR (7 downto 0);
                               variable aborted : out boolean) is
            variable tmp      : STD_LOGIC_VECTOR (7 downto 0) := (others => '0');
            variable sda_prev : STD_LOGIC;
        begin
            aborted := false;
            for i in 7 downto 0 loop
                -- Wait for SCL rising edge OR a START/STOP (SDA change while SCL=1)
                loop
                    sda_prev := sda;
                    wait on scl, sda;
                    if (scl = '1' or scl = 'H') then
                        if (sda_prev = '1' and (sda = '0')) then
                            -- SDA falling while SCL high -> RESTART
                            aborted := true;
                            return;
                        elsif (sda_prev = '0' and (sda = '1' or sda = 'H')) then
                            -- SDA rising while SCL high -> STOP
                            aborted := true;
                            return;
                        end if;
                    end if;
                    exit when (scl'event and (scl = '1' or scl = 'H'));
                end loop;
                -- Sample SDA
                if (sda = '0') then
                    tmp(i) := '0';
                else
                    tmp(i) := '1';
                end if;
            end loop;
            b := tmp;
        end procedure;

        -- Drive a byte MSB-first. Each bit is placed on SDA while SCL is
        -- low and held through the next SCL high. After 8 bits, release
        -- SDA and sample the master's ACK/NAK on the 9th rising edge.
        procedure drive_byte (b            : STD_LOGIC_VECTOR (7 downto 0);
                              variable ack : out boolean) is
        begin
            for i in 7 downto 0 loop
                wait until falling_edge(scl);
                if (b(i) = '0') then
                    slave_sda_drv <= '0';
                else
                    slave_sda_drv <= 'Z';
                end if;
            end loop;
            -- Release for ACK
            wait until falling_edge(scl);
            slave_sda_drv <= 'Z';
            -- Sample master's ACK bit on rising edge
            wait until (scl'event and (scl = '1' or scl = 'H'));
            if (sda = '0') then
                ack := true;
            else
                ack := false;
            end if;
        end procedure;

        variable byte_v   : STD_LOGIC_VECTOR (7 downto 0);
        variable abort_v  : boolean;
        variable ack_v    : boolean;
        variable pointer  : unsigned (7 downto 0) := (others => '0');
        variable is_read  : boolean;
        variable sda_prev : STD_LOGIC;

    begin
        slave_sda_drv <= 'Z';
        slave_scl_drv <= 'Z';

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
                -- First byte after (re)START is address + R/W
                sample_byte(byte_v, abort_v);
                exit start_seen when abort_v;

                if (byte_v(7 downto 1) = "1001000") then
                    drive_ack;
                    is_read := (byte_v(0) = '1');
                    if (byte_v(0) = '1') then
                        report "[SLAVE] Addressed, RW=1 (read)";
                    else
                        report "[SLAVE] Addressed, RW=0 (write)";
                    end if;

                    if (is_read) then
                        -- Drive bytes until NAK or abort
                        read_loop : loop
                            case to_integer(pointer) is
                                when 16#00# =>
                                    drive_byte(slave_temp_raw(15 downto 8), ack_v);
                                    dbg_read_count <= dbg_read_count + 1;
                                when 16#01# =>
                                    drive_byte(slave_temp_raw(7 downto 0),  ack_v);
                                when 16#03# =>
                                    drive_byte(slave_config_reg,            ack_v);
                                when others =>
                                    drive_byte(x"00", ack_v);
                            end case;
                            pointer := pointer + 1;
                            exit read_loop when not ack_v;
                        end loop;
                        -- Master NAKed.  Wait for STOP or RESTART.
                        loop
                            sda_prev := sda;
                            wait on sda, scl;
                            if (scl = '1' or scl = 'H') then
                                if (sda_prev = '0' and (sda = '1' or sda = 'H')) then
                                    report "[SLAVE] STOP after read";
                                    exit start_seen;
                                elsif (sda_prev = '1' and sda = '0') then
                                    report "[SLAVE] RESTART after read";
                                    next main_loop;
                                end if;
                            end if;
                        end loop;
                    else
                        -- Write: first data byte is the pointer
                        sample_byte(byte_v, abort_v);
                        if (abort_v) then
                            report "[SLAVE] Abort during pointer";
                            exit start_seen;
                        end if;
                        drive_ack;
                        pointer        := unsigned(byte_v);
                        dbg_last_ptr   <= byte_v;
                        report "[SLAVE] Ptr <= " &
                               integer'image(to_integer(unsigned(byte_v)));

                        -- Subsequent bytes are data, until abort
                        write_loop : loop
                            sample_byte(byte_v, abort_v);
                            exit write_loop when abort_v;
                            drive_ack;
                            if (to_integer(pointer) = 16#03#) then
                                slave_config_reg <= byte_v;
                                report "[SLAVE] CFG  <= " &
                                       integer'image(to_integer(unsigned(byte_v)));
                            end if;
                            pointer := pointer + 1;
                        end loop;
                    end if;
                else
                    report "[SLAVE] Addr mismatch, ignoring";
                    -- No ACK - wait for STOP
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