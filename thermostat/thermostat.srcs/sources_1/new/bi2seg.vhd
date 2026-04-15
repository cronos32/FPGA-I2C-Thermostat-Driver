
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

-- Uncomment the following library declaration if using
-- arithmetic functions with Signed or Unsigned values
--use IEEE.NUMERIC_STD.ALL;

-- Uncomment the following library declaration if instantiating
-- any Xilinx leaf cells in this code.
--library UNISIM;
--use UNISIM.VComponents.all;

entity bin2seg is
    Port ( bin : in std_logic_vector(3 downto 0);
           seg : out std_logic_vector(6 downto 0));
end bin2seg;

architecture Behavioral of bin2seg is
begin


p_7seg_decoder : process (bin) is
begin
    case bin is
        when x"0" =>
            seg <= "0000001";
        when x"1" =>
            seg <= "1001111";
          
        when x"2" =>
            seg <= "0010010";
            
        when x"3" =>
            seg <= "0000110";

        when x"4" =>
            seg <= "1001100";
            
        when x"5" =>
            seg <= "0100100";
            
        when x"6" =>
            seg <= "0100000";  
             
        when x"7" =>
            seg <= "0001111";
            
        when x"8" =>
            seg <= "0000000";
            
        when x"9" =>
            seg <= "0000100";
            
        when x"A" =>
            seg <= "0001000";
            
        when x"b" =>
            seg <= "1100000";  
             
        when x"C" =>
            seg <= "0110001";
            
        when x"d" =>
            seg <= "1000010";
            
        when x"E" =>
            seg <= "0110000";

        -- Default case (e.g., for undefined values)
        when others =>
            seg <= "0111000";
    end case;
end process p_7seg_decoder;


end Behavioral;
