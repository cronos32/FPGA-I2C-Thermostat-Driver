# FPGA I2C Thermostat Driver

This project implements a thermostatic driver using a **Nexys A7 Artix-7 50T** FPGA board. It reads temperature from the onboard **ADT7420** I²C sensor, displays it on 7-segment displays, and allows user interaction via push-buttons. The system controls heating and cooling outputs based on user-defined temperature setpoints, using LEDs to indicate whether heating or cooling is active. The design is written in VHDL, leveraging experience gained in bachelor-level courses at **Brno University of Technology**.

## Team members

- Lukáš Gajdík
- Zuzana Hubáčková
- Jakub Oselka

## Goals

✅ **Lab 1: Architecture.** Block diagram design, role assignment, Git initialization, `.xdc` file preparation.

 **Lab 2: Unit Design.** Development of individual modules, testbench simulation, Git updates.

 **Lab 3: Integration.** Merging modules into the Top-level entity, synthesis, and initial HW testing, Git updates.

 **Lab 4: Tuning.** Debugging, code optimization, and Git documentation.

 **Lab 5: Defense.** Completion, video demonstration of the functional device, poster presentation, and code review.

## Project Objectives

1. **Measure temperature** accurately using the ADT7420 sensor over I²C.
2. **Display temperature** in °C a 4-digit 7-segment display.
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
| `clk`     |    in     | `std_logic`                    | System clock signal                                |
| `btnu`    |    in     | `std_logic`                    | Increment button (increase value)                  |
| `btnd`    |    in     | `std_logic`                    | Decrement button (decrease value)                  |
| `btnc`    |    in     | `std_logic`                    | Reset button (center button)                       |
| `led16_r` |   out     | `std_logic`                    | Heating indicator (red LED)                        |
| `led16_b` |   out     | `std_logic`                    | Cooling indicator (blue LED)                       |
| `led16_g` |   out     | `std_logic`                    | System ready indicator (green LED)                 |
| `seg`     |   out     | `std_logic_vector(6 downto 0)` | 7-segment display cathodes (CA–CG, active-low)     |
| `dp`      |   out     | `std_logic`                    | Decimal point (active-low)                         |
| `anode`   |   out     | `std_logic_vector(7 downto 0)` | 7-segment display anodes (AN7–AN0, active-low)     |
| `TMP_SDA` |  inout    | `std_logic`                    | I²C serial data line                               |
| `TMP_SCL` |   out     | `std_logic`                    | I²C serial clock line                              |

## Diagram (work in progress)

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
