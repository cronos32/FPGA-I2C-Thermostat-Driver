----------------------------------------------------------------------------------

----------------------------------------------------------------------------------


library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

use IEEE.NUMERIC_STD.ALL;

-- Uncomment the following library declaration if instantiating
-- any Xilinx leaf cells in this code.
--library UNISIM;
--use UNISIM.VComponents.all;

entity thermostat_top is
    port ( clk : in STD_LOGIC;
        btnu : in STD_LOGIC;
        btnd : in STD_LOGIC;
        btnc : in STD_LOGIC;
        seg : out STD_LOGIC_VECTOR (6 downto 0);
        dp : out STD_LOGIC;
        an : out STD_LOGIC_VECTOR (7 downto 0);
        led16_r : out STD_LOGIC;
        led16_g : out STD_LOGIC;
        led16_b : out STD_LOGIC;
        TMP_SDA : inout STD_LOGIC;
        TMP_SCL : inout STD_LOGIC
    );
end thermostat_top;

architecture Behavioral of thermostat_top is

    -- ----------------------------------------------------------------
    -- Component declarations
    -- ----------------------------------------------------------------

    component display_driver is
        port (
            rst   : in std_logic;
            clk   : in std_logic;
            data  : in std_logic_vector (31 downto 0);
            dp_en : in STD_LOGIC_VECTOR (7 downto 0);
            seg   : out std_logic_vector (6 downto 0);
            anode : out std_logic_vector (7 downto 0);
            dp    : out std_logic
        );
    end component display_driver;
    
    component display_data_combiner is
        port (
            set_temp     : in  unsigned(11 downto 0); -- for example 232
            current_temp : in  unsigned(11 downto 0); -- for example 244
            data_out     : out std_logic_vector(31 downto 0)
        );
    end component display_data_combiner;
    
    component  temp_regulator is
        port (
            set_temp     : in  unsigned(11 downto 0); -- e. g. 232
            current_temp : in  unsigned(11 downto 0);
    
            led_red   : out std_logic;
            led_blue  : out std_logic;
            led_green : out std_logic;
    
            heat_en : out std_logic;
            cool_en : out std_logic
        );
    end component  temp_regulator;
    
    component ui_fsm is
        port (
            clk         : in  STD_LOGIC;
            reset       : in  STD_LOGIC;
            btn_up      : in  STD_LOGIC;
            btn_down    : in  STD_LOGIC;
            temp_out    : out STD_LOGIC_VECTOR(11 downto 0)
        );
    end component ui_fsm;

    component adt7420_reader is
        generic (
        CLOCK_FREQ_HZ    : integer;
        READ_INTERVAL_MS : integer
        );
        port (
            clock            : in    STD_LOGIC;                       -- Master clock
            reset            : in    STD_LOGIC;                       -- Active-high reset
            sensor_address   : in    STD_LOGIC_VECTOR (6 downto 0);   -- Typ. "1001000" (0x48)
            resolution_16bit : in    STD_LOGIC;                       -- 0=13-bit, 1=16-bit
            temperature      : out   STD_LOGIC_VECTOR (15 downto 0);  -- Signed tenths of C
            temp_valid       : out   STD_LOGIC;                       -- 1-cycle pulse per reading
            error            : out   STD_LOGIC;                       -- Sticky: any byte NAKed
            scl              : inout STD_LOGIC;
            sda              : inout STD_LOGIC
        );
    end component adt7420_reader;
    
    signal sig_display_data : std_logic_vector (31 downto 0); --xxxCxxxC
    signal sig_dp    : std_logic_vector(7 downto 0):= "10111011";  -- decimal points "10111011"
    
    signal sig_set_temp_slv  : std_logic_vector(11 downto 0);
    signal sig_set_temp     : unsigned(11 downto 0);

    signal sig_current_temp : unsigned(11 downto 0);
    signal sig_current_temp_int : integer;
    
    -- Intermediate signal to hold the raw SLV from the reader
    signal sig_temp_vector : std_logic_vector(15 downto 0);
    signal sig_temp_valid  : std_logic;

begin
    
    sig_set_temp <= unsigned(sig_set_temp_slv);
    
    process(clk)
        variable v_temp_signed : integer;
    begin
        if rising_edge(clk) then
            -- Only update when the sensor delivers a fresh reading (1 Hz pulse)
            if sig_temp_valid = '1' then
                -- Convert the 16-bit signed vector to an integer
                v_temp_signed := to_integer(signed(sig_temp_vector));

                -- Clamp to 0-4095 range for display/regulator
                if v_temp_signed < 0 then
                    sig_current_temp <= (others => '0');
                elsif v_temp_signed > 4095 then
                    sig_current_temp <= (others => '1');
                else
                    sig_current_temp <= to_unsigned(v_temp_signed, 12);
                end if;
            end if;
        end if;
    end process;
 
    -- UI FSM: no ce port, clk_en is instantiated inside ui_fsm
    ui_fsm_0 : ui_fsm
        port map (
            clk         => clk,
            reset       => btnc,
            btn_up      => btnu,
            btn_down    => btnd,
            temp_out    => sig_set_temp_slv
        );

    ------------------------------------------------------------------
    -- ADT7420 Temperature Sensor Reader Instantiation
    ------------------------------------------------------------------
    sensor_reader : adt7420_reader
        generic map ( 
            CLOCK_FREQ_HZ    => 100_000_000,
            READ_INTERVAL_MS => 1000 -- Read once per second
        )
        port map (
            clock            => clk,              -- Corrected port name
            reset            => btnc,             -- Corrected port name
            sensor_address   => "1001000",        -- Standard 0x48 address
            resolution_16bit => '1',              -- Use 16-bit for better accuracy
            temperature      => sig_temp_vector,  -- Connect to intermediate vector
            temp_valid       => sig_temp_valid,
            error            => open,             -- Leave open or connect to an LED
            scl              => TMP_SCL,
            sda              => TMP_SDA
        );

    display_0 : display_driver
    port map (
        clk     => clk,
        rst     => btnc,
        data    => sig_display_data,
        dp_en   => sig_dp,
        seg     => seg,
        anode   => an(7 downto 0),
        dp      => dp
    );
    
    combiner_0 : display_data_combiner
    port map(
        set_temp     => sig_set_temp,
        current_temp => sig_current_temp,
        data_out     => sig_display_data
    );
    
    regulator_0 : temp_regulator
    port map(
        set_temp     => sig_set_temp,
        current_temp => sig_current_temp,

        led_red      => led16_r,
        led_blue     => led16_b,
        led_green    => led16_g--,

        --heat_en =>  -not used right now, for later purposes
        --cool_en =>
    );

end Behavioral;