// vim: ts=4:
/////////////////////////////////////////////////////////////
// Interface modules for MCP3202 12-bit spi adc.
/////////////////////////////////////////////////////////////
// 3 perspectives: Master, Monitor, Slave
// With these 3 blocks all anchored on the 4 I/O pins (spi)
// They are targetted at the LPC chip. They will be used for:
// emulation, monitoring, simlation fpga accelleration, 
// asic bist?, chip testers and verilator testbenches.
/////////////////////////////////////////////////////////////

// This is the master interface on chip, intended to talk to I/O pads
// Talks to the SPI ADC and strobes the data onto the bus
// Runs continuous. Alternating reads of channel 0, then channel 1, and repeat
// Sample rate is 15K each (total 30K). The ad_clk runs at 600Khzi. 40 ad_clk cycles to sample 0 and 1.
// Area is to be minimized. A bit serial (MSB) output is used
module adc_spi_master
(
	// Input clock,
	input wire clk,
	input wire reset,
	
	// External A/D Converter 
	// Assumed 1 external I/O reg on each.
	output logic ad_ncs,
	output logic ad_clk,
	output logic ad_mosi,
	input  logic ad_miso,
	
	// ADC monitor outputs
	output logic tick, // at very start of each 15kz sample cycle
	output logic dout, // serial output
	output logic chan, // Indicate chan 0 or 1
	output logic dval, // Indicates valid bit 
    output logic strb // indicates start next chan, chan valid, Coincident with dval tbd.
);
	// Parameters
	parameter CLK_FREQ_HZ 			= 48000000; // Our ref clk
	parameter SAMPLE_FREQ_HZ    	= 15000; // System selected
	parameter CYC_PER_SAMPLE 		= 3200; // CLK_FREQ_HZ / SAMPLE_FREQ_HZ;
	parameter ADC_CLK_HZ 			= 600000; // Device limited
	parameter ADC_CLK_PER_SAMPLE 	= 40; // ADC_CLK_HZ / SAMPLE_FREQ_HZ adc clk cycles to read inputs 0 and 1
	parameter CYC_PER_ADC_HALF_CYC 	= 40; // CLK_FREQ_HZ / ADC_CLK_HZ / 2
	parameter CYC_PER_ADC_CYC 		= 80; // CLK_FREQ_HZ / ADC_CLK_HZ 
	parameter HALF_ADC_CLK_PER_SAMPLE=80; // 2 * ADC_CLK_HZ / SAMPLE_FREQ_HZ adc clk cycles to read inputs 0 and 1

	// Half cycle Base rate (2x bitrate)
	logic half_cyc; // strobe
	logic [5:0] div_half;
	assign half_cyc = ( div_half == 39 ) ? 1'b1 : 1'b0;
	always_ff @(posedge clk) 
		div_half <= (reset)?0:(half_cyc)?0:div_half+1;

	// Sample period counter
	logic [6:0] count2x;
	always_ff @(posedge clk)
		count2x <= (reset)?0:(half_cyc && count2x== 79)?0:(half_cyc)?count2x+1:count2x;

	// Waves for SPI samplign cycle
	logic [0:39] ncs_wave, clk_wave, mosi_wave; 
	logic [0:39] samp_wave, chan_wave, strb_wave, tick_wave; 
	initial begin
		ncs_wave = 40'b1_0000_0_000000000000_1_0000_0_000000000000_1111;
		clk_wave = 40'b0_1111_1_111111111111_0_1111_1_111111111111_0000;
	    mosi_wave= 40'b0_1101_0_000000000000_0_1111_0_000000000000_0000;
		samp_wave= 40'b0_0000_0_111111111111_0_0000_0_111111111111_0000;	
		chan_wave= 40'b1_0000_0_000000000000_0_1111_1_111111111111_1111;	
		strb_wave= 40'b0_0010_0_000000000000_0_0010_0_000000000000_0000;	
		tick_wave= 40'b0_1000_0_000000000000_0_0000_0_000000000000_0000;	
	end
	logic ncs_reg , clk_reg , mosi_reg ; 
	logic samp_reg , chan_reg , strb_reg, tick_reg ; 
	always_ff @(posedge clk)  ncs_reg <=  ncs_wave[count2x[6:1]];
	always_ff @(posedge clk)  clk_reg <=  clk_wave[count2x[6:1]] & count2x[0]; // gated clk
	always_ff @(posedge clk) mosi_reg <= mosi_wave[count2x[6:1]];
	always_ff @(posedge clk) samp_reg <= samp_wave[count2x[6:1]] & !count2x[0] & half_cyc; // sample pulse
	always_ff @(posedge clk) chan_reg <= chan_wave[count2x[6:1]];
	always_ff @(posedge clk) strb_reg <= strb_wave[count2x[6:1]] & !count2x[0] & half_cyc; // chan stobe
	always_ff @(posedge clk) tick_reg <= tick_wave[count2x[6:1]] & !count2x[0] & half_cyc; // chan stobe

	// Connect up ADC outputs (should have ext regs)
	assign ad_ncs = ncs_reg;
	assign ad_clk = clk_reg;
	assign ad_mosi= mosi_reg;

	// Connect up ADC input (should have ext reg)
	logic data_reg;
	always_ff @(posedge clk) 
		data_reg <= (reset)?0:(samp_reg)?ad_miso:data_reg;

	// Connect up internal interface
	assign dout = data_reg;
	logic samp_del;
	always_ff @(posedge clk) 
		samp_del <= samp_reg;
	assign dval = samp_del;
	assign chan = chan_reg;
	assign strb = strb_reg;
	assign tick = tick_reg;

endmodule

// This the monitor interface. It can montitor internal or external interfaces
// The interface can be asychous. The interface is oversampled and decoded, with
// parallel 12 bit output. and valid strobe
// External registers for async crossing are assumed. Should use I/O regs for chip monitoring.
// Also use to monitor internal interfaced in the case of emulation or simulation.
module adc_spi_monitor
(
	// Input clock,
	input wire clk,
	input wire reset,
	
	// A/D Converter interface
	input  logic ad_ncs,
	input  logic ad_clk,
	input  logic ad_mosi,
	input  logic ad_miso,
	
	// ADC monitor outputs
	output logic [11:0] dout0, // parallel output
	output logic [11:0] dout1, // parallel output
    output logic strobe
);
	// Parameters
	parameter CLK_FREQ_HZ 			= 48000000; // Our ref clk
	parameter SAMPLE_FREQ_HZ    	= 15000; // System selected
	parameter CYC_PER_SAMPLE 		= 3200; // CLK_FREQ_HZ / SAMPLE_FREQ_HZ;
	parameter ADC_CLK_HZ 			= 600000; // Device limited
	parameter ADC_CLK_PER_SAMPLE 	= 40; // ADC_CLK_HZ / SAMPLE_FREQ_HZ adc clk cycles to read inputs 0 and 1
	parameter CYC_PER_ADC_HALF_CYC 	= 40; // CLK_FREQ_HZ / ADC_CLK_HZ / 2
	parameter CYC_PER_ADC_CYC 		= 80; // CLK_FREQ_HZ / ADC_CLK_HZ 
	parameter HALF_ADC_CLK_PER_SAMPLE=80; // 2 * ADC_CLK_HZ / SAMPLE_FREQ_HZ adc clk cycles to read inputs 0 and 1

	// How it works: (assume montonic transitions
	// waits for nCS to fall, then monitors the 17 clock rising edges following
	// 3rd edge indicates the channel, 6th throught 17th are the 12 data bits MSB first
	// Latch and hold the parallel data and as recevied chan0 and chan1, strobe on chan1 latching

	// detect edges
	logic ncs_del, ncs_fall;
	always_ff @(posedge clk) ncs_del <= ad_ncs;
	assign ncs_fall = !ad_ncs & ncs_del;
	logic clk_del, clk_rise;
	always_ff @(posedge clk) clk_del <= ad_clk;
	assign clk_rise = ad_clk & !clk_del;

	// Count the states
	// 0 is idle/ncs fall, 1-17 of clk rise after
	logic [4:0] state; 
	always_ff @(posedge clk) 
		state <= ( reset ) ? 0 : ( ncs_fall ) ? 0 : ( clk_rise && state < 17 ) ? state + 1 : state;
			
	// Latch the channel from mosi
	logic chan_reg;
	always_ff @(posedge clk) 
		chan_reg <= ( reset ) ? 0 : ( clk_rise && state == 2 ) ? ad_mosi : chan_reg;

	// Shift in the data from miso, MSB first
	logic [11:0] in_reg;
	always_ff @(posedge clk) 
		in_reg <= ( reset ) ? 0 : ( clk_rise ) ? { in_reg[10:0], ad_miso } : in_reg;

	// Wait 1 clk after loading last bit
	logic del_last;
	always_ff @(posedge clk) 
		del_last <= ( clk_rise && state == 16 ) ? 1'b1 : 1'b0;

	// After loading last bit, copy to correct data output reg
	always_ff @(posedge clk) begin
		dout0 <= ( reset ) ? 0 : ( chan_reg == 0 && del_last ) ? in_reg : dout0;
		dout1 <= ( reset ) ? 0 : ( chan_reg == 1 && del_last ) ? in_reg : dout1;
	end

	// Delay d1load to generate otuptu strobe
	always_ff @(posedge clk) 
		strobe <= ( chan_reg == 1 && del_last ) ? 1'b1 : 1'b0;
	
endmodule

// This is the simulated ADC (MCP3202), Not general purpose
// SImualted only enough to work for this applicaiton.
// Ideally Will be a part of any BIST logic, keep it small.
// It has input ports for the parallel 12 bit data ports (0, 1)
// The external interface may be asycnronous, however latency matters somewhat
// This interface assumes exactly 1 ff between the core and the chip pin (IO flop) for all 4 signals.
module adc_spi_simulate
(
	// Input clock,
	input wire clk,
	input wire reset,
	
	// A/D Converter spi interface
	// Assume 1 external I/O Flop per signal
	input  logic ad_ncs,
	input  logic ad_clk,
	input  logic ad_mosi,
	output logic ad_miso,
	
	// ADC simulation inteface
	input logic [11:0] din0,
	input logic [11:0] din1,
	output logic strb0, // din0 was sampled
	output logic strb1  // din1 was sampled
);
	// Parameters
	parameter CLK_FREQ_HZ 			= 48000000; // Our ref clk
	parameter SAMPLE_FREQ_HZ    	= 15000; // System selected
	parameter CYC_PER_SAMPLE 		= 3200; // CLK_FREQ_HZ / SAMPLE_FREQ_HZ;
	parameter ADC_CLK_HZ 			= 600000; // Device limited
	parameter ADC_CLK_PER_SAMPLE 	= 40; // ADC_CLK_HZ / SAMPLE_FREQ_HZ adc clk cycles to read inputs 0 and 1
	parameter CYC_PER_ADC_HALF_CYC 	= 40; // CLK_FREQ_HZ / ADC_CLK_HZ / 2
	parameter CYC_PER_ADC_CYC 		= 80; // CLK_FREQ_HZ / ADC_CLK_HZ 
	parameter HALF_ADC_CLK_PER_SAMPLE=80; // 2 * ADC_CLK_HZ / SAMPLE_FREQ_HZ adc clk cycles to read inputs 0 and 1

// This needs to behave like the adc istself as far as our master above needs
// when CS is high we output miso = 0;
// We watch for CS to fall, and can count clock rise edges, 
// sample the correct channel on the 3rd rise from mosi;
// on the falling clock after the 4th rise output miso 0,
// Then for the next 12 falling clocks shift output bitgs 11 to 0;
// output is set to 0 whenever CS is high.

	// detect edges
	logic ncs_del, ncs_fall;
	always_ff @(posedge clk) ncs_del <= ad_ncs;
	assign ncs_fall = !ad_ncs & ncs_del;
	logic clk_del, clk_rise, clk_fall;
	always_ff @(posedge clk) clk_del <= ad_clk;
	assign clk_rise = ad_clk & !clk_del;
	assign clk_fall = !ad_clk & clk_del;

	// Count the states
	// 0 is idle/ncs fall, 1-17 of clk rise after
	logic [4:0] state; 
	always_ff @(posedge clk) 
		state <= ( reset ) ? 0 : ( ncs_fall ) ? 0 : ( clk_rise && state < 17 ) ? state + 1 : state;

	// sreg load from chan, and shift out
	logic [12:0] sreg;
	always_ff @(posedge clk) 
		sreg <= ( reset ) ? 0 : ( ad_ncs ) ? 0 :
                                ( clk_rise && state == 2 && ad_mosi == 0 ) ? {1'b0, din0} :
		                        ( clk_rise && state == 2 && ad_mosi == 1 ) ? {1'b0, din1} :
								( clk_fall && state >= 5 ) ? { sreg[11:0], 1'b0 } : sreg;

	// assign output miso 
	assign ad_miso = sreg[12];

endmodule

