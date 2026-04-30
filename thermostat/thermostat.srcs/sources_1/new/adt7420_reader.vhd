-- adt7420_reader: ADT7420 I2C temperature sensor reader.
--
-- Thin wrapper around pmod_temp_sensor_adt7420 (Digi-Key / Scott Larson driver) that:
--   * inverts reset -> reset_n (Larson driver uses active-low reset)
--   * instantiates pmod_temp_sensor_adt7420 with configurable sys_clk_freq
--   * converts the raw 16-bit register value (16-bit mode, LSB=0.0078125 C)
--     into signed tenths-of-a-degree to match thermostat_top's expectation
--   * generates a one-cycle temp_valid pulse on each new reading
--
-- Conversion math (16-bit mode):
--   tenths = raw_signed * 10 / 128
--          = (raw*8 + raw*2) >> 7    (avoids a signed multiplier)
--
-- pmod_temp_sensor_adt7420 writes 0x80 to the config register at startup,
-- putting the ADT7420 into 16-bit continuous-conversion mode.

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity adt7420_reader is
    generic (
        CLOCK_FREQ_HZ : integer := 100_000_000;
        SENSOR_ADDR   : STD_LOGIC_VECTOR(6 downto 0) := "1001011"  -- Nexys A7: 0x4B
    );
    port (
        clock       : in    STD_LOGIC;
        reset       : in    STD_LOGIC;                       -- active-HIGH (e.g. btnc)
        temperature : out   STD_LOGIC_VECTOR (15 downto 0);  -- signed tenths of C
        temp_valid  : out   STD_LOGIC;                       -- 1-cycle pulse per reading
        ack_error   : out   STD_LOGIC;                       -- from Larson's i2c_master
        scl         : inout STD_LOGIC;
        sda         : inout STD_LOGIC
    );
end entity;

architecture behavioral of adt7420_reader is

    component pmod_temp_sensor_adt7420 is
        generic (
            sys_clk_freq     : INTEGER := 50_000_000;
            temp_sensor_addr : STD_LOGIC_VECTOR(6 downto 0) := "1001011");
        port (
            clk         : in    STD_LOGIC;
            reset_n     : in    STD_LOGIC;
            scl         : inout STD_LOGIC;
            sda         : inout STD_LOGIC;
            i2c_ack_err : out   STD_LOGIC;
            temperature : out   STD_LOGIC_VECTOR(15 downto 0));
    end component;

    signal reset_n      : STD_LOGIC;
    signal raw_temp     : STD_LOGIC_VECTOR (15 downto 0);
    signal raw_temp_d   : STD_LOGIC_VECTOR (15 downto 0) := (others => '0');
    signal tenths_r     : signed (15 downto 0) := (others => '0');
    signal temp_valid_r : STD_LOGIC := '0';

begin

    reset_n <= not reset;

    sensor : pmod_temp_sensor_adt7420
        generic map (
            sys_clk_freq     => CLOCK_FREQ_HZ,
            temp_sensor_addr => SENSOR_ADDR
        )
        port map (
            clk         => clock,
            reset_n     => reset_n,
            scl         => scl,
            sda         => sda,
            i2c_ack_err => ack_error,
            temperature => raw_temp
        );

    ------------------------------------------------------------------
    -- Convert raw register value to signed tenths of a degree.
    -- Pulse temp_valid for one clock when raw_temp changes.
    ------------------------------------------------------------------
    conv_proc : process (clock, reset)
        variable raw16  : signed (15 downto 0);
        variable scaled : signed (31 downto 0);
    begin
        if reset = '1' then
            tenths_r     <= (others => '0');
            temp_valid_r <= '0';
            raw_temp_d   <= (others => '0');
        elsif rising_edge(clock) then
            raw_temp_d   <= raw_temp;
            temp_valid_r <= '0';
            if raw_temp /= raw_temp_d then
                raw16  := signed(raw_temp);
                scaled := shift_left(resize(raw16, 32), 3)
                        + shift_left(resize(raw16, 32), 1);
                tenths_r     <= resize(shift_right(scaled, 7), 16);
                temp_valid_r <= '1';
            end if;
        end if;
    end process;

    temperature <= std_logic_vector(tenths_r);
    temp_valid  <= temp_valid_r;

end architecture;
