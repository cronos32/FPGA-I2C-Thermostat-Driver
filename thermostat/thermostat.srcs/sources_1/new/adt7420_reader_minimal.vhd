-- ADT7420 Reader -- MINIMAL, single-FSM design.
--
-- Inspired by David J. Marion's Verilog I2C master for the Nexys A7 temp
-- sensor: one self-contained module, no separate i2c_controller, no
-- restart/trigger handshakes between modules. Each I2C bit is driven by
-- the same state machine that decides what to send/receive.
--
-- Read transaction (uses ADT7420 power-on defaults: pointer=0x00,
-- continuous 13-bit conversion):
--
--   START -> addr+R -> ACK -> MSB -> ACK -> LSB -> NAK -> STOP
--
-- Bit-period structure (one full SCL cycle = 4 quarters of QUARTER ticks):
--   Q0: SCL=0, master sets/releases SDA
--   Q1: SCL=0, SDA setup time
--   Q2: SCL=1 (rising edge here), slave samples / master ready to read
--   Q3: SCL=1, SDA hold time -- master samples mid-Q3 for safety
--
-- Output 'sda_dir' is exposed for debug: route to an LED to verify the
-- master correctly hands SDA over to the slave during ACK and data-read
-- phases (Marion's debug trick).

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity adt7420_reader_minimal is
    generic (
        CLOCK_FREQ_HZ    : integer := 100_000_000;  -- main clock
        SCL_FREQ_HZ      : integer := 100_000;      -- target SCL frequency
        READ_INTERVAL_MS : integer := 1000          -- between reads
    );
    port (
        clock          : in    STD_LOGIC;
        reset          : in    STD_LOGIC;

        sensor_address : in    STD_LOGIC_VECTOR (6 downto 0);  -- 0x4B for Nexys A7

        temperature    : out   STD_LOGIC_VECTOR (15 downto 0); -- signed tenths of C
        temp_valid     : out   STD_LOGIC;                      -- 1-cycle pulse
        sda_dir        : out   STD_LOGIC;                      -- '1'=master, '0'=slave (debug)

        scl            : inout STD_LOGIC;
        sda            : inout STD_LOGIC
    );
end entity;

architecture behavioral of adt7420_reader_minimal is

    ------------------------------------------------------------------
    -- Timing constants
    ------------------------------------------------------------------
    -- Ticks per quarter of an SCL period.
    -- @100 MHz / 100 kHz / 4 = 250 ticks per quarter, 1000 per bit period.
    constant QUARTER         : integer := CLOCK_FREQ_HZ / SCL_FREQ_HZ / 4;
    constant BIT_PERIOD      : integer := 4 * QUARTER;

    -- Power-on delay: ADT7420 needs ~1 ms POR + ~240 ms for first
    -- conversion in 13-bit mode. 250 ms covers both.
    constant POR_TICKS       : integer := (CLOCK_FREQ_HZ / 1000) * 250;

    constant INTERVAL_TICKS  : integer := (CLOCK_FREQ_HZ / 1000) * READ_INTERVAL_MS;

    ------------------------------------------------------------------
    -- State machine
    ------------------------------------------------------------------
    type T_STATE is (
        S_POR,        -- power-on / first-conversion wait
        S_IDLE,       -- between reads (interval timer)
        S_START,      -- generate START condition
        S_ADDR,       -- send 8 bits of {addr,R}
        S_ADDR_ACK,   -- read slave's ACK
        S_MSB,        -- read 8 MSB bits
        S_MSB_ACK,    -- master ACKs
        S_LSB,        -- read 8 LSB bits
        S_LSB_NAK,    -- master NAKs (last byte)
        S_STOP,       -- generate STOP condition
        S_DONE        -- latch result, pulse temp_valid, return to IDLE
    );
    signal state : T_STATE := S_POR;

    -- Per-bit-period tick counter, 0 .. BIT_PERIOD-1
    signal tick    : unsigned (15 downto 0) := (others => '0');
    -- Bit index (7 down to 0) when iterating 8 bits in a state
    signal bit_idx : unsigned (3 downto 0)  := (others => '0');

    -- POR / interval timers
    signal por_count      : unsigned (31 downto 0) := (others => '0');
    signal interval_count : unsigned (31 downto 0) := (others => '0');

    ------------------------------------------------------------------
    -- Bus drivers (open-drain: '0' = pull low, '1' = release)
    ------------------------------------------------------------------
    signal scl_drive     : STD_LOGIC := '1';
    signal sda_drive     : STD_LOGIC := '1';
    signal sda_is_master : STD_LOGIC := '1';  -- debug

    ------------------------------------------------------------------
    -- Data
    ------------------------------------------------------------------
    signal addr_byte    : STD_LOGIC_VECTOR (7 downto 0);  -- {addr, '1'} for read
    signal msb_data     : STD_LOGIC_VECTOR (7 downto 0) := (others => '0');
    signal lsb_data     : STD_LOGIC_VECTOR (7 downto 0) := (others => '0');

    signal temperature_r : signed (15 downto 0) := (others => '0');
    signal temp_valid_r  : STD_LOGIC := '0';

begin

    ------------------------------------------------------------------
    -- Open-drain output: pull low when drive='0', tri-state otherwise.
    -- Reading 'sda' anywhere returns the IOBUF input -- the actual pin.
    ------------------------------------------------------------------
    scl     <= '0' when (scl_drive = '0') else 'Z';
    sda     <= '0' when (sda_drive = '0') else 'Z';
    sda_dir <= sda_is_master;

    addr_byte <= sensor_address & '1';  -- always read-mode in this reader

    ------------------------------------------------------------------
    -- Main FSM. One process drives everything (Marion-style):
    --   * SCL is generated explicitly by scl_drive per quarter
    --   * SDA is set/released per state
    --   * Bit index decrements for 8-bit phases
    ------------------------------------------------------------------
    main_proc : process (reset, clock)
        variable raw16  : signed (15 downto 0);
        variable code13 : signed (15 downto 0);
        variable scaled : signed (31 downto 0);
    begin
        if (reset = '1') then
            state          <= S_POR;
            tick           <= (others => '0');
            bit_idx        <= (others => '0');
            por_count      <= (others => '0');
            interval_count <= (others => '0');
            scl_drive      <= '1';
            sda_drive      <= '1';
            sda_is_master  <= '1';
            msb_data       <= (others => '0');
            lsb_data       <= (others => '0');
            temp_valid_r   <= '0';
        elsif rising_edge(clock) then
            temp_valid_r <= '0';

            case state is

                ----------------------------------------------------------
                when S_POR =>
                    scl_drive     <= '1';
                    sda_drive     <= '1';
                    sda_is_master <= '1';
                    if por_count = to_unsigned(POR_TICKS - 1, por_count'length) then
                        state          <= S_IDLE;
                        interval_count <= (others => '0');
                    else
                        por_count <= por_count + 1;
                    end if;

                ----------------------------------------------------------
                when S_IDLE =>
                    scl_drive     <= '1';
                    sda_drive     <= '1';
                    sda_is_master <= '1';
                    if interval_count = to_unsigned(INTERVAL_TICKS - 1, interval_count'length) then
                        state <= S_START;
                        tick  <= (others => '0');
                    else
                        interval_count <= interval_count + 1;
                    end if;

                ----------------------------------------------------------
                -- START: SDA falls while SCL is high.
                -- Q0: scl=1, sda=1 (idle bus)
                -- Q1: scl=1, sda=0 (START condition)
                -- Q2: scl=1, sda=0 (hold)
                -- Q3: scl=0, sda=0 (SCL drops, ready for first addr bit)
                when S_START =>
                    sda_is_master <= '1';
                    if tick < QUARTER then
                        scl_drive <= '1'; sda_drive <= '1';
                    elsif tick < 2*QUARTER then
                        scl_drive <= '1'; sda_drive <= '0';
                    elsif tick < 3*QUARTER then
                        scl_drive <= '1'; sda_drive <= '0';
                    else
                        scl_drive <= '0'; sda_drive <= '0';
                    end if;
                    if tick = BIT_PERIOD - 1 then
                        tick    <= (others => '0');
                        bit_idx <= to_unsigned(7, bit_idx'length);
                        state   <= S_ADDR;
                    else
                        tick <= tick + 1;
                    end if;

                ----------------------------------------------------------
                -- ADDR: send 8 bits of {addr,R}, MSB first.
                -- Q0,Q1: scl=0, sda=bit  (data setup during SCL low)
                -- Q2,Q3: scl=1, sda=bit  (slave samples during SCL high)
                when S_ADDR =>
                    sda_is_master <= '1';
                    if tick < 2*QUARTER then
                        scl_drive <= '0';
                    else
                        scl_drive <= '1';
                    end if;
                    sda_drive <= addr_byte(to_integer(bit_idx));
                    if tick = BIT_PERIOD - 1 then
                        tick <= (others => '0');
                        if bit_idx = 0 then
                            state <= S_ADDR_ACK;
                        else
                            bit_idx <= bit_idx - 1;
                        end if;
                    else
                        tick <= tick + 1;
                    end if;

                ----------------------------------------------------------
                -- ADDR_ACK: master releases SDA, slave drives ACK low.
                when S_ADDR_ACK =>
                    sda_is_master <= '0';
                    if tick < 2*QUARTER then
                        scl_drive <= '0';
                    else
                        scl_drive <= '1';
                    end if;
                    sda_drive <= '1';  -- release
                    if tick = BIT_PERIOD - 1 then
                        tick    <= (others => '0');
                        bit_idx <= to_unsigned(7, bit_idx'length);
                        state   <= S_MSB;
                    else
                        tick <= tick + 1;
                    end if;

                ----------------------------------------------------------
                -- MSB: slave drives SDA, master reads. Sample mid-SCL-high
                -- (tick = 3*QUARTER) for the most stable read.
                when S_MSB =>
                    sda_is_master <= '0';
                    if tick < 2*QUARTER then
                        scl_drive <= '0';
                    else
                        scl_drive <= '1';
                    end if;
                    sda_drive <= '1';  -- release for slave
                    if tick = 3*QUARTER then
                        msb_data(to_integer(bit_idx)) <= sda;
                    end if;
                    if tick = BIT_PERIOD - 1 then
                        tick <= (others => '0');
                        if bit_idx = 0 then
                            state <= S_MSB_ACK;
                        else
                            bit_idx <= bit_idx - 1;
                        end if;
                    else
                        tick <= tick + 1;
                    end if;

                ----------------------------------------------------------
                -- MSB_ACK: master pulls SDA low for ACK.
                when S_MSB_ACK =>
                    sda_is_master <= '1';
                    if tick < 2*QUARTER then
                        scl_drive <= '0';
                    else
                        scl_drive <= '1';
                    end if;
                    sda_drive <= '0';  -- ACK
                    if tick = BIT_PERIOD - 1 then
                        tick    <= (others => '0');
                        bit_idx <= to_unsigned(7, bit_idx'length);
                        state   <= S_LSB;
                    else
                        tick <= tick + 1;
                    end if;

                ----------------------------------------------------------
                -- LSB: identical to MSB but stores into lsb_data.
                when S_LSB =>
                    sda_is_master <= '0';
                    if tick < 2*QUARTER then
                        scl_drive <= '0';
                    else
                        scl_drive <= '1';
                    end if;
                    sda_drive <= '1';
                    if tick = 3*QUARTER then
                        lsb_data(to_integer(bit_idx)) <= sda;
                    end if;
                    if tick = BIT_PERIOD - 1 then
                        tick <= (others => '0');
                        if bit_idx = 0 then
                            state <= S_LSB_NAK;
                        else
                            bit_idx <= bit_idx - 1;
                        end if;
                    else
                        tick <= tick + 1;
                    end if;

                ----------------------------------------------------------
                -- LSB_NAK: master releases SDA (high = NAK) for last byte.
                when S_LSB_NAK =>
                    sda_is_master <= '1';
                    if tick < 2*QUARTER then
                        scl_drive <= '0';
                    else
                        scl_drive <= '1';
                    end if;
                    sda_drive <= '1';  -- NAK = SDA high
                    if tick = BIT_PERIOD - 1 then
                        tick  <= (others => '0');
                        state <= S_STOP;
                    else
                        tick <= tick + 1;
                    end if;

                ----------------------------------------------------------
                -- STOP: SDA rises while SCL is high.
                -- Q0: scl=0, sda=1 (SCL falls cleanly; SDA still high from NAK)
                -- Q1: scl=0, sda=0 (SDA falls during SCL low -- prep)
                -- Q2: scl=1, sda=0 (SCL rises)
                -- Q3: scl=1, sda=1 (SDA rises -> STOP condition)
                when S_STOP =>
                    sda_is_master <= '1';
                    if tick < QUARTER then
                        scl_drive <= '0'; sda_drive <= '1';
                    elsif tick < 2*QUARTER then
                        scl_drive <= '0'; sda_drive <= '0';
                    elsif tick < 3*QUARTER then
                        scl_drive <= '1'; sda_drive <= '0';
                    else
                        scl_drive <= '1'; sda_drive <= '1';
                    end if;
                    if tick = BIT_PERIOD - 1 then
                        tick  <= (others => '0');
                        state <= S_DONE;
                    else
                        tick <= tick + 1;
                    end if;

                ----------------------------------------------------------
                when S_DONE =>
                    -- Convert {MSB, LSB} from 13-bit two's-complement to
                    -- signed tenths of a degree.
                    --   raw16  = {MSB, LSB}
                    --   code13 = raw16 >> 3      (top 13 bits, sign-extended)
                    --   tenths = code13 * 10 / 16   (=*10 via x*8 + x*2)
                    raw16  := signed(msb_data & lsb_data);
                    code13 := shift_right(raw16, 3);
                    scaled := shift_left(resize(code13, 32), 3)
                            + shift_left(resize(code13, 32), 1);
                    temperature_r <= resize(shift_right(scaled, 4), 16);

                    temp_valid_r   <= '1';
                    interval_count <= (others => '0');
                    state          <= S_IDLE;

            end case;
        end if;
    end process;

    temperature <= std_logic_vector(temperature_r);
    temp_valid  <= temp_valid_r;

end architecture;
