#### MAX10 FPGA use

A max10 fpga is mounted on a PCB with a emualtor footprint, and HDMI connector.
This fpga is used to bring up a new chip. It provides 4 fold functionallity useful for chip
development, PCB bringup, chip bringup, and manufacturing chip testing.

    - Simulation: Acceleration simulation by combining the Chip, System Simulator, and HDMI Monitor
    - Emulator: Emulate the chip by combining the chip and the HDMI Monitor
    - Monitor: Monitor the pins of a running chip and display on HDMI Monitor (decode ADC, probes)
    - Tester: Test chips by combining a system simulator and HDMI Monitor

