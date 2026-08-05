# SPDX-FileCopyrightText: © 2024 Tiny Tapeout
# SPDX-License-Identifier: Apache-2.0

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles


@cocotb.test()
async def test_project(dut):
    dut._log.info("Start")

    # Set the clock period to 48 MHz
    clock = Clock(dut.clk, 20832, unit="ps")
    cocotb.start_soon(clock.start())

    # Reset
    dut._log.info("Reset")
    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1

    dut._log.info("Test project behavior")

    # Set the input values you want to test
    # dut.ui_in.value = 20
    # dut.uio_in.value = 30

    # Wait for one clock cycle to see the output values
    assert dut.uio_out.value == (3750>>4)
    assert int(dut.user_project.i_core.rms_hold_ct.value) == 0
    assert int(dut.user_project.i_core.rms_hold_ct.value) == 0
    dut._log.info("60 Hz cycle")
    #await ClockCycles(dut.clk, 50000 * 16 + 3200 * 10 )
    await ClockCycles(dut.clk, 50000 * 16 * 16)
    # check RMS values
    assert int(dut.user_project.i_core.rms_hold_ct.value) < (1200*1200*3750)
    assert int(dut.user_project.i_core.rms_hold_ct.value) > (1000*1000*3750)
    assert int(dut.user_project.i_core.rms_hold_ref.value) < (600*600*3750)
    assert int(dut.user_project.i_core.rms_hold_ref.value) > (500*500*3750)

    # The following assersion is just an example of how to check the output values.
    # Change it to match the actual expected output of your module:
    #assert dut.uo_out.value == 50

    # Keep testing the module by changing the input values, waiting for
    # one or more clock cycles, and asserting the expected output values.
