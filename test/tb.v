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
	// 60 Hz sin/cos cordic
  	/////////////////////

	// create /16 sample flag
	reg [3:0] sample_count;
	wire sample_flag;
	always @(posedge clk)
		sample_count <= ( !rst_n ) ? 0 : sample_count + 1;
	assign sample_flag = ( sample_count == 15 ) ? 1'b1 : 1'b0;
	
	// Create the -pi/2 to pi/2 angle sweep
    reg signed [15:0] angle;
    always @(posedge clk) begin
        if( !rst_n ) begin
            angle <= -12500;
        end else if ( sample_flag ) begin
            angle <= ( angle == 12499 ) ? -12500 : angle + 1;
        end
    end

	// create polarity correction
    reg polarity;
    always @(posedge clk) begin
        if( !rst_n ) begin
            polarity <= 1;
        end else if ( sample_flag ) begin
            polarity <= ( angle == 12499 ) ? !polarity : polarity;
        end
    end

	// Cordic 50K point = 2*PI
    wire [15:0] sin_out, cos_out;
    cordic_sincos_50000_core_20 i_tb_sin(
        .clk( clk ),
        .rst( !rst_n ),
        .start( sample_flag ),
        .angle_in( angle ),
        .sin_out ( sin_out ),
        .cos_out ( cos_out ),
        .valid( ),
        .busy( )
    );

	// Corect polarity
   	wire [15:0] cos_pol, sin_pol;
    assign cos_pol = ( polarity ) ? -cos_out : cos_out;
    assign sin_pol = ( polarity ) ? -sin_out : sin_out;
	// scale 3/8 so peaks at +/-1544, about 75% full scale
    wire [11:0] cos3x, sin3x;
    assign cos3x = cos_pol[15-:12] + { cos_pol[15], cos_pol[15-:11] };
    assign sin3x = sin_pol[15-:12] + { sin_pol[15], sin_pol[15-:11] };

  	/////////////////////
	// ADC device Simulation
  	/////////////////////

    wire [11:0] din0, din1;
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
        .din0( din0 ), // serial output
        .din1( din1 ), // serial output
        .strb0( sstrb0 ), // indicateds data sampled
        .strb1( sstrb1 ) 
    );

	assign din0 = cos3x;
	assign din1 = sin3x;

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
