library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_thermostat_top is
end tb_thermostat_top;

architecture tb of tb_thermostat_top is

    component thermostat_top
        port (clk     : in std_logic;
              btnu    : in std_logic;
              btnd    : in std_logic;
              btnc    : in std_logic;
              seg     : out std_logic_vector (6 downto 0);
              dp      : out std_logic;
              an      : out std_logic_vector (7 downto 0);
              led16_r : out std_logic;
              led16_g : out std_logic;
              led16_b : out std_logic;
              TMP_SDA : inout std_logic;
              TMP_SCL : inout std_logic);
    end component;

    signal clk     : std_logic := '0';
    signal btnu    : std_logic := '0';
    signal btnd    : std_logic := '0';
    signal btnc    : std_logic := '0';
    signal seg     : std_logic_vector (6 downto 0);
    signal dp      : std_logic;
    signal an      : std_logic_vector (7 downto 0);
    signal led16_r : std_logic;
    signal led16_g : std_logic;
    signal led16_b : std_logic;
    signal TMP_SDA : std_logic := 'Z';
    signal TMP_SCL : std_logic := 'Z';

    constant TbPeriod : time := 10 ns; -- 100 MHz
    signal TbSimEnded : std_logic := '0';

begin
    -- I2C Pull-upy
    TMP_SDA <= 'H';
    TMP_SCL <= 'H';

    dut : thermostat_top
    port map (clk     => clk,
              btnu    => btnu,
              btnd    => btnd,
              btnc    => btnc,
              seg     => seg,
              dp      => dp,
              an      => an,
              led16_r => led16_r,
              led16_g => led16_g,
              led16_b => led16_b,
              TMP_SDA => TMP_SDA,
              TMP_SCL => TMP_SCL);

    -- Clock generation
    clk <= not clk after TbPeriod/2 when TbSimEnded /= '1' else '0';

    -----------------------------------------------------------
    -- Simulace I2C senzoru (odpovídá Masterovi)
    -----------------------------------------------------------
    p_sensor_model : process
    begin
        wait until falling_edge(TMP_SDA) and TMP_SCL /= '0'; -- START
        for i in 1 to 9 loop wait until falling_edge(TMP_SCL); end loop;
        TMP_SDA <= '0'; wait until rising_edge(TMP_SCL); wait until falling_edge(TMP_SCL); TMP_SDA <= 'Z'; -- ACK
        
        -- Master bude chtít číst data, senzor by měl něco poslat (např. 0x09 0x60 = 24.0°C)
        -- Pro zjednodušení v TB jen posíláme ACK, Master si přečte '1' (vysoká impedance)
        for i in 1 to 9 loop wait until falling_edge(TMP_SCL); end loop;
        TMP_SDA <= '0'; wait until rising_edge(TMP_SCL); wait until falling_edge(TMP_SCL); TMP_SDA <= 'Z'; -- ACK
    end process;

    stimuli : process
    begin
        -- 1. Reset (středové tlačítko BTNC)
        btnc <= '1';
        wait for 100 ns;
        btnc <= '0';
        wait for 1 us;

        -- 2. Simulace stisku BTNU (Zvýšení nastavené teploty)
        -- Protože v UI FSM máš pravděpodobně debouncer, musíme držet tlačítko déle
        btnu <= '1';
        wait for 20 ms; 
        btnu <= '0';
        wait for 20 ms;

        -- 3. Simulace stisku BTND (Snížení nastavené teploty)
        btnd <= '1';
        wait for 20 ms;
        btnd <= '0';
        wait for 20 ms;

        -- Počkáme na výsledek regulace a zobrazení
        wait for 100 ms;

        TbSimEnded <= '1';
        wait;
    end process;

end tb;