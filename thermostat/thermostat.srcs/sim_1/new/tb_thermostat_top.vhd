-- tb_thermostat_top: Integration testbench for thermostat_top.
-- Instantiates a behavioural ADT7420 I2C model and exercises the full
-- design: sensor reads, button-driven setpoint changes, and LED outputs.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_thermostat_top is
end tb_thermostat_top;

architecture tb of tb_thermostat_top is

    component thermostat_top
        port (clk     : in std_logic;
              btnu    : in std_logic;
              btnd    : in std_logic;
              btnc    : in std_logic;
              seg     : out std_logic_vector (6 downto 0);
              dp      : out std_logic;
              an      : out std_logic_vector (7 downto 0);
              led16_r : out std_logic;
              led16_g : out std_logic;
              led16_b : out std_logic;
              TMP_SDA : inout std_logic;
              TMP_SCL : inout std_logic);
    end component;

    signal clk     : std_logic := '0';
    signal btnu    : std_logic := '0';
    signal btnd    : std_logic := '0';
    signal btnc    : std_logic := '0';
    signal seg     : std_logic_vector (6 downto 0);
    signal dp      : std_logic;
    signal an      : std_logic_vector (7 downto 0);
    signal led16_r : std_logic;
    signal led16_g : std_logic;
    signal led16_b : std_logic;
    
    -- I2C Resolved Signals
    signal TMP_SDA : std_logic;
    signal TMP_SCL : std_logic;
    signal slave_sda_drv : std_logic := 'Z'; 

    -- Slave Internal State
    -- Default: 22.1 C pre-calculated for the 16-bit ADT7420 format
    signal slave_temp_raw   : std_logic_vector(15 downto 0) := x"0B10"; 
    signal slave_config_reg : std_logic_vector(7 downto 0)  := x"00";
    signal dbg_read_count   : integer := 0;

    constant TbPeriod : time := 10 ns; 
    signal TbSimEnded : std_logic := '0';

begin

    -- I2C Pull-ups and Resolution
    TMP_SDA <= 'H';
    TMP_SCL <= 'H';
    TMP_SDA <= slave_sda_drv; -- Slave drives '0' or 'Z'

    dut : thermostat_top
    port map (clk => clk, btnu => btnu, btnd => btnd, btnc => btnc,
              seg => seg, dp => dp, an => an,
              led16_r => led16_r, led16_g => led16_g, led16_b => led16_b,
              TMP_SDA => TMP_SDA, TMP_SCL => TMP_SCL);

    clk <= not clk after TbPeriod/2 when TbSimEnded /= '1' else '0';

    -------------------------------------------------------------------
    -- ROBUST ADT7420 SLAVE MODEL (VHDL-93 COMPATIBLE)
    -------------------------------------------------------------------
    slave_proc : process
        procedure drive_ack is
        begin
            wait until falling_edge(TMP_SCL);
            slave_sda_drv <= '0';
            wait until falling_edge(TMP_SCL);
            slave_sda_drv <= 'Z';
        end procedure;

        procedure sample_byte (variable b            : out std_logic_vector(7 downto 0);
                               variable abort_reason : out integer) is
            variable tmp      : std_logic_vector(7 downto 0) := (others => '0');
            variable sda_prev : std_logic;
        begin
            abort_reason := 0;
            for i in 7 downto 0 loop
                loop
                    sda_prev := TMP_SDA;
                    wait on TMP_SCL, TMP_SDA;
                    if (TMP_SCL = '1' or TMP_SCL = 'H') then
                        if ((sda_prev = '1' or sda_prev = 'H') and TMP_SDA = '0') then
                            abort_reason := 2; -- RESTART
                            return;
                        elsif (sda_prev = '0' and (TMP_SDA = '1' or TMP_SDA = 'H')) then
                            abort_reason := 1; -- STOP
                            return;
                        end if;
                    end if;
                    exit when (TMP_SCL'event and (TMP_SCL = '1' or TMP_SCL = 'H'));
                end loop;
                -- FIXED LINE 98-99: Replaced VHDL-2008 conditional with VHDL-93 if/else
                if (TMP_SDA = '0') then
                    tmp(i) := '0';
                else
                    tmp(i) := '1';
                end if;
            end loop;
            b := tmp;
        end procedure;

        procedure drive_byte (b : std_logic_vector(7 downto 0); variable ack : out boolean) is
        begin
            if not (TMP_SCL = '0' or TMP_SCL = 'L') then
                wait until falling_edge(TMP_SCL);
            end if;
            for i in 7 downto 0 loop
                -- FIXED LINE 109: Replaced VHDL-2008 conditional with VHDL-93 if/else
                if (b(i) = '0') then
                    slave_sda_drv <= '0';
                else
                    slave_sda_drv <= 'Z';
                end if;
                wait until falling_edge(TMP_SCL);
            end loop;
            slave_sda_drv <= 'Z';
            wait until rising_edge(TMP_SCL);
            if (TMP_SDA = '0' or TMP_SDA = 'L') then
                ack := true;
            else
                ack := false;
            end if;
            wait until falling_edge(TMP_SCL);
        end procedure;

        variable byte_v   : std_logic_vector(7 downto 0);
        variable abort_v  : integer;
        variable ack_v    : boolean;
        variable pointer  : unsigned(7 downto 0) := (others => '0');
        variable is_read  : boolean;
        variable sda_prev : std_logic;

    begin
        slave_sda_drv <= 'Z';
        wait for 2 us;

        main_loop : loop
            loop
                sda_prev := TMP_SDA;
                wait on TMP_SDA;
                exit when (sda_prev = '1' or sda_prev = 'H') and (TMP_SDA = '0') and (TMP_SCL = '1' or TMP_SCL = 'H');
            end loop;

            start_seen : loop
                sample_byte(byte_v, abort_v);
                if abort_v = 1 then exit start_seen;
                elsif abort_v = 2 then next main_loop;
                end if;

                if (byte_v(7 downto 1) = "1001000") then
                    drive_ack;
                    is_read := (byte_v(0) = '1');
                    if (is_read) then
                        read_loop : loop
                            case to_integer(pointer) is
                                when 16#00# => drive_byte(slave_temp_raw(15 downto 8), ack_v);
                                               dbg_read_count <= dbg_read_count + 1;
                                when 16#01# => drive_byte(slave_temp_raw(7 downto 0),  ack_v);
                                when 16#03# => drive_byte(slave_config_reg, ack_v);
                                when others => drive_byte(x"00", ack_v);
                            end case;
                            pointer := pointer + 1;
                            exit read_loop when not ack_v;
                        end loop;
                        -- Wait for STOP/RESTART
                        loop
                            sda_prev := TMP_SDA;
                            wait on TMP_SDA, TMP_SCL;
                            if (TMP_SCL = '1' or TMP_SCL = 'H') then
                                if (sda_prev = '0' and (TMP_SDA = '1' or TMP_SDA = 'H')) then exit start_seen;
                                elsif ((sda_prev = '1' or sda_prev = 'H') and TMP_SDA = '0') then next main_loop;
                                end if;
                            end if;
                        end loop;
                    else
                        sample_byte(byte_v, abort_v);
                        if abort_v = 1 then exit start_seen;
                        elsif abort_v = 2 then next main_loop;
                        end if;
                        drive_ack;
                        pointer := unsigned(byte_v);
                        write_loop : loop
                            sample_byte(byte_v, abort_v);
                            exit write_loop when abort_v /= 0;
                            drive_ack;
                            if (to_integer(pointer) = 16#03#) then slave_config_reg <= byte_v; end if;
                            pointer := pointer + 1;
                        end loop;
                        if abort_v = 1 then exit start_seen;
                        elsif abort_v = 2 then next main_loop;
                        end if;
                    end if;
                else
                    -- Address mismatch: wait for STOP
                    loop
                        sda_prev := TMP_SDA;
                        wait on TMP_SDA;
                        exit when (sda_prev = '0') and (TMP_SDA = '1' or TMP_SDA = 'H') and (TMP_SCL = '1' or TMP_SCL = 'H');
                    end loop;
                    exit start_seen;
                end if;
            end loop;
        end loop;
    end process;

    stimuli : process
    begin
        btnc <= '1';
        wait for 1 us;
        btnc <= '0';
        wait for 100 ns;

        btnu <= '1';
        wait for 30 ms; 
        btnu <= '0';
        
        report "Waiting for sensor acquisition cycle...";
        wait for 1100 ms; 

        report "Simulation finished.";
        TbSimEnded <= '1';
        wait;
    end process;

end tb;