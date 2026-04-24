-- ADT7420 Temperature Sensor Reader -- SIMPLIFIED
--
-- Reads the ADT7420 using the sensor's power-on defaults, with NO
-- configuration write and NO pointer write:
--   * Pointer register defaults to 0x00 (Temperature MSB) on POR
--   * Continuous conversion, 13-bit resolution is the POR default
--   * After reading MSB the pointer auto-increments to LSB (0x01)
--
-- This means a single read transaction is enough -- no repeated START,
-- no preceding write phase. Transaction (3 triggers):
--   T1  START + addr + R  (slave ACK)
--   T2  read MSB          (master ACK)
--   T3  read LSB          (master NAK + STOP)
--
-- Output `temperature` is signed tenths of a degree Celsius
-- (13-bit mode: LSB = 0.0625 C -> tenths = code13 * 10 / 16).

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity adt7420_reader_simple is
    generic (
        CLOCK_FREQ_HZ    : integer := 100_000_000;
        READ_INTERVAL_MS : integer := 1000
    );
    port (
        clock            : in    STD_LOGIC;
        reset            : in    STD_LOGIC;

        sensor_address   : in    STD_LOGIC_VECTOR (6 downto 0);

        temperature      : out   STD_LOGIC_VECTOR (15 downto 0);
        temp_valid       : out   STD_LOGIC;
        error            : out   STD_LOGIC;

        scl              : inout STD_LOGIC;
        sda              : inout STD_LOGIC
    );
end entity;

architecture behavioral of adt7420_reader_simple is

    component i2c_controller is
        port (
            clock      : in    STD_LOGIC;
            reset      : in    STD_LOGIC;
            trigger    : in    STD_LOGIC;
            restart    : in    STD_LOGIC;
            last_byte  : in    STD_LOGIC;
            address    : in    STD_LOGIC_VECTOR (6 downto 0);
            read_write : in    STD_LOGIC;
            write_data : in    STD_LOGIC_VECTOR (7 downto 0);
            read_data  : out   STD_LOGIC_VECTOR (7 downto 0);
            ack_error  : out   STD_LOGIC;
            busy       : out   STD_LOGIC;
            scl        : inout STD_LOGIC;
            sda        : inout STD_LOGIC);
    end component;

    type T_STATE is (
        S_STARTUP,
        S_IDLE,
        S_RD_ADDR_R,  S_RD_ADDR_R_WAIT,
        S_RD_MSB,     S_RD_MSB_WAIT,
        S_RD_LSB,     S_RD_LSB_WAIT,
        S_RD_DONE
    );
    signal state : T_STATE := S_STARTUP;

    signal i2c_trigger    : STD_LOGIC := '0';
    signal i2c_restart    : STD_LOGIC := '0';  -- never asserted
    signal i2c_last_byte  : STD_LOGIC := '0';
    signal i2c_read_write : STD_LOGIC := '1';  -- always read in this version
    signal i2c_write_data : STD_LOGIC_VECTOR (7 downto 0) := (others => '0');
    signal i2c_read_data  : STD_LOGIC_VECTOR (7 downto 0);
    signal i2c_ack_error  : STD_LOGIC;
    signal i2c_busy       : STD_LOGIC;
    signal busy_d         : STD_LOGIC := '0';

    -- 10 ms startup delay covers the ADT7420 power-on reset (<= 1 ms).
    -- The first valid conversion needs ~240 ms, but READ_INTERVAL_MS
    -- (default 1000 ms) is already larger so the first read is valid.
    constant STARTUP_TICKS : integer := (CLOCK_FREQ_HZ / 1000) * 10;
    signal startup_cnt : unsigned (31 downto 0) := (others => '0');

    constant INTERVAL_TICKS : integer :=
        (CLOCK_FREQ_HZ / 1000) * READ_INTERVAL_MS;
    signal interval_cnt  : unsigned (31 downto 0) := (others => '0');
    signal interval_tick : STD_LOGIC := '0';

    signal raw_msb       : STD_LOGIC_VECTOR (7 downto 0) := (others => '0');
    signal raw_lsb       : STD_LOGIC_VECTOR (7 downto 0) := (others => '0');
    signal temperature_r : signed (15 downto 0) := (others => '0');
    signal temp_valid_r  : STD_LOGIC := '0';
    signal error_r       : STD_LOGIC := '0';

begin

    i2c : i2c_controller
        port map (
            clock      => clock,
            reset      => reset,
            trigger    => i2c_trigger,
            restart    => i2c_restart,
            last_byte  => i2c_last_byte,
            address    => sensor_address,
            read_write => i2c_read_write,
            write_data => i2c_write_data,
            read_data  => i2c_read_data,
            ack_error  => i2c_ack_error,
            busy       => i2c_busy,
            scl        => scl,
            sda        => sda
        );

    interval_proc : process (reset, clock)
    begin
        if (reset = '1') then
            interval_cnt  <= (others => '0');
            interval_tick <= '0';
        elsif (clock'Event and clock = '1') then
            interval_tick <= '0';
            if (interval_cnt = to_unsigned(INTERVAL_TICKS - 1, interval_cnt'length)) then
                interval_cnt  <= (others => '0');
                interval_tick <= '1';
            else
                interval_cnt <= interval_cnt + 1;
            end if;
        end if;
    end process;

    fsm_proc : process (reset, clock)
    begin
        if (reset = '1') then
            state         <= S_STARTUP;
            i2c_trigger   <= '0';
            i2c_last_byte <= '0';
            raw_msb       <= (others => '0');
            raw_lsb       <= (others => '0');
            temp_valid_r  <= '0';
            error_r       <= '0';
            busy_d        <= '0';
            startup_cnt   <= (others => '0');
        elsif (clock'Event and clock = '1') then
            i2c_trigger  <= '0';
            temp_valid_r <= '0';
            busy_d       <= i2c_busy;

            case state is
                when S_STARTUP =>
                    if (startup_cnt = to_unsigned(STARTUP_TICKS - 1, startup_cnt'length)) then
                        state <= S_IDLE;
                    else
                        startup_cnt <= startup_cnt + 1;
                    end if;

                when S_IDLE =>
                    if (interval_tick = '1') then
                        state <= S_RD_ADDR_R;
                    end if;

                -- T1: START + addr + R, controller gets slave ACK and pauses.
                when S_RD_ADDR_R =>
                    i2c_last_byte <= '0';
                    i2c_trigger   <= '1';
                    state         <= S_RD_ADDR_R_WAIT;

                when S_RD_ADDR_R_WAIT =>
                    if (busy_d = '1' and i2c_busy = '0') then
                        if (i2c_ack_error = '1') then
                            error_r <= '1';
                        end if;
                        state <= S_RD_MSB;
                    end if;

                -- T2: read MSB, master ACKs (last_byte=0).
                when S_RD_MSB =>
                    i2c_last_byte <= '0';
                    i2c_trigger   <= '1';
                    state         <= S_RD_MSB_WAIT;

                when S_RD_MSB_WAIT =>
                    if (busy_d = '1' and i2c_busy = '0') then
                        raw_msb <= i2c_read_data;
                        state   <= S_RD_LSB;
                    end if;

                -- T3: read LSB, master NAKs and STOPs (last_byte=1).
                when S_RD_LSB =>
                    i2c_last_byte <= '1';
                    i2c_trigger   <= '1';
                    state         <= S_RD_LSB_WAIT;

                when S_RD_LSB_WAIT =>
                    if (busy_d = '1' and i2c_busy = '0') then
                        raw_lsb <= i2c_read_data;
                        state   <= S_RD_DONE;
                    end if;

                when S_RD_DONE =>
                    temp_valid_r  <= '1';
                    i2c_last_byte <= '0';
                    state         <= S_IDLE;

            end case;
        end if;
    end process;

    -- 13-bit conversion: top 13 bits of {MSB, LSB} are the signed code,
    -- low 3 bits of LSB are flags. tenths = code13 * 10 / 16.
    conv_proc : process (reset, clock)
        variable raw16  : signed (15 downto 0);
        variable code13 : signed (15 downto 0);
        variable scaled : signed (31 downto 0);
    begin
        if (reset = '1') then
            temperature_r <= (others => '0');
        elsif (clock'Event and clock = '1') then
            if (state = S_RD_DONE) then
                raw16  := signed(raw_msb & raw_lsb);
                code13 := shift_right(raw16, 3);
                scaled := shift_left(resize(code13, 32), 3)
                        + shift_left(resize(code13, 32), 1);
                temperature_r <= resize(shift_right(scaled, 4), 16);
            end if;
        end if;
    end process;

    temperature <= std_logic_vector(temperature_r);
    temp_valid  <= temp_valid_r;
    error       <= error_r;

end architecture;
