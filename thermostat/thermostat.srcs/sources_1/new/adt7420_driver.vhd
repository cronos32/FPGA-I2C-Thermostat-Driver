library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity adt7420_driver is
    port (
        clk, rst   : in std_logic;
        temp_10x   : out integer; -- 225 for 22.5°C
        scl, sda   : inout std_logic
    );
end entity;

architecture rtl of adt7420_driver is
    type state_t is (WAIT_1S, SET_REG, READ_MSB, READ_LSB, CALC);
    signal state : state_t := WAIT_1S;
    signal timer : integer := 0;
    
    -- I2C signály
    signal m_start, m_stop, m_busy, m_rw : std_logic;
    signal m_din, m_dout : std_logic_vector(7 downto 0);
    signal reg_msb, reg_lsb : std_logic_vector(7 downto 0);
begin

    I2C_INST: entity work.i2c_master
        port map (clk=>clk, rst=>rst, addr=>"1001000", rw=>m_rw, data_in=>m_din, 
                  data_out=>m_dout, start=>m_start, stop_on_done=>m_stop, 
                  busy=>m_busy, scl=>scl, sda=>sda);

    process(clk)
        variable raw_13bit : signed(12 downto 0);
    begin
        if rising_edge(clk) then
            m_start <= '0';
            case state is
                when WAIT_1S =>
                    if timer = 50_000_000 then -- 1 sekunda při 50MHz
                        timer <= 0; state <= SET_REG;
                    else timer <= timer + 1; end if;

                when SET_REG => -- Řekneme "chci registr 0x00"
                    m_rw <= '0'; m_din <= x"00"; m_stop <= '1'; m_start <= '1';
                    if m_busy = '1' then state <= READ_MSB; end if;

                when READ_MSB =>
                    if m_busy = '0' then
                        m_rw <= '1'; m_stop <= '0'; m_start <= '1'; -- Čteme, chceme další (ACK)
                        state <= READ_LSB;
                    end if;

                when READ_LSB =>
                    if m_busy = '1' then reg_msb <= m_dout; end if;
                    if m_busy = '0' then
                        m_rw <= '1'; m_stop <= '1'; m_start <= '1'; -- Čteme poslední (NACK)
                        state <= CALC;
                    end if;

                when CALC =>
                    if m_busy = '1' then reg_lsb <= m_dout; end if;
                    if m_busy = '0' then
                        -- Výpočet: (Raw * 625) / 1000
                        raw_13bit := signed(reg_msb & reg_lsb(7 downto 3));
                        temp_10x <= to_integer(raw_13bit * 625) / 1000;
                        state <= WAIT_1S;
                    end if;
            end case;
        end if;
    end process;
end architecture;