# FPGA I2C Thermostat Driver

This project implements a thermostatic driver using a **Nexys A7 Artix-7 50T** FPGA board. It reads temperature from the onboard **ADT7420** I²C sensor, displays it on 7-segment displays, and allows user interaction via push-buttons. The system controls heating and cooling outputs based on user-defined temperature setpoints, using LEDs to indicate whether heating or cooling is active. The design is written in VHDL, leveraging experience gained in bachelor-level courses at **Brno University of Technology**.

## Team members

- Lukáš Gajdík
- Zuzana Hubáčková
- Jakub Oselka

## Goals

- **Lab 1: Architecture.** Block diagram design, role assignment, Git initialization, `.xdc` file preparation.

- **Lab 2: Unit Design.** Development of individual modules, testbench simulation, Git updates.

- **Lab 3: Integration.** Merging modules into the Top-level entity, synthesis, and initial HW testing, Git updates.

- **Lab 4: Tuning.** Debugging, code optimization, and Git documentation.

- **Lab 5: Defense.** Completion, video demonstration of the functional device, poster presentation, and code review.

## Project Objectives

1. **Measure temperature** accurately using the ADT7420 sensor over I²C.
2. **Display temperature** in °C or °F on a 4-digit 7-segment display.
3. **User interaction**:
    - Adjust temperature setpoint using buttons.
    - ??Switch between Celsius and Fahrenheit.??
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

## Diagram (work in progress)

![block diagram](block_diagram_v1.png)
