----------------------------------------------------------------------------------
-- Company: 
-- Engineer: 
-- 
-- Create Date: 03/05/2026 05:12:21 PM
-- Design Name: 
-- Module Name: clk_en - Behavioral
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

use IEEE.NUMERIC_STD.ALL;

-- Uncomment the following library declaration if instantiating
-- any Xilinx leaf cells in this code.
--library UNISIM;
--use UNISIM.VComponents.all;

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
