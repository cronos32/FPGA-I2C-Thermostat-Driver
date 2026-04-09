----------------------------------------------------------------------------------
-- Company: 
-- Engineer: 
-- 
-- Create Date: 04/02/2026 06:01:53 PM
-- Design Name: 
-- Module Name: thermostat_top - Behavioral
-- Project Name: 
-- Target Devices: 
-- Tool Versions: 
-- Description: 
-- 
-- Dependencies: 
-- 
-- Revision:
-- Revision 0.01 - File Created
-- Additional Comments:
-- 
----------------------------------------------------------------------------------


library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

use IEEE.NUMERIC_STD.ALL;

-- Uncomment the following library declaration if instantiating
-- any Xilinx leaf cells in this code.
--library UNISIM;
--use UNISIM.VComponents.all;

entity thermostat_top is
    Port ( clk : in STD_LOGIC;
--           btnu : in STD_LOGIC;
--           btnd : in STD_LOGIC;
           btnc : in STD_LOGIC;
           seg : out STD_LOGIC_VECTOR (6 downto 0);
           dp : out STD_LOGIC;
           an : out STD_LOGIC_VECTOR (7 downto 0);
           --sw dodelat
           led16_r : out STD_LOGIC;
           led16_g : out STD_LOGIC;
           led16_b : out STD_LOGIC--;
--           TMP_SDA : inout STD_LOGIC;
--           TMP_SCL : out STD_LOGIC
    );
end thermostat_top;

architecture Behavioral of thermostat_top is

    component display_driver is
        port (
            rst   : in std_logic;
            clk   : in std_logic;
            data  : in std_logic_vector (31 downto 0);
            dp_en : in STD_LOGIC_VECTOR (7 downto 0);
            seg   : out std_logic_vector (6 downto 0);
            anode : out std_logic_vector (7 downto 0);
            dp    : out std_logic
        );
    end component display_driver;
    
    component display_data_combiner is
        port (
            set_temp     : in  unsigned(11 downto 0); -- for example 232
            current_temp : in  unsigned(11 downto 0); -- for example 244
            sw_unit      : in  std_logic;             -- 0 = C, 1 = F
  
            data_out     : out std_logic_vector(31 downto 0)
        );
    end component display_data_combiner;
    
    component  temp_regulator is
        port (
            set_temp     : in  unsigned(11 downto 0); -- např 232
            current_temp : in  unsigned(11 downto 0);
    
            led_red   : out std_logic;
            led_blue  : out std_logic;
            led_green : out std_logic;
    
            heat_en : out std_logic;
            cool_en : out std_logic
        );
    end component  temp_regulator;
    
signal sig_display_data : std_logic_vector (31 downto 0); --xxxCxxxC nebo xxxFxxxF
signal sig_dp    : std_logic_vector(7 downto 0):= "10111011";  -- decimal points "10111011"

signal set_temp     : unsigned(11 downto 0);
signal current_temp : unsigned(11 downto 0);

begin

    display_0 : display_driver
    port map (
        clk => clk,
        rst => btnc,
        data => sig_display_data,
        dp_en => sig_dp,
        seg => seg,
        anode => an(7 downto 0),
        dp => dp
    );
    
    combiner_0 : display_data_combiner
    port map(
        set_temp     => set_temp,
        current_temp => current_temp,
        sw_unit      => '0',
        data_out     => sig_display_data
    );
    
    regulator_0 : temp_regulator
    port map(
        set_temp     => set_temp,
        current_temp => current_temp,

        led_red      => led16_r,
        led_blue     => led16_b,
        led_green    => led16_g--,

        --heat_en => 
        --cool_en =>
    );

end Behavioral;