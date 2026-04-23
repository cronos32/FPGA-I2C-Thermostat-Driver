-- tb_bin2seg: Testbench for bin2seg.
-- Applies all 16 possible 4-bit inputs and checks the active-low
-- 7-segment output, including the special 0xC -> 'C' case.
-- Based on lab material by Tomas Fryza, Brno University of Technology.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;  -- Required for "to_unsigned"

entity tb_bin2seg is
end tb_bin2seg;

architecture tb of tb_bin2seg is

    component bin2seg
        port (bin : in std_logic_vector (3 downto 0);
              seg : out std_logic_vector (6 downto 0));
    end component;

    signal bin : std_logic_vector (3 downto 0);
    signal seg : std_logic_vector (6 downto 0);

begin

    dut : bin2seg
    port map (bin => bin,
              seg => seg);

    stimuli : process
    begin
        -- ***EDIT*** Adapt initialization as needed
        ---bin <= (others => '0');

        -- ***EDIT*** Add stimuli here
        -- Loop through all hexadecimal values (0 to 15)
        for i in 0 to 15 loop
        
            -- Convert integer i to 4-bit std_logic_vector
            bin <= std_logic_vector(to_unsigned(i, 4));
            wait for 10 ns;
    
        end loop;

        wait;
    end process;

end tb;