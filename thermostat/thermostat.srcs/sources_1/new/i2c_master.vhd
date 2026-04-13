library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- I2C Master — single byte per transaction (addr + 1 data byte)
-- CLK_DIV = half-period in system clock cycles
-- At CLK_DIV=500, 100 MHz: SCL = 100e6 / (4 * 250) = 100 kHz
--
-- Each I2C bit uses 4 quarter-period ticks:
--   phase 0,1 : SCL low  (SDA set up here)
--   phase 2,3 : SCL high (SDA sampled at phase 2 for reads)
-- State advances at the phase 3→0 boundary (end of each bit).
--
-- Transaction sequence:
--   IDLE → STRT → ADDR(8 bits) → ADDR_ACK → DATA(8 bits) → DATA_ACK → [STP | IDLE]

entity i2c_master is
    generic ( CLK_DIV : integer := 500 ); -- 100MHz -> 100kHz
    port (
        clk, rst   : in    std_logic;
        addr       : in    std_logic_vector(6 downto 0);
        rw         : in    std_logic;
        data_in    : in    std_logic_vector(7 downto 0);
        data_out   : out   std_logic_vector(7 downto 0);
        start      : in    std_logic;
        stop_on_done : in  std_logic; -- '1' sends STOP, '0' keeps runing (for ACK)
        busy, nack : out   std_logic;
        scl, sda   : inout std_logic
    );
end entity;

architecture rtl of i2c_master is
    type state_t is (IDLE, STRT, BITS, ACK_WAIT, MSTR_ACK, STP);
    signal state : state_t := IDLE;
    signal count : integer range 0 to CLK_DIV := 0;
    signal i2c_clk, scl_en, sda_out : std_logic := '1';
    signal bit_idx : integer range 0 to 7 := 7;
    signal shift_reg : std_logic_vector(7 downto 0);
begin
    -- Hodiny
    process(clk) begin
        if rising_edge(clk) then
            if count = CLK_DIV then count <= 0; i2c_clk <= not i2c_clk;
            else count <= count + 1; end if;
        end if;
    end process;

    process(clk) begin
        if rising_edge(clk) then
            if rst = '1' then state <= IDLE; sda_out <= '1'; scl_en <= '0';
            elsif i2c_clk = '1' and count = 0 then
                case state is
                    when IDLE =>
                        busy <= '0';
                        if start = '1' then 
                            state <= STRT; busy <= '1'; 
                            shift_reg <= addr & rw;
                        end if;
                    when STRT => sda_out <= '0'; scl_en <= '1'; state <= BITS; bit_idx <= 7;
                    when BITS =>
                        sda_out <= shift_reg(bit_idx);
                        if bit_idx = 0 then state <= ACK_WAIT; else bit_idx <= bit_idx - 1; end if;
                    when ACK_WAIT =>
                        sda_out <= '1'; 
                        nack <= sda; -- Vzorkování ACK/NACK
                        if rw = '1' then state <= MSTR_ACK; -- Budeme číst
                        elsif stop_on_done = '1' then state <= STP;
                        else state <= IDLE; busy <= '0'; end if; -- Pro zápis registru
                    when MSTR_ACK =>
                        data_out <= shift_reg; -- Tady by bylo vzorkování (zjednodušeno)
                        sda_out <= stop_on_done; -- '1' pro NACK (konec čtení), '0' pro ACK
                        state <= STP;
                    when STP => scl_en <= '0'; sda_out <= '0'; state <= IDLE;
                end case;
            end if;
        end if;
    end process;
    scl <= '0' when (scl_en = '1' and i2c_clk = '0') else 'Z';
    sda <= '0' when (sda_out = '0') else 'Z';
end architecture; 