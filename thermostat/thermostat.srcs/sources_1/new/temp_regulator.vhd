-- temp_regulator: Purely combinational hysteresis thermostat controller.
-- Compares current_temp against set_temp +/- HYST (5 = 0.5 deg C).
-- Drives heat_en + led_red  when heating is needed,
--         cool_en + led_blue when cooling is needed,
--         led_green          when within the hysteresis band.
-- No clock or reset; outputs update immediately with inputs.

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity temp_regulator is
    port (
        set_temp     : in  unsigned(11 downto 0); -- např 232
        current_temp : in  unsigned(11 downto 0);

        led_red   : out std_logic;
        led_blue  : out std_logic;
        led_green : out std_logic;

        heat_en : out std_logic;
        cool_en : out std_logic
    );
end temp_regulator;

architecture Behavioral of temp_regulator is

    constant HYST : integer := 5; -- 0.5°C (zoom ×10)

begin

    process(set_temp, current_temp)
        variable set_i  : integer;
        variable curr_i : integer;
    begin
        set_i  := to_integer(set_temp);
        curr_i := to_integer(current_temp);

        -- default
        heat_en   <= '0';
        cool_en   <= '0';
        led_red   <= '0';
        led_blue  <= '0';
        led_green <= '0';

        if curr_i < (set_i - HYST) then
            -- heating
            heat_en <= '1';
            led_red <= '1';

        elsif curr_i > (set_i + HYST) then
            -- cooling
            cool_en  <= '1';
            led_blue <= '1';

        else
            -- ok
            led_green <= '1';
        end if;

    end process;

end Behavioral;