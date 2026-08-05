// vim: ts=4:
/*
 * Copyright (c) 2024 Your Name
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

module tt_um_pump_out(
    input  wire [7:0] ui_in,    // Dedicated inputs
    output wire [7:0] uo_out,   // Dedicated outputs
    input  wire [7:0] uio_in,   // IOs: Input path
    output wire [7:0] uio_out,  // IOs: Output path
    output wire [7:0] uio_oe,   // IOs: Enable path (active high: 0=input, 1=output)
    input  wire       ena,      // always 1 when the design is powered, so you can ignore it
    input  wire       clk,      // clock
    input  wire       rst_n     // reset_n - low to reset
);

  // All output pins must be assigned. If not used, assign to 0.
  assign uo_out[7] = 0; 
  //assign uio_out = 0;
  assign uio_oe  = 0;

  // List all unused inputs to prevent warnings
  wire _unused = &{ena, uio_in, ui_in[7:5], 1'b0};

	// I/O Regs in this layer
 
	wire ncs_io, clk_io, mosi_io;
	reg ncs_reg, clk_reg, mosi_reg;
	reg miso_io; 
	always @(posedge clk) ncs_reg <= ncs_io;
	always @(posedge clk) clk_reg <= clk_io;
	always @(posedge clk) mosi_reg<= mosi_io;
	always @(posedge clk) miso_io <= ui_in[0]; 
	assign uo_out[0] = ncs_reg;
	assign uo_out[1] = clk_reg;	
	assign uo_out[2] = mosi_reg;	
	
	// Instantate and connect core logic to the TT I/O

	localparam REALTIME = 3750;
	assign uio_out[7:0] = ( REALTIME >> 4 ); // So we can check it in TB
	lpc_core #(
		.NUM_SAMPLE( REALTIME )  // TT Is always real time 3750
	) i_core (
		// System
		.clk		( clk  ),
		.reset 		( !rst_n ),
		// Fpga monitors 
		.fpga_probe ( ),
		.fpga_probe2( ),
		// Dig IO
		.button		( ui_in[1]  ),
		.setup_sw	( ui_in[4]  ),
		.period_sw	( ui_in[2]  ),
		.timeout_sw	( ui_in[3]  ),
		.time_led	( uo_out[3] ),
		.fault_led	( uo_out[4] ),
		.run_led		( uo_out[5] ),
		.pump_out	( uo_out[6] ),
		// ADC Interface
		.adc_ncs    ( ncs_io ),
		.adc_clk		( clk_io ),
		.adc_mosi	( mosi_io ),
		.adc_miso	( miso_io  )
	);

  
endmodule
