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
	logic stick, sdata, schan, sdval, sstrb;
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
    	.tick( stick ), // sample cycle begin
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

	// Strobe to advance 3200 cycles
	logic strobe;
	logic [11:0] strb_cnt;
	always @(posedge clk) begin
		strb_cnt <= ( reset || strb_cnt == 3199 ) ? 0 : strb_cnt + 1;
		strobe   <= ( strb_cnt == 3199 ) ? 1'b1 : 1'b0;
	end

    // Count angle every start pulse (-12500 to 12300 step by 200 then back to -12500, 250 steps per cycle
    logic [15:0] angle;
    reg polarity;
    always @(posedge clk) begin
        if( reset ) begin
            angle <= -12500;
            polarity <= 1;
        end else begin
            if( strobe ) begin
                angle <= ( angle == 12300 ) ? -12500 : angle + 200;
                polarity <= ( angle == 12300 ) ? ~polarity : polarity;
            end
        end
    end

	// Coridc core
    logic [15:0] sin_out, cos_out;
    logic valid, busy;
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

   // Corect polarity
    wire [15:0] cos_pol, sin_pol;
    assign cos_pol = ( polarity ) ? ~cos_out : cos_out;
    assign sin_pol = ( polarity ) ? ~sin_out : sin_out;
    // scale 3/8 so peaks at +/-1544, about 75% full scale
    wire [11:0] cos3x, sin3x;
    assign cos3x = cos_pol[15-:12] + { cos_pol[15], cos_pol[15-:11] };
    assign sin3x = sin_pol[15-:12] + { sin_pol[15], sin_pol[15-:11] };

	// register sin/cos
    reg signed [11:0] sin, cos;
    always @(posedge clk) begin
		sin <= ( reset ) ? 0 : sin3x;
		cos <= ( reset ) ? 0 : cos3x;
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
	logic sload; // clear addressed acc this cycle (if wr_acc = 1)
	logic clr_acc; // clear the accumulators
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
				( ld_sign && adc_src ) ? sdata: 
				( ld_sign ) ? read_data[31] : sign;

	// Srega/b
	always @(posedge clk) 
		sregb <= ( reset ) ? 0 :
				 ( ld_sq ) ? { read_data[31-:12], 11'h000 } : 
				 ( ld_trig ) ? { cos[11:0], 11'h000 } :
				 ( shr_b  ) ? { sregb[22], sregb[22:1] } : // >>>
							 sregb;
	always @(posedge clk) 
		srega <= ( reset ) ? 0 :
				 ( ld_sq ) ? { read_data[31-:12], 11'h000 } : 
				 ( ld_trig)? { sin[11:0], 11'h000 } :
				 ( shr_a ) ? { srega[22], srega[22:1] } : // >>>
				 ( shl_a ) ? { srega[21:0], 1'b0 } : // <<<
							   srega;

	// word addition
	logic [22:0] src;
	assign src = ( sel_a ) ? srega : sregb;
	logic signed [35:0] suma, sumb, sum;
	assign suma = read_data;
	assign sumb = ( sload ) ? { {24{src[22]}},src[22-:12] } :
                  ( !(mult_bit^sign) ) ? 0 : { {13{src[22]}}, src };
	assign sum  = 
				  ( sclr & !sload ) ? 0 : 
                  ( sign ) ? suma - sumb : suma + sumb;
	
	// Accumulators
	always_ff @(posedge clk) begin
		acc_ct_sin <= ( reset ) ? 0 : ( clr_acc ) ? 0 : ( wr_acc && addr == 0 ) ? sum : acc_ct_sin;
		acc_ct_cos <= ( reset ) ? 0 : ( clr_acc ) ? 0 : ( wr_acc && addr == 1 ) ? sum : acc_ct_cos;
		acc_ref_sin<= ( reset ) ? 0 : ( clr_acc ) ? 0 : ( wr_acc && addr == 2 ) ? sum : acc_ref_sin;
		acc_ref_cos<= ( reset ) ? 0 : ( clr_acc ) ? 0 : ( wr_acc && addr == 3 ) ? sum : acc_ref_cos;
	end

	// RMS COntrol Logic
	// For ADC MSB first bit procesing,
	//  Sstrb: If this is the start clear all accumulators on
	//  bit11=0, --> sign = 0; bitt11=1 --> sign = 1 (subtract), adjust acc0-=srega, then acc1-=sregb
	//  10-0: 2 cycles acc_n adc bit * sign * srega --> acc0, then adc bit ^ sign * sregb --< acc1, then >>> srega and sregb
    // For squaring 
	// do CT RMS^s by acc0 = acc0^2+acc1^2
	//  sstrb: load acc0 into srega, b, and sign, and simultaneously init acc0 (!sign then 0, or if sign, acc0 <-- sregb)
    //  for 10-0 acc0 accumulate and srega <<, and sregb >>>, then next
	//  load acc1 into srega, b, and sign
    //  for 10-0 acc0 accumulate and srega <<, and sregb >>>, then next
	// do Ref RMS^s by acc2 = acc2^2+acc3^2
	// give output strobe, RMS CT = acc0[23:0], RMS Reg = acc2[23:0]

	// Keep track of ADC sample counts and classiffy each sample pair
	// 0: is start (clear) and first saple of accumulaiton
    // 1: is the normal accumulation
    // 2: is RMS^2 calc of CT
    // 3: is RMS^2 calc of Ref
	localparam NUM_CYC = 250 * 1;
	logic [11:0] sample_count;
	logic [1:0] stype; // 0:clear, 1:acc, 2:rms CT, 3:rms Ref
	always @(posedge clk) 
		sample_count <= ( reset ) ? (NUM_CYC+2-1) : 
						( !stick ) ? sample_count : 
						( sample_count == (NUM_CYC+2-1) ) ? 0 : sample_count + 1;
	assign stype = ( sample_count == 0 ) ? 0 :
				  ( sample_count == NUM_CYC ) ? 2 :
				  ( sample_count == NUM_CYC + 1) ? 3 : 1;
	
	// Detect first bit (MSB) from ADC (for each channel in turn)
	logic wait_1st, first_bit, rem_bit;
	always_ff @(posedge clk) 
		wait_1st <= ( reset ) ? 0 : ( sstrb ) ? 1 : ( sdval ) ? 0 : wait_1st;
	assign first_bit = wait_1st & sdval;
	assign rem_bit = sdval & !first_bit;
	// and delayed rem bit to give 4 cycle op after sign known
	logic del_rem, pre0, pre1;
	always_ff @(posedge clk) begin
		del_rem <= rem_bit;
		pre0 <= first_bit;
		pre1 <= pre0;
	end

	// Clear all Accs for stype=0
	always_comb begin
		case( stype ) 
			0 : begin // Initialize (zero) and ADC Accumulate
					// pre0 - if sign, pre-acc srega to acc[0]=0
					// pre1 - if sign, pre-acc sregb to acc[1]=1
					// Const
					shl_a = 0;
					sclr = 0;
					ld_sq = 0;
					adc_src = 1;
					sload = sign & ( pre0 | pre1 );
					addr[1] = schan;
					// Strobe, clear if stype == 0;
					clr_acc = ( sstrb && !schan && stype == 0 ) ? 1'b1 : 1'b0; // init accs at start
					// First Bit
					ld_trig = first_bit;
					ld_sign = first_bit;
					// Bit timed
					addr[0] = del_rem | pre1 ; // 0 then 1 -->  sin then cos
					wr_acc = rem_bit | del_rem | ( sign & ( pre0 | pre1 ) );
					sel_a = rem_bit | pre0;
					shr_a = rem_bit | pre0;
					shr_b = del_rem | pre1;
				end
			1 : begin // Normal ADC accumulate
					// pre0 - if sign, pre-acc srega to acc[0]=0
					// pre1 - if sign, pre-acc sregb to acc[1]=1
					// Const
					shl_a = 0;
					sclr = 0;
					ld_sq = 0;
					adc_src = 1;
					sload = sign & ( pre0 | pre1 );
					addr[1] = schan;
					clr_acc = 0;
					// First Bit
					ld_trig = first_bit;
					ld_sign = first_bit;
					// Bit timed
					addr[0] = del_rem | pre1 ; // 0 then 1 -->  sin then cos
					wr_acc = rem_bit | del_rem | ( sign & ( pre0 | pre1 ) );
					sel_a = rem_bit | pre0;
					shr_a = rem_bit | pre0;
					shr_b = del_rem | pre1;
				end
			2 : begin // Chan 0 RMS, save acc0, and clr acc0 then acc0 += acc0^2 then acc0 +=  acc1^2,
					// First - lo sregs, ld sign, if chan 0 then clr reg
					// pre0 - if sign, pre-acc srega/b to acc[0]=0 andshl a, and shr b
					// Const
					addr[1] = 0;
					sel_a = 0;
					clr_acc = 0;
					adc_src = 0;
					ld_trig = 0;
					shr_a = 0;
					// First Bit
					ld_sq = first_bit; // Load sregs from acc sum
					ld_sign = first_bit;
					addr[0] = schan & first_bit ; 
					sclr = first_bit & !schan; // Clear acc0
					// Bit Timed
					sload = sign & pre0;
					wr_acc = sclr | rem_bit | (sign & pre0);
					shl_a = rem_bit | pre0 ;
					shr_b = rem_bit | pre0 ;
				end
			3 : begin // chan 1 RMS same, but address the acc2, acc3 and RMS^2 = acc2
					// Const
					addr[1] = 1;
					sel_a = 0;
					clr_acc = 0;
					adc_src = 0;
					ld_trig = 0;
					shr_a = 0;
					// First Bit
					ld_sq = first_bit; // Load sregs from acc sum
					ld_sign = first_bit;
					addr[0] = schan & first_bit ; 
					sclr = first_bit & !schan; // Clear acc0
					// Bit Timed
					sload = sign & pre0;
					wr_acc = sclr | rem_bit | (sign & pre0);
					shl_a = rem_bit | pre0 ;
					shr_b = rem_bit | pre0 ;
				end
		endcase
	end

	// Strobe out calculated RMS
	logic rms_valid;
	logic [23:0] rms_ct, rms_ref;
	assign rms_ct  = acc_ct_sin[23:0];
	assign rms_ref = acc_ref_sin[23:0];
	assign rms_valid = ( stick && stype == 3 ) ? 1'b1 :1'b0;


	// Temp Registers
	logic [23:0] rms_hold_ct, rms_hold_ref;
	always_ff @(posedge clk) begin
		rms_hold_ct <= ( reset ) ? 0 : ( rms_valid ) ? rms_ct  : rms_hold_ct;
		rms_hold_ref<= ( reset ) ? 0 : ( rms_valid ) ? rms_ref : rms_hold_ref;
	end

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




	
