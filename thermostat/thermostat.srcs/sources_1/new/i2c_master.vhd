-- i2c_master.vhd
-- Single-byte I2C master wrapper around i2c_controller.
--
-- INTERFACE CONTRACT:
--   1. Set addr, rw, data_in, stop_on_done BEFORE asserting start.
--   2. Pulse start HIGH for exactly ONE clock cycle.
--   3. Poll busy; when it falls to '0' the byte is done.
--   4. nack is held HIGH from when busy falls until the next start
--      (latched -- driver does not need to catch a one-cycle pulse).
--   5. stop_on_done='0': no STOP, bus stays held.
--      Next start automatically becomes a repeated START.
--   6. stop_on_done='1': STOP generated after the byte.
--
-- DEPENDENCY: i2c_controller.vhd

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity i2c_master is
    port (
        clk          : in    STD_LOGIC;
        rst          : in    STD_LOGIC;
        addr         : in    STD_LOGIC_VECTOR(6 downto 0);
        rw           : in    STD_LOGIC;                     -- 0=write, 1=read
        data_in      : in    STD_LOGIC_VECTOR(7 downto 0);
        data_out     : out   STD_LOGIC_VECTOR(7 downto 0);
        start        : in    STD_LOGIC;                     -- pulse 1 cycle to begin
        stop_on_done : in    STD_LOGIC;                     -- 1=STOP after byte
        busy         : out   STD_LOGIC;
        nack         : out   STD_LOGIC;                     -- held high after NAK until next start
        scl          : inout STD_LOGIC;
        sda          : inout STD_LOGIC
    );
end entity;

architecture rtl of i2c_master is

    type T_STATE is (
        IDLE,
        TRIGGER,       -- pulse ctrl_trigger for one cycle
        WAIT_BUSY_HI,  -- wait for ctrl_busy to rise (controller latched trigger)
        WAIT_BUSY_LO,  -- wait for ctrl_busy to fall  (byte finished)
        DONE           -- hold results; return here until next start
    );
    signal state : T_STATE := IDLE;

    signal ctrl_trigger    : STD_LOGIC := '0';
    signal ctrl_restart    : STD_LOGIC := '0';
    signal ctrl_last_byte  : STD_LOGIC := '0';
    signal ctrl_read_write : STD_LOGIC := '0';
    signal ctrl_write_data : STD_LOGIC_VECTOR(7 downto 0) := (others => '0');
    signal ctrl_read_data  : STD_LOGIC_VECTOR(7 downto 0);
    signal ctrl_ack_error  : STD_LOGIC;
    signal ctrl_busy       : STD_LOGIC;

    -- Remembers whether the bus is held open (no STOP on last byte)
    signal bus_held : STD_LOGIC := '0';

begin

    ctrl: entity work.i2c_controller
        port map (
            clock      => clk,
            reset      => rst,
            trigger    => ctrl_trigger,
            restart    => ctrl_restart,
            last_byte  => ctrl_last_byte,
            address    => addr,
            read_write => ctrl_read_write,
            write_data => ctrl_write_data,
            read_data  => ctrl_read_data,
            ack_error  => ctrl_ack_error,
            busy       => ctrl_busy,
            scl        => scl,
            sda        => sda
        );

    process (clk)
    begin
        if rising_edge(clk) then
            -- Clear pulse-only outputs every cycle
            ctrl_trigger <= '0';
            ctrl_restart <= '0';

            if rst = '1' then
                state          <= IDLE;
                busy           <= '0';
                nack           <= '0';
                bus_held       <= '0';
                ctrl_last_byte <= '0';
                ctrl_read_write<= '0';
                ctrl_write_data<= (others => '0');
                data_out       <= (others => '0');

            else
                case state is

                    -- -------------------------------------------------------
                    when IDLE =>
                        if start = '1' then
                            ctrl_read_write <= rw;
                            ctrl_write_data <= data_in;
                            ctrl_last_byte  <= stop_on_done;
                            nack            <= '0';
                            busy            <= '1';
                            state           <= TRIGGER;
                        end if;

                    -- -------------------------------------------------------
                    -- Assert trigger for exactly one cycle.
                    -- Also assert restart if the bus is currently held open.
                    when TRIGGER =>
                        ctrl_trigger <= '1';
                        if bus_held = '1' then
                            ctrl_restart <= '1';
                        end if;
                        state <= WAIT_BUSY_HI;

                    -- -------------------------------------------------------
                    -- Wait for i2c_controller to accept the trigger (go busy).
                    when WAIT_BUSY_HI =>
                        if ctrl_busy = '1' then
                            state <= WAIT_BUSY_LO;
                        end if;

                    -- -------------------------------------------------------
                    -- Wait for i2c_controller to finish the byte (busy falls).
                    when WAIT_BUSY_LO =>
                        if ctrl_busy = '0' then
                            data_out <= ctrl_read_data;
                            nack     <= ctrl_ack_error;   -- latched; held until next start
                            bus_held <= not ctrl_last_byte;
                            busy     <= '0';
                            state    <= DONE;
                        end if;

                    -- -------------------------------------------------------
                    -- Hold data_out / nack stable. Accept next start here too
                    -- so back-to-back bytes don't need to pass through IDLE.
                    when DONE =>
                        if start = '1' then
                            ctrl_read_write <= rw;
                            ctrl_write_data <= data_in;
                            ctrl_last_byte  <= stop_on_done;
                            nack            <= '0';
                            busy            <= '1';
                            state           <= TRIGGER;
                        end if;

                    when others =>
                        state <= IDLE;

                end case;
            end if;
        end if;
    end process;

end architecture;