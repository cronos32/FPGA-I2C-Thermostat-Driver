library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_adt7420_driver is
end tb_adt7420_driver;

architecture tb of tb_adt7420_driver is

    component adt7420_driver
        port (clk      : in std_logic;
              rst      : in std_logic;
              temp_10x : out integer range -10000 to 10000;
              scl      : inout std_logic;
              sda      : inout std_logic);
    end component;

    signal clk      : std_logic;
    signal rst      : std_logic;
    signal temp_10x : integer range -10000 to 10000;
    signal scl      : std_logic;
    signal sda      : std_logic;

    constant TbPeriod : time := 10 ns; 
    signal TbClock    : std_logic := '0';
    signal TbSimEnded : std_logic := '0';

begin
    -- Pull-upy jsou kritické!
    scl <= 'H';
    sda <= 'H';

    dut : adt7420_driver
    port map (clk      => clk,
              rst      => rst,
              temp_10x => temp_10x,
              scl      => scl,
              sda      => sda);

    -- Generování hodin
    TbClock <= not TbClock after TbPeriod/2 when TbSimEnded /= '1' else '0';
    clk <= TbClock;

    -----------------------------------------------------------------------
    -- VYLEPŠENÝ I2C SLAVE MODEL
    -----------------------------------------------------------------------
    p_i2c_slave : process
    begin
        sda <= 'Z';
        
        -- 1. Čekání na START podmínku (SDA padá, když SCL je log. 1)
        wait until falling_edge(sda) and (to_x01(scl) = '1');
        
        -- 2. Přijetí adresy (8 bitů: 7 adresa + 1 R/W)
        for i in 0 to 7 loop
            wait until falling_edge(scl);
        end loop;
        
        -- 3. Odeslání ACK (9. bit)
        -- Musíme počkat, až SCL padne, pak stáhnout SDA na '0'
        wait for 100 ns; -- Malá prodleva pro stabilitu
        sda <= '0'; 
        wait until falling_edge(scl);
        sda <= 'Z';

        -- Poznámka: Tento model pošle jen jeden ACK pro první byte. 
        -- Pro kompletní simulaci by zde měl být loop pro další byty.
    end process;

    stimuli : process
    begin
        -- Reset sequence
        rst <= '1';
        wait for 100 ns;
        rst <= '0';
        
        -- POZOR: Pokud váš driver čeká 1 vteřinu reálného času,
        -- simulace se může zdát "zaseknutá". 
        -- Doporučuji v adt7420_driver.vhd dočasně snížit čítač pro WAIT_1S.
        
        wait for 1001 ms; 

        report "Simulace ukoncena.";
        TbSimEnded <= '1';
        wait;
    end process;

end tb;