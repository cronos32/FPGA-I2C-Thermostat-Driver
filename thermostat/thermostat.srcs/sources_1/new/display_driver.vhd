library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_display_driver is
end tb_display_driver;

architecture tb of tb_display_driver is

    -- Component declaration
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

    -- Device Under Test (DUT)
    -- IMPORTANT: In your display_driver.vhd, change G_MAX to 10 for simulation!
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
        data <= x"00000000";
        dp_en <= "00000000";
        wait for 100 ns;
        rst <= '0';
        wait for 50 ns;

        -- 2. Test Data: Displaying "1234.5678"
        -- We set data to hex values and enable one decimal point (dp)
        data  <= x"12345678"; 
        dp_en <= "00010000"; -- Decimal point on the 5th digit (index 4)
        
        -- 3. Observation
        -- If G_MAX is set to 10 in the driver, each digit switches every 100ns.
        -- We wait 2000ns to see several full cycles of all 8 digits.
        wait for 2000 ns;

        -- 4. Change data to check Hex decoding (A, B, C...)
        data <= x"ABCDEF00";
        dp_en <= "11111111"; -- All decimal points on
        wait for 2000 ns;

        -- End simulation
        TbSimEnded <= '1';
        report "Simulation finished successfully.";
        wait;
    end process;

end tb;