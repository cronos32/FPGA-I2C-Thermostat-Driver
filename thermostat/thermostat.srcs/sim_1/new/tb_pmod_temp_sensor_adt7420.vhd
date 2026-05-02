-- tb_pmod_temp_sensor_adt7420.vhd
--
-- Testbench for pmod_temp_sensor_adt7420 (the Digi-Key reader that
-- writes 0x80 to config reg 0x03 once at startup, then loops on a
-- 2-byte read from reg 0x00 + 0x01).
--
-- The reader's `temperature` output is the raw 16-bit register value
-- from the ADT7420 (NOT converted to tenths-of-degree like
-- adt7420_reader produces).  The slave model is the same one used in
-- tb_i2c_adt7420_full; SIM_CLOCK_FREQ is reduced so the Larson 100 ms
-- power-up wait shrinks to a few ms of simulated time.
--
-- Note: pmod_temp_sensor_adt7420 has reset_n active LOW.

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_pmod_temp_sensor_adt7420 is
    generic (
        SENSOR_ADDR      : STD_LOGIC_VECTOR(6 downto 0) := "1001011"; -- 0x4B
        TEMP_RAW_DEFAULT : STD_LOGIC_VECTOR(15 downto 0) := x"0B00";  -- 22.0 C
        SIM_CLOCK_FREQ   : integer := 4_000_000
    );
end entity;

architecture behavioral of tb_pmod_temp_sensor_adt7420 is

    signal clk         : STD_LOGIC := '0';
    signal reset_n     : STD_LOGIC := '0';                              -- active LOW
    signal temperature : STD_LOGIC_VECTOR(15 downto 0);
    signal ack_err     : STD_LOGIC;

    signal scl           : STD_LOGIC;
    signal sda           : STD_LOGIC;
    signal slave_sda_drv : STD_LOGIC := 'Z';

    signal slave_temp_raw   : STD_LOGIC_VECTOR(15 downto 0) := TEMP_RAW_DEFAULT;
    signal slave_config_reg : STD_LOGIC_VECTOR(7 downto 0)  := x"00";

    -- Normalized view of `temperature` for the waveform viewer: bus
    -- pull-up makes 1-bits resolve to 'H', so the raw signal renders as
    -- e.g. "0H00" instead of "0B00".  to_X01 maps H->1 / L->0.
    signal temperature_x01 : STD_LOGIC_VECTOR(15 downto 0);

begin

    temperature_x01 <= to_X01(temperature);


    clk <= not clk after 5 ns;  -- 100 MHz simulation clock (period 10 ns)

    scl <= 'H';
    sda <= 'H';
    sda <= slave_sda_drv;

    dut : entity work.pmod_temp_sensor_adt7420
        generic map (
            sys_clk_freq     => SIM_CLOCK_FREQ,
            temp_sensor_addr => SENSOR_ADDR
        )
        port map (
            clk         => clk,
            reset_n     => reset_n,
            scl         => scl,
            sda         => sda,
            i2c_ack_err => ack_err,
            temperature => temperature
        );

    -- ----------------------------------------------------------------
    -- Stimulus
    --   1. Hold reset_n low briefly, then release.
    --   2. Wait for the Larson startup write (config reg 0x03 = 0x80).
    --   3. Verify three temperature codes (22.0 C, -5.0 C, 125.0 C).
    -- ----------------------------------------------------------------
    stim_proc : process
    begin
        reset_n        <= '0';
        slave_temp_raw <= TEMP_RAW_DEFAULT;
        wait for 500 ns;
        reset_n <= '1';
        report "[TB] Reset released at " & time'image(now);

        -- Bus pull-up makes the slave's 1-bits resolve to 'H' on SDA, so
        -- temperature/slave_config_reg end up with 'H' bits.  Compare via
        -- to_integer(unsigned(...)) to absorb the H -> 1 / L -> 0 mapping.
        wait until to_integer(unsigned(slave_config_reg)) = 16#80#;
        report "[TB] Config write received: reg 0x03 = 0x80 (16-bit mode)";

        wait until to_integer(unsigned(temperature)) =
                   to_integer(unsigned(TEMP_RAW_DEFAULT)) for 50 ms;
        assert to_integer(unsigned(temperature)) =
               to_integer(unsigned(TEMP_RAW_DEFAULT))
            report "[TB] R1: expected 0x" &
                   integer'image(to_integer(unsigned(TEMP_RAW_DEFAULT))) &
                   ", got 0x" &
                   integer'image(to_integer(unsigned(temperature)))
            severity failure;
        report "[TB] R1 raw temperature = 0x" &
               integer'image(to_integer(unsigned(temperature)));

        slave_temp_raw <= x"FD80";       -- -5.0 C in 16-bit mode
        wait until to_integer(unsigned(temperature)) = 16#FD80# for 50 ms;
        assert to_integer(unsigned(temperature)) = 16#FD80#
            report "[TB] R2: expected 0xFD80, got 0x" &
                   integer'image(to_integer(unsigned(temperature)))
            severity failure;
        report "[TB] R2 raw temperature = 0xFD80";

        slave_temp_raw <= x"3E80";       -- 125.0 C in 16-bit mode
        wait until to_integer(unsigned(temperature)) = 16#3E80# for 50 ms;
        assert to_integer(unsigned(temperature)) = 16#3E80#
            report "[TB] R3: expected 0x3E80, got 0x" &
                   integer'image(to_integer(unsigned(temperature)))
            severity failure;
        report "[TB] R3 raw temperature = 0x3E80";

        assert ack_err = '0'
            report "[TB] ack_err unexpectedly asserted"
            severity failure;

        report "+++All good";
        wait for 5 ms;
        std.env.finish;
    end process;

    watchdog_proc : process
    begin
        wait for 500 ms;
        report "[TB] WATCHDOG: 500 ms elapsed."
             & " scl="        & std_logic'image(scl)
             & " sda="        & std_logic'image(sda)
             & " ack_err="    & std_logic'image(ack_err)
             & " config_reg=" & integer'image(to_integer(unsigned(slave_config_reg)))
            severity failure;
        wait;
    end process;

    -- ----------------------------------------------------------------
    -- Full ADT7420 slave model (identical structure to
    -- tb_i2c_adt7420_full.vhd: register pointer, config reg, temp reg,
    -- repeated-START handling).
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
                            abort := 2; return;
                        elsif prev = '0' and (sda = '1' or sda = 'H') then
                            abort := 1; return;
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
            loop
                sprev := sda;
                wait on sda;
                exit when (sprev = '1' or sprev = 'H') and sda = '0'
                      and (scl = '1' or scl = 'H');
            end loop;
            report "[SLAVE] START";

            transaction_loop : loop
                sample_byte(byte_v, abort_v);
                if abort_v = 2 then
                    next transaction_loop;
                elsif abort_v = 1 then
                    exit transaction_loop;
                end if;

                if byte_v(7 downto 1) /= SENSOR_ADDR then
                    report "[SLAVE] Address mismatch";
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

                if is_read then
                    read_loop : loop
                        case to_integer(ptr) is
                            when 16#00# => drive_byte(slave_temp_raw(15 downto 8), got_ack);
                            when 16#01# => drive_byte(slave_temp_raw(7 downto 0),  got_ack);
                            when 16#03# => drive_byte(slave_config_reg,             got_ack);
                            when others => drive_byte(x"00",                        got_ack);
                        end case;
                        ptr := ptr + 1;
                        exit read_loop when not got_ack;
                    end loop read_loop;
                    loop
                        sprev := sda;
                        wait on sda, scl;
                        if scl = '1' or scl = 'H' then
                            if sprev = '0' and (sda = '1' or sda = 'H') then
                                exit transaction_loop;
                            elsif (sprev = '1' or sprev = 'H') and sda = '0' then
                                next transaction_loop;
                            end if;
                        end if;
                    end loop;
                else
                    sample_byte(byte_v, abort_v);
                    if    abort_v = 1 then exit transaction_loop;
                    elsif abort_v = 2 then next transaction_loop; end if;
                    ptr := unsigned(byte_v);
                    drive_ack;
                    report "[SLAVE] Ptr <= 0x" & integer'image(to_integer(ptr));

                    write_loop : loop
                        sample_byte(byte_v, abort_v);
                        if abort_v = 2 then next transaction_loop; end if;
                        exit write_loop when abort_v = 1;
                        drive_ack;
                        if to_integer(ptr) = 16#03# then
                            slave_config_reg <= byte_v;
                            report "[SLAVE] Config reg <= 0x"
                                 & integer'image(to_integer(unsigned(byte_v)));
                        end if;
                        ptr := ptr + 1;
                    end loop write_loop;
                    exit transaction_loop;
                end if;
            end loop transaction_loop;
        end loop main_loop;
    end process;

end architecture;