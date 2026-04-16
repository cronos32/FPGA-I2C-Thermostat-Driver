library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity adt7420_driver is
    port (
        clk, rst : in    std_logic;
        temp_10x : out   integer range -10000 to 10000;
        scl, sda : inout std_logic
    );
end entity;

architecture rtl of adt7420_driver is

    type state_t is (WAIT_1S,
                     SET_REG,   WAIT_SET,
                     READ_MSB,  WAIT_MSB,
                     READ_LSB,  WAIT_LSB,
                     CALC);
    signal state : state_t := WAIT_1S;
    signal timer : integer range 0 to 100_000_001 := 0;

    signal m_start, m_stop, m_busy, m_rw : std_logic := '0';
    signal m_din, m_dout                 : std_logic_vector(7 downto 0) := (others => '0');
    signal m_nack                        : std_logic;  -- connect nack port

    signal cap_msb, cap_lsb : std_logic_vector(7 downto 0) := (others => '0');

    signal raw_13bit : signed(12 downto 0);
    signal product_26   : signed(25 downto 0);

begin

    I2C_INST: entity work.i2c_master
        port map (
            clk          => clk,
            rst          => rst,
            addr         => "1001000",   -- ADT7420 default address
            rw           => m_rw,
            data_in      => m_din,
            data_out     => m_dout,
            start        => m_start,
            stop_on_done => m_stop,
            busy         => m_busy,
            nack         => m_nack,
            scl          => scl,
            sda          => sda
        );

    process(clk)
    begin
    -- Ostatní product_26 atd. už nebudete potřebovat

        if rising_edge(clk) then
            m_start <= '0';  -- default: no pulse

            if rst = '1' then
                state   <= WAIT_1S;
                timer   <= 0;
                cap_msb <= (others => '0');
                cap_lsb <= (others => '0');

            else
                case state is

                    when WAIT_1S =>
                        if timer = 100_000_000 then
                            timer <= 0; state <= SET_REG;
                        else
                            timer <= timer + 1;
                        end if;

                    -- Write register pointer (0x00 = temperature register)
                    when SET_REG =>
                        m_rw   <= '0';
                        m_din  <= x"00";
                        m_stop <= '0';    -- no STOP: keep bus for repeated START
                        m_start <= '1';
                        state   <= WAIT_SET;

                    when WAIT_SET =>
                        -- Standard Handshake. Wait for Master to start, then wait for it to finish.
                        if m_busy = '1' then 
                            m_start <= '0'; -- Clear start pulse immediately
                        elsif m_busy = '0' and m_start = '0' then
                            state <= READ_MSB; 
                        end if;

                    -- Start reading MSB (first of two bytes)
                    when READ_MSB =>
                        m_rw    <= '1';
                        m_stop  <= '0'; -- ACK
                        m_start <= '1';
                        state   <= WAIT_MSB;

                    -- Handshake to ensure data is ready
                    when WAIT_MSB =>
                        if m_busy = '1' then 
                            m_start <= '0'; 
                        elsif m_busy = '0' and m_start = '0' then
                            cap_msb <= m_dout; -- Capture happens exactly when transaction ends
                            state <= READ_LSB;
                        end if;

                    -- First read completes → capture MSB, start LSB read
                    when READ_LSB =>
                        m_rw    <= '1';
                        m_stop  <= '1'; -- NACK: last byte
                        m_start <= '1';
                        state   <= WAIT_LSB;

                    when WAIT_LSB =>
                        if m_busy = '1' then 
                            m_start <= '0';
                        elsif m_busy = '0' and m_start = '0' then
                            cap_lsb <= m_dout;
                            state <= CALC;
                        end if;

                    -- Second read completes → capture LSB

                -- ... v procesu ...
                    when CALC =>
                        -- Použijeme trik s 5/8. 
                        -- Násobení 5 je bleskové a dělení 8 je jen shift.
                        -- Hodnota se uloží do registru temp_10x při dalším taktu.
                        temp_10x <= to_integer(raw_13bit * 5) / 8; 
                        state <= WAIT_1S;
                        
                    when others => state <= WAIT_1S;
                end case;
            end if;
        end if;
    end process;

end architecture;
