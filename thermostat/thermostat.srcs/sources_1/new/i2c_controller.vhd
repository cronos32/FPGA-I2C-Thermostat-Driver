library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity i2c_controller is
    port (
        clock      : in  STD_LOGIC;
        reset      : in  STD_LOGIC;
        trigger    : in  STD_LOGIC;
        restart    : in  STD_LOGIC;
        last_byte  : in  STD_LOGIC;
        address    : in  STD_LOGIC_VECTOR (6 downto 0);
        read_write : in  STD_LOGIC;
        write_data : in  STD_LOGIC_VECTOR (7 downto 0);
        read_data  : out STD_LOGIC_VECTOR (7 downto 0);
        ack_error  : out STD_LOGIC;
        busy       : out STD_LOGIC;
        scl        : inout STD_LOGIC;
        sda        : inout STD_LOGIC
    );
end entity;

architecture behavioral of i2c_controller is

    type T_STATE is (
        START1, START2,
        WRITING_DATA, WRITING_ACK, WRITE_WAITING,
        READING_DATA, READING_ACK, READ_WAITING,
        STOP1, STOP2, STOP3,
        RESTART1
    );

    signal running : STD_LOGIC := '0';
    signal pause_running : STD_LOGIC := '0';
    signal running_clock : STD_LOGIC;
    signal previous_running_clock : STD_LOGIC;
    signal state : T_STATE := START1;

    signal scl_local : STD_LOGIC := '1';
    signal sda_local : STD_LOGIC := '1';

begin

-- Clock divider / runner
process (reset, clock)
    variable i2c_clock_counter : UNSIGNED (7 downto 0);
begin
    if (reset = '1') then
        i2c_clock_counter      := (others => '0');
        running                <= '0';
        running_clock          <= '0';
        previous_running_clock <= '0';

    elsif rising_edge(clock) then
        if (trigger = '1') then
            running <= '1';
            i2c_clock_counter := (others => '0');
        end if;

        if (running = '1') then
            i2c_clock_counter := i2c_clock_counter + 1;
            previous_running_clock <= running_clock;
            running_clock <= i2c_clock_counter(7);
        end if;

        if (pause_running = '1') then
            running <= '0';
        end if;
    end if;
end process;

-- Main FSM
process (reset, clock)
    variable clock_flip : STD_LOGIC := '0';
    variable bit_counter : INTEGER range 0 to 8 := 0;
    variable data_to_write : STD_LOGIC_VECTOR (7 downto 0);
begin
    if (reset = '1') then
        scl_local     <= '1';
        sda_local     <= '1';
        state         <= START1;
        pause_running <= '0';
        ack_error     <= '0';
        read_data     <= (others => '0');
        clock_flip    := '0';
        bit_counter   := 0;
        data_to_write := (others => '0');

    elsif rising_edge(clock) then

        pause_running <= '0';

        if (running = '1' and running_clock = '1' and previous_running_clock = '0') then

            case state is

                when START1 =>
                    scl_local <= '1';
                    sda_local <= '1';
                    state <= START2;

                when START2 =>
                    sda_local <= '0';
                    clock_flip := '0';
                    bit_counter := 8;
                    data_to_write := address & read_write;
                    state <= WRITING_DATA;

                when WRITING_DATA =>
                    scl_local <= clock_flip;
                    sda_local <= data_to_write(bit_counter - 1);

                    if (clock_flip = '1') then
                        bit_counter := bit_counter - 1;
                        if (bit_counter = 0) then
                            state <= WRITING_ACK;
                        end if;
                    end if;

                    clock_flip := not clock_flip;

                -- 🔥 FIXED CORE LOGIC
                when WRITING_ACK =>
                    scl_local <= clock_flip;
                    sda_local <= '1';

                    if (clock_flip = '1') then
                        -- Sample ACK
                        ack_error <= sda;

                    else
                        -- Decide next step safely

                        if (restart = '1') then
                            state <= RESTART1;

                        elsif (last_byte = '1') then
                            state <= STOP1;

                        else
                            pause_running <= '1';

                            if (read_write = '0') then
                                state <= WRITE_WAITING;
                            else
                                state <= READ_WAITING;
                            end if;
                        end if;
                    end if;

                    clock_flip := not clock_flip;

                when WRITE_WAITING =>
                    data_to_write := write_data;
                    bit_counter := 8;
                    state <= WRITING_DATA;

                when READING_DATA =>
                    scl_local <= clock_flip;
                    sda_local <= '1';

                    if (clock_flip = '1') then
                        bit_counter := bit_counter - 1;
                        read_data(bit_counter) <= sda;

                        if (bit_counter = 0) then
                            state <= READING_ACK;
                        end if;
                    end if;

                    clock_flip := not clock_flip;

                when READING_ACK =>
                    scl_local <= clock_flip;
                    sda_local <= last_byte;

                    if (clock_flip = '1') then
                        if (last_byte = '1') then
                            state <= STOP1;
                        else
                            pause_running <= '1';
                            state <= READ_WAITING;
                        end if;
                    end if;

                    clock_flip := not clock_flip;

                when READ_WAITING =>
                    bit_counter := 8;
                    state <= READING_DATA;

                when STOP1 =>
                    sda_local <= '0';
                    scl_local <= '0';
                    state <= STOP2;

                when STOP2 =>
                    scl_local <= '1';
                    state <= STOP3;

                when STOP3 =>
                    sda_local <= '1';
                    pause_running <= '1';
                    state <= START1;

                when RESTART1 =>
                    -- Generate repeated START
                    scl_local <= '0';
                    sda_local <= '1';
                    state <= START1;

            end case;
        end if;
    end if;
end process;

busy <= running;

scl <= 'Z' when (scl_local = '1') else '0';
sda <= 'Z' when (sda_local = '1') else '0';

end architecture;