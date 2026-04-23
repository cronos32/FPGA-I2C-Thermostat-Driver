-- display_data_combiner: Combinational BCD converter for dual-temperature display.
-- Converts two 12-bit unsigned temperatures (in tenths of deg C) into a
-- 32-bit word for the display_driver. Each value is split into hundreds,
-- tens, and ones BCD digits (4 bits each); the lowest nibble of each group
-- is fixed to 0xC to show the letter 'C' on the 7-segment display.
-- Values above 999 are clamped.
--
-- Output format (32 bits, active-low 7-seg encoding via bin2seg):
--   [31:28] set hundreds   [27:24] set tens   [23:20] set ones   [19:16] set unit (C/F)
--   [15:12] cur hundreds   [11:8]  cur tens   [7:4]   cur ones   [3:0]   cur unit (C/F)


library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity display_data_combiner is
    port (
        set_temp     : in  unsigned(11 downto 0); -- for example 232
        current_temp : in  unsigned(11 downto 0); -- for example 244
        data_out     : out std_logic_vector(31 downto 0)
    );
end display_data_combiner;

architecture Behavioral of display_data_combiner is

    function to_bcd4(val : unsigned(11 downto 0))
        return std_logic_vector is
        variable v        : integer;
        variable hundreds : integer;
        variable tens     : integer;
        variable ones     : integer;
        variable result   : std_logic_vector(15 downto 0);
    begin
        v := to_integer(val);

        -- clamp to 999 so hundreds always fits in 4 bits.
        --  Without this, values > 999 give hundreds > 9 and to_unsigned(x,4) wraps.
        if v > 999 then v := 999; end if;

        hundreds := v / 100;
        tens     := (v / 10) mod 10;
        ones     := v mod 10;

        result(15 downto 12) := std_logic_vector(to_unsigned(hundreds, 4));
        result(11 downto 8)  := std_logic_vector(to_unsigned(tens,     4));
        result(7  downto 4)  := std_logic_vector(to_unsigned(ones,     4));
        result(3 downto 0) := x"C";  -- 'C' in bin2seg

        return result;
    end function;

begin

    data_out <= to_bcd4(set_temp) & to_bcd4(current_temp);

end Behavioral;