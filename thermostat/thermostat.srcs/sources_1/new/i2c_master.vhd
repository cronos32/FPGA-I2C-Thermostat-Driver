library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- I2C Master — single byte per transaction (addr + 1 data byte)
-- CLK_DIV = half-period in system clock cycles
-- At CLK_DIV=250, 50 MHz: SCL = 50e6 / (4 * 125) = 100 kHz
--
-- Each I2C bit uses 4 quarter-period ticks:
--   phase 0,1 : SCL low  (SDA set up here)
--   phase 2,3 : SCL high (SDA sampled at phase 2 for reads)
-- State advances at the phase 3→0 boundary (end of each bit).
--
-- Transaction sequence:
--   IDLE → STRT → ADDR(8 bits) → ADDR_ACK → DATA(8 bits) → DATA_ACK → [STP | IDLE]

entity i2c_master is
    generic ( CLK_DIV : integer := 250 );
    port (
        clk, rst     : in    std_logic;
        addr         : in    std_logic_vector(6 downto 0);
        rw           : in    std_logic;
        data_in      : in    std_logic_vector(7 downto 0);
        data_out     : out   std_logic_vector(7 downto 0);
        start        : in    std_logic;
        stop_on_done : in    std_logic;
        busy, nack   : out   std_logic;
        scl, sda     : inout std_logic
    );
end entity;

architecture rtl of i2c_master is

    -- Quarter-period: CLK_DIV/2 system cycles per phase tick
    constant Q : integer := CLK_DIV / 2;

    type state_t is (IDLE, STRT, ADDR, ADDR_ACK, DATA, DATA_ACK, STP);
    signal state : state_t := IDLE;

    signal q_cnt    : integer range 0 to Q-1 := 0;
    signal tick     : std_logic := '0';
    signal phase    : integer range 0 to 3 := 0;

    signal scl_oe   : std_logic := '0';  -- '1' = pull SCL low
    signal sda_oe   : std_logic := '0';  -- '1' = pull SDA low
    signal sda_in   : std_logic;         -- read-back from SDA pin

    signal busy_i   : std_logic := '0';
    signal nack_i   : std_logic := '0';
    signal rw_lat   : std_logic := '0';
    signal sod_lat  : std_logic := '0';
    signal din_lat  : std_logic_vector(7 downto 0) := (others => '0');

    signal shift_tx : std_logic_vector(7 downto 0) := (others => '0');
    signal shift_rx : std_logic_vector(7 downto 0) := (others => '0');
    signal bit_idx  : integer range 0 to 7 := 7;

    signal start_pending : std_logic := '0'; -- NEW: Latch for start pulse
begin

    -- Open-drain outputs (external pullup brings to '1' when released)
    scl    <= '0' when scl_oe = '1' else 'Z';
    sda    <= '0' when sda_oe = '1' else 'Z';
    sda_in <= sda;   -- synthesis: IOBUF read-back; simulation: resolves correctly

    busy <= busy_i;
    nack <= nack_i;

    -- Quarter-period tick generator
    process(clk)
    begin
        if rising_edge(clk) then
            tick <= '0';
            if rst = '1' then
                q_cnt <= 0;
            elsif q_cnt = Q-1 then
                q_cnt <= 0;
                tick  <= '1';
            else
                q_cnt <= q_cnt + 1;
            end if;
        end if;
    end process;

    -- Main FSM — advances one step per tick
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                state  <= IDLE; phase <= 0;
                scl_oe <= '0';  sda_oe <= '0';
                busy_i <= '0';  nack_i <= '0';
                start_pending <= '0';

            else
                -- Latch the start signal in case the tick hasn't happened yet
                if start = '1' then
                    start_pending <= '1';
                end if;

                if tick = '1' then

                    -- Default: advance phase; state machine overrides at phase=3
                    if phase = 3 then phase <= 0; else phase <= phase + 1; end if;

                    case state is

                        -- --------------------------------------------------------
                        when IDLE =>
                            scl_oe <= '0'; sda_oe <= '0';
                            busy_i <= '0'; nack_i <= '0';
                            phase  <= 0;   -- hold in phase 0 while idle
                            if start_pending = '1' then
                                shift_tx <= addr & rw;
                                rw_lat   <= rw;
                                din_lat  <= data_in;
                                sod_lat  <= stop_on_done;
                                busy_i   <= '1';
                                start_pending <= '0'; -- Reset the latch
                                state    <= STRT;
                            end if;

                        -- --------------------------------------------------------
                        -- START: SDA falls while SCL is high
                        when STRT =>
                            case phase is
                                when 0 => scl_oe <= '0'; sda_oe <= '0';  -- both high
                                when 1 => scl_oe <= '0'; sda_oe <= '1';  -- SDA falls = START
                                when 2 => scl_oe <= '1'; sda_oe <= '1';  -- SCL falls
                                when 3 =>
                                    bit_idx <= 7;
                                    state   <= ADDR;
                                when others => null;
                            end case;

                        -- --------------------------------------------------------
                        -- ADDR: send 8 bits (7-bit address + R/W)
                        when ADDR =>
                            case phase is
                                when 0 =>
                                    scl_oe <= '1';  -- SCL low: set SDA
                                    if shift_tx(bit_idx) = '0' then sda_oe <= '1';
                                    else sda_oe <= '0'; end if;
                                when 1 => scl_oe <= '1';   -- hold
                                when 2 => scl_oe <= '0';   -- SCL rises
                                when 3 =>
                                    scl_oe <= '0';
                                    if bit_idx = 0 then
                                        state <= ADDR_ACK;
                                    else
                                        bit_idx <= bit_idx - 1;
                                    end if;
                                when others => null;
                            end case;

                        -- --------------------------------------------------------
                        -- ADDR_ACK: release SDA, sample device ACK
                        when ADDR_ACK =>
                            case phase is
                                when 0 => scl_oe <= '1'; sda_oe <= '0';  -- release SDA
                                when 1 => scl_oe <= '1';
                                when 2 =>
                                    scl_oe <= '0';         -- SCL rises
                                    nack_i <= sda_in;      -- sample: '0'=ACK, '1'=NACK
                                when 3 =>
                                    scl_oe <= '0';
                                    bit_idx <= 7;
                                    if rw_lat = '0' then
                                        shift_tx <= din_lat;   -- load data byte for write
                                    end if;
                                    state <= DATA;
                                when others => null;
                            end case;

                        -- --------------------------------------------------------
                        -- DATA: send (write) or receive (read) 8 data bits
                        when DATA =>
                            case phase is
                                when 0 =>
                                    scl_oe <= '1';             -- SCL low: drive/release SDA
                                    if rw_lat = '0' then       -- write: output bit
                                        if shift_tx(bit_idx) = '0' then sda_oe <= '1';
                                        else sda_oe <= '0'; end if;
                                    else                       -- read: release SDA
                                        sda_oe <= '0';
                                    end if;
                                when 1 => scl_oe <= '1';      -- hold
                                when 2 =>
                                    scl_oe <= '0';             -- SCL rises
                                    if rw_lat = '1' then
                                        shift_rx(bit_idx) <= sda_in;
                                    end if;
                                when 3 =>
                                    scl_oe <= '0';
                                    if bit_idx = 0 then
                                        if rw_lat = '1' then
                                            data_out <= shift_rx;
                                        end if;
                                        state <= DATA_ACK;
                                    else
                                        bit_idx <= bit_idx - 1;
                                    end if;
                                when others => null;
                            end case;

                        -- --------------------------------------------------------
                        -- DATA_ACK: write→receive device ACK; read→send master ACK/NACK
                        when DATA_ACK =>
                            case phase is
                                when 0 =>
                                    scl_oe <= '1';
                                    if rw_lat = '0' then
                                        sda_oe <= '0';          -- write: release, device ACKs
                                    else
                                        -- read: ACK='0'(sda_oe=1), NACK='1'(sda_oe=0)
                                        if sod_lat = '1' then sda_oe <= '0';
                                        else sda_oe <= '1'; end if;
                                    end if;
                                when 1 => scl_oe <= '1';
                                when 2 =>
                                    scl_oe <= '0';              -- SCL rises
                                    if rw_lat = '0' then nack_i <= sda_in; end if;
                                when 3 =>
                                    scl_oe <= '0';
                                    if sod_lat = '1' then
                                        state <= STP;
                                    else
                                        state  <= IDLE;
                                        busy_i <= '0';
                                    end if;
                                when others => null;
                            end case;

                        -- --------------------------------------------------------
                        -- STOP: SCL rises, then SDA rises
                        when STP =>
                            case phase is
                                when 0 => scl_oe <= '1'; sda_oe <= '1';  -- SCL & SDA low
                                when 1 => scl_oe <= '0'; sda_oe <= '1';  -- SCL rises
                                when 2 => scl_oe <= '0'; sda_oe <= '0';  -- SDA rises = STOP
                                when 3 =>
                                    scl_oe <= '0'; sda_oe <= '0';
                                    state  <= IDLE; busy_i <= '0';
                                when others => null;
                            end case;
                        when others => state <= IDLE;
                    end case;
                end if;
            end if;
        end if;
    end process;
end architecture;
