library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_display_driver is
end tb_display_driver;

architecture tb of tb_display_driver is

    -- Component declaration matching the actual entity
    component display_driver
        port (
            rst   : in  std_logic;
            clk   : in  std_logic;
            data  : in  std_logic_vector (31 downto 0);
            dp_en : in  std_logic_vector (7 downto 0);
            seg   : out std_logic_vector (6 downto 0);
            anode : out std_logic_vector (7 downto 0);
            dp    : out std_logic
        );
    end component;

    -- Local signals
    signal clk   : std_logic := '0';
    signal rst   : std_logic;
    signal data  : std_logic_vector (31 downto 0) := (others => '0');
    signal dp_en : std_logic_vector (7 downto 0)  := (others => '0');
    signal seg   : std_logic_vector (6 downto 0);
    signal anode : std_logic_vector (7 downto 0);
    signal dp    : std_logic;

    constant TbPeriod : time := 10 ns; -- 100 MHz
    signal TbSimEnded : std_logic := '0';

begin

    -- Instance of the Device Under Test (DUT)
    dut : display_driver
    port map (
        clk   => clk,
        rst   => rst,
        data  => data,
        dp_en => dp_en,
        seg   => seg,
        anode => anode,
        dp    => dp
    );

    -- Clock generation
    clk <= not clk after TbPeriod/2 when TbSimEnded /= '1' else '0';

    -- Stimuli process
    stimuli : process
    begin
        -- 1. Reset Phase
        rst <= '1';
        data <= (others => '0');
        dp_en <= (others => '0');
        wait for 100 ns;
        rst <= '0';
        wait for 100 ns;

        -- 2. Load test data (Displaying 0x12345678)
        -- Digit 0 will be '8', Digit 7 will be '1'
        data  <= x"12345678"; 
        dp_en <= "10000001"; -- Turn on decimal points for first and last digit
        
        -- 3. Observation Phase
        -- We need to wait long enough for the multiplexer to cycle through digits.
        -- Note: If G_MAX is 800,000, each digit takes 8ms. 
        -- To see all 8 digits in simulation, you'd need to wait > 64ms.
        -- RECOMMENDATION: Change G_MAX to 32 in your code for faster simulation!
        
        wait for 1 ms; -- Adjust this based on your G_MAX value

        -- 4. Change data
        data <= x"ABCDEF00";
        wait for 1 ms;

        -- End simulation
        report "Simulation finished. Check waveforms for anode/segment switching.";
        TbSimEnded <= '1';
        wait;
    end process;

end tb;