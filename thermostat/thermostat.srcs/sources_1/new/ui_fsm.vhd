library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity TermostatLowLevel is
    Port (
        clk      : in  STD_LOGIC;      -- Hlavní hodiny
        ce       : in  STD_LOGIC;      -- Clock Enable 
        reset    : in  STD_LOGIC;
        btn_up   : in  STD_LOGIC;      -- Signál z debounceru
        btn_down : in  STD_LOGIC;
        teplota_out : out STD_LOG_VECTOR(11 downto 0)
    );
end TermostatLowLevel;

architecture Behavioral of TermostatLowLevel is
    -- Stavové registry
    signal up_latched   : std_logic := '0';
    signal down_latched : std_logic := '0';
    
    signal temp_reg : integer range 0 to 4095 := 220;
begin

    -- 1. ČÁST: Záchyt signálu (Set/Reset logika)
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                up_latched <= '0';
                down_latched <= '0';
            else
                -- Pokud přijde signál z debounceru, "nahodíme" latch
                if btn_up = '1' then
                    up_latched <= '1';
                end if;
                
                if btn_down = '1' then
                    down_latched <= '1';
                end if;

                -- Pokud proběhl výpočet v pomalém cyklu (ce='1'), latch shodíme
                if ce = '1' then
                    up_latched <= '0';
                    down_latched <= '0';
                end if;
            end if;
        end if;
    end process;

    -- 2. ČÁST: Výpočetní logika 
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                temp_reg <= 220;
            elsif ce = '1' then
                
                if up_latched = '1' then
                    if temp_reg <= 395 then
                        temp_reg <= temp_reg + 5;
                    end if;
                elsif down_latched = '1' then
                    if temp_reg >= 55 then
                        temp_reg <= temp_reg - 5;
                    end if;
                end if;
                
            end if;
        end if;
    end process;

    teplota_out <= std_logic_vector(to_unsigned(temp_reg, 12));

end Behavioral;