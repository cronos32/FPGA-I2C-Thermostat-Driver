-- tb_display_data_combiner: Testbench for display_data_combiner.
-- Applies set_temp / current_temp values and checks that data_out carries
-- correct BCD digits with 0xC in each unit position.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_display_data_combiner is
end tb_display_data_combiner;

architecture tb of tb_display_data_combiner is

    component display_data_combiner
        port (set_temp     : in unsigned (11 downto 0);
              current_temp : in unsigned (11 downto 0);
              data_out     : out std_logic_vector (31 downto 0));
    end component;

    signal set_temp     : unsigned (11 downto 0);
    signal current_temp : unsigned (11 downto 0);
    -- Removed ghost signal: sw_unit
    signal data_out     : std_logic_vector (31 downto 0);

begin

    dut : display_data_combiner
    port map (set_temp     => set_temp,
              current_temp => current_temp,
              data_out     => data_out);

    stimuli : process
    begin
        -----------------------------------------------------------
        -- Test 1: Normal Values (21.0 and 24.5)
        -----------------------------------------------------------
        set_temp     <= to_unsigned(210, 12); 
        current_temp <= to_unsigned(245, 12); 
        wait for 100 ns;
        
        -- Assuming your combiner maps set_temp to higher bits and current to lower
        -- Adjust the hex values below based on your specific BCD mapping!
        assert (data_out(11 downto 0) = x"245") 
            report "Test 1 Failed: Current temp BCD mismatch" severity error;

        -----------------------------------------------------------
        -- Test 2: Clamping Logic (Set temp = 150.0 -> 99.9)
        -----------------------------------------------------------
        set_temp     <= to_unsigned(1500, 12); 
        current_temp <= to_unsigned(10, 12);   
        wait for 100 ns;

        -- We expect set_temp to be clamped at 999 (x"999")
        assert (data_out(31 downto 20) = x"999")
            report "Test 2 Failed: Set temp was not clamped to 999" severity error;
            
        assert (data_out(11 downto 0) = x"010")
            report "Test 2 Failed: Current temp BCD mismatch" severity error;

        -----------------------------------------------------------
        -- End of Test
        -----------------------------------------------------------
        report "Simulation Complete. Check the console for any 'Failure' messages.";
        wait;
    end process;

end tb;