-- i2c_controller: Basic I2C master FSM.
-- Adapted from https://github.com/aslak3/i2c-controller
-- An internal 10-bit counter divides the 100 MHz clock to ~98 kHz SCL.
-- The FSM sequences through START, address+R/W, data bytes, ACK/NAK, STOP.
-- Open-drain operation: scl/sda are inout; driving 'Z' releases the line to
-- the pull-up resistor, driving '0' pulls it low (via scl_local / sda_local).
--
-- Each ACK has a _LOW companion state (WRITING_ACK_LOW / READING_ACK_LOW)
-- that drops SCL low after the 9th clock, parking the bus at SCL=0, SDA=Z
-- before any pause / STOP / RESTART. This prevents the slave from holding
-- SDA low across a long pause (which could look like a STOP to a decoder)
-- and gives a clean SCL falling edge for the slave to release SDA.

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity i2c_controller is
    port (
        clock      : in  STD_LOGIC;                      -- Master clock
        reset      : in  STD_LOGIC;                      -- Master reset
        trigger    : in  STD_LOGIC;                      -- Continue on after pause
        restart    : in  STD_LOGIC;                      -- Generates a new START
        last_byte  : in  STD_LOGIC;                      -- This is the last byte to read/write
        address    : in  STD_LOGIC_VECTOR (6 downto 0);  -- Slave address
        read_write : in  STD_LOGIC;                      -- 0=write, 1=read
        write_data : in  STD_LOGIC_VECTOR (7 downto 0);  -- Data to write
        read_data  : out STD_LOGIC_VECTOR (7 downto 0);  -- Data we have read
        ack_error  : out STD_LOGIC;                      -- 0=ACK, 1=NAK
        busy       : out STD_LOGIC;                      -- Controller is processing
        scl        : inout STD_LOGIC;                    -- Tri-state
        sda        : inout STD_LOGIC);                   -- Ditto
end entity;

architecture behavioral of i2c_controller is
    type T_STATE is (START1, START2,
        WRITING_DATA, WRITING_ACK, WRITING_ACK_LOW, WRITE_WAITING,
        READING_DATA, READING_ACK, READING_ACK_LOW, READ_WAITING,
        STOP1, STOP2, STOP3,
        RESTART1
    );
    signal running : STD_LOGIC := '0';                -- Not idle; trigger recieved
    signal pause_running : STD_LOGIC := '0';        -- Used to wait for next trigger
    signal running_clock : STD_LOGIC;                -- Generator of 100KHz ish SCL
    signal previous_running_clock : STD_LOGIC;        -- Used to find the edge
    signal state : T_STATE := START1;                -- Current state
    signal scl_local : STD_LOGIC := '1';            -- Local copies of output
    signal sda_local : STD_LOGIC := '1';            -- Ditto

begin
    process (reset, clock)
    -- 10-bit counter: bit 9 flips every 512 main clocks -> SCL period
    -- = 1024 cycles -> ~97.7 kHz at 100 MHz main clock (standard-mode I2C).
    variable i2c_clock_counter : UNSIGNED (9 downto 0);    -- Slows down the SCL from main clock
    begin
        if (reset = '1') then
            i2c_clock_counter      := (others => '0');
            running                <= '0';
            running_clock          <= '0';
            previous_running_clock <= '0';
        elsif (clock'Event and clock = '1') then
            if (trigger = '1') then
                -- On a trigger, enter running state and clear the counter
                running <= '1';
                i2c_clock_counter := (others => '0');
            end if;
            if (running = '1') then
                -- If we are running, inc the counter and extract the MSB for 2nd process
                i2c_clock_counter := i2c_clock_counter + 1;
                previous_running_clock <= running_clock;
                running_clock <= i2c_clock_counter (9);
            end if;
            if (pause_running = '1') then
                -- Handle the 2nd process wanting to wait for a trigger (eg. the next byte to write)
                running <= '0';
            end if;
        end if;
    end process;

    process (reset, clock)
    variable clock_flip : STD_LOGIC := '0';                    -- Used to toggle the scl_local
    variable bit_counter : INTEGER range 0 to 8 := 0;        -- Used in read/write to count bits
    variable data_to_write : STD_LOGIC_VECTOR (7 downto 0);    -- May be a slave address or actual data
    begin
        if (reset = '1') then
            -- Tri-state outputs and reset the state for the first trigger
            scl_local     <= '1';
            sda_local     <= '1';
            state         <= START1;
            pause_running <= '0';
            ack_error     <= '0';
            read_data     <= (others => '0');
            clock_flip    := '0';
            bit_counter   := 0;
            data_to_write := (others => '0');
        elsif (clock'Event and clock = '1') then
            -- Assume we are not pausing
            pause_running <= '0';

            if (restart = '1') then
                -- On restart force the state
                state <= RESTART1;
            end if;

            if (running = '1' and running_clock = '1' and previous_running_clock = '0') then
                case state is
                    when START1 =>
                        scl_local <= '1';
                        sda_local <= '1';
                        state <= START2;

                    when START2 =>
                        -- Prepare for sending the address by setting bit count up and setting up the
                        -- byte value we are writing to the address + read/write mode
                        sda_local <= '0';
                        clock_flip := '0';
                        bit_counter := 8;
                        data_to_write := address & read_write;
                        state <= WRITING_DATA;

                    when WRITING_DATA =>
                        -- Two cycles per bit
                        scl_local <= clock_flip;
                        -- Assert the actual bit we are writing using the bit_counter
                        sda_local <= data_to_write (bit_counter - 1);
                        if (clock_flip = '1') then
                            -- Clock going down, then next bit and move to ACK when all are sent
                            bit_counter := bit_counter - 1;
                            if (bit_counter = 0) then
                                state <= WRITING_ACK;
                            end if;
                        end if;
                        clock_flip := not clock_flip;

                    when WRITING_ACK =>
                        -- 9th clock for the slave's ACK. Master releases SDA
                        -- (sda_local='1'); slave pulls it low to ACK.
                        scl_local <= clock_flip;
                        sda_local <= '1';
                        if (clock_flip = '1') then
                            -- SCL high: sample the ACK bit. We move to
                            -- WRITING_ACK_LOW next so SCL gets a clean falling
                            -- edge before we pause or transition -- slaves
                            -- release SDA on SCL low, and parking the bus at
                            -- SCL=0 avoids a false-STOP during long pauses.
                            ack_error <= sda;
                            state <= WRITING_ACK_LOW;
                        end if;
                        clock_flip := not clock_flip;

                    when WRITING_ACK_LOW =>
                        -- Force SCL low so slave releases ACK, then decide
                        -- where to go next. Bus is parked at SCL=0, SDA=Z.
                        scl_local <= '0';
                        sda_local <= '1';
                        if (last_byte = '1') then
                            -- Last byte to write? Generate a STOP sequence.
                            state <= STOP1;
                        else
                            -- Otherwise wait for the next trigger. We might
                            -- be reading or writing now, as this byte sent
                            -- might have been the slave address.
                            pause_running <= '1';
                            if (read_write = '0') then
                                state <= WRITE_WAITING;
                            else
                                state <= READ_WAITING;
                            end if;
                        end if;

                    when WRITE_WAITING =>
                        -- Get ready for the next byte to write. Force
                        -- clock_flip='0' so WRITING_DATA's first cycle drives
                        -- SCL low and latches SDA's first bit cleanly.
                        data_to_write := write_data;
                        bit_counter := 8;
                        clock_flip := '0';
                        state <= WRITING_DATA;

                    when READING_DATA =>
                        scl_local <= clock_flip;
                        -- Tri-state the SDA so we can input on it
                        sda_local <= '1';
                        if (clock_flip = '1') then
                            -- Clock going down, then decreemnt the bit count and at the end, switch to reading
                            -- ACK state
                            bit_counter := bit_counter - 1;
                            if (bit_counter = 0) then
                                state <= READING_ACK;
                            end if;
                            -- Get the actual data bit
                            read_data (bit_counter) <= sda;
                        end if;
                        clock_flip := not clock_flip;

                    when READING_ACK =>
                        -- 9th clock: master drives ACK (0) or NAK (1) on SDA.
                        scl_local <= clock_flip;
                        sda_local <= last_byte;
                        if (clock_flip = '1') then
                            -- SCL high: slave has sampled our ACK/NAK.
                            -- Move to READING_ACK_LOW so SCL drops low and
                            -- the bus parks at SCL=0 before pausing/STOP.
                            state <= READING_ACK_LOW;
                        end if;
                        clock_flip := not clock_flip;

                    when READING_ACK_LOW =>
                        -- Force SCL low and release SDA so either slave can
                        -- drive next data bit (on trigger) or STOP1 can pull
                        -- SDA low cleanly while SCL is low.
                        scl_local <= '0';
                        sda_local <= '1';
                        if (last_byte = '1') then
                            state <= STOP1;
                        else
                            pause_running <= '1';
                            state <= READ_WAITING;
                        end if;

                    when READ_WAITING =>
                        -- Prepare the bit counter. Force clock_flip='0' so
                        -- READING_DATA's first cycle drives SCL low cleanly.
                        bit_counter := 8;
                        clock_flip := '0';
                        state <= READING_DATA;

                    when STOP1 =>
                        sda_local <= '0';
                        scl_local <= '0';
                        state <= STOP2;

                    when STOP2 =>
                        scl_local <= '1';
                        state <= STOP3;

                    when STOP3 =>
                        -- Wait for next trigger to start the next transaction
                        sda_local <= '1';
                        pause_running <= '1';
                        state <= START1;

                    when RESTART1 =>
                        -- Lower SCL while keeping SDA high so START1->START2 generates
                        -- a clean repeated START (SDA falls while SCL is high).
                        -- Do NOT drive SDA low here: SDA rising in START1 while SCL is
                        -- already high would look like a STOP condition to the slave.
                        scl_local <= '0';
                        sda_local <= '1';
                        state <= START1;
                end case;
            end if;
        end if;
    end process;

    busy <= running;
    -- Tri-state if the internal signal is 1
    scl <= 'Z' when (scl_local = '1') else '0';
    sda <= 'Z' when (sda_local = '1') else '0';
end architecture;