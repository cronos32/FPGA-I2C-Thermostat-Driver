-- clk_en: Parameterizable clock-enable pulse generator.
-- Counts from 0 to G_MAX-1 and asserts ce for exactly one clock cycle
-- when the counter wraps, producing a periodic enable pulse.
-- Used throughout the design to create lower-rate processes without
-- generating additional clocks (avoids clock domain crossings).
-- Based on lab material by Tomas Fryza, Brno University of Technology.

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity clk_en is
    generic (
        G_MAX : positive := 5  -- Default number of clock cycles
    );
    Port ( clk : in STD_LOGIC;
           rst : in STD_LOGIC;
           ce : out STD_LOGIC);
end clk_en;

architecture Behavioral of clk_en is

signal sig_cnt: integer range 0 to G_max -1;

begin
    synchronous_process : process (clk) is
    begin
        if rising_edge (clk) then
            if rst = '1' then 
                sig_cnt <= 0;
                ce <= '0';
            elsif sig_cnt = G_max - 1 then
                sig_cnt <= 0;
                ce <= '1';
            else
                ce <= '0'; 
                sig_cnt <= sig_cnt + 1;
            end if;
        end if;
    
    end process;

end Behavioral;
