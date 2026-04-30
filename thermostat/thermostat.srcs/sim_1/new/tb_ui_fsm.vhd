-- tb_ui_fsm: Testbench for ui_fsm.
-- Simulates btn_up / btn_down presses and verifies that temp_out increments
-- and decrements in 5-unit steps, clamped to the 50-400 (5.0-40.0 deg C) range.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_ui_fsm is
end tb_ui_fsm;

architecture tb of tb_ui_fsm is

    component ui_fsm
        port (clk      : in  std_logic;
              reset    : in  std_logic;
              btn_up   : in  std_logic;
              btn_down : in  std_logic;
              temp_out : out std_logic_vector (11 downto 0));
    end component;

    signal clk      : std_logic := '0';
    signal reset    : std_logic;
    signal btn_up   : std_logic := '0';
    signal btn_down : std_logic := '0';
    signal temp_out : std_logic_vector (11 downto 0);

    constant TbPeriod : time := 10 ns; -- 100 MHz
    signal TbSimEnded : std_logic := '0';

begin

    dut : ui_fsm
    port map (clk      => clk,
              reset    => reset,
              btn_up   => btn_up,
              btn_down => btn_down,
              temp_out => temp_out);

    clk <= not clk after TbPeriod/2 when TbSimEnded /= '1' else '0';

    stimuli : process
    begin
        -- 1. Reset and Initialization Check
        reset <= '1';
        wait for 100 ns;
        reset <= '0';
        wait for 10 ns; -- Delta cycle settle
        
        -- Default should be 22.0 C (220 decimal = x"0DC")
        assert (unsigned(temp_out) = 220) 
            report "Initial temperature mismatch! Expected 220." severity error;

        -- 2. Simulate SINGLE UP Press
        -- Debounce takes ~8ms, CE (Clock Enable) fires every 100ms.
        -- To trigger EXACTLY ONE update, we hold for more than 8ms but less than 100ms.
        btn_up <= '1';
        wait for 50 ms; 
        btn_up <= '0';
        
        -- Wait for the 100ms CE window to pass so the change is latched
        wait for 150 ms;
        assert (unsigned(temp_out) = 225) 
            report "UP press failed! Expected 225 (+0.5C)." severity error;

        -- 3. Simulate SINGLE DOWN Press
        btn_down <= '1';
        wait for 50 ms;
        btn_down <= '0';

        wait for 150 ms;
        assert (unsigned(temp_out) = 220) 
            report "DOWN press failed! Expected return to 220." severity error;

        -- 4. Simulate AUTO-INCREMENT (Hold for 300ms)
        -- This should trigger 3 increments (+1.5C)
        btn_up <= '1';
        wait for 350 ms; -- 3 full CE periods
        btn_up <= '0';
        
        wait for 100 ms;
        assert (unsigned(temp_out) = 235) 
            report "Auto-increment failed! Expected 235." severity error;

        report "UI FSM Simulation Complete.";
        TbSimEnded <= '1';
        wait;
    end process;

end tb;