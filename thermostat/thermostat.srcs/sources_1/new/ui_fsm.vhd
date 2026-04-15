library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity ui_fsm is
    Port (
        clk      : in  STD_LOGIC;       -- Main system clock (100 MHz)
        reset    : in  STD_LOGIC;       -- Synchronous reset
        btn_up   : in  STD_LOGIC;       -- Raw input from UP button
        btn_down : in  STD_LOGIC;       -- Raw input from DOWN button
        temp_out : out STD_LOGIC_VECTOR(11 downto 0)
    );
end ui_fsm;

architecture Behavioral of ui_fsm is

    -- Component for the clock enable generator
    component clk_en is
        generic ( G_MAX : positive );
        port (
            clk : in  std_logic;
            rst : in  std_logic;
            ce  : out std_logic
        );
    end component clk_en;
    
    -- Component for the debouncer
    component debounce is
        port (
            clk        : in  std_logic;
            rst        : in  std_logic;
            btn_in     : in  std_logic;
            btn_state  : out std_logic;
            btn_press  : out std_logic
        );
    end component;

    -- Signals for Clock Enable logic
    signal ce        : std_logic;
    signal ce_prev   : std_logic := '0';
    
    -- Signals from debouncers
    signal press_up   : std_logic;
    signal press_down : std_logic;
    
    -- Latches to catch the short pulses from debouncers
    signal up_latched   : std_logic := '0';
    signal down_latched : std_logic := '0';

    -- Internal temperature register
    signal temp_reg : integer range 0 to 4095 := 220;
 
begin

    ----------------------------------------------------------------
    -- Clock Enable: 10 Hz pulse at 100 MHz clock
    ----------------------------------------------------------------
    ce_gen : clk_en
        generic map ( G_MAX => 10_000_000 )
        port map ( clk => clk, rst => reset, ce => ce );

    ----------------------------------------------------------------
    -- Debouncer Instances
    ----------------------------------------------------------------
    deb_up : debounce
        port map (
            clk       => clk,
            rst       => reset,
            btn_in    => btn_up,
            btn_press => press_up,  -- 1-clock cycle pulse
            btn_state => open       -- not used here
        );

    deb_down : debounce
        port map (
            clk       => clk,
            rst       => reset,
            btn_in    => btn_down,
            btn_press => press_down, -- 1-clock cycle pulse
            btn_state => open        -- not used here
        );
    
    ----------------------------------------------------------------
    -- Process 1: Latch logic (High speed)
    ----------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            ce_prev <= ce; -- Used to clear latches in the next cycle
 
            if reset = '1' then
                up_latched   <= '0';
                down_latched <= '0';
            else
                -- Catch the debouncer pulse
                if press_up = '1' then
                    up_latched <= '1';
                end if;
 
                if press_down = '1' then
                    down_latched <= '1';
                end if;

                 -- Clear the latch after the slow process has seen it
                if ce_prev = '1' then
                    up_latched   <= '0';
                    down_latched <= '0';
                end if;
                -- Alternative for ce_prev (not needed):
                --if ce = '1' then
                --    up_latched   <= btn_up; -- rewriting by new state of the button
                --    down_latched <= btn_down;
                --else
                --    if btn_up = '1' then up_latched <= '1'; end if;
                --    if btn_down = '1' then down_latched <= '1'; end if;
                --end if;
            end if;
        end if;
    end process;
 
    ----------------------------------------------------------------
    -- Process 2: Temperature Update (Slow speed via CE)
    ----------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                temp_reg <= 220;
            elsif ce = '1' then
                if up_latched = '1' then
                    if temp_reg <= 395 then
                        temp_reg <= temp_reg + 5;
                    end if;
                elsif down_latched = '1' then
                    if temp_reg >= 55 then
                        temp_reg <= temp_reg - 5;
                    end if;
                end if;
            end if;
        end if;
    end process;

    -- Output assignment
    temp_out <= std_logic_vector(to_unsigned(temp_reg, 12));
 
end Behavioral;