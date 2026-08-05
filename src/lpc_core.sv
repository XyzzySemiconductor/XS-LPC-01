// vim: ts=4:
// The LPC Core.
// Wrapped by chip specific warapepr (ie project.,v)
module lpc_core (
	// System
	input logic clk,
	input logic reset,
	// FPGA debug probes
	output logic [31:0] fpga_probe,
	output logic [31:0] fpga_probe2,
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
	parameter NUM_SAMPLE = 250 * 1; // samples to accumulate mult of 250 per 60hz cycle
	parameter MAX_RMS 	= 1103; 	// max RMS current

	// TT tie-off (to be removed)
	reg [15:0] xstate;
	always_ff @(posedge clk) 
		xstate <= ( reset ) ? 0 : xstate + &{ clk, reset, button, period_sw, timeout_sw, setup_sw, adc_miso };
	//assign { time_led, fault_led, run_led, pump_out } = xstate;
    
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
    	.dout( sdata ), // serial output, need to invert 1st/sign bit to get 2's comp
    	.chan( schan ), // Indicate chan 0 or 1
    	.dval( sdval ), // Indicates valid bit 
    	.strb( sstrb ) // indicates start of channel 
	);

	// Test shift registers, It should be removed during synth (I hope)
	logic [11:0] sreg, dp0, dp1, data0, data1;
	always_ff @(posedge clk) begin
		sreg <= (reset)?0:(sdval)?{sreg[10:0],sdata}:sreg;
		dp0 <= (reset)?0:(sstrb&& schan)?sreg:dp0;  
		dp1 <= (reset)?0:(sstrb&&!schan)?sreg:dp1;
	end
	assign data0 = 12'h800 ^ dp0;
	assign data1 = 12'h800 ^ dp1;
	

	////////////////
	// Debounce
	////////////////
	
	logic button_debounce; 
	forge_debounce #(48) i_bounc(.clk(clk),.reset(reset),.in(!button),.out(button_debounce),.out_pulse(),.long());

	////////////////
    // RMS Compute
	////////////////
	
	// SregA[12]: Multiplier (bit-serial operand) for squaring (SHFIT up), SD, shift in adc msb first
	// SregB[24]: Multiplicand (word operand, shifted >>> each cycle), shift in adc msb first
	// sign: sign multipler bit from ADC first bit
	// 0: acc_ct[36]: Partial product accumulator for CT*sin
	// 1: acc_ref[36]: Partial product accumulator for CT*cos

	// RMS Arch Data Registers
	logic signed [35:0] acc_ct;
	logic signed [35:0] acc_ref;
	logic sign;
	logic signed [22:0] srega;
	logic signed [22:0] sregb;

	// data path Controls
	logic wait_1st, first_bit, rem_bit;
	logic ld_sq;  	// shifts in teh ADC into srega and b
	logic ld_sign;	// On the first bit from adc load the sign (msb)
	logic addr; 	// Acc accumulator address
	logic shr_b, shl_a; // control shift on multplier arguments
	logic sload; 	// forced add
	logic clr_acc;  // clear all accumulators
	logic wr_acc; 	// write acc this cycle

	// Sign register
	always @(posedge clk) 
		sign <= ( reset ) ? 0 :
				( ld_sign ) ? (first_bit^sdata) : sign; // invert sign!!

	// Srega/b
	always @(posedge clk) 
		sregb <= ( reset  ) ? 0 :
				 ( ld_sq  ) ? { sregb[21-:11], (first_bit^sdata), 11'b0 } : 
				 ( shr_b  ) ? { sregb[22], sregb[22:1] } : // >>>
							    sregb;
	always @(posedge clk) 
		srega <= ( reset ) ? 0 :
				 ( ld_sq ) ? { srega[21-:11], (first_bit^sdata), 11'b0 } : 
				 ( shl_a ) ? { srega[21:0], 1'b0 } : // <<<
							   srega;

	// word addition
	logic signed [63:0] suma, sumb, sum;
	assign suma = ( addr == 0 ) ? acc_ct : acc_ref;
	assign sumb = ( sload ) ? { {24{sregb[22]}},sregb[22-:12] } :
                  ( !(srega[22]^sign) ) ? 0 : { {13{sregb[22]}}, sregb};
	assign sum  = ( sign ) ? suma - sumb : suma + sumb;
	
	// Accumulators
	always_ff @(posedge clk) begin
		acc_ct  <= ( reset ) ? 0 : ( clr_acc ) ? 0 : ( wr_acc && addr == 0 ) ? sum : acc_ct;
		acc_ref <= ( reset ) ? 0 : ( clr_acc ) ? 0 : ( wr_acc && addr == 1 ) ? sum : acc_ref;
	end

	// RMS COntrol Logic
	// Run along with adc sample bit arrival
	// clear accs at start of period
	// 12 bits shifted in from adc MSB first, stash first as sign
	// shift into upper 12 bits of srega and sregb
	// Post counter is normally 0, and is kicked into place teh cycle after the last bit arrived.
	// post12: For negative add sample to accumulator (selected by adc channel) give us the +1
	// post11..1: add sreg B conditonally to acc, and shift sreg a <<, and sreg b >>> 
	// A hight level controller is in charge of claering the accumulators every so often N * 250
	// to control understanding of the cycles I'll use a 5 bit state machine.
	// It will run each sample-pair cycle (15khz). chan 0 then chan 1.
	// state will increment per 12 bits input, and then self increment 12 more times, and then wait for the next cycle.
	
	// Sample Counting
	logic [11:0] sample_count;
	always @(posedge clk) 
		sample_count <= ( reset ) ? (NUM_SAMPLE-1) : 
						( !stick ) ? sample_count : 
						( sample_count == (NUM_SAMPLE-1) ) ? 0 : sample_count + 1;
	// high level system tick for sample based control
	logic win_tick;
	assign win_tick = ( stick && sample_count == NUM_SAMPLE-1 ) ? 1'b1 : 1'b0;
	
	
	// Detect first bit (MSB) from ADC (for each channel in turn)

	always_ff @(posedge clk) 
		wait_1st <= ( reset ) ? 0 : ( sstrb ) ? 1 : ( sdval ) ? 0 : wait_1st;
	assign first_bit = wait_1st & sdval;
	assign rem_bit = sdval & !first_bit;

	// State transition based control
	logic [4:0] state;
	always @(posedge clk) 
		state <= ( reset ) ? 0 :
				 ( sstrb && !schan ) ? 0 : // clear for each channel
				 ( state < 11 && ( first_bit || rem_bit )) ? state + 1 :
				 ( state == 11 && rem_bit ) ? 16 :
				 ( state == 27 ) ? 0 :
				 ( state >= 16 ) ? state + 1 : state;
				 

	// Clear all Accs for stype=0
	always_comb begin
		// Defaults on controls
		ld_sq = first_bit | rem_bit;// shifts in teh ADC into srega and b
		ld_sign = first_bit;// On the first bit from adc load the sign (msb)
		addr = schan; 		// Acc accumulator address
		clr_acc = win_tick;	// clear all accumulators
		// test state to drive square
		if( state == 16 ) begin
			shl_a = 1;
			shr_b = 1;
			sload = 1; // select the '+1' arg
			wr_acc = sign; // load '+1' if negative
		end else if( state > 16 && state < 28 ) begin
			shl_a = 1; // Keep shifint and condiitonally addign
			shr_b = 1;
			wr_acc = 1;
			sload = 0;
		end else begin
			// defulat
			shl_a = 0;
			shr_b = 0;
			sload = 0;
			wr_acc = 0;
		end
		// state should sit at 28 until done
	end

	// Do the rms compares
	logic ct_lt_ref;
	always @(posedge clk)
		ct_lt_ref <= ( acc_ct < acc_ref ) ? 1'b1 : 1'b0;

	logic ct_gt_max;
	always @(posedge clk)
		ct_gt_max <= ( acc_ct > NUM_SAMPLE * MAX_RMS * MAX_RMS ) ? 1'b1 : 1'b0;
	

	// Temp Registers
	logic [35:0] rms_hold_ct, rms_hold_ref;
	always_ff @(posedge clk) begin
		rms_hold_ct <= ( reset ) ? 0 : ( win_tick ) ? acc_ct  : rms_hold_ct;
		rms_hold_ref<= ( reset ) ? 0 : ( win_tick ) ? acc_ref : rms_hold_ref;
	end
	
	assign fpga_probe = rms_hold_ct[31-:32];  // FPGA debug only
	assign fpga_probe2 = rms_hold_ref[31-:32];  // FPGA debug only
	
	
	////////////////
    // LPC Control
	////////////////

	// 24hr period timer
	// assume 1/4 sec win_tick
	logic [18:0] win_cnt;
	always @(posedge clk)
		win_cnt <= 	( reset ) ? 0 : 
					( button_debounce || pump_out ) ? 0 : 
               ( win_tick && ( win_cnt == (19'h54600 - 1 ))) ? 0 : 
					( win_tick ) ? win_cnt + 1 : win_cnt;
	
	// Modulate life led based on 24hr countdown (fast as time gets closer)
	// Say pick the given Hz-ish range bit, ghiher and higher freq as the upper bits decrement
	always @(posedge clk)
		time_led <= ( reset ) ? 0 :
					( setup_sw ) ?  win_cnt[~win_cnt[18-:3]] : 
					( !setup_sw && win_tick ) ? !ct_lt_ref : time_led;
	
	// Over Current Logic
	// 4 sec 15amp
	// 16 consecutive samples over 15amps RMS
	// In auto mode triggers stop, latched until stops
	logic [3:0] ovl_cnt;
	always @(posedge clk) 
		ovl_cnt <= ( reset ) ? 0 : 
					( !pump_out ) ? 0 :
					( win_tick && !ct_gt_max ) ? 0 :
					( win_tick && ct_gt_max && ovl_cnt != 15 ) ? ovl_cnt + 1 : ovl_cnt;
	logic ovl_flag;
	always @(posedge clk) 
		ovl_flag <= ( reset ) ? 0 : 
					( !pump_out ) ? 0 :
					(  pump_out && ovl_cnt == 15 && win_tick ) ? 1 : ovl_flag;
	
	// Timeout Logic
	// timeout (3,6,12,24sec-ish), 
	// Set at start of auto cycle
	// count down win_ticks.
	// Signal end when done.

	logic [12:0] timesel;
	assign timesel = 	( period_sw && !timeout_sw ) ? 3*60*4 : // 3 min
							( period_sw &&  timeout_sw ) ? 6*60*4 : // 6 min
							(!period_sw && !timeout_sw ) ?12*60*4 : // 12 min
																	24*60*4 ; // 24 min

	logic [12:0] timeout_cnt;
	always @(posedge clk) 
		timeout_cnt <= ( reset ) ? 0 : 
					( !pump_out ) ? 0 :
					( win_tick && (timeout_cnt != timesel) ) ? timeout_cnt + 1 : timeout_cnt;

	logic timeout;
	always @(posedge clk) 
		timeout  <= ( reset ) ? 0 : 
					( !pump_out ) ? 0 :
					( win_tick && ( timeout_cnt == timesel )) ? 1 : timeout;

	// Low Current Logic
	// 2 cycles (1/2sec) of under current triggers auto mode stop
	logic ltref_last;
	always @(posedge clk) 
		ltref_last <= ( reset ) ? 0 : 
						( !pump_out ) ? 0 :
						 ( ct_lt_ref && win_tick ) ? 1 : ltref_last;
	logic ufl_flag;
	always @(posedge clk) 
		ufl_flag <= ( reset ) ? 0 : 
					( !pump_out ) ? 0 :
					( timeout_cnt >= 5 && ltref_last && ct_lt_ref && win_tick ) ? 1 : ufl_flag;
					
	// Short cycle / Empty fault
	// Pumped for too short of time (~4sec)
	// If we are not pumping at the 4 sec time after start. Its too short.
	
	logic short_cycle; // 
	always @(posedge clk) 
		short_cycle <= ( reset ) ? 0 :
							( !pump_out ) ? 0 :
							( pump_out && win_tick && timeout_cnt == 0 ) ? 1 : // assume it will be a short cycle
							( pump_out && win_tick && timeout_cnt >= 16 ) ? 0 : short_cycle; // runnign and Timeout_cnt >= 4 sec, means we're not short cycled
					
	// Pump Cycle Logic
	// first rule, pump led follows pump output, 
    // Pump output is always on if button is pressed
    // Pump output follows button in setup mode.
	// In automode it does the button or 24hr start, and stop
	// pump led is driven here.

	// Setup Mode
	// !setup_sw (active low)
	// In setup pump output is off when button is off
	// In setup the time/fault leds are wired compelemted to the compare.
	// TIme lights are  powered above

	// Fault state and LED:
	logic [1:0] fault;
	always @(posedge clk) 
		fault    <= ( reset ) ? 0 : 
					( pump_out ) ? 0 : // clear on pump on
					( fault == 0 && ovl_flag ) ? 2 : // over current
					( fault == 0 && timeout  ) ? 1  : // timeout
					( fault == 0 && short_cycle ) ? 3 : // Empty tank
								   fault;
	always @(posedge clk) 
		fault_led <= ( reset ) ? 0 : 
					( !setup_sw ) ? ((win_tick) ? ct_lt_ref : fault_led) :
					( pump_out ) ? 0 :
					( fault != 0 && win_cnt[2:0] == 0 || fault >= 2 && win_cnt[2:0] == 2 || fault == 3 && win_cnt[2:0] == 4 ) ? 1'b1 : 1'b0;

	// Auto mode
	// In auto pump output is (re)started by pressing the button or 24hr ellapse
	// In auto the pump remains on after button release.
 	// Turns off on low current (empty) (under current 1/2 sec), 
	// or overcurrent (15Amp 4 sec-ish
	// after finish the fault light signals last result run. blinks: 1-timeout, 2-overcurrent, none if low current (expected)
	
	// Auto start
	logic [1:0] auto;
	always @(posedge clk) 
		auto <= ( reset ) ? 0 : ( setup_sw && auto == 3 ) ? 3 : ( setup_sw ) ? auto + 1 : 0;
    
	// Pump Reg
	always @(posedge clk) 
		pump_out <= ( reset ) ? 0 :
					( button_debounce ) ? 1 : 
					( !setup_sw && !button_debounce ) ? 0 :
					( auto == 2 ) ? 1 : 
					( win_tick && ( win_cnt == (19'h54600 - 1 ))) ? 1 :
					( ovl_flag || ufl_flag || timeout ) ? 0 : pump_out; // short_cycle specifically not in this list!

	// Run Led follows pump output
	always @(posedge clk)
		run_led <= pump_out;

endmodule

module forge_debounce(
    input clk,
    input reset,
    input in,
    output out_pulse, // fixed pulse 15ms after 5ms pressure
	 output out, // Follow input with asymetric 5/100 debouncing
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

    assign out_pulse = (state == S_WAIT_PULSE) ? 1'b1 : 1'b0;
	 assign out = ( state != S_IDLE && state != S_WAIT_PRESS ) ? 1'b1 : 1'b0;
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




	
