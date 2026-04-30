-- tb_i2c_adt7420_full.vhd
--
-- Full ADT7420 I2C slave testbench targeting adt7420_reader_digikey (Build F).
--
-- The Larson/Digi-Key driver issues two transaction types:
--
--   1. Config write (once at startup):
--      S  +  addr+W  +  ACK  +  0x03  +  ACK  +  0x80  +  ACK  +  STOP
--
--   2. Read with repeated START (continuous):
--      S  +  addr+W  +  ACK  +  0x00  +  ACK
--         +  Sr  +  addr+R  +  ACK  +  MSB  +  ACK(master)  +  LSB  +  NAK(master)  +  STOP
--
-- The slave model has a full register map: pointer register, config register
-- (0x03), and temperature register (0x00-0x01). It handles repeated STARTs
-- by re-entering the address phase inside the same transaction loop.
--
-- Generics
--   SENSOR_ADDR      7-bit I2C address (default 0x4B for Nexys A7)
--   TEMP_RAW_DEFAULT Initial 16-bit register value (16-bit mode: LSB = 1/128 C)
--   SIM_CLOCK_FREQ   Passed to CLOCK_FREQ_HZ of adt7420_reader_digikey.
--                    Lowering this shrinks the Larson 100 ms startup counter
--                    without changing the simulation clock (still 10 ns / cycle).
--                    4_000_000 -> startup ~= 4 ms simulated, divider = 2.
--
-- Temperature encoding (16-bit mode, tenths = raw * 10 / 128):
--   x"0B00"  (2816)  22.0 C  -> 220 tenths
--   x"FD80"  (-640)  -5.0 C  -> -50 tenths
--   x"3E80" (16000) 125.0 C  -> 1250 tenths
--
-- slave_config_reg is a testbench signal updated by the slave process when
-- the DUT writes register 0x03. stim_proc waits for it to reach 0x80 before
-- expecting temperature readings.

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_i2c_adt7420_full is
    generic (
        SENSOR_ADDR      : STD_LOGIC_VECTOR(6 downto 0) := "1001011"; -- 0x4B
        TEMP_RAW_DEFAULT : STD_LOGIC_VECTOR(15 downto 0) := x"0B00";  -- 22.0 C
        SIM_CLOCK_FREQ   : integer := 4_000_000
    );
end entity;

architecture behavioral of tb_i2c_adt7420_full is

    signal clk         : STD_LOGIC := '0';
    signal rst         : STD_LOGIC := '1';
    signal temperature : STD_LOGIC_VECTOR(15 downto 0);
    signal temp_valid  : STD_LOGIC;
    signal ack_err     : STD_LOGIC;

    signal scl           : STD_LOGIC;
    signal sda           : STD_LOGIC;
    signal slave_sda_drv : STD_LOGIC := 'Z';

    -- Driven by stim_proc to change what the slave returns
    signal slave_temp_raw   : STD_LOGIC_VECTOR(15 downto 0) := TEMP_RAW_DEFAULT;
    -- Updated by slave_proc when the DUT writes config register 0x03
    signal slave_config_reg : STD_LOGIC_VECTOR(7 downto 0)  := x"00";

begin

    clk <= not clk after 5 ns;  -- 100 MHz system clock

    scl <= 'H';
    sda <= 'H';
    sda <= slave_sda_drv;

    dut : entity work.adt7420_reader_digikey
        generic map (
            CLOCK_FREQ_HZ => SIM_CLOCK_FREQ,
            SENSOR_ADDR   => SENSOR_ADDR
        )
        port map (
            clock       => clk,
            reset       => rst,
            temperature => temperature,
            temp_valid  => temp_valid,
            ack_error   => ack_err,
            scl         => scl,
            sda         => sda
        );

    -- ----------------------------------------------------------------
    -- Stimulus
    -- ----------------------------------------------------------------
    stim_proc : process
    begin
        rst            <= '1';
        slave_temp_raw <= TEMP_RAW_DEFAULT;
        wait for 200 ns;
        rst <= '0';

        -- Larson startup: writes 0x80 to config reg 0x03 before any reads.
        -- slave_config_reg is updated by slave_proc when that byte arrives.
        wait until slave_config_reg = x"80";
        report "[TB] Config write received: reg 0x03 = 0x80 (16-bit mode)";

        -- Reading 1: 22.0 C  (raw=0x0B00=2816, tenths=2816*10/128=220)
        wait until rising_edge(temp_valid);
        report "[TB] R1 = " & integer'image(to_integer(signed(temperature))) & " tenths C";
        assert to_integer(signed(temperature)) = 220
            report "R1: expected 220, got " &
                   integer'image(to_integer(signed(temperature)))
            severity failure;

        -- Reading 2: -5.0 C  (raw=0xFD80=-640, tenths=-640*10/128=-50)
        slave_temp_raw <= x"FD80";
        wait until rising_edge(temp_valid);
        report "[TB] R2 = " & integer'image(to_integer(signed(temperature))) & " tenths C";
        assert to_integer(signed(temperature)) = -50
            report "R2: expected -50, got " &
                   integer'image(to_integer(signed(temperature)))
            severity failure;

        -- Reading 3: 125.0 C  (raw=0x3E80=16000, tenths=16000*10/128=1250)
        slave_temp_raw <= x"3E80";
        wait until rising_edge(temp_valid);
        report "[TB] R3 = " & integer'image(to_integer(signed(temperature))) & " tenths C";
        assert to_integer(signed(temperature)) = 1250
            report "R3: expected 1250, got " &
                   integer'image(to_integer(signed(temperature)))
            severity failure;

        report "+++All good";
        wait for 10 ms;
        std.env.finish;
    end process;

    -- ----------------------------------------------------------------
    -- Watchdog: generous timeout -- SIM_CLOCK_FREQ=4M gives ~4 ms startup.
    -- ----------------------------------------------------------------
    watchdog_proc : process
    begin
        wait for 500 ms;
        report "[TB] WATCHDOG: 500 ms elapsed."
             & " scl="        & std_logic'image(scl)
             & " sda="        & std_logic'image(sda)
             & " temp_valid=" & std_logic'image(temp_valid)
             & " ack_err="    & std_logic'image(ack_err)
             & " config_reg=" & integer'image(to_integer(unsigned(slave_config_reg)))
            severity failure;
        wait;
    end process;

    -- ----------------------------------------------------------------
    -- Full ADT7420 slave model.
    --
    -- transaction_loop iterates once per START/RESTART address phase.
    -- `next transaction_loop` is used to re-enter the address phase
    -- after a repeated START (Sr) without returning to main_loop.
    --
    -- sample_byte: reads 8 bits MSB-first on rising SCL edges.
    --   abort = 0  normal
    --   abort = 1  STOP detected
    --   abort = 2  RESTART (Sr) detected
    --
    -- drive_ack: pulls SDA low for one full SCL period (9th clock).
    --
    -- drive_byte: drives 8 bits MSB-first; captures master ACK/NAK.
    --   ack_rcvd = true  -> master acknowledged (continue)
    --   ack_rcvd = false -> master NAK'd (last byte, stop sending)
    -- ----------------------------------------------------------------
    slave_proc : process
        variable byte_v  : STD_LOGIC_VECTOR(7 downto 0);
        variable abort_v : integer;
        variable got_ack : boolean;
        variable ptr     : unsigned(7 downto 0) := x"00";
        variable sprev   : STD_LOGIC;
        variable is_read : boolean;

        procedure sample_byte (variable b     : out STD_LOGIC_VECTOR(7 downto 0);
                                variable abort : out integer) is
            variable tmp  : STD_LOGIC_VECTOR(7 downto 0) := (others => '0');
            variable prev : STD_LOGIC;
        begin
            abort := 0;
            for i in 7 downto 0 loop
                loop
                    prev := sda;
                    wait on scl, sda;
                    if scl = '1' or scl = 'H' then
                        if (prev = '1' or prev = 'H') and sda = '0' then
                            abort := 2; return;             -- Sr
                        elsif prev = '0' and (sda = '1' or sda = 'H') then
                            abort := 1; return;             -- STOP
                        end if;
                    end if;
                    exit when scl'event and (scl = '1' or scl = 'H');
                end loop;
                if sda = '0' then tmp(i) := '0'; else tmp(i) := '1'; end if;
            end loop;
            b := tmp;
        end procedure;

        procedure drive_ack is
        begin
            wait until falling_edge(scl);
            slave_sda_drv <= '0';
            wait until falling_edge(scl);
            slave_sda_drv <= 'Z';
        end procedure;

        procedure drive_byte (b               : in  STD_LOGIC_VECTOR(7 downto 0);
                               variable ack_rcvd : out boolean) is
        begin
            if not (scl = '0' or scl = 'L') then
                wait until falling_edge(scl);
            end if;
            for i in 7 downto 0 loop
                if b(i) = '0' then slave_sda_drv <= '0';
                else                slave_sda_drv <= 'Z';
                end if;
                wait until falling_edge(scl);
            end loop;
            slave_sda_drv <= 'Z';
            wait until rising_edge(scl);
            ack_rcvd := (sda = '0' or sda = 'L');
            wait until falling_edge(scl);
        end procedure;

    begin
        slave_sda_drv <= 'Z';
        wait for 1 us;

        main_loop : loop

            -- Wait for START: SDA falls while SCL is high
            loop
                sprev := sda;
                wait on sda;
                exit when (sprev = '1' or sprev = 'H') and sda = '0'
                      and (scl = '1' or scl = 'H');
            end loop;
            report "[SLAVE] START";

            -- transaction_loop iterates once per address phase.
            -- A repeated START (Sr) causes `next transaction_loop`.
            transaction_loop : loop

                sample_byte(byte_v, abort_v);
                if abort_v = 2 then
                    report "[SLAVE] Sr -- re-entering address phase";
                    next transaction_loop;
                elsif abort_v = 1 then
                    report "[SLAVE] STOP during address phase";
                    exit transaction_loop;
                end if;

                -- Address mismatch: NAK (release SDA), wait for STOP
                if byte_v(7 downto 1) /= SENSOR_ADDR then
                    report "[SLAVE] Address mismatch ("
                         & integer'image(to_integer(unsigned(byte_v(7 downto 1)))) & ")";
                    loop
                        sprev := sda;
                        wait on sda;
                        exit when (sprev = '0') and (sda = '1' or sda = 'H')
                              and (scl = '1' or scl = 'H');
                    end loop;
                    exit transaction_loop;
                end if;

                is_read := (byte_v(0) = '1');
                drive_ack;
                report "[SLAVE] Addr OK  R/W=" & std_logic'image(byte_v(0));

                -- ---------------------------------------------------
                -- READ phase: drive register bytes from current ptr.
                -- Stop when master sends NAK (last byte).
                -- ---------------------------------------------------
                if is_read then
                    read_loop : loop
                        case to_integer(ptr) is
                            when 16#00# =>
                                drive_byte(slave_temp_raw(15 downto 8), got_ack);
                            when 16#01# =>
                                drive_byte(slave_temp_raw(7 downto 0),  got_ack);
                            when 16#03# =>
                                drive_byte(slave_config_reg,             got_ack);
                            when others =>
                                drive_byte(x"00",                        got_ack);
                        end case;
                        ptr := ptr + 1;
                        exit read_loop when not got_ack;    -- NAK = done
                    end loop read_loop;

                    -- After the last byte, wait for STOP or Sr
                    loop
                        sprev := sda;
                        wait on sda, scl;
                        if scl = '1' or scl = 'H' then
                            if sprev = '0' and (sda = '1' or sda = 'H') then
                                report "[SLAVE] STOP after read";
                                exit transaction_loop;
                            elsif (sprev = '1' or sprev = 'H') and sda = '0' then
                                report "[SLAVE] Sr after read";
                                next transaction_loop;
                            end if;
                        end if;
                    end loop;

                -- ---------------------------------------------------
                -- WRITE phase: first byte is the register pointer,
                -- subsequent bytes are data for that register.
                -- A Sr mid-write re-enters the address phase.
                -- ---------------------------------------------------
                else
                    sample_byte(byte_v, abort_v);
                    if    abort_v = 1 then exit transaction_loop;
                    elsif abort_v = 2 then next transaction_loop; end if;
                    ptr := unsigned(byte_v);
                    drive_ack;
                    report "[SLAVE] Ptr <= 0x" & integer'image(to_integer(ptr));

                    write_loop : loop
                        sample_byte(byte_v, abort_v);
                        if abort_v = 2 then
                            report "[SLAVE] Sr in write loop";
                            next transaction_loop;          -- Sr: handle new addr
                        end if;
                        exit write_loop when abort_v = 1;  -- STOP ends write
                        drive_ack;
                        if to_integer(ptr) = 16#03# then
                            slave_config_reg <= byte_v;     -- signal update, stim sees it
                            report "[SLAVE] Config reg <= 0x"
                                 & integer'image(to_integer(unsigned(byte_v)));
                        end if;
                        ptr := ptr + 1;
                    end loop write_loop;

                    report "[SLAVE] STOP after write";
                    exit transaction_loop;
                end if;

            end loop transaction_loop;
        end loop main_loop;
    end process;

end architecture;
