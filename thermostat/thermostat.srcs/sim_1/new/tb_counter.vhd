library ieee;
use ieee.std_logic_1164.all;

entity tb_counter is
end tb_counter;

architecture tb of tb_counter is

    -- 1. Define a constant here so it is visible to the whole architecture
    constant C_G_BITS : positive := 3; 
    constant TbPeriod : time := 10 ns;

    component counter
        generic (
            G_BITS : positive := 3
        );
        port (
            clk : in std_logic;
            rst : in std_logic;
            en  : in std_logic;
            cnt : out std_logic_vector (G_BITS - 1 downto 0)
        );
    end component;

    signal clk : std_logic;
    signal rst : std_logic;
    signal en  : std_logic;
    -- 2. Use the constant here
    signal cnt : std_logic_vector (C_G_BITS - 1 downto 0);

    signal TbClock : std_logic := '0';
    signal TbSimEnded : std_logic := '0';

begin

    dut : counter
        generic map ( 
            G_BITS => C_G_BITS  -- 3. Pass the constant to the component
        )
        port map (
            clk => clk,
            rst => rst,
            en  => en,
            cnt => cnt
        );

    -- Clock generation
    TbClock <= not TbClock after TbPeriod/2 when TbSimEnded /= '1' else '0';
    clk <= TbClock;

    stimuli : process
    begin
        -- Initialize
        rst <= '1'; -- Usually best to start with a reset
        en  <= '0';
        wait for TbPeriod * 2;
        
        rst <= '0';
        wait for TbPeriod;
        
        en <= '1'; -- Start counting
        
        -- Wait and finish
        wait for 100 * TbPeriod;
        TbSimEnded <= '1';
        wait;
    end process;

end tb;