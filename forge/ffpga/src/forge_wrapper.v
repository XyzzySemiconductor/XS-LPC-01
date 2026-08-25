// vim: ts=4:
// Top level forge FPGA
// Wraps the tiny_tapeout chip

(* top *) module forge_wrapper
(
// Forge FPGA built in clk reset

(* clkbuf_inhibit *) 	input wire clk,   // from PLL
						output wire osc_en,
// Inputs
	
//(* iopad_external_pin *)	input  logic arm_button,
(* iopad_external_pin *)	input  wire button,
(* iopad_external_pin *)	input  wire setup_sw,
(* iopad_external_pin *)	input  wire period_sw,
(* iopad_external_pin *)	input  wire timeout_sw,

	// Output
(* iopad_external_pin *)	output wire time_led,
(* iopad_external_pin *)	output wire fault_led,
(* iopad_external_pin *)	output wire run_led,
(* iopad_external_pin *)	output wire pump_out,
						output wire time_led_oe,
						output wire fault_led_oe,
						output wire run_led_oe,
						output wire pump_out_oe,
						
	// External A/D Converters (2.5v)
(* iopad_external_pin *)	output reg  adc_ncs,
(* iopad_external_pin *)	output reg	 adc_clk, 
(* iopad_external_pin *)	input  wire  adc_miso,
(* iopad_external_pin *)	output reg  adc_mosi,
						output wire  adc_ncs_oe,
						output wire	 adc_clk_oe, 
						output wire	 adc_mosi_oe, 
						
	// Forge PLL control
						output pll_en,
						output [5:0] pll_refdiv,
						output [11:0] pll_fbdiv,
						output [2:0] pll_postdiv1,
						output [2:0] pll_postdiv2,
						output pll_bypass,
						output pll_clk_selection,
    						input pll_lock
);

    // PLL Control, 50 Mhz int Osc Ref,  48 Mhz out
    assign pll_en = 1'b1;
    assign pll_refdiv = 6'b00_0001;		// Equivalent value in decimal form 6'd1,
    assign pll_fbdiv = 12'b0000_0001_1000;	// Equivalent value in decimal form 12'd24,
    assign pll_postdiv1 = 3'b101;		// Equivalent value in decimal form 3'd5,
    assign pll_postdiv2 = 3'b101;		// Equivalent value in decimal form 3'd5,
    assign pll_bypass = 1'b0;
    assign pll_clk_selection = 1'b0;

 
    // Enable OSC
    assign osc_en = 1'b1;
    
    // Emable GPIO Output OEs
    assign time_led_oe 		= 1'b1;
    assign fault_led_oe 		= 1'b1;
    assign run_led_oe 		= 1'b1;
    assign pump_out_oe 		= 1'b1;
    assign adc_ncs_oe 		= 1'b1;
    assign adc_clk_oe 		= 1'b1;
    assign adc_mosi_oe 		= 1'b1;
				
	// Create an internal reset 
	reg [7:0] rst_cnt = 0;
	reg reset = 1;
	initial reset = 1;
	initial rst_cnt = 0;
	always @(posedge clk) begin
		rst_cnt <= ( rst_cnt != 8'hff ) ? rst_cnt + 1 : rst_cnt;
		reset <= ( rst_cnt == 8'hff ) ? 1'b0 : 1'b1;
	end
		
	// Register ADC I/O
	wire ncs_io, clk_io, mosi_io;
	reg miso_io;
	always @(posedge clk) adc_ncs <= ncs_io;
	always @(posedge clk) adc_clk <= clk_io;
	always @(posedge clk) adc_mosi <= mosi_io;
	always @(posedge clk) miso_io <= adc_miso; 
	
	// PUMP Chip CORE emulation/test
    localparam REALTIME = 3750; // Must be 3750 for realtime!
  	lpc_core #(
        .NUM_SAMPLE( REALTIME )  // TT Is always real time 3750
    ) i_core (
		// System
		.clk			( clk ),
		.reset 		( reset ),
		// Dig IO
		.button		( button ),
		.setup_sw	( setup_sw ),
		.period_sw	( period_sw ),
		.timeout_sw	( timeout_sw ),
		.time_led	( time_led ),
		.fault_led	( fault_led ),
		.run_led		( run_led ),
		.pump_out	( pump_out ),
		// ADC Interface
		.adc_ncs    ( ncs_io ),
		.adc_clk		( clk_io ),
		.adc_mosi	( mosi_io ),
		.adc_miso	( miso_io )
	);


endmodule // forge_launcher_wrapper 