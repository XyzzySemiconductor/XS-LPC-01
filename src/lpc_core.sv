// vim: ts=4:
// The LPC Core.
// Wrapped by chip specific warapepr (ie project.,v)
module lpc_core (
	// System
	input logic clk,
	input logic reset,
	// Digial Inputs
	input logic button,
	input logic period_sw,
	input logic timeout_sw,
	input logic setup_sw,
	// Digial outputs
	output logic time_led,
	output logic fault_led,
	output logic run_led,
	output logic pump_out,
	// ADC/SPI Interface
	output logic adc_ncs,	// /cs to adc
	output logic adc_clk,	// shift clk to adc
	output logic adc_mosi,  // shift data input to adc
	 input logic adc_miso 	// shift data output from adc
);

	reg [15:0] state;
	always_ff @(posedge clk) 
		state <= ( reset ) ? 0 : state + &{ clk, reset, button, period_sw, timeout_sw, setup_sw, adc_miso };
	assign { time_led,fault_led,run_led,pump_out,adc_ncs,adc_clk,adc_mosi } = state;
    

endmodule
	
