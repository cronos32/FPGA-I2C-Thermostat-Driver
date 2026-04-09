library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

--output format
--[31:28] set stovky
--[27:24] set desítky
--[23:20] set jednotky
--[19:16] set jednotka (C/F)
--
--[15:12] cur stovky
--[11:8]  cur desítky
--[7:4]   cur jednotky
--[3:0]   cur jednotka (C/F)

entity display_data_combiner is
    port (
        set_temp     : in  unsigned(11 downto 0); -- for example 232
        current_temp : in  unsigned(11 downto 0); -- for example 244
        sw_unit      : in  std_logic;             -- 0 = C, 1 = F

        data_out     : out std_logic_vector(31 downto 0)
    );
end display_data_combiner;

architecture Behavioral of display_data_combiner is

    function to_bcd4(val : unsigned(11 downto 0); unit : std_logic)
        return std_logic_vector is

        variable temp : integer := to_integer(val);
        variable hundreds : integer;
        variable tens     : integer;
        variable ones     : integer;
        variable result   : std_logic_vector(15 downto 0);

    begin
        hundreds := temp / 100;
        tens     := (temp / 10) mod 10;
        ones     := temp mod 10;

        result(15 downto 12) := std_logic_vector(to_unsigned(hundreds,4));
        result(11 downto 8)  := std_logic_vector(to_unsigned(tens,4));
        result(7 downto 4)   := std_logic_vector(to_unsigned(ones,4));

        -- unit setting
        if unit = '0' then
            result(3 downto 0) := "1100"; -- C
        else
            result(3 downto 0) := "1111"; -- F
        end if;

        return result;
    end function;

    signal set_bcd  : std_logic_vector(15 downto 0);
    signal curr_bcd : std_logic_vector(15 downto 0);

begin

    process(set_temp, current_temp, sw_unit)
    begin
        set_bcd  <= to_bcd4(set_temp, sw_unit);
        curr_bcd <= to_bcd4(current_temp, sw_unit);

        data_out <= set_bcd & curr_bcd;
    end process;

end Behavioral;