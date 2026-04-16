library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_adt7420_driver is
end tb_adt7420_driver;

architecture tb of tb_adt7420_driver is

    -- Fix: Added range to match entity for strict simulators
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

    -- Fix: 100 MHz clock (10 ns period)
    constant TbPeriod : time := 10 ns; 
    signal TbClock    : std_logic := '0';
    signal TbSimEnded : std_logic := '0';

begin
    -- Pull-ups for I2C lines
    scl <= 'H';
    sda <= 'H';

    dut : adt7420_driver
    port map (clk      => clk,
              rst      => rst,
              temp_10x => temp_10x,
              scl      => scl,
              sda      => sda);

    -- Clock generation
    TbClock <= not TbClock after TbPeriod/2 when TbSimEnded /= '1' else '0';
    clk <= TbClock;

    -----------------------------------------------------------------------
    -- SIMPLE I2C SLAVE MODEL (The "Fake" ADT7420)
    -----------------------------------------------------------------------
    -- This process provides ACKs so the FSM doesn't stall.
    -- It simply pulls SDA low whenever SCL is high during an ACK slot.
    -----------------------------------------------------------------------
    i2c_responder : process
    begin
        sda <= 'Z';
        wait until falling_edge(scl);
        -- Simple logic: monitor SCL pulses. 
        -- For a real test, you'd count 8 bits then drive '0' on the 9th.
        -- Here we just keep SDA high-impedance unless we want to force a dummy ACK.
        loop
            for i in 0 to 7 loop
                wait until falling_edge(scl);
            end loop;
            -- 9th bit (ACK)
            sda <= '0'; 
            wait until falling_edge(scl);
            sda <= 'Z';
        end loop;
    end process;

    stimuli : process
    begin
        -- Reset sequence
        rst <= '1';
        wait for 100 ns;
        rst <= '0';
        
        -- Fix: Simulation timing.
        -- If DUT waits 100M cycles at 100MHz, that is exactly 1 second.
        -- We wait slightly more than 1s to see the first I2C transaction.
        wait for 1001 ms; 

        -- End simulation
        report "Simulation finished after first read cycle.";
        TbSimEnded <= '1';
        wait;
    end process;

end tb;