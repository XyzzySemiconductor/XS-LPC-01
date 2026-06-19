// vim: ts=4:
// Top level forge FPGA
// Wraps the tiny_tapeout chip
// Adds clocking and reset and wires up IO


module forge_wrapper ()
	// Instantiate tt chip I/Os
    wire [7:0] ui_in;    // Dedicated inputs
    wire [7:0] uo_out;   // Dedicated outputs
    wire [7:0] uio_in;   // IOs: Input path
    wire [7:0] uio_out;  // IOs: Output path
    wire [7:0] uio_oe;   // IOs: Enable path (active high: 0=input, 1=output)

	tt_um_60hz_load i_chip(
		.ui_in	( ui_in		),   // Dedicated inputs
		.uo_out	( uo_out	),   // Dedicated outputs
		.uio_in	( 8'h00		),   // IOs: Input path
		.uio_out( 			),   // IOs: Output path
		.uio_oe	( 			),   // IOs: Enable path (active high)
		.ena		( 1'b1	),   // always 1 when the design is powered
		.clk		( clk	),   // clock
		.rst_n  ( !reset 	)    // reset_n - low to reset
	);
endmodule

