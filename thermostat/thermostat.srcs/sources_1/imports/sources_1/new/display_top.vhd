----------------------------------------------------------------------------------
-- Company: 
-- Engineer: 
-- 
-- Create Date: 03/12/2026 05:48:18 PM
-- Design Name: 
-- Module Name: display_top - Behavioral
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

-- Uncomment the following library declaration if using
-- arithmetic functions with Signed or Unsigned values
--use IEEE.NUMERIC_STD.ALL;

-- Uncomment the following library declaration if instantiating
-- any Xilinx leaf cells in this code.
--library UNISIM;
--use UNISIM.VComponents.all;

entity display_top is
    Port ( clk : in STD_LOGIC;
           btnu : in STD_LOGIC;
           sw : in STD_LOGIC_VECTOR (7 downto 0);
           seg : out STD_LOGIC_VECTOR (6 downto 0);
           an : out STD_LOGIC_VECTOR (7 downto 0);
           dp : out STD_LOGIC);
end display_top;

architecture Behavioral of display_top is

    component display_driver is
        port (rst   : in std_logic;
              clk   : in std_logic;
              data  : in std_logic_vector (7 downto 0);
              seg   : out std_logic_vector (6 downto 0);
              anode : out std_logic_vector (1 downto 0));
    end component display_driver;

begin

    display_0 : display_driver
    port map (
        clk => clk,
        rst => btnu,
        data => sw,
        seg => seg,
        anode => an(1 downto 0)
    );

    an(7 downto 2) <= b"11_1111";
    dp <= '1';

end Behavioral;