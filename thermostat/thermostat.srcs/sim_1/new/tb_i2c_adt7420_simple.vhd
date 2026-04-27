-- tb_i2c_adt7420_simple.vhd
--
-- Minimal ADT7420 I2C slave testbench targeting adt7420_reader_simple.
--
-- adt7420_reader_simple issues only direct reads (no config write, no
-- pointer write -- relies on ADT7420 power-on defaults):
--   S + addr(0x4B)+R  ->  slave ACK
--   8 SCL clocks      ->  slave drives MSB,  master ACK
--   8 SCL clocks      ->  slave drives LSB,  master NAK
--   STOP
--
-- Bus wiring
--   scl/sda start as weak 'H' (pull-ups).
--   DUT drives 'Z' (release) or '0' (pull low).
--   Slave model drives slave_sda_drv ('Z' or '0') onto sda.
--   std_logic resolution:  H + Z + Z = H,  H + Z + 0 = 0.
--
-- Three temperatures exercised (13-bit mode, LSB = 0.0625 C):
--   x"0B10"  22.1 C  -> tenths = 221
--   x"FD58"  -5.3 C  -> tenths = -53 or -54 (sign extension rounding)
--   x"3E80" 125.0 C  -> tenths = 1250

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_i2c_adt7420_simple is
end entity;

architecture behavioral of tb_i2c_adt7420_simple is

    signal clk         : STD_LOGIC := '0';
    signal rst         : STD_LOGIC := '1';
    signal temperature : STD_LOGIC_VECTOR(15 downto 0);
    signal temp_valid  : STD_LOGIC;
    signal err_out     : STD_LOGIC;

    signal scl           : STD_LOGIC;
    signal sda           : STD_LOGIC;
    signal slave_sda_drv : STD_LOGIC := 'Z';

    -- Driven by stim_proc between readings
    signal slave_temp_raw : STD_LOGIC_VECTOR(15 downto 0) := x"0B10";

    constant SENSOR_ADDR : STD_LOGIC_VECTOR(6 downto 0) := "1001011"; -- 0x4B

begin

    clk <= not clk after 5 ns;  -- 100 MHz

    scl <= 'H';                 -- weak pull-ups
    sda <= 'H';
    sda <= slave_sda_drv;

    dut : entity work.adt7420_reader_simple
        generic map (
            CLOCK_FREQ_HZ    => 100_000_000,
            READ_INTERVAL_MS => 2           -- 2 ms between reads keeps sim short
        )
        port map (
            clock          => clk,
            reset          => rst,
            sensor_address => SENSOR_ADDR,
            temperature    => temperature,
            temp_valid     => temp_valid,
            error          => err_out,
            scl            => scl,
            sda            => sda
        );

    -- ----------------------------------------------------------------
    -- Stimulus: release reset, verify three consecutive readings.
    -- slave_temp_raw is updated after each temp_valid pulse so the
    -- slave returns the new value on the next transaction.
    -- ----------------------------------------------------------------
    stim_proc : process
    begin
        rst            <= '1';
        slave_temp_raw <= x"0B10";   -- 22.1 C
        wait for 200 ns;
        rst <= '0';

        -- Reading 1: 22.1 C  (code13=354, tenths=354*10/16=221)
        wait until rising_edge(temp_valid);
        report "[TB] R1 = " & integer'image(to_integer(signed(temperature))) & " tenths C";
        assert to_integer(signed(temperature)) = 221
            report "R1: expected 221, got " &
                   integer'image(to_integer(signed(temperature)))
            severity failure;

        -- Reading 2: -5.3 C  (code13=-85, tenths floor(-850/16)=-54)
        slave_temp_raw <= x"FD58";
        wait until rising_edge(temp_valid);
        report "[TB] R2 = " & integer'image(to_integer(signed(temperature))) & " tenths C";
        assert to_integer(signed(temperature)) = -53 or
               to_integer(signed(temperature)) = -54
            report "R2: expected -53 or -54, got " &
                   integer'image(to_integer(signed(temperature)))
            severity failure;

        -- Reading 3: 125.0 C  (code13=2000, tenths=1250)
        slave_temp_raw <= x"3E80";
        wait until rising_edge(temp_valid);
        report "[TB] R3 = " & integer'image(to_integer(signed(temperature))) & " tenths C";
        assert to_integer(signed(temperature)) = 1250
            report "R3: expected 1250, got " &
                   integer'image(to_integer(signed(temperature)))
            severity failure;

        report "+++All good";
        wait for 5 ms;
        std.env.finish;
    end process;

    -- ----------------------------------------------------------------
    -- Watchdog: 200 ms covers several 2 ms read cycles with margin.
    -- ----------------------------------------------------------------
    watchdog_proc : process
    begin
        wait for 200 ms;
        report "[TB] WATCHDOG: 200 ms elapsed."
             & " scl="       & std_logic'image(scl)
             & " sda="       & std_logic'image(sda)
             & " temp_valid=" & std_logic'image(temp_valid)
             & " err="       & std_logic'image(err_out)
            severity failure;
        wait;
    end process;

    -- ----------------------------------------------------------------
    -- ADT7420 slave model (direct-read only).
    --
    -- Procedures inside the process share the slave_sda_drv signal
    -- via the enclosing architecture.
    --
    -- sample_byte: reads 8 bits MSB-first on rising SCL edges.
    --   abort = 0  normal completion
    --   abort = 1  STOP detected  (SDA rises while SCL high)
    --   abort = 2  RESTART detected (SDA falls while SCL high)
    --
    -- drive_ack: pulls SDA low for one full SCL cycle (9th clock).
    --
    -- drive_byte: drives 8 bits MSB-first; captures master ACK/NAK.
    -- ----------------------------------------------------------------
    slave_proc : process
        variable byte_v  : STD_LOGIC_VECTOR(7 downto 0);
        variable abort_v : integer;
        variable got_ack : boolean;
        variable sprev   : STD_LOGIC;

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
                            abort := 2; return;             -- RESTART
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
            wait until falling_edge(scl);   -- start of 9th SCL low
            slave_sda_drv <= '0';
            wait until falling_edge(scl);   -- end of 9th SCL high
            slave_sda_drv <= 'Z';
        end procedure;

        procedure drive_byte (b             : in  STD_LOGIC_VECTOR(7 downto 0);
                               variable ack : out boolean) is
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
            slave_sda_drv <= 'Z';                   -- release for master ACK/NAK
            wait until rising_edge(scl);
            ack := (sda = '0' or sda = 'L');
            wait until falling_edge(scl);
        end procedure;

    begin
        slave_sda_drv <= 'Z';
        wait for 1 us;                              -- let DUT come out of reset

        main_loop : loop

            -- Wait for START: SDA falls while SCL is high
            loop
                sprev := sda;
                wait on sda;
                exit when (sprev = '1' or sprev = 'H') and sda = '0'
                      and (scl = '1' or scl = 'H');
            end loop;
            report "[SLAVE] START";

            -- Sample address byte
            sample_byte(byte_v, abort_v);
            if abort_v /= 0 then next main_loop; end if;

            if byte_v(7 downto 1) = SENSOR_ADDR and byte_v(0) = '1' then
                report "[SLAVE] Addr match R=1, driving bytes";
                drive_ack;
                drive_byte(slave_temp_raw(15 downto 8), got_ack);  -- MSB
                drive_byte(slave_temp_raw(7 downto 0),  got_ack);  -- LSB
            else
                report "[SLAVE] Addr/mode mismatch, ignoring";
            end if;

            -- Wait for STOP or RESTART before re-entering main_loop
            loop
                sprev := sda;
                wait on sda, scl;
                exit when (scl = '1' or scl = 'H') and
                    ((sprev = '0' and (sda = '1' or sda = 'H')) or
                     ((sprev = '1' or sprev = 'H') and sda = '0'));
            end loop;

        end loop main_loop;
    end process;

end architecture;
