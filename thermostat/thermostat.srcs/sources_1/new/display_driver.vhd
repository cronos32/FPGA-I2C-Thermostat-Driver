-- display_driver: Time-multiplexed 8-digit 7-segment display driver.
-- Uses clk_en (G_MAX = 800_000, 125 Hz tick) and a 3-bit counter to cycle
-- through all eight display positions. A case statement selects the active
-- 4-bit nibble from the 32-bit data word and passes it to bin2seg for
-- segment decoding. Decimal-point output is indexed from the dp_en mask.
-- Anode outputs are active-low (one '0' active per digit at a time).


library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- Uncomment the following library declaration if using
-- arithmetic functions with Signed or Unsigned values
--use IEEE.NUMERIC_STD.ALL;

-- Uncomment the following library declaration if instantiating
-- any Xilinx leaf cells in this code.
--library UNISIM;
--use UNISIM.VComponents.all;

entity display_driver is
    Port ( 
           rst : in STD_LOGIC;
           clk : in STD_LOGIC;
           data : in STD_LOGIC_VECTOR (31 downto 0);
           dp_en : in STD_LOGIC_VECTOR (7 downto 0);
           seg : out STD_LOGIC_VECTOR (6 downto 0);
           anode : out STD_LOGIC_VECTOR (7 downto 0);
           dp : out STD_LOGIC);
end display_driver;

architecture Behavioral of display_driver is

    -- Component declaration for clock enable
    component clk_en is
        generic ( G_MAX : positive );
        port (
            clk : in  std_logic;
            rst : in  std_logic;
            ce  : out std_logic
        );
    end component clk_en;
 
    -- Component declaration for binary counter
    component counter is
        generic ( G_BITS : positive );
        port (
            clk : in  std_logic;
            rst : in  std_logic;
            en  : in  std_logic;
            cnt : out std_logic_vector(G_BITS - 1 downto 0)
        );
    end component counter;
 
    component bin2seg is
        port (
            bin : in std_logic_vector(3 downto 0);
            seg : out std_logic_vector(6 downto 0)
        );

    end component bin2seg;
 
    -- Internal signals
    signal sig_en : std_logic;
    
    signal sig_digit : std_logic_vector(2 downto 0) := "000";
    
    signal sig_bin : std_logic_vector(3 downto 0);

begin

    ------------------------------------------------------------------------
    -- Clock enable generator for refresh timing
    ------------------------------------------------------------------------
    clock_0 : clk_en
        generic map ( G_MAX => 200_000 )  -- Adjust for flicker-free multiplexing
        port map (                   -- For simulation: 32
            clk => clk,              -- For implementation: 3_200_000
            rst => rst,
            ce  => sig_en
        );

    ------------------------------------------------------------------------
    -- N-bit counter for digit selection
    ------------------------------------------------------------------------
    counter_0 : counter
        generic map ( G_BITS => 3 )
        port map (
            clk => clk,
            rst => rst,
            en  => sig_en,
            cnt => sig_digit
        );

    ------------------------------------------------------------------------
    -- Digit select
    ------------------------------------------------------------------------
    --sig_bin <= data(3 downto 0)  when sig_digit = "000" else
           --data(7 downto 4)  when sig_digit = "001" else
           --data(11 downto 8) when sig_digit = "010" else
           --data(15 downto 12);
    digit_select: process (sig_digit, data) is
    begin
        case sig_digit is
            when "000" => sig_bin <= data(3 downto 0);
            when "001" => sig_bin <= data(7 downto 4);
            when "010" => sig_bin <= data(11 downto 8);
            when "011" => sig_bin <= data(15 downto 12);
            when "100" => sig_bin <= data(19 downto 16);
            when "101" => sig_bin <= data(23 downto 20);
            when "110" => sig_bin <= data(27 downto 24);
            when "111" => sig_bin <= data(31 downto 28);
            when others => sig_bin <= (others => '0');
        end case;
    end process;

    -- DP
    dp <= dp_en(to_integer(unsigned(sig_digit)));
    ------------------------------------------------------------------------
    -- 7-segment decoder
    ------------------------------------------------------------------------
    decoder_0 : bin2seg
        port map (
            bin => sig_bin,
            seg => seg
        );

    ------------------------------------------------------------------------
    -- Anode select process
    ------------------------------------------------------------------------
    p_anode_select : process (sig_digit) is
    begin
        case sig_digit is
            when "000" =>
                anode <= "11111110";  -- digit 0
            when "001" =>
                anode <= "11111101";  -- digit 1
            when "010" =>
                anode <= "11111011";  -- digit 2
            when "011" =>
                anode <= "11110111";  -- digit 3
            when "100" =>
                anode <= "11101111";  -- digit 4
            when "101" =>
                anode <= "11011111";  -- digit 5
            when "110" =>
                anode <= "10111111";  -- digit 6
            when "111" =>
                anode <= "01111111";  -- digit 7
            when others =>
                anode <= "11111111";  -- All off
        end case;
    end process;

end Behavioral;