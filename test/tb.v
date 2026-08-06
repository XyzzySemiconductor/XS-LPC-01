// vim: ts=4:
`default_nettype none
`timescale 1ns / 1ps

/* This testbench just instantiates the module and makes some convenient wires
   that can be driven / tested by the cocotb test.py.
*/
module tb ();

  // Dump the signals to a FST file. You can view it with gtkwave or surfer.
  initial begin
    $dumpfile("tb.fst");
    $dumpvars(0, tb);
    //#1;
  end

  // Wire up the inputs and outputs:
  reg clk;
  reg rst_n;
  reg ena;
  reg [7:0] ui_in;
  reg [7:0] uio_in;
  wire [7:0] uo_out;
  wire [7:0] uio_out;
  wire [7:0] uio_oe;
`ifdef GL_TEST
  wire VPWR = 1'b1;
  wire VGND = 1'b0;
`endif

	// Breakout the I/O
	wire ad_ncs, ad_mosi, ad_miso, ad_clk;
	assign ad_ncs = uo_out[0];
	assign ad_clk = uo_out[1];
	assign ad_mosi= uo_out[2];
	wire pump_out, time_led, fault_led, run_led;
	assign time_led = uo_out[3];
	assign fault_led= uo_out[4];
	assign run_led 	= uo_out[5];
	assign pump_out = uo_out[6];


  	// Replace tt_um_example with your module name:
  	tt_um_pump_out user_project (
`ifdef GL_TEST
      .VPWR(VPWR),
      .VGND(VGND),
`endif
      .ui_in  ({ui_in[7:1], ad_miso}),    // Dedicated inputs
      .uo_out (uo_out),   // Dedicated outputs
      .uio_in (uio_in),   // IOs: Input path
      .uio_out(uio_out),  // IOs: Output path
      .uio_oe (uio_oe),   // IOs: Enable path (active high: 0=input, 1=output)
      .ena    (ena),      // enable - goes high when design is selected
      .clk    (clk),      // clock
      .rst_n  (rst_n)     // not reset
  	);

  	//////////////////////
  	//////////////////////
	//
  	// ADC System Simulation
	//
  	/////////////////////
  	//////////////////////

	/////////////////////
	// Pump System Model
  	/////////////////////

	// 4 Hz (or 60 Hz for 15x faster that realtime
	reg [23:0] tick_cnt;
	always @(posedge clk) 
		tick_cnt <= ( !rst_n ) ? 0 : ( tick_cnt == (48000000 / 60) - 1 ) ? 0 : tick_cnt + 1;
	reg sys_tick;
	always_ff @(posedge clk) 
		//sys_tick <=  ( tick_cnt == (48000000 / 60) - 1 ) ? 1'b1 : 1'b0 ;	// 15x faster realtime
		sys_tick <=  ( tick_cnt == (48000000 / 4 ) - 1 ) ? 1'b1 : 1'b0 ; 	// Realtime

	wire signed [11:0] sys_ct;
	pump_model 
	#(
		.SP_STALL( 12'sd1024 ),	// >= 15 amps rms
		.SP_RUN  ( 12'sd666  ),	// typical 10 amps rms
		.SP_EMPTY( 12'sd500  ),	// empty say 9 amps rms
		.SP_OFF	 ( 12'sd100	 )		// Off still ac noise 0.1 amps rms
	) i_pump (
		// System
		.clk		( clk ),
		.reset		( !rst_n ),
		.fpga_probe ( ),
		.tick		( sys_tick ),// 250ms in sim step time. 
		.pump_out	( pump_out ),	// signal to turn on pump
		.ct			( sys_ct ),	// range +/-2000 is +/-30 Amps isntantaneous (typicaol 10Amp RMS = +/-15Amps
		.empty		( 1'b0 ), 	// change setpoint to empty current if not start current
		.stall		( 1'b1 ), 	// change to the stall current (or keep it in stall after start)
		.n_empty	( 1'b0 ) 	// change to the normal curretn (if not start current
	);	
	

  	/////////////////////
	// ADC device Simulation
  	/////////////////////

	wire sstrb0, sstrb1;
	
    adc_spi_simulate i_adc_sim (
        // Input clock,
        .clk    ( clk    ),
        .reset  ( !rst_n ),
        // External A/D Converter 
        .ad_ncs ( ad_ncs ),
        .ad_clk ( ad_clk ),
        .ad_mosi( ad_mosi ),
        .ad_miso( ad_miso ),
        // ADC monitor outputs
        .din0( sys_ct ), //din0 ), // serial output
        .din1( sys_ct>>>1 ), // serial output
        .strb0( sstrb0 ), // indicateds data sampled
        .strb1( sstrb1 ) 
    );


  	/////////////////////
	// ADC Monitor
  	/////////////////////

    wire [11:0] dout0, dout1;
	wire mstrobe;
    adc_spi_monitor i_adc_mon (
        // Input clock,
        .clk    ( clk    ),
        .reset  ( !rst_n ),
        // External A/D Converter 
        .ad_ncs ( ad_ncs ),
        .ad_clk ( ad_clk ),
        .ad_mosi( ad_mosi ),
        .ad_miso( ad_miso ),
        // ADC monitor outputs
        .dout0( dout0 ), // serial output
        .dout1( dout1 ), // serial output
        .strobe( mstrobe ) // indicates dout1 was updated
    );

endmodule
