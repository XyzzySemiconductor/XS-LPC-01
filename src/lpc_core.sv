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
   	// Physical parameters


	// TT tie-off (to be removed)
	reg [15:0] xstate;
	always_ff @(posedge clk) 
		xstate <= ( reset ) ? 0 : xstate + &{ clk, reset, button, period_sw, timeout_sw, setup_sw, adc_miso };
	assign { time_led, fault_led, run_led, pump_out } = xstate;
    
	////////////////
    // ADC inteface
	////////////////

	// ADC serial interface
	logic sdata, schan, sdval, sstrb;
	adc_spi_master i_adcif (
    	// Input clock,
    	.clk	( clk ),
    	.reset	( reset ),
    	// External A/D Converter 
    	// Assumed 1 external I/O reg on each.
    	.ad_ncs	( adc_ncs ),
    	.ad_clk	( adc_clk ),
    	.ad_mosi( adc_mosi ),
    	.ad_miso( adc_miso ),
    	// ADC monitor outputs
    	.dout( sdata ), // serial output
    	.chan( schan ), // Indicate chan 0 or 1
    	.dval( sdval ), // Indicates valid bit 
    	.strb( sstrb ) // indicates start of channel 
	);

	// Test shift registers
	logic [11:0] sreg, data0, data1;
	always_ff @(posedge clk) begin
		sreg <= (reset)?0:(sdval)?{sreg[10:0],sdata}:sreg;
		data0 <= (reset)?0:(sstrb&&schan)?sreg:data0;
		data1 <= (reset)?0:(sstrb&&!schan)?sreg:data1;
	end

	////////////////
	// Debounce
	////////////////
	
	logic button_debounce; 
	logic long_button;
	forge_debounce #(48) i_bounc(.clk(clk),.reset(reset),.in(button),.out(button_debounce),.long(long_button));

	////////////////
    // 60Hz Coric 
	////////////////
	
	// TODO tighten this down

    logic [15:0] angle;
    logic [15:0] sin_out, cos_out;
    logic valid, busy, strobe;

`define USE_CORDIC
`ifdef USE_CORDIC
    cordic_sincos_50000_core_20 i_cordic(
        .clk( clk ),
        .rst( reset ),
        .start( strobe ),
        .angle_in( angle ),
        .sin_out ( sin_out ),
        .cos_out ( cos_out ),
        .valid( valid ),
        .busy( busy )
    );
`endif
	// Strobe to advance 
	logic [11:0] strb_cnt;
	always @(posedge clk) begin
		strb_cnt <= ( reset || strb_cnt == 3199 ) ? 0 : strb_cnt + 1;
		strobe   <= ( strb_cnt == 3199 ) ? 1'b1 : 1'b0;
	end

    // Count angle every start pulse (-25000 to 24999 )
    // at 3Mhz (48Mhz/16) this gives us exactly 60 Hz grid freq
	// with an advance of strobe of 3200 cycles, and advance of 200 gives 60Hz
	// TODO make sure to reduce this logic

    reg polarity;
    reg pdir;
    always @(posedge clk) begin
        if( reset ) begin
            angle <= 12500;
            polarity <= 0;
            pdir <= 0;
        end else begin
            if( strobe ) begin
                angle <= angle + (( pdir ) ? 200 : -200);
                polarity <= ( angle == 12499 && pdir == 1 ) ? ~polarity : polarity;
                pdir <= ( pdir == 0 && angle == 1 ) ? 1 : ( pdir == 1 && angle == 12499 ) ? 0 : pdir;
            end
        end
    end
   // Multiply cos by 3: to nicely fill dynamic range
    wire signed [11:0] cos3x;
    wire signed [11:0] sin3x;

`ifdef USE_CORDIC
    assign cos3x = cos_out[15-:12] + ( cos_out[15-:12] >>> 1 );
    assign sin3x = sin_out[15-:12] + ( sin_out[15-:12] >>> 1 );
`endif

//`define MAKE_ROM
`ifdef MAKE_ROM
    /////////////////////
    // Build a rom
    reg [8:0] cos_rom[31:0];
    initial for( int ii = 0; ii < 32; ii++ )
        cos_rom[ii] <= 12'sd0;
    reg [15:0] prev_angle;
    always @(posedge clk) begin
        prev_angle <= angle;
        if( strobe && !angle[15] )
            if( prev_angle[8:0] == (1<<8) )  cos_rom[prev_angle[13-:5]] <= cos3x[10:2];
    end
    always @(posedge clk) begin
        if( strobe && angle == 100 && pdir == 1 && polarity == 0 )
            for( int ii = 0; ii < 32; ii++ )
            $display("cos_rom[%0d] = 9'd%0d;", ii, cos_rom[ii] );
    end
    ///////////////////
`endif

`ifndef USE_CORDIC // if not cordic, then ROM
    reg [8:0] cos_rom [31:0];
    initial begin
cos_rom[0] = 9'd385;
cos_rom[1] = 9'd384;
cos_rom[2] = 9'd380;
cos_rom[3] = 9'd375;
cos_rom[4] = 9'd369;
cos_rom[5] = 9'd361;
cos_rom[6] = 9'd352;
cos_rom[7] = 9'd341;
cos_rom[8] = 9'd329;
cos_rom[9] = 9'd315;
cos_rom[10] = 9'd300;
cos_rom[11] = 9'd284;
cos_rom[12] = 9'd267;
cos_rom[13] = 9'd249;
cos_rom[14] = 9'd229;
cos_rom[15] = 9'd209;
cos_rom[16] = 9'd187;
cos_rom[17] = 9'd166;
cos_rom[18] = 9'd143;
cos_rom[19] = 9'd119;
cos_rom[20] = 9'd96;
cos_rom[21] = 9'd72;
cos_rom[22] = 9'd47;
cos_rom[23] = 9'd22;
cos_rom[24] = 9'd0;
cos_rom[25] = 9'dx;
cos_rom[26] = 9'dx;
cos_rom[27] = 9'dx;
cos_rom[28] = 9'dx;
cos_rom[29] = 9'dx;
cos_rom[30] = 9'dx;
cos_rom[31] = 9'dx;
    end
    assign valid = 1;
    wire [8:0] read;
    assign read = cos_rom[angle[13-:5]];
    assign cos3x = { 1'b0, read, 2'b00 };
`endif // ROM not CORDIC

    // Correct Polarity (just negate)
    reg signed [11:0] sin, cos;
    always @(posedge clk) begin
        if( reset ) begin
            sin<= 0;
            cos<= 0;
        end else if( valid ) begin
            sin   <= ( polarity ) ? ~sin3x : sin3x; // use cos as it aligns with polarity
            cos   <= ( polarity ) ? ~cos3x : cos3x; // use cos as it aligns with polarity
        end
    end

	////////////////
    // RMS Compute
	////////////////
	
	// input: sin, cos, sdata
	// output: rms
	// Core funtion is word serial multiply accumulate with 1 or 4 acc registers

	// SregA: Multiplier (bit-serial operand) for squaring (SHFIT up), 
    //    or  Multiplicand (Cos), for accumulation multiplyt (shift >>> each cyccle)
	// SregB: Multiplicand (word operand, shifted >>> each cycle)
	// sign: sign multipler from 1st bit from ADC or when SregA is loaded for multiply
	// 0: acc_ct_sin[36]: Partial product accumulator for CT*sin
	// 1: acc_ct_cos[36]: Partial product accumulator for CT*cos
	// 2: acc_ref_sin[36]: Partial product accumulator for Ref*sin
	// 3: acc_ref_cos[36]: Partial product accumulator for Ref*cos

	// Regisers
	logic [35:0] acc_ct_sin;
	logic [35:0] acc_ct_cos;
	logic [35:0] acc_ref_sin;
	logic [35:0] acc_ref_cos;
	logic sign;
	logic [22:0] srega;
	logic [22:0] sregb;

	// data path Controls
	logic ld_sq;  // Load the square to start (loads srega, sregb, sign)
	logic [1:0] addr; // Current accumulator
	logic ld_sign;	// On the first bit from adc load the sign (msb)
	logic ld_trig;	// load srega = sin, sregb = cos
	logic shr_a, shr_b, shl_a; // control shift on multplier arguments
	logic adc_src; // select acd as input
	logic sel_a; // select a (sin) as mutliplicand this cyclew, else b (cos)
	logic sclr; // clear addressed acc this cycle (if wr_acc = 1)
	logic wr_acc; // write acc this cycle

	// Select multiplier bit
	logic mult_bit;
	assign mult_bit = ( adc_src ) ? sdata : srega[22];
	
	// Acc read mux:
	wire [35:0] read_data;
	assign read_data = ( addr == 0 ) ? acc_ct_sin :
                       ( addr == 1 ) ? acc_ct_cos :
                       ( addr == 2 ) ? acc_ref_sin :
                       /*addr == 3*/   acc_ref_cos ;

	// Sign register
	always @(posedge clk) 
		sign <= ( reset ) ? 0 :
				( ld_sign ) ? mult_bit : sign;

	// Srega/b
	always @(posedge clk) 
		sregb <= ( reset ) ? 0 :
				 ( ld_sq ) ? { read_data[35-:12], 11'h000 } : 
				 ( ld_trig ) ? { cos[11:0], 11'h000 } :
				 ( shr_b  ) ? { sregb[22], sregb[22:1] } : // >>>
							 sregb;
	always @(posedge clk) 
		srega <= ( reset ) ? 0 :
				 ( ld_sq ) ? { read_data[35-:12], 11'h000 } : 
				 ( ld_trig)? { sin[11:0], 11'h000 } :
				 ( shr_a ) ? { srega[22], srega[22:1] } : // >>>
				 ( shl_a ) ? { srega[21:0], 1'b0 } : // <<<
							   srega;

	// word addition
	logic signed [35:0] suma, sumb, sum;
	assign suma = read_data;
	assign sumb = ( !mult_bit ) ? 0 : ( sel_a ) ? srega : sregb;
	assign sum  = ( sclr ) ? 0 : 
                  ( sign ) ? suma - sumb : suma + sumb;
	
	// Accumulators
	always_ff @(posedge clk) begin
		acc_ct_sin <= ( reset ) ? 0 : ( wr_acc && addr == 0 ) ? sum : acc_ct_sin;
		acc_ct_cos <= ( reset ) ? 0 : ( wr_acc && addr == 0 ) ? sum : acc_ct_cos;
		acc_ref_sin<= ( reset ) ? 0 : ( wr_acc && addr == 0 ) ? sum : acc_ref_sin;
		acc_ref_cos<= ( reset ) ? 0 : ( wr_acc && addr == 0 ) ? sum : acc_ref_cos;
	end

	// RMS COntrol Logic
	// For ADC MSB first bit procesing,
	//  If this is the start clear all accumulators
	//  11: load into sign register
	//  10-0: 2 cycles acc_n adc bit * srega --> acc, then adc bit * sregb, then >>> srega and sregb
    // For squaring 
	// do CT RMS^s by acc0 = acc0^2+acc1^2
	//  load acc0 into srega, b, and sign, and simultaneously clear acc0
    //  for 10-0 acc0 accumulate and srega <<, and sregb >>>, then next
	//  load acc1 into srega, b, and sign
    //  for 10-0 acc0 accumulate and srega <<, and sregb >>>, then next
	// do Ref RMS^s by acc2 = acc2^2+acc3^2
	// give output strobe, RMS CT = acc0[23:0], RMS Reg = acc2[23:0]


	////////////////
    // LPC Control
	////////////////

	// 24hr/6hr period timer

	// With increasingb breathing rate LED

	// Over Current Logic

	// Low Current Logic

	// Timeout Logic

	// Pump Cycle Logic

	// Setup Mode

	
endmodule

module forge_debounce(
    input clk,
    input reset,
    input in,
    output out, // fixed pulse 15ms after 5ms pressure
    output long // after fire held for > 2/3 sec, until release
    );

    parameter CLOCK_FREQ_MHZ = 48;
    localparam CYC_PER_MS = CLOCK_FREQ_MHZ * 1000; // 1 Ms count time
    localparam CYC_LONG   = ( CLOCK_FREQ_MHZ * 2 / 3 ) * 'h100000;

    logic [25:0] count1 = 0; // total 1.3 sec
    logic [22:0] count0 = 0;
    logic [2:0] meta;
    logic       inm;


    always_ff @(posedge clk) { inm, meta } <= { meta, in };

    // State Machine    
    localparam S_IDLE       = 0;
    localparam S_WAIT_PRESS = 1;
    localparam S_WAIT_PULSE = 2;
    localparam S_WAIT_LONG  = 3;
    localparam S_LONG       = 4;
    localparam S_WAIT_OFF   = 5;
    localparam S_WAIT_LOFF  = 6;
    logic [2:0] state = S_IDLE;
    always_ff @(posedge clk) begin
        if( reset ) begin
            state <= S_IDLE;
        end else begin
            case( state )
                S_IDLE       :  state <= ( inm ) ? S_WAIT_PRESS : S_IDLE;
                S_WAIT_PRESS :  state <= (!inm ) ? S_IDLE       : (count1 == ( 5  * CYC_PER_MS )) ? S_WAIT_PULSE : S_WAIT_PRESS;    // 5 msec debounce on
                S_WAIT_PULSE :  state <=                          (count1 == ( 25 * CYC_PER_MS )) ? S_WAIT_LONG  : S_WAIT_PULSE;    // 25 msec pusle
                S_WAIT_LONG  :  state <= (!inm ) ? S_WAIT_OFF   : (count1 >=          CYC_LONG  ) ? S_LONG       : S_WAIT_LONG;         // 0.66 sec long
                S_LONG       :  state <= (!inm ) ? S_WAIT_LOFF  :  S_LONG;
                S_WAIT_OFF   :  state <= ( inm ) ? S_WAIT_LONG  : (count0 == ( 100 * CYC_PER_MS)) ? S_IDLE       : S_WAIT_OFF;      // 100 mses debounce off
                S_WAIT_LOFF  :  state <= ( inm ) ? S_LONG       : (count0 == ( 100 * CYC_PER_MS)) ? S_IDLE       : S_WAIT_LOFF;
                default: state <= S_IDLE;
            endcase
        end
    end

    assign out = (state == S_WAIT_PULSE) ? 1'b1 : 1'b0;
    assign long = (state == S_LONG || state == S_WAIT_LOFF) ? 1'b1 : 1'b0;

    // Counters
    always_ff @(posedge clk) begin
        if( reset ) begin
            count0 <= 0;
            count1 <= 0;
        end else begin
            count0 <= ( state == S_WAIT_OFF  ||
                        state == S_WAIT_LOFF ) ? (count0 + 1) : 0; // count when low waiting
            count1 <= ( state == S_IDLE      ) ? 0            : (count1 + 1);
        end
    end

endmodule




	
