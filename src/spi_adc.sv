// vim: ts=4:

// Talks to the SPI ADC and strobes the data onto the bus
module spi_adc_in
(
	// Input clock,
	input wire clk,
	input wire reset,
	
	// External A/D Converters (2.5v)
	output reg  ad_cs,
	input  wire  [1:0] ad_sdata,
	
	// ADC monitor outputs
	output wire [11:0] ad_out0,
	output wire [11:0] ad_out1,
	output reg ad_strobe
);

endmodule

