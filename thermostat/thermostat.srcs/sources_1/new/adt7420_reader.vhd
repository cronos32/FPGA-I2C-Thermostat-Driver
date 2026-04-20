-- ADT7420 Temperature Sensor Reader
-- Inspired by https://github.com/aslak3/i2c-controller
--
-- Wraps the i2c_controller and provides periodic (~1 Hz) temperature
-- readings from an ADT7420 digital temperature sensor.
--
-- Output `temperature` is a signed integer in tenths of a degree Celsius.
--   e.g.  22.1 C  ->   221
--         -5.3 C  ->   -53  (or -54, see conversion note)
--        125.0 C  ->  1250
--
-- Resolution is software-selectable via `resolution_16bit`:
--   '0' = 13-bit ADC, 0.0625    C per LSB   (power-on default)
--   '1' = 16-bit ADC, 0.0078125 C per LSB
-- Both modes are converted to the same tenths-of-degree output.
--
-- The underlying i2c_controller works one bus "byte" per `trigger` pulse,
-- where the very first byte of a transaction is always
-- {slave_address, R/W} (i.e. you do NOT supply it in write_data).  So a
-- full I2C write of N data bytes requires N+1 triggers, and a full read
-- of M data bytes preceded by a pointer-write requires 1 + 1 + 1 + M
-- triggers (addr+W, pointer, RESTART+addr+R, M reads).
--
-- Transaction layout for a temperature read (5 triggers):
--   T1  addr+W                                     (from controller.START1/2)
--   T2  pointer = 0x00                             (WRITE_WAITING -> WRITING_DATA)
--   T3  RESTART + addr+R                           (restart=1)
--   T4  read MSB, controller ACKs                  (last_byte=0)
--   T5  read LSB, controller NAKs + STOP           (last_byte=1)
--
-- And for the one-time configuration write (3 triggers):
--   T1  addr+W
--   T2  pointer = 0x03
--   T3  value (last_byte=1 -> STOP)

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity adt7420_reader is
    generic (
        -- Main clock frequency in Hz.  Used to derive the read interval.
        CLOCK_FREQ_HZ    : integer := 50_000_000;
        -- Read interval in milliseconds (default 1000 ms = 1 Hz).
        READ_INTERVAL_MS : integer := 1000
    );
    port (
        clock            : in    STD_LOGIC;                       -- Master clock
        reset            : in    STD_LOGIC;                       -- Master reset (active high)

        -- Configuration
        sensor_address   : in    STD_LOGIC_VECTOR (6 downto 0);   -- Typ. "1001000" (0x48)
        resolution_16bit : in    STD_LOGIC;                       -- 0=13-bit, 1=16-bit

        -- Results
        temperature      : out   STD_LOGIC_VECTOR (15 downto 0);  -- Signed tenths of C
        temp_valid       : out   STD_LOGIC;                       -- 1-cycle pulse on new reading
        error            : out   STD_LOGIC;                       -- Sticky: any transaction NAKed

        -- I2C bus (open-drain / tri-state, needs external pull-ups)
        scl              : inout STD_LOGIC;
        sda              : inout STD_LOGIC
    );
end entity;

architecture behavioral of adt7420_reader is

    ------------------------------------------------------------------
    -- Component declaration of the existing I2C controller
    ------------------------------------------------------------------
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

    ------------------------------------------------------------------
    -- ADT7420 register addresses
    ------------------------------------------------------------------
    constant REG_TEMP_MSB : STD_LOGIC_VECTOR (7 downto 0) := x"00";
    constant REG_CONFIG   : STD_LOGIC_VECTOR (7 downto 0) := x"03";

    ------------------------------------------------------------------
    -- FSM states.
    -- For each bus byte we do:
    --   _SETUP : drive trigger='1' with write_data/last_byte/restart/rw
    --            set correctly, then advance to _WAIT.
    --   _WAIT  : watch for busy to go 1->0 (byte finished), then move on.
    ------------------------------------------------------------------
    type T_STATE is (
        S_RESET,

        -- One-time configuration write (3 triggers)
        S_CFG_ADDR,   S_CFG_ADDR_WAIT,    -- T1: addr+W
        S_CFG_PTR,    S_CFG_PTR_WAIT,     -- T2: pointer = 0x03
        S_CFG_VAL,    S_CFG_VAL_WAIT,     -- T3: value (last_byte -> STOP)

        -- Idle until next read interval
        S_IDLE,

        -- Temperature read (5 triggers)
        S_RD_ADDR_W,  S_RD_ADDR_W_WAIT,   -- T1: addr+W
        S_RD_PTR,     S_RD_PTR_WAIT,      -- T2: pointer = 0x00
        S_RD_RESTART, S_RD_RESTART_WAIT,  -- T3: RESTART + addr+R
        S_RD_MSB,     S_RD_MSB_WAIT,      -- T4: read MSB (ACK)
        S_RD_LSB,     S_RD_LSB_WAIT,      -- T5: read LSB (NAK + STOP)

        S_RD_DONE
    );
    signal state : T_STATE := S_RESET;

    ------------------------------------------------------------------
    -- I2C controller ports
    ------------------------------------------------------------------
    signal i2c_trigger    : STD_LOGIC := '0';
    signal i2c_restart    : STD_LOGIC := '0';
    signal i2c_last_byte  : STD_LOGIC := '0';
    signal i2c_read_write : STD_LOGIC := '0';
    signal i2c_write_data : STD_LOGIC_VECTOR (7 downto 0) := (others => '0');
    signal i2c_read_data  : STD_LOGIC_VECTOR (7 downto 0);
    signal i2c_ack_error  : STD_LOGIC;
    signal i2c_busy       : STD_LOGIC;
    signal busy_d         : STD_LOGIC := '0';  -- delayed busy for edge detect

    ------------------------------------------------------------------
    -- Interval timer
    ------------------------------------------------------------------
    constant INTERVAL_TICKS : integer :=
        (CLOCK_FREQ_HZ / 1000) * READ_INTERVAL_MS;
    signal interval_cnt  : unsigned (31 downto 0) := (others => '0');
    signal interval_tick : STD_LOGIC := '0';

    ------------------------------------------------------------------
    -- Data path
    ------------------------------------------------------------------
    signal raw_msb       : STD_LOGIC_VECTOR (7 downto 0) := (others => '0');
    signal raw_lsb       : STD_LOGIC_VECTOR (7 downto 0) := (others => '0');
    signal cfg_is_16bit  : STD_LOGIC := '0';  -- latched at reset
    signal temperature_r : signed (15 downto 0) := (others => '0');
    signal temp_valid_r  : STD_LOGIC := '0';
    signal error_r       : STD_LOGIC := '0';

begin

    ------------------------------------------------------------------
    -- I2C controller instance
    ------------------------------------------------------------------
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

    ------------------------------------------------------------------
    -- Free-running interval timer (ticks once every READ_INTERVAL_MS)
    ------------------------------------------------------------------
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

    ------------------------------------------------------------------
    -- Main FSM
    ------------------------------------------------------------------
    fsm_proc : process (reset, clock)
    begin
        if (reset = '1') then
            state          <= S_RESET;
            i2c_trigger    <= '0';
            i2c_restart    <= '0';
            i2c_last_byte  <= '0';
            i2c_read_write <= '0';
            i2c_write_data <= (others => '0');
            raw_msb        <= (others => '0');
            raw_lsb        <= (others => '0');
            temp_valid_r   <= '0';
            error_r        <= '0';
            cfg_is_16bit   <= '0';
            busy_d         <= '0';
        elsif (clock'Event and clock = '1') then
            -- One-cycle defaults
            i2c_trigger  <= '0';
            i2c_restart  <= '0';
            temp_valid_r <= '0';
            busy_d       <= i2c_busy;

            case state is
                ----------------------------------------------------------
                when S_RESET =>
                    cfg_is_16bit <= resolution_16bit;
                    state <= S_CFG_ADDR;

                ----------------------------------------------------------
                -- Configuration write: addr+W, ptr=0x03, data=config byte
                -- Config byte layout (Table 11 of datasheet):
                --   [7]   Resolution   (1 = 16-bit, 0 = 13-bit)
                --   [6:5] Op mode      (00 = continuous conversion)
                --   [4]   INT/CT mode  (0 = interrupt)
                --   [3]   INT polarity (0 = active low)
                --   [2]   CT polarity  (0 = active low)
                --   [1:0] Fault queue  (00 = 1 fault)
                -- All zeros except the resolution bit -> safe defaults.
                ----------------------------------------------------------

                -- T1: slave addr + W.  write_data is ignored for this
                -- byte (controller internally sends {address, read_write}).
                when S_CFG_ADDR =>
                    i2c_read_write <= '0';
                    i2c_write_data <= (others => '0');
                    i2c_last_byte  <= '0';
                    i2c_trigger    <= '1';
                    state          <= S_CFG_ADDR_WAIT;

                when S_CFG_ADDR_WAIT =>
                    if (busy_d = '1' and i2c_busy = '0') then
                        if (i2c_ack_error = '1') then
                            error_r <= '1';
                        end if;
                        state <= S_CFG_PTR;
                    end if;

                -- T2: pointer byte = 0x03
                when S_CFG_PTR =>
                    i2c_read_write <= '0';
                    i2c_write_data <= REG_CONFIG;
                    i2c_last_byte  <= '0';
                    i2c_trigger    <= '1';
                    state          <= S_CFG_PTR_WAIT;

                when S_CFG_PTR_WAIT =>
                    if (busy_d = '1' and i2c_busy = '0') then
                        if (i2c_ack_error = '1') then
                            error_r <= '1';
                        end if;
                        state <= S_CFG_VAL;
                    end if;

                -- T3: config value (last byte -> STOP)
                when S_CFG_VAL =>
                    i2c_read_write <= '0';
                    i2c_write_data <= cfg_is_16bit & "0000000";
                    i2c_last_byte  <= '1';
                    i2c_trigger    <= '1';
                    state          <= S_CFG_VAL_WAIT;

                when S_CFG_VAL_WAIT =>
                    if (busy_d = '1' and i2c_busy = '0') then
                        if (i2c_ack_error = '1') then
                            error_r <= '1';
                        end if;
                        i2c_last_byte <= '0';
                        state         <= S_IDLE;
                    end if;

                ----------------------------------------------------------
                when S_IDLE =>
                    if (interval_tick = '1') then
                        state <= S_RD_ADDR_W;
                    end if;

                ----------------------------------------------------------
                -- Read: addr+W, pointer=0x00, RESTART, addr+R, MSB, LSB
                ----------------------------------------------------------

                -- T1: addr + W
                when S_RD_ADDR_W =>
                    i2c_read_write <= '0';
                    i2c_write_data <= (others => '0');
                    i2c_last_byte  <= '0';
                    i2c_trigger    <= '1';
                    state          <= S_RD_ADDR_W_WAIT;

                when S_RD_ADDR_W_WAIT =>
                    if (busy_d = '1' and i2c_busy = '0') then
                        if (i2c_ack_error = '1') then
                            error_r <= '1';
                        end if;
                        state <= S_RD_PTR;
                    end if;

                -- T2: pointer byte = 0x00
                when S_RD_PTR =>
                    i2c_read_write <= '0';
                    i2c_write_data <= REG_TEMP_MSB;
                    i2c_last_byte  <= '0';
                    i2c_trigger    <= '1';
                    state          <= S_RD_PTR_WAIT;

                when S_RD_PTR_WAIT =>
                    if (busy_d = '1' and i2c_busy = '0') then
                        if (i2c_ack_error = '1') then
                            error_r <= '1';
                        end if;
                        state <= S_RD_RESTART;
                    end if;

                -- T3: RESTART + addr + R.  Asserting restart=1 with a
                -- fresh trigger causes the controller to go through
                -- RESTART1 -> START1 -> START2 -> WRITING_DATA where it
                -- sends {address, '1'} (the R bit).
                when S_RD_RESTART =>
                    i2c_read_write <= '1';
                    i2c_restart    <= '1';
                    i2c_last_byte  <= '0';
                    i2c_trigger    <= '1';
                    state          <= S_RD_RESTART_WAIT;

                when S_RD_RESTART_WAIT =>
                    if (busy_d = '1' and i2c_busy = '0') then
                        if (i2c_ack_error = '1') then
                            error_r <= '1';
                        end if;
                        state <= S_RD_MSB;
                    end if;

                -- T4: read MSB (not last -> ACK)
                when S_RD_MSB =>
                    i2c_read_write <= '1';
                    i2c_last_byte  <= '0';
                    i2c_trigger    <= '1';
                    state          <= S_RD_MSB_WAIT;

                when S_RD_MSB_WAIT =>
                    if (busy_d = '1' and i2c_busy = '0') then
                        raw_msb <= i2c_read_data;
                        state   <= S_RD_LSB;
                    end if;

                -- T5: read LSB (last -> NAK + STOP)
                when S_RD_LSB =>
                    i2c_read_write <= '1';
                    i2c_last_byte  <= '1';
                    i2c_trigger    <= '1';
                    state          <= S_RD_LSB_WAIT;

                when S_RD_LSB_WAIT =>
                    if (busy_d = '1' and i2c_busy = '0') then
                        raw_lsb <= i2c_read_data;
                        state   <= S_RD_DONE;
                    end if;

                ----------------------------------------------------------
                when S_RD_DONE =>
                    temp_valid_r  <= '1';
                    i2c_last_byte <= '0';
                    state         <= S_IDLE;

            end case;
        end if;
    end process;

    ------------------------------------------------------------------
    -- Temperature conversion to tenths of a degree Celsius
    --
    -- Raw 16-bit word is {MSB, LSB} in two's complement.
    --
    -- 13-bit mode: upper 13 bits are the signed temperature code; the
    --              lower 3 bits are status flags.  LSB = 0.0625 C.
    --              tenths = code13 * 0.625 = code13 * 10 / 16
    --              implemented as (code13 * 10) >>> 4   (exact)
    --
    -- 16-bit mode: all 16 bits are the signed temperature code;
    --              LSB = 0.0078125 C.
    --              tenths = code16 * 0.078125 = code16 * 10 / 128
    --              implemented as (code16 * 10) >>> 7   (exact)
    --
    -- Note: arithmetic shift-right rounds toward -inf, so a negative
    -- input like -85 (-5.3125 C, 13-bit) converts to -54 rather than
    -- -53.  That's 0.1 C off in the last digit and well within sensor
    -- tolerance.
    ------------------------------------------------------------------
    conv_proc : process (reset, clock)
        variable raw16  : signed (15 downto 0);
        variable code13 : signed (15 downto 0);
        variable scaled : signed (31 downto 0);
    begin
        if (reset = '1') then
            temperature_r <= (others => '0');
        elsif (clock'Event and clock = '1') then
            if (state = S_RD_DONE) then
                raw16 := signed(raw_msb & raw_lsb);
                if (cfg_is_16bit = '1') then
                    scaled := resize(raw16, 32) * to_signed(10, 6);
                    temperature_r <= resize(shift_right(scaled, 7), 16);
                else
                    code13 := shift_right(raw16, 3);
                    scaled := resize(code13, 32) * to_signed(10, 6);
                    temperature_r <= resize(shift_right(scaled, 4), 16);
                end if;
            end if;
        end if;
    end process;

    ------------------------------------------------------------------
    -- Outputs
    ------------------------------------------------------------------
    temperature <= std_logic_vector(temperature_r);
    temp_valid  <= temp_valid_r;
    error       <= error_r;

end architecture;