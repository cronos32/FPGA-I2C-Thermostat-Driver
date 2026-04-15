library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all; -- TATO KNIHOVNA JE NUTNÁ PRO TYP UNSIGNED!

entity tb_display_data_combiner is
end tb_display_data_combiner;

architecture tb of tb_display_data_combiner is

    component display_data_combiner
        port (set_temp     : in unsigned (11 downto 0);
              current_temp : in unsigned (11 downto 0);
              data_out     : out std_logic_vector (31 downto 0));
    end component;

    signal set_temp     : unsigned (11 downto 0);
    signal current_temp : unsigned (11 downto 0);
    signal sw_unit      : std_logic;
    signal data_out     : std_logic_vector (31 downto 0);

begin

    dut : display_data_combiner
    port map (set_temp     => set_temp,
              current_temp => current_temp,
              data_out     => data_out);

    stimuli : process
    begin
        -- Test 1: Pokojová teplota a nastavená teplota v Celsiích
        -- to_unsigned(hodnota, počet_bitů)
        set_temp     <= to_unsigned(210, 12); -- "21.0"
        current_temp <= to_unsigned(245, 12); -- "24.5"
        wait for 100 ns;


        -- Test 2: Horní limit (tvůj kód má 'clamp' na 999)
        set_temp     <= to_unsigned(1500, 12); -- Mělo by se zobrazit jako 999
        current_temp <= to_unsigned(10, 12);   -- Mělo by být 010
        wait for 100 ns;

        -- Konec simulace (zastaví se)
        wait;
    end process;

end tb;