# FPGA I2C Thermostat Driver

This project implements a thermostatic driver using a **Nexys A7 Artix-7 50T** FPGA board. It reads temperature from the onboard **ADT7420** I²C sensor, displays it on 7-segment displays, and allows user interaction via push-buttons. The system controls heating and cooling outputs based on user-defined temperature setpoints, using LEDs to indicate whether heating or cooling is active. The design is written in VHDL, leveraging experience gained in bachelor-level courses at **Brno University of Technology**.

## Team members

- Lukáš Gajdík
- Zuzana Hubáčková
- Jakub Oselka

## Goals

✅ **Lab 1: Architecture.** Block diagram design, role assignment, Git initialization, `.xdc` file preparation.

✅ **Lab 2: Unit Design.** Development of individual modules, testbench simulation, Git updates.

✅ **Lab 3: Integration.** Merging modules into the Top-level entity, synthesis, and initial HW testing, Git updates.

✅ **Lab 4: Tuning.** Debugging, code optimization, and Git documentation.

 **Lab 5: Defense.** Completion, video demonstration of the functional device, poster presentation, and code review.

## Project Objectives

1. **Measure temperature** accurately using the ADT7420 sensor over I²C.
2. **Display temperature** in °C on a 4-digit 7-segment display.
3. **User interaction**:
    - Adjust temperature setpoint using buttons.
4. **Control logic**:
    - Activate heating or cooling outputs according to temperature and setpoint.
    - Indicate status with LEDs.
5. **Modular VHDL design**:
    - Debounced buttons.
    - I²C master module.
    - Temperature processing and unit conversion.
    - Control logic for thermostat operation.
    - 7-segment display driver with multiplexing.
6. **Reliable and synthesizable design** ready for FPGA implementation.

## Inputs and Outputs

| Port name | Direction | Type                           | Description                                        |
|:---------:|:---------:|:-------------------------------|:---------------------------------------------------|
| `clk`     |    in     | `std_logic`                    | System clock signal (100 MHz)                      |
| `btnu`    |    in     | `std_logic`                    | Increment button (increase setpoint)               |
| `btnd`    |    in     | `std_logic`                    | Decrement button (decrease setpoint)               |
| `btnc`    |    in     | `std_logic`                    | Reset button (center button)                       |
| `led16_r` |   out     | `std_logic`                    | Heating indicator (red LED)                        |
| `led16_b` |   out     | `std_logic`                    | Cooling indicator (blue LED)                       |
| `led16_g` |   out     | `std_logic`                    | System ready / in-range indicator (green LED)      |
| `seg`     |   out     | `std_logic_vector(6 downto 0)` | 7-segment display cathodes (CA–CG, active-low)     |
| `dp`      |   out     | `std_logic`                    | Decimal point (active-low)                         |
| `an`      |   out     | `std_logic_vector(7 downto 0)` | 7-segment display anodes (AN7–AN0, active-low)     |
| `TMP_SDA` |  inout    | `std_logic`                    | I²C serial data line (open-drain, needs pull-up)   |
| `TMP_SCL` |  inout    | `std_logic`                    | I²C serial clock line (open-drain, needs pull-up)  |

> **Note:** `TMP_SDA` and `TMP_SCL` are declared `inout` because I²C is an open-drain bus — the FPGA must both drive the line low and read it back for ACK detection and data reception. This is the only place `inout` appears; all internal components use separate `_oe` / `_in` logic.

## Block diagram

### Diagram of initial design

```mermaid

flowchart TD

    %% ── External I/O ──────────────────────────────────────────────
    CLK([clk])
    BTNC([btnc\nreset])
    BTNU([btnu\nup])
    BTND([btnd\ndown])
    I2C_BUS([ADT7420 sensor\nSDA / SCL])

    SEG([7-seg display\nseg / an / dp])
    LED([RGB LED\nled16 r/g/b])
    HEAT([heat_en])
    COOL([cool_en])

    %% ── Modules ───────────────────────────────────────────────────
    TOP["thermostat_top\n─────────────\nsync current_temp\nclamp logic\n[cite: 1, 12]"]

    subgraph UI ["ui_fsm (User Interface) [cite: 48, 49]"]
        CE["clk_en\n(G_MAX=10^7)\n[cite: 56, 82]"]
        DBU["debounce\n(up)\n[cite: 57, 83]"]
        DBD["debounce\n(down)\n[cite: 58]"]
        FSM["UI Logic\ntemp_reg: 55-395\n"]
    end

    subgraph SENS_GRP ["Sensor Subsystem"]
        SENS["adt7420_driver\n───────────────\nFSM Control\nFixed-pt: * 625 / 1000\n[cite: 101, 108]"]
        I2C["i2c_master\n──────────\nQuarter-period FSM\nOpen-drain OE\n[cite: 109, 210]"]
    end

    COMB["display_data_combiner\n─────────────────────\nBCD: hundreds/tens/ones\nUnit: C / F\n[cite: 162, 164]"]

    REG["temp_regulator\n──────────────\nHysteresis: 0.5°C\n[cite: 187, 188]"]

    DISP["display_driver\n──────────────\nRefresh Multiplexer\n[cite: 24, 25]"]

    %% ── Connections ─────────────────────────────────────────────
    CLK  --> TOP
    CLK  --> UI
    CLK  --> SENS
    CLK  --> DISP
    
    BTNC -->|reset| TOP
    BTNC -->|reset| UI
    BTNC -->|rst| SENS
    BTNC -->|rst| DISP

    %% ── UI Internal & External ────────────────────────────────────
    BTNU --> DBU
    BTND --> DBD
    CE   -->|ce 10Hz| FSM
    DBU  -->|press_up| FSM
    DBD  -->|press_down| FSM
    FSM  -->|teplota_out 12b| TOP

    %% ── Data Flow ───────────────────────────────────────────────
    TOP  -->|set_temp| COMB
    TOP  -->|set_temp| REG
    
    SENS -->|temp_10x| TOP
    TOP  -->|current_temp| COMB
    TOP  -->|current_temp| REG

    SENS <--> I2C
    I2C  <-->|SCL / SDA| I2C_BUS

    %% ── Output ────────────────────────────────────────────────────
    COMB -->|data_out 32b| DISP
    DISP -->|seg / anode / dp| SEG

    REG  -->|led_r/g/b| LED
    REG  -->|heat_en| HEAT
    REG  -->|cool_en| COOL

    %% ── Styles ────────────────────────────────────────────────────
    classDef io     fill:#E6F1FB,stroke:#185FA5,color:#0C447C
    classDef module fill:#EAF3DE,stroke:#3B6D11,color:#27500A
    classDef top    fill:#EEEDFE,stroke:#534AB7,color:#3C3489

    class CLK,BTNC,BTNU,BTND,I2C_BUS,SEG,LED,HEAT,COOL io
    class COMB,REG,DISP,UI,SENS,I2C module
    class TOP top

```

### Diagram of final design

![Diagram of final design](img/thermostat_top_diagram.png)

## VHDL FSM diagrams

### States of i2c_master

```mermaid
stateDiagram-v2
    [*] --> IDLE

    IDLE --> STRT : start_pending=1
    IDLE --> IDLE : otherwise

    STRT --> ADDR_S : after START condition

    ADDR_S --> ADDR_S : bit_idx != 0
    ADDR_S --> ADDR_ACK : bit_idx == 0

    ADDR_ACK --> DATA : always

    DATA --> DATA : bit_idx != 0
    DATA --> DATA_ACK : bit_idx == 0

    DATA_ACK --> STP : stop_on_done=1
    DATA_ACK --> IDLE : stop_on_done=0

    STP --> IDLE
```

### States of adt7420_driver

```mermaid
stateDiagram-v2
    [*] --> WAIT_1S

    WAIT_1S --> WAIT_1S : timer < 1s
    WAIT_1S --> SET_REG : timer done

    SET_REG --> WAIT_SET

    WAIT_SET --> WAIT_SET : m_busy=1
    WAIT_SET --> READ_MSB : m_busy=0 && start=0

    READ_MSB --> WAIT_MSB

    WAIT_MSB --> WAIT_MSB : m_busy=1
    WAIT_MSB --> READ_LSB : m_busy=0 && start=0

    READ_LSB --> WAIT_LSB

    WAIT_LSB --> WAIT_LSB : m_busy=1
    WAIT_LSB --> CALC : m_busy=0 && start=0

    CALC --> WAIT_1S
```

## Module descriptions

### `thermostat_top`
Top-level entity that wires all subsystems together. Instantiates the sensor reader, UI FSM, display combiner, display driver, and temperature regulator. Contains the only `inout` ports in the design (`TMP_SDA`, `TMP_SCL`) as required by the physical I²C bus. A synchronous process clamps the raw signed 16-bit temperature from the sensor into an unsigned 12-bit value (tenths of °C) for use by the display and regulator.

### `i2c_controller`
Basic I²C master FSM. An internal 7-bit counter divides the 100 MHz clock down to generate a bit clock (`running_clock`). The FSM advances on each rising edge of `running_clock` and sequences through START, address+R/W, data bytes, ACK/NAK, and STOP states. Open-drain operation is emulated via output-enable signals (`scl_oe`, `sda_oe`) rather than `inout` ports — '1' pulls the line low, '0' releases it to the pull-up resistor. Adapted from [aslak3/i2c-controller](https://github.com/aslak3/i2c-controller).

### `adt7420_reader`
Wrapper around `i2c_controller` that performs periodic temperature reads from the ADT7420 sensor. At startup it writes the configuration register (resolution selection). Then, every `READ_INTERVAL_MS` milliseconds, it executes a 5-trigger read sequence: address+W → pointer byte → RESTART+address+R → read MSB → read LSB. A separate combinational process converts the raw 16-bit two's-complement ADC value to tenths of °C (signed). Temperature is output as a 16-bit signed vector; `temp_valid` pulses high for one clock cycle per completed reading.

### `ui_fsm`
User-interface state machine for setpoint adjustment. Internally instantiates `clk_en` (10 Hz tick) and two `debounce` instances for the up/down buttons. A fast process latches 1-cycle button-press pulses between slow ticks. A slow process (gated by the 10 Hz CE) increments or decrements the integer setpoint register by 0.5 °C steps (5 in tenths-of-degree units), clamped to the range 5.5 °C – 39.5 °C. The 12-bit result is output as a `std_logic_vector`.

### `temp_regulator`
Purely combinational thermostat controller with hysteresis. Compares `current_temp` against `set_temp ± HYST` (HYST = 5, i.e. ±0.5 °C). Drives `led_red` and `heat_en` when heating is required, `led_blue` and `cool_en` when cooling is required, and `led_green` when the temperature is within the hysteresis band. No clock or reset — output changes immediately with inputs.

### `display_data_combiner`
Purely combinational BCD converter. Takes two 12-bit unsigned values (`set_temp` and `current_temp`, in tenths of °C) and packs them into a single 32-bit word for the display driver. Each value is split into hundreds, tens, and ones digits (4 bits each), with the lowest nibble fixed to `0xC` to display the letter "C" (degrees Celsius) on the rightmost digit of each group. Values above 999 are clamped.

### `display_driver`
Time-multiplexed 8-digit 7-segment display driver. Uses `clk_en` (800 kHz tick) and a 3-bit `counter` to cycle through the eight display positions. A combinational case statement selects the active 4-bit nibble from the 32-bit data word, passes it to `bin2seg` for segment decoding, and drives the corresponding anode low. Decimal-point output is taken directly from the matching bit of the `dp_en` mask.

### `bin2seg` (bi2seg)
Purely combinational 4-bit binary to 7-segment decoder. Covers hexadecimal digits 0–9, A–F with active-low segment outputs (a '0' turns a segment on). The special code `0xC` displays the letter "C" used for the Celsius unit indicator.

### `debounce`
Button debouncer with synchronizer. Samples the raw button input at 2 ms intervals via `clk_en`. Four consecutive equal samples are required before the debounced output changes state (shift-register majority filter). A one-cycle `btn_press` pulse is generated on the rising edge of the debounced output. A two-flip-flop input synchronizer prevents metastability.

### `clk_en`
Parameterizable clock-enable generator. Counts from 0 to `G_MAX − 1` and asserts `ce` for exactly one clock cycle when the count wraps, producing a periodic enable pulse. Used throughout the design to create lower-rate processes without generating additional clocks.

### `counter`
Generic N-bit synchronous up-counter with synchronous reset and clock-enable input. Counts from 0 to `2^G_BITS − 1` and wraps. Used inside `display_driver` to cycle through the 8 display digits.

## Simulations

![tb_clk_en-img](img/tb_img/tb_clk_en.png)
[tb_clk_en](thermostat/thermostat.srcs/sim_1/new/tb_clk_en.vhd)

---

![tb_bin2seg-img](img/tb_img/tb_bin2seg.png)
[tb_bin2seg](thermostat/thermostat.srcs/sim_1/new/tb_bin2seg.vhd)

---

![tb_debounce-img](img/tb_img/tb_debounce.png)
[tb_debounce](thermostat/thermostat.srcs/sim_1/new/tb_debounce.vhd)

---

![tb_display_data_combiner-img](img/tb_img/tb_display_data_combiner.png)
[tb_display_data_combiner](thermostat/thermostat.srcs/sim_1/new/tb_display_data_combiner.vhd)

---

![tb_temp_regulator-img](img/tb_img/tb_temp_regulator.png)
[tb_temp_regulator](thermostat/thermostat.srcs/sim_1/new/tb_temp_regulator.vhd)

---

![tb_ui_fsm-img](img/tb_img/tb_ui_fsm.png)
[tb_ui_fsm](thermostat/thermostat.srcs/sim_1/new/tb_ui_fsm.vhd)

---

![tb_display_driver-img](img/tb_img/tb_display_driver.png)
[tb_display_driver](thermostat/thermostat.srcs/sim_1/new/tb_display_driver.vhd)

---

![tb_counter-img](img/tb_img/tb_counter.png)
[tb_counter](thermostat/thermostat.srcs/sim_1/new/tb_counter.vhd)

---

![tb_adt7420-img](img/tb_img/tb_adt7420.png)
[tb_adt7420](thermostat/thermostat.srcs/sim_1/new/tb_adt7420.vhd)

---

> **Note:** A top-level integration testbench (`tb_thermostat_top`) was not completed — the I²C bus timing made cycle-accurate simulation impractical within the available time.

## Resource utilization

Post-synthesis results for target device **xc7a50ticsg324-1L** (Nexys A7-50T):

| Resource         | Used  | Available | Utilization |
|:-----------------|------:|----------:|------------:|
| Slice LUTs       | 1 736 |    32 600 |       5.33% |
| Slice Registers  |   247 |    65 200 |       0.38% |
| F7 Muxes         |    17 |    16 300 |       0.10% |
| F8 Muxes         |     6 |     8 150 |       0.07% |
| Block RAM        |     0 |        75 |       0.00% |
| DSP48E1          |     0 |       120 |       0.00% |

Post-implementation LUT count: **1 696** (5.20%).

## Demo video

> *Link will be added after the Lab 5 demonstration.*

## References

1. Analog Devices, *ADT7420 ±0.25°C Accuracy 16-Bit Digital I²C Temperature Sensor*, datasheet Rev. C. [Online]. Available: https://www.analog.com/media/en/technical-documentation/data-sheets/ADT7420.pdf
2. Digilent, *Nexys A7 Reference Manual*. [Online]. Available: https://digilent.com/reference/programmable-logic/nexys-a7/reference-manual
3. A. Slater, *i2c-controller — A simple I²C controller in VHDL*, GitHub. [Online]. Available: https://github.com/aslak3/i2c-controller *(used as the basis for `i2c_controller.vhd`)*
4. T. Fryza, *Digital Electronics 2 — Lab materials*, Brno University of Technology, 2026.
5. Digilent, *Nexys A7 Master XDC constraints file*, GitHub. [Online]. Available: https://github.com/Digilent/digilent-xdc
