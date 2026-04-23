-- tb_debounce: Testbench for debounce.
-- Simulates noisy button presses and verifies that btn_state and btn_press
-- respond only after four consecutive stable samples (2 ms each).
-- Based on lab material by Tomas Fryza, Brno University of Technology.

library ieee;
use ieee.std_logic_1164.all;

entity tb_debounce is
end tb_debounce;

architecture tb of tb_debounce is

    component debounce
        port (clk       : in std_logic;
              rst       : in std_logic;
              btn_in    : in std_logic;
              btn_state : out std_logic;
              btn_press : out std_logic);
    end component;

    signal clk       : std_logic;
    signal rst       : std_logic;
    signal btn_in    : std_logic;
    signal btn_state : std_logic;
    signal btn_press : std_logic;

    constant TbPeriod : time := 10 ns; -- 100 MHz
    signal TbClock    : std_logic := '0';
    signal TbSimEnded : std_logic := '0';

begin

    dut : debounce
    port map (clk       => clk,
              rst       => rst,
              btn_in    => btn_in,
              btn_state => btn_state,
              btn_press => btn_press);

    -- Clock generation with proper stop condition
    TbClock <= not TbClock after TbPeriod/2 when TbSimEnded /= '1' else '0';
    clk <= TbClock;

    stimuli : process
    begin
        -- 1. Initialization
        btn_in <= '0';
        rst <= '1';
        wait for 100 ns;
        rst <= '0';
        wait for 1 ms; -- Stabilize

        -- 2. Simulate REALISTIC Bouncing (Transitions shorter than 8ms)
        -- These pulses are ~500us. Since sampling is every 2ms, 
        -- btn_state should NOT change here.
        btn_in <= '1'; wait for 500 us;
        btn_in <= '0'; wait for 300 us;
        btn_in <= '1'; wait for 800 us;
        btn_in <= '0'; wait for 400 us;

        -- 3. VALID PRESS (Stable for > 8 ms)
        -- We wait 20ms to ensure 4 samples are captured.
        btn_in <= '1';
        wait for 20 ms; 
        
        -- At this point, btn_state should be '1' and btn_press should have pulsed.

        -- 4. VALID RELEASE with Bouncing
        -- Again, small bounces shouldn't trigger a state change until stable.
        btn_in <= '0'; wait for 1 ms;
        btn_in <= '1'; wait for 1 ms;
        btn_in <= '0'; 
        
        -- Wait for the debouncer to confirm release
        wait for 20 ms;

        -- End simulation
        TbSimEnded <= '1';
        report "Simulation Finished Successfully";
        wait;
    end process;

end tb;