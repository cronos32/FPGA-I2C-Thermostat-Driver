-- tb_i2c_master.vhd
--
-- Direct testbench for the Digi-Key Larson i2c_master core
-- (sources_1/new/i2c_master.vhd).  Replaces the legacy
-- tb_i2c_controller.vhd which targeted a different master with
-- mismatched ports.
--
-- Slave model:
--   * Responds at 7-bit address 0x4B (matches the ADT7420 PMOD)
--   * Three readable/writable register slots (0x00, 0x01, 0x03)
--   * ACKs every address/data byte; supports repeated START
--
-- Sequences exercised:
--   1. Two-byte write: ptr=0x03, value=0x80 (config-register style).
--   2. Pointer write + repeated START + 2-byte read with master NAK
--      on the last byte.
--   3. ack_error must stay '0' throughout.
--
-- Bus wiring follows the same convention as tb_i2c_adt7420_full:
-- pull-up 'H' + slave drives 'Z' or '0' resolves to idle-high or low.

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_i2c_master is
end entity;

architecture behavioral of tb_i2c_master is
    constant SYS_CLK_FREQ : integer := 100_000_000;
    constant BUS_CLK_FREQ : integer := 400_000;
    constant SLAVE_ADDR   : STD_LOGIC_VECTOR(6 downto 0) := "1001011";  -- 0x4B

    signal clk     : STD_LOGIC := '0';
    signal reset_n : STD_LOGIC := '0';
    signal ena     : STD_LOGIC := '0';
    signal addr    : STD_LOGIC_VECTOR(6 downto 0) := (others => '0');
    signal rw      : STD_LOGIC := '0';
    signal data_wr : STD_LOGIC_VECTOR(7 downto 0) := (others => '0');
    signal busy    : STD_LOGIC;
    signal data_rd : STD_LOGIC_VECTOR(7 downto 0);
    signal ack_err : STD_LOGIC;

    signal scl           : STD_LOGIC;
    signal sda           : STD_LOGIC;
    signal slave_sda_drv : STD_LOGIC := 'Z';

    -- Slave register file.  Reg00/01 are preloaded so reads return
    -- recognisable patterns; reg03 starts at 0 and is updated by the
    -- write transaction below.
    signal slave_reg00 : STD_LOGIC_VECTOR(7 downto 0) := x"A5";
    signal slave_reg01 : STD_LOGIC_VECTOR(7 downto 0) := x"5A";
    signal slave_reg03 : STD_LOGIC_VECTOR(7 downto 0) := x"00";

    -- Captured data_rd values from the read transaction.
    signal first_byte_read  : STD_LOGIC_VECTOR(7 downto 0) := (others => '0');
    signal second_byte_read : STD_LOGIC_VECTOR(7 downto 0) := (others => '0');

    -- Normalized views for the waveform viewer: bus pull-up makes
    -- 1-bits resolve to 'H', so raw signals render as e.g. "HH" or
    -- "A5" with H bits.  to_X01 maps H->1 / L->0.
    signal data_rd_x01         : STD_LOGIC_VECTOR(7 downto 0);
    signal first_byte_read_x01 : STD_LOGIC_VECTOR(7 downto 0);
    signal second_byte_read_x01: STD_LOGIC_VECTOR(7 downto 0);

begin

    data_rd_x01          <= to_X01(data_rd);
    first_byte_read_x01  <= to_X01(first_byte_read);
    second_byte_read_x01 <= to_X01(second_byte_read);


    clk <= not clk after 5 ns;  -- 100 MHz system clock

    scl <= 'H';
    sda <= 'H';
    sda <= slave_sda_drv;

    dut : entity work.i2c_master
        generic map (
            input_clk => SYS_CLK_FREQ,
            bus_clk   => BUS_CLK_FREQ
        )
        port map (
            clk       => clk,
            reset_n   => reset_n,
            ena       => ena,
            addr      => addr,
            rw        => rw,
            data_wr   => data_wr,
            busy      => busy,
            data_rd   => data_rd,
            ack_error => ack_err,
            sda       => sda,
            scl       => scl
        );

    -- ----------------------------------------------------------------
    -- Stimulus: drive the master with a two-byte write, then a
    -- pointer-write + repeated-start two-byte read.  The handshake
    -- follows the same busy-rising-edge pattern that
    -- pmod_temp_sensor_adt7420 uses against this master.
    -- ----------------------------------------------------------------
    stim_proc : process
    begin
        reset_n <= '0';
        ena     <= '0';
        wait for 200 ns;
        reset_n <= '1';
        wait for 1 us;

        -- Write transaction: addr=0x4B, payload=[0x03, 0x80]
        report "[TB] Write transaction: reg 0x03 <= 0x80";
        addr    <= SLAVE_ADDR;
        rw      <= '0';
        data_wr <= x"03";
        ena     <= '1';
        wait until rising_edge(busy);     -- 1st: start latched
        data_wr <= x"80";                 -- latched at slv_ack1
        wait until rising_edge(busy);     -- 2nd: 1st byte sent, 2nd latched
        ena <= '0';                       -- ena=0 -> stop after 2nd byte ACK
        wait until busy = '0';
        wait for 5 us;

        assert ack_err = '0'
            report "[TB] ack_error unexpectedly set after write"
            severity failure;
        -- Compare via integer to absorb 'H'/'L' resolved-bus values that
        -- otherwise mismatch '1'/'0' in strict std_logic equality.
        assert to_integer(unsigned(slave_reg03)) = 16#80#
            report "[TB] Slave reg03 expected 0x80, got 0x" &
                   integer'image(to_integer(unsigned(slave_reg03)))
            severity failure;
        report "[TB] Write transaction OK";

        -- Read transaction: write ptr=0x00, repeated start, read 2 bytes
        report "[TB] Read transaction: ptr=0x00, expect MSB=0xA5 LSB=0x5A";
        addr    <= SLAVE_ADDR;
        rw      <= '0';
        data_wr <= x"00";
        ena     <= '1';
        wait until rising_edge(busy);     -- 1st: start latched
        rw <= '1';                        -- request read after pointer byte
        wait until rising_edge(busy);     -- 2nd: ptr sent, master will Sr+read
        wait until rising_edge(busy);     -- 3rd: MSB read; LSB next
        ena <= '0';                       -- ena=0 -> NAK + STOP after LSB
        first_byte_read <= data_rd;       -- MSB available now
        wait until busy = '0';
        second_byte_read <= data_rd;      -- LSB available at end
        wait for 5 us;

        assert ack_err = '0'
            report "[TB] ack_error unexpectedly set after read"
            severity failure;
        -- Bus-resolved 'H' bits compare unequal to '1' under strict
        -- std_logic equality; convert to integer for the check.
        assert to_integer(unsigned(first_byte_read)) = 16#A5#
            report "[TB] MSB expected 0xA5, got 0x" &
                   integer'image(to_integer(unsigned(first_byte_read)))
            severity failure;
        assert to_integer(unsigned(second_byte_read)) = 16#5A#
            report "[TB] LSB expected 0x5A, got 0x" &
                   integer'image(to_integer(unsigned(second_byte_read)))
            severity failure;

        report "+++All good";
        wait for 10 us;
        std.env.finish;
    end process;

    -- Watchdog: I2C transactions at 400 kHz are well under 1 ms each,
    -- so anything past a few ms means the master is wedged.
    watchdog_proc : process
    begin
        wait for 5 ms;
        report "[TB] WATCHDOG: 5 ms elapsed."
             & " busy="    & std_logic'image(busy)
             & " ack_err=" & std_logic'image(ack_err)
             & " scl="     & std_logic'image(scl)
             & " sda="     & std_logic'image(sda)
            severity failure;
        wait;
    end process;

    -- ----------------------------------------------------------------
    -- I2C slave model (same protocol-level structure as
    -- tb_i2c_adt7420_full.vhd, pared down to a tiny register file).
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
            -- Wait for START: SDA falls while SCL is high.
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

                if byte_v(7 downto 1) /= SLAVE_ADDR then
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
                report "[SLAVE] Addr OK, R/W=" & std_logic'image(byte_v(0));

                if is_read then
                    read_loop : loop
                        case to_integer(ptr) is
                            when 16#00# => drive_byte(slave_reg00, got_ack);
                            when 16#01# => drive_byte(slave_reg01, got_ack);
                            when 16#03# => drive_byte(slave_reg03, got_ack);
                            when others => drive_byte(x"00",       got_ack);
                        end case;
                        ptr := ptr + 1;
                        exit read_loop when not got_ack;
                    end loop read_loop;
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
                        case to_integer(ptr) is
                            when 16#00# => slave_reg00 <= byte_v;
                            when 16#01# => slave_reg01 <= byte_v;
                            when 16#03# => slave_reg03 <= byte_v;
                            when others => null;
                        end case;
                        report "[SLAVE] reg[0x"
                             & integer'image(to_integer(ptr)) & "] <= 0x"
                             & integer'image(to_integer(unsigned(byte_v)));
                        ptr := ptr + 1;
                    end loop write_loop;
                    exit transaction_loop;
                end if;
            end loop transaction_loop;
        end loop main_loop;
    end process;

end architecture;