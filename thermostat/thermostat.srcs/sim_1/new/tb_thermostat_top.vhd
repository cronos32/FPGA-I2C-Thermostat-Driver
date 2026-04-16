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
    signal TMP_SDA : std_logic;
    signal TMP_SCL : std_logic;

    constant TbPeriod : time := 10 ns; 
    signal TbSimEnded : std_logic := '0';

begin
    -- I2C Pull-ups
    TMP_SDA <= 'H';
    TMP_SCL <= 'H';

    dut : thermostat_top
    port map (clk => clk, btnu => btnu, btnd => btnd, btnc => btnc,
              seg => seg, dp => dp, an => an,
              led16_r => led16_r, led16_g => led16_g, led16_b => led16_b,
              TMP_SDA => TMP_SDA, TMP_SCL => TMP_SCL);

    clk <= not clk after TbPeriod/2 when TbSimEnded /= '1' else '0';

    -----------------------------------------------------------
    -- PERSISTENT SENSOR MODEL (ADT7420)
    -----------------------------------------------------------
    p_sensor_model : process
    begin
        -- Start detection (SDA falls while SCL is high)
        wait until falling_edge(TMP_SDA) and (TMP_SCL = 'H' or TMP_SCL = '1');
        
        -- Address Phase (8 bits: 7 addr + 1 R/W)
        for i in 1 to 8 loop
            wait until falling_edge(TMP_SCL);
        end loop;
        
        -- 9th bit: Drive ACK
        wait for 1 us; -- Safety margin
        TMP_SDA <= '0'; 
        wait until falling_edge(TMP_SCL);
        TMP_SDA <= 'Z';

        -- Data Phase (Repeat for as many bytes as the master wants)
        -- This loop handles the multi-byte read/write pattern of the ADT driver
        loop
            for i in 1 to 8 loop
                wait until falling_edge(TMP_SCL);
            end loop;
            
            -- ACK Slot
            wait for 1 us;
            TMP_SDA <= '0'; 
            wait until falling_edge(TMP_SCL);
            TMP_SDA <= 'Z';
            
            -- Exit data phase if a STOP or REPEATED START is detected
            -- (Simplified: in this TB we just look for a long SCL high period)
            exit when TMP_SCL'last_event > 1 ms; 
        end loop;
    end process;

    stimuli : process
    begin
        -- 1. Robust Reset (1 us)
        btnc <= '1';
        wait for 1 us;
        btnc <= '0';
        wait for 100 ns;

        -- 2. UI Interaction
        -- Increment target temperature
        btnu <= '1';
        wait for 30 ms; 
        btnu <= '0';
        wait for 10 ms;

        -- 3. The Long Wait
        -- IMPORTANT: If your driver has a "WAIT_1S" state, the simulation
        -- will need to run for >1000 ms to see the first LED update.
        -- Tip: Change the 1-second constant in your driver to 1ms for simulation!
        report "Waiting for sensor acquisition cycle...";
        wait for 1100 ms; 

        report "Simulation finished.";
        TbSimEnded <= '1';
        wait;
    end process;

end tb;