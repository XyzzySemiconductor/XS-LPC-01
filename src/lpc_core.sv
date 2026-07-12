// vim: ts=4:
// The LPC Core.
// Wrapped by chip specific warapepr (ie project.,v)
module lpc_core (
	// System
	input logic clk,
	input logic reset,
	// Digial Inputs
	input logic button,
	input logic interval_sw,
	input logic timeout_sw,
	input logic auto_sw,
	// Digial outputs
	output logic time_led,
	output logic fault_led,
	output logic run_led,
	output logic out_relay,
	// ADC/SPI Interface
	output logic adc_ncs,	// /cs to adc
	output logic adc_clk,	// shift clk to adc
	output logic adc_din,  // shift data input to adc
	 input logic adc_dout // shift data output from adc
);

endmodule
	
