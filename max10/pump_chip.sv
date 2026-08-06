// vim: ts=4:
`timescale 1ns / 1ps
module pump_chip

#(
	// Parameter Declarations
	parameter UNIQ_ID = 32'h0000_0000
)

(
	/////////////
	// LPC CHIP IO
	/////////////

	// Input Buttons
	//input  logic button, // pin 140

	// Output LED/SPK
	//output logic time_led, // pin 101
	//output logic fault_led, // pin 99
	//output logic run_led, // pin 100
	//output logic pump_out, // pin 124

	// External Current Control Input
	//input	 logic setup_sw,  // pin 62 
	//input  logic period_sw,  // pin 135
	//input  logic timeout_sw, // pin 66 

	// ADC I/O (spi)
	//output logic adc_ncs,  // pin 132
	//output logic adc_clk,  // pin 105
	//input  logic adc_miso, // pin 106
	//output logic adc_mosi, // pin 65 

	////////////
	// DEBUG IO
	////////////
	
	// Bank 1A: emualtor LEDs
	output [8:1] anain,
	
	// Bank 7, keypad input
	inout [6:0] digio,

	
	// SPI8 Bus, to PSRAM
	inout  wire [7:0]  spi8_data_pad,   //   pad_io.export
	inout  wire spi_clk0,
	inout  wire spi_ncs,
	inout  wire spi_ds,
	inout  wire spi_nrst,
	
	// HDMI Output (Tru LVDS)
	output logic		hdmi2_d0,
	output logic		hdmi2_d1,
	output logic		hdmi2_d2,
	output logic      hdmi2_ck,
	
	// Input clock, reset
	output logic clk_out, // Differential output
	input logic clk_in,	 // Reference 48Mhz or other
	input logic reset_n
);

	// all I/O is internally emulated in the code as we are a full simulation
	logic adc_ncs;   	// pin 132
	logic adc_clk;   	// pin 105
	logic adc_miso;  	// pin 106
	logic adc_mosi;  	// pin 65 
	logic setup_sw;  	// pin 62 
	logic period_sw; 	// pin 135
	logic timeout_sw;	// pin 66 
	logic button; 		// pin 140
	logic time_led; 	// pin 101
	logic fault_led; 	// pin 99
	logic run_led; 	// pin 100
	logic pump_out; 	// pin 124



	logic [4:0] key; // keypad, bit 4 indicates pressed

	// PLL (only 1 PLL in E144 package!)

	logic clk;	// global 48Mhz clock
	logic clk4; // global 192MhZ spi8 clk
	logic hdmi_clk; 	// Pixel clk, apparentlyi can support 720p
	logic hdmi_clk5;  // 5x pixel clk clock for data xmit, 10b*3=30/3lanes=10ddr=5 

	trial_pll _spll(
		.inclk0 (clk_in),		// External clock input
		.c0     (clk_out), 	// Flash Clock 6Mhz, also External clock output differential
		.c1	  (clk),			// Global Clock ADC rate 48 Mhz
		.c2	  (clk4),		// Global Clock SPI8 rate 192 Mhz
		.c3	  (hdmi_clk),	// HDMI pixel clk
		.c4	  (hdmi_clk5)  // HDMI ddr clock 5x
		);
		
	// delayed from fpga config and external reset d-assert

	logic [3:0] reset_shift = 0; // initial value upon config
	always @(posedge clk) begin
			if( !reset_n ) begin
				reset_shift <= 4'h0;
			end else begin
				if( reset_shift != 4'HF ) begin
					reset_shift[3:0] <= reset_shift[3:0] + 4'h1;
				end else begin
					reset_shift[3:0] <= reset_shift[3:0];
				end
			end
	end

	logic reset;
	assign reset = (reset_shift[3:0] != 4'hF) ? 1'b1 : 1'b0; // reset de-asserted after all bit shifted in 


	// AIN LED Display with counter
	assign anain[4:1] = ~{ time_led, fault_led, run_led, pump_out }; // active low leds

	logic [24:0] count;
	always @(posedge clk) begin
		count <= count + 1;
	end
	assign anain[8:5] = 3'b111; //count[24:21];


	/////////////////////////////////
	/////////////////////////////////
	////
	////  Pump Chip (DUT) 
	////
	/////////////////////////////////
	/////////////////////////////////

  // Fpga probes

	logic [31:0] fpga_probe;	
	logic [31:0] fpga_probe2;	
	logic [11:0] fpga_probe3;	
	

	// Register ADC I/O
		
	wire ncs_io, clk_io, mosi_io, miso_io; 
	always @(posedge clk) adc_ncs <= ncs_io;
	always @(posedge clk) adc_clk <= clk_io;
	always @(posedge clk) adc_mosi <= mosi_io;
	always @(posedge clk) miso_io <= adc_miso; 
	
	// PUMP Chip CORE emulation/test
	localparam NUM_SAMPLE = 3750;//250; // // 3750 is realtime, 250 is 15x realtime
	lpc_core #(
		.NUM_SAMPLE( NUM_SAMPLE ), 
		.MAX_RMS( 1103 ) // 15 amps
	) i_core (
		// System
		.clk			( clk ),
		.reset 		( reset ),
		.fpga_probe ( fpga_probe ),
		.fpga_probe2 ( fpga_probe2 ),
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

  	//////////////////////
  	//////////////////////
	//
  	// ADC System Simulation
	//
  	/////////////////////
  	//////////////////////

	logic [11:0] ref_in;
	/////////////
	// Sim Time
	/////////////
	
	// 4 Hz (or 60 Hz for 15x faster that realtime
	logic [23:0] tick_cnt;
	logic sys_tick;
	logic [19:0] time_cnt; // sim time count is count of tick's 

	always_ff @(posedge clk) 
		if( NUM_SAMPLE == 250 ) begin
			tick_cnt <= ( reset ) ? 0 : ( tick_cnt == (48000000 / 60) - 1 ) ? 0 : tick_cnt + 1;
			sys_tick <=  ( tick_cnt == (48000000 / 60) - 1 ) ? 1'b1 : 1'b0 ;	// 15x faster realtime
			time_cnt <= ( reset ) ? 0 : ( tick_cnt == (48000000 / 60) - 1 ) ? time_cnt + 1 : time_cnt;
		end else begin
			tick_cnt <= ( reset ) ? 0 : ( tick_cnt == (48000000 / 4) - 1 ) ? 0 : tick_cnt + 1;
		   sys_tick <=  ( tick_cnt == (48000000 / 4 ) - 1 ) ? 1'b1 : 1'b0 ; 	// Realtime	
			time_cnt <= ( reset ) ? 0 : ( tick_cnt == (48000000 / 4) - 1 ) ? time_cnt + 1 : time_cnt;
		end
	
	// Model Inputs
	logic empty, stall, n_empty;
	
	// Test Inputs driving.
	always_comb begin
		// Defaut Nominal, Test 1
		// ADC Inptu
		ref_in = 663; // 663 ~9A RMS
		// Chip Inputs
		button = 1;
		setup_sw = 1;
		period_sw  = 1; 
		timeout_sw = 0;  /// default 3 min
		// Model Inputs
		empty = 0;
		stall = 0;
		n_empty = 0;
		
		// Test 2, short cycle fault 
		//empty = 1; // observed 3 blink fault code
		
		// Test 3, timeout faults 
		//n_empty = 1; // observed 1 blink fault code (3min, 6min, 12min, 24min each tested)
		
		// Test 4, stall over current fault test
		//stall = 1; // Observed 2 blink fault code
		
		// Test 5: button restart
		//button = ( 	time_cnt == 'h40 ) ? 1'b0 : 1'b1;

		// Test 6: test sweep
		// serially test all features. except setup and 24hr
		//button = ( 								// Reset normal
		//				time_cnt == 'h80 ||	// Button normal
		//				time_cnt == 'h100 ||	// Button short cycle
		//				time_cnt == 'h180 ||	// Button over current
		//				time_cnt == 'h200 ||	// Timeout 3 min
		//				time_cnt == 'h600 ||	// Timeout 6 min
		//				time_cnt == 'hD00 ||	// timeout 12 min
		//				time_cnt == 'h1A00 ||// Timeout 24 min
		//				time_cnt == 'h3200 ||// Button Normal
		//				time_cnt == 'h3240 	// Wait 24hr, and be a over current
		//						) ? 1'b0 : 1'b1;
		//empty = ( time_cnt >= 'h100 && time_cnt < 'h180 ) ? 1'b1 : 1'b0;
		////stall = ( time_cnt >= 'hC0 && time_cnt < 'h200 || time_cnt >= 3240 ) ? 1'b1 : 1'b0;
		//stall = ( time_cnt >= 'h180 && time_cnt < 'h200 ) ? 1'b1 : 1'b0;
		//
		//n_empty 		= ( time_cnt >= 'h200  && time_cnt <'h3200 ) ? 1'b1 : 1'b0;
		//timeout_sw 	= ( time_cnt >= 'h200  && time_cnt <'h600 ||
		//				    time_cnt >= 'hD00  && time_cnt <'h1A00 ) ?1'b0 : 1'b1;
		//period_sw  	= ( time_cnt >= 'hD00  && time_cnt <'h3200 ) ?1'b0 : 1'b1;						  
		
		// Test 7 : setup, with ref ramp up/down while button pressed
		//button = ( time_cnt >= 1 && time_cnt < 80 ) ? 0 : 1;
		//ref_in = ( time_cnt >= 1 && time_cnt < 40 ) ? (time_cnt << 5) : 
		//         ( time_cnt >= 40 && time_cnt < 80 ) ? ((80-time_cnt)<<5) : 663;
		//setup_sw = 0;
		//n_empty = 1;
		
		//Test 8: 24hr test. 
		//Pump om power up, set it to timeout (3min)
		n_empty = ( time_cnt >= 'h40 ) ? 1 : 0;

		
	end
	

	
	
	
	/////////////////////
	// Pump System Model
  	/////////////////////



	logic signed [11:0] sys_ct;
	pump_model 
	#(
		.SP_STALL ( 12'sd1200  ),	// >= 15 amps rms (1103)
		.SP_RUN 	 ( 12'sd735   ),	// typical 10 amps rms (753)
		.SP_EMPTY ( 12'sd600   ),	// empty under 9 amps rms (663)
		.SP_OFF	 ( 12'sd7 	  )	// Off still ac noise 0.1 amps rms (7)
	) i_pump (
		// System
		.clk		( clk ),
		.reset	( reset ),
		.tick		( sys_tick ),// 250ms in sim step time. 
		.fpga_probe ( fpga_probe3 ),
		.pump_out( pump_out ),	// signal to turn on pump
		.ct		( sys_ct ),	// range +/-2000 is +/-30 Amps isntantaneous (typicaol 10Amp RMS = +/-15Amps
		.empty	( empty ), 	// change setpoint to empty current if not start current
		.stall	( stall ), 	// change to the stall current (or keep it in stall after start)
		.n_empty	( n_empty ) 	// change to the normal curretn (if not start current
	);	
	
	
	
  	/////////////////////
	// ADC device Simulation
  	/////////////////////


	wire sstrb0, sstrb1;
	
    adc_spi_simulate i_adc_sim (
        // Input clock,
        .clk    ( clk    ),
        .reset  ( reset ),
        // External A/D Converter 
        .ad_ncs ( adc_ncs ),
        .ad_clk ( adc_clk ),
        .ad_mosi( adc_mosi ),
        .ad_miso( adc_miso ),
        // ADC monitor outputs
        .din0( sys_ct ), // adc input signed for sim input
        .din1( ref_in ), // 663 for 9Amp
        .strb0( sstrb0 ), // indicateds data sampled
        .strb1( sstrb1 ) 
    );

  	/////////////////////
	// ADC Monitor
  	/////////////////////

    wire signed [11:0] dout0, dout1;
	 wire mstrobe;
    adc_spi_monitor i_adc_mon (
        // Input clock,
        .clk    ( clk    ),
        .reset  ( reset ),
        // External A/D Converter 
        .ad_ncs ( adc_ncs ),
        .ad_clk ( adc_clk ),
        .ad_mosi( adc_mosi ),
        .ad_miso( adc_miso ),
        // ADC monitor outputs
        .dout0( dout0 ), // signed for mon output
        .dout1( dout1 ), // signed for mon output
        .strobe( mstrobe ) // indicates dout1 was updated
    );
	
	//////////////////////////
	// RMS calc on Monitors
	//////////////////////////


	// Quick and large RMS
	logic [1:0][31:0] rms_sum;
	logic       [ 7:0] rms_count;
	logic [1:0][31:0] rms_hold;
	logic [1:0][23:0] rms_sq;
	assign rms_sq[0] = (( dout0[11] ) ? -dout0 : dout0) * (( dout0[11] ) ? -dout0 : dout0);
	assign rms_sq[1] = (( dout1[11] ) ? -dout1 : dout1) * (( dout1[11] ) ? -dout1 : dout1);
	always @(posedge clk) begin
		if( reset ) begin
				rms_sum <= 0;
				rms_count <= 0;
				rms_hold <= 0;
		end else begin
			if( mstrobe ) begin
				rms_count   <= (rms_count == 249) ? 0 : rms_count + 1;
				rms_sum[0] 	<= (rms_count == 249) ? rms_sq[0] : rms_sq[0] + rms_sum[0]; 
				rms_sum[1] 	<= (rms_count == 249) ? rms_sq[1] : rms_sq[1] + rms_sum[1]; 
				rms_hold[0] <= (rms_count == 249) ? rms_sum[0] : rms_hold[0];
				rms_hold[1] <= (rms_count == 249) ? rms_sum[1] : rms_hold[1];
			end
		end
	end

	
	// Scope monitor probes 
	logic signed [4:0][11:0] probe;
	assign probe[0] = dout0;	// pump ct wave
	assign probe[1] = dout1;	// Ref
	assign probe[2] = rms_hold[0][30-:12]; // RMS^2
	assign probe[3] = rms_hold[1][30-:12];
	assign probe[4] = fpga_probe3; //dout0 >>> 1; probe3 is the model's live Scale factor, about 50% is 1:1

	
	//////////////////////////////
	//////////////////////////////
	//
   // HDMI Scope Probes
	//
	//////////////////////////////
	//////////////////////////////

	// Scope capture 8bits of digitial and 5 analog (12bit) inputs for each strobe.
	// This data is packed into 8bytes (8+5*12-5) = 63, and takes advantage of 7*9=63 to minimize block ram usage later(:)
	// Note funny *non* 2's comp format for the integers. Note lsbs dropped in favour of the digital logic analyser.
	// Upon strobe, the current inputs are assumed stable (or don't care:) for 4 cycles as the sampled data is packed into a bram x16 fifo.
	// WHen sufficient words are accumulated, A busrt write to the PSram occurs, writing the data in a large 32Mb loop.
	// the 32MB gives a buffer of 4M samples, which is 1.3sec at 3Msps, or 4.6 minutes at 15Ksps, for the circular buffer.
	// Video pan zoom controlled by keypad. Blipvert to upload psram over HDMI (cheap usb3 dongle compatible) is a long button hold.
	
	logic mad_strobe;		
	logic [7:0] dig_mon;	
	logic [11:0] mad_a0, mad_a1, mad_b0, mad_b1, iest;

	// monitor 8x chip I/O pins

	// create 15 Khz strobe 
	logic [11:0] strobe_count;
	always_ff @(posedge clk) begin
		strobe_count <= ( strobe_count == 3199 ) ? 0 : strobe_count + 1;
		mad_strobe <= ( strobe_count == 3199 ) ? 1'b1 : 1'b0;
	end
	
	// monitor 8x chip I/O pins
	
	assign dig_mon = { 
							time_led		, 
							fault_led	,
							run_led 		,
							setup_sw 	,
							period_sw 	,
							timeout_sw 	,
							button		, 
							pump_out  
							};	
							
		
	// monitor 5x 12-bit analog channels
	
	assign mad_a0 = 12'h7ff ^ probe[0];
	assign mad_a1 = 12'h7ff ^ probe[1];
	assign mad_b0 = 12'h7ff ^ probe[2];
	assign mad_b1 = 12'h7ff ^ probe[3];
	assign iest   = 12'h7ff ^ probe[4];
							
	// Fast Scope is used to capture fast SPI comms signalling.
	// Fast scope is 5 binary channels (cs+4data). Scope triggers on rising CS, restarting at 1Hz. Use any fast clk (6Mhz to 192Mhz), displays in window.
	logic fast_clk;
	logic fast_cs;
	logic [3:0] fast_data;
	
	// Fast scope Inputs
	assign fast_clk = clk_out; //(6mhz)
	assign fast_cs = adc_ncs; // triggered on rising edge
	assign fast_data = { adc_ncs, adc_clk, adc_mosi, adc_miso }; // bottom to top
	
	/////////////////////////////////
	////
	////       FPGA System
	////
	/////////////////////////////////	

	
	
	// Digio pads.
	logic [6:0] digio_in, digio_out;
	ioe_pads7 _digio_pads (
		.dout( digio_in ), 
		.din( digio_out ),  
		.pad_io( digio ),
		.oe ( 7'b1101010 ) // Row drive 1653, col sense 204
	);
		
		
	// Keyboard Scanner
	key_scan _keypad ( 
		.clk( clk ),
		.reset( reset ),
		.keypad_in( digio_in ),
		.keypad_out( digio_out ),
		.key( key )
	);	

	// SPI 8 Memory interface

	logic [7:0] 	spi_data_out;
	logic   			spi_data_oe;
	logic [1:0]   	spi_le_out; // match delay
	logic [7:0] 	spi_data_in;
	logic [1:0]		spi_le_in; // match IO registering
	logic				spi_clk;
	logic				spi_cs;
	logic				spi_rwds_out;
	logic				spi_rwds_oe;
	logic				spi_rwds_in;
	
	// SPI Controller
	
	logic psram_ready;
	logic [17:0] rdata;
	logic [15:0] wdata;
	logic rvalid;
	logic [24:0] araddr;
	logic arvalid, arready;
	logic wready;
	logic [24:0] awaddr;
	logic awvalid;
	logic awready;
	
	// hack view alignment hook
	logic pwm_del, burn_del, zoom_del;
	logic [15:0] retrigger;
	logic [24:0] base_addr;
	logic [24:0] burn_addr;
	logic [3:0] zoom;
	logic zoom_button;
	logic key_del;
	logic burn;
	logic m_cap_halt;
	logic m_pwm;

	assign m_pwm = 0;
	assign burn = 0;
	assign m_cap_halt = 1;
	
	always @(posedge clk) begin
		if( reset ) begin
			zoom <= 0;
			zoom_button <= 0;
			key_del <= 0;
			base_addr <= 0;
			burn_addr <= 0;
			pwm_del <= 0;
			retrigger <= 0;
		end else begin
			key_del <= key[4];
			pwm_del <= m_pwm;
			burn_del <= burn;
			retrigger <= ( !pwm_del && m_pwm && retrigger == 0 ) ? 16'hffff : ( retrigger == 0 ) ? 0 : retrigger - 1;
			base_addr <= ( !pwm_del && m_pwm && retrigger == 0 && !m_cap_halt ) ? awaddr : base_addr; 
			burn_addr <= ( !pwm_del && m_pwm && retrigger == 0 && !m_cap_halt ) ? awaddr : // default to base addr
			             ( !burn_del && burn                              ) ? awaddr : // snap to burn addr
							 ( !key_del && key == 5'h16                       ) ? burn_addr + (512<<zoom) :
							 ( !key_del && key == 5'h14                       ) ? burn_addr - (512<<zoom) :
							                                                      burn_addr;
			zoom <= ( !key_del && key == 5'h12 ) ? ( ( zoom == 12 ) ? 0 : zoom + 1 ) : 
					  ( !key_del && key == 5'h18 ) ? ( ( zoom == 0 ) ? 11 : zoom - 1 ) : zoom;
		end
	end 
	
	// bv raddr bus 
	logic [24:0] 	bv_araddr;
	logic [7:0]  	bv_arlen; // always == 8'd32
	logic        	bv_arvalid;
	logic 		 	bv_arready;
	psram_ctrl _psram_ctl(
		// System
		.clk		( clk ),
		.clk4		( clk4 ),
		.reset	( reset ),
		// Psram spi8 interface
		.spi_data_out( spi_data_out ),
		.spi_data_oe(  spi_data_oe  ),
		.spi_le_out( 	spi_le_out 	 ),
		.spi_data_in( 	spi_data_in  ),
		.spi_le_in( 	spi_le_in 	 ),
		.spi_clk( 		spi_clk 		 ),
		.spi_cs( 		spi_cs 		 ),
		.spi_rwds_out( spi_rwds_out ),
		.spi_rwds_oe( 	spi_rwds_oe  ),
		.spi_rwds_in( 	spi_rwds_in  ),
		// Status
		.psram_ready( psram_ready ),	// Indicates control is ready to accept requests
		// AXI4 R/W port
		// Write Data
		.wdata( wdata ),
		.wvalid( 1'b1 ), // always avail)
		.wready( wready ),
		// Write Addr
		.awaddr( awaddr ),
		.awlen( 8'h08 ),	// assumed 8
		.awvalid( awvalid ), // write valid
		.awready( awready ),
		// Write Response
		.bready( 1'b1 ),	// Assume 1, non blocking
		.bvalid( ),
		.bresp(  ),
		// Read Addr, Port 0, bl=4
		.araddr0 ( burn_addr + ( araddr << zoom ) - (((burn)?(192*16):(64*16))<<zoom) ),
		.arlen0  ( 8'd04 ),	// assumed 4
		.arvalid0( arvalid ), // read valid	
		.arready0( arready ),
		// Read Addr, Port 1, bl = 32
		.araddr1 ( bv_araddr ),
		.arlen1  ( bv_arlen ),	// assumed 32
		.arvalid1( bv_arvalid ), // read valid	
		.arready1( bv_arready ),
		// Read Data, shared
		.rdata( rdata[17:0] ),
		.rvalid( rvalid ),
		.rready( 1'b1 ) // Assumed 1, non blocking
	);	

 	    
	// Capture ID regs 
	//logic [35:0] id_reg;
	//always @(posedge clk) begin
	//	id_reg <= ( !psram_ready && rvalid ) ? { id_reg[17:0], rdata[17:0] } : id_reg;
	//end
		
	// feedback delay le 2 cycles to match IO
	logic [1:0] 	spi_le_reg;
	always @(posedge clk4) spi_le_reg <= spi_le_out;
	always @(posedge clk4) spi_le_in  <= spi_le_reg;
	
	// Registered I/O pad interfaces
	reg_ioe _spi_d0 ( .inclock( clk4 ), .outclock( clk4 ), .dout( spi_data_in[0] ), .din( spi_data_out[0] ), .oe( spi_data_oe ), .pad_io( spi8_data_pad[0] ) );
	reg_ioe _spi_d1 ( .inclock( clk4 ), .outclock( clk4 ), .dout( spi_data_in[1] ), .din( spi_data_out[1] ), .oe( spi_data_oe ), .pad_io( spi8_data_pad[1] ) );
	reg_ioe _spi_d2 ( .inclock( clk4 ), .outclock( clk4 ), .dout( spi_data_in[2] ), .din( spi_data_out[2] ), .oe( spi_data_oe ), .pad_io( spi8_data_pad[2] ) );
	reg_ioe _spi_d3 ( .inclock( clk4 ), .outclock( clk4 ), .dout( spi_data_in[3] ), .din( spi_data_out[3] ), .oe( spi_data_oe ), .pad_io( spi8_data_pad[3] ) );
	reg_ioe _spi_d4 ( .inclock( clk4 ), .outclock( clk4 ), .dout( spi_data_in[4] ), .din( spi_data_out[4] ), .oe( spi_data_oe ), .pad_io( spi8_data_pad[4] ) );
	reg_ioe _spi_d5 ( .inclock( clk4 ), .outclock( clk4 ), .dout( spi_data_in[5] ), .din( spi_data_out[5] ), .oe( spi_data_oe ), .pad_io( spi8_data_pad[5] ) );
	reg_ioe _spi_d6 ( .inclock( clk4 ), .outclock( clk4 ), .dout( spi_data_in[6] ), .din( spi_data_out[6] ), .oe( spi_data_oe ), .pad_io( spi8_data_pad[6] ) );
	reg_ioe _spi_d7 ( .inclock( clk4 ), .outclock( clk4 ), .dout( spi_data_in[7] ), .din( spi_data_out[7] ), .oe( spi_data_oe ), .pad_io( spi8_data_pad[7] ) );
	reg_ioe _spi_ds ( .inclock( clk4 ), .outclock( clk4 ), .dout( spi_rwds_in    ), .din( spi_rwds_out    ), .oe( spi_rwds_oe ), .pad_io( spi_ds           ) );
	reg_ioe _spi_clk( .inclock( clk4 ), .outclock( clk4 ), .dout( ),                .din( spi_clk  ),        .oe( 1'b1        ), .pad_io( spi_clk0         ) );
	reg_ioe _spi_ncs( .inclock( clk4 ), .outclock( clk4 ), .dout( ),                .din( !spi_cs  ),        .oe( 1'b1        ), .pad_io( spi_ncs          ) ); // invert CS on output
	reg_ioe _spi_nrst(.inclock( clk4 ), .outclock( clk4 ), .dout( ),                .din( !reset   ),        .oe( 1'b1        ), .pad_io( spi_nrst         ) ); // send out nreset
	

	////////////////////////////////
	//       Data Capture
	////////////////////////////////
	
	// Can capture ALL adc samples, when psram_ready
	// write all samples into the fifo (as burst write of 4 16-bit samples)	
	// When there are 8 words in the fifo, initiate a write 
	// increment the address by 16bytes  = 8x 16bit = 2 samples of 64 bit;


			
	// Fifo Write 
	
	logic almost_empty;
	logic [15:0] wrfifo_data;
	logic wrfifo;
	logic [3:0][15:0] mad_data;
	logic [2:0] mad_strobe_d;
	logic mscroll_halt;
	
	always @(posedge clk) begin
		mad_strobe_d <= { mad_strobe_d[1:0], mad_strobe & psram_ready}; 
		if( mad_strobe ) begin
		mad_data <= { { iest[11:8], mad_a0[11:1],dig_mon[7] },
						 { iest[7:4], mad_a1[11:1],dig_mon[6] },
						 { iest[3:1],dig_mon[5], mad_b0[11:1],dig_mon[4] }, 
						 { 1'b0, dig_mon[3:1], mad_b1[11:1],dig_mon[0] } };
		end else begin
			mad_data <= mad_data;
		end
	end
	assign wrfifo_data = ( mad_strobe ) ? { iest[11:8], mad_a0[11:1],dig_mon[7] } :
			               ( mad_strobe_d[0] ) ? mad_data[2] :
			               ( mad_strobe_d[1] ) ? mad_data[1] :
			               ( mad_strobe_d[2] ) ? mad_data[0] : 16'h0048;
	assign wrfifo = (mad_strobe & psram_ready) | (|mad_strobe_d);
	
	adc_fifo _write_fifo
	(
	.clock( clk ),
	.almost_empty( almost_empty ),
	.wrreq( wrfifo ),
	.data( wrfifo_data ),
	.rdreq( wready ),
	.q( wdata )
	);

	// Fifo Read / PSRAM Write control. 
	// when there are 8 or more (!almost_empty)
	// psram write awaddr and awvalid write request
	// wait for awready
	// increment awaddr address by 16
	// Repeat.
	
	always @(posedge clk) begin
		if( reset ) begin
			awaddr <= 25'b0;
			awvalid <= 0;
		end else begin
			//if( m_cap_halt && awaddr[24:4] == (base_addr[24:4] - 16384) ) begin // approx 10 ms before start
			if( awaddr[24:4] == 21'h1FFFFF ) begin
				awvalid <= 0;
				awaddr <= awaddr;
			end else begin
				awvalid <= !almost_empty; // race if mem ctrl reads ahead, but not here
				awaddr <= ( awready & awvalid ) ? awaddr + 25'd16 : awaddr;
			end
		end
	end
		
	//assign tidx = awaddr[24:22]; // test index based on write address, 1/8th buffer per step.
	
	/////////////////////////////////
	////
	////       HDMI VIDEO
	////
	//////////////////////////////////
	
	// HDMI reset
	logic [3:0] hdmi_reg;
	always @(posedge hdmi_clk) begin
		hdmi_reg[3:0] <= { hdmi_reg[2:0], reset };
	end
	logic hdmi_reset;
	assign hdmi_reset = hdmi_reg[3];
	
	logic video_preamble;
	logic data_preamble;
	logic video_guard;
	logic data_guard;
	logic data_island;
	
	// XVGA 800x480x60hz sych generator
	logic blank, hsync, vsync;
	vga_800x480_sync _sync
	(
		.clk(   hdmi_clk   ),	
		.reset( reset ),
		.blank( blank ),
		.hsync( hsync ),
		.vsync( vsync ),
		// HDMI encoding controls
		.video_preamble( video_preamble ),
		.data_preamble ( data_preamble  ),
		.video_guard   ( video_guard    ),
		.data_guard    ( data_guard     ),
		.data_island   ( data_island    )
	);
	
	// Font Generator
	logic [7:0] char_x, char_y;
	logic [255:0] ascii_char;
	logic [15:0] hex_char;
	logic [1:0] bin_char;
	ascii_font57 _font
	(
		.clk( hdmi_clk ),
		.reset( reset ),
		.blank( blank ),
		.hsync( hsync ),
		.vsync( vsync ),
		.char_x( char_x ), // 0 to 105 chars horizontally
		.char_y( char_y ), // o to 59 rows vertically
		.hex_char   ( hex_char ),
		.binary_char( bin_char ),
		.ascii_char ( ascii_char )	
	);

	// test pattern gen
	logic [7:0] test_red, test_green, test_blue;
	test_pattern _testgen 
	(
		.clk( hdmi_clk  ),
		.reset( reset ),
		.blank( blank ),
		.hsync( hsync ),
		.vsync( vsync ),
		.red	( test_red   ),
		.green( test_green ),
		.blue	( test_blue  )
	);	
	
	// Flash Memory interface (init font and text overlay)
	// the serial interface runs at 6 Mhz (max 7 Mhz!)
	// we assigned c0 the output diff pair clock to this interface.
	
	logic [11:0] 	flash_addr; // 32 bit word address, 16Kbytes total flash for M04
	logic 			flash_read;
	logic				flash_data;
	logic 			flash_wait;
	logic 			flash_valid;
	ufm_flash _flash (
		.clock						( clk_out 			 ), // 6 Mhz
		.avmm_data_addr			( flash_addr[11:0] ), // word address 
		.avmm_data_read			( flash_read 		 ),
		.avmm_data_readdata		( flash_data 		 ),
		.avmm_data_waitrequest	( flash_wait 		 ),
		.avmm_data_readdatavalid( flash_valid 		 ),
		.avmm_data_burstcount	( 128 * 32 			 ), // 4K bit burst
		.reset_n						( !reset 			 )
	);	
	
	// Text Overlay 
	logic text_ovl;
	logic [3:0] text_color;
	text_overlay _text
	(
		.clk( hdmi_clk  ),
		.reset( reset ),
		.blank( blank ),
		.hsync( hsync ),
		.vsync( vsync ),
		// Overlay output bit for ORing
		.overlay( text_ovl ),
		.color( text_color ),
		// Avalon bus to init font and text rams
		.flash_clock( clk_out 			 ), // 6 Mhz
		.flash_addr ( flash_addr[11:0] ), // word address 
		.flash_read ( flash_read 		 ),
		.flash_data ( flash_data 		 ),
		.flash_wait ( flash_wait 		 ),
		.flash_valid( flash_valid 		 )
	);

	/////////////////////////////////////////////////////
	// BlipVert, 1sec dump of 32M sram on HDMI video out
	/////////////////////////////////////////////////////
	
	// clock crossing of blank
	logic [1:0] bvena;
	always @(posedge clk) bvena[1:0] <= { bvena[0], !blank };	
	
	logic [16:0] bv_wdata;
	logic        bv_wvalid;
	logic blipvert;
	logic m_long_fire;
	
	assign blipvert = ( m_long_fire || key == 5'h17 ) ? 1'b1 : 1'b0;
	
	blipvert _bv_unit (
		// System
		.clk		( clk ),
		.reset	( reset ),
		// enable input
		.enable	( bvena[1] & blipvert ), // Rising edge starts
		.base( base_addr[24:0] ), // starting addr to flag first 1k block
		// Psram Port
		.araddr	( bv_araddr ), 
		.arlen 	( bv_arlen  ), // bv uses 32 always
		.arvalid	( bv_arvalid ), // read valid	
		.arready	( bv_arready ),
		.rdata	( rdata[17:0] ), 
		.rvalid	( rvalid ),
		// Output data 
		.vdata	( bv_wdata ),
		.vvalid	( bv_wvalid )
	);
		
	
	// Clock domain crossing fifo 17bit wide
	logic [16:0] bv_vdata;
	logic        bv_vvalid_n; // inverse valid
	logic [30:0] blank_delay;
	logic 		 read_fifo;
	
	always @(posedge hdmi_clk) // Delay reading to allow starting the fill
		{ read_fifo, blank_delay } <= { blank_delay, !blank };
		
	bvfifo _bv_fifo (
		// Write port
		.wrclk	( clk ),
		.wrreq	( bv_wvalid ),
		.data		( bv_wdata[16:0] ),
		// Read port
		.rdclk	( hdmi_clk ),
		.rdreq	( !bv_vvalid_n & read_fifo ), // auto read when not emptyu
		.rdempty	( bv_vvalid_n ),
		.q			( bv_vdata[16:0] )
		);	
		

	// Average of the adc values
	
	logic [0:3][33:0]  acc	   ; // accumulate 4M x 12 bit samples, 1.3 sec
	logic [0:3][11:0]  avg	   ;
	logic [21:0]       acc_cnt ; // count to 4M
	
	always @(posedge clk) begin
		if( reset ) begin
			acc     <= 0;
			acc_cnt <= 0;
			avg     <= 0;
		end else begin
			if( mad_strobe ) begin
				acc[0] <= ( acc_cnt == 0 ) ? { 22'h00_0000, 12'h7ff^mad_a0[11:0] } : acc[0] + { 22'h00_0000, 12'h7ff^mad_a0[11:0] };
				acc[1] <= ( acc_cnt == 0 ) ? { 22'h00_0000, 12'h7ff^mad_a1[11:0] } : acc[1] + { 22'h00_0000, 12'h7ff^mad_a1[11:0] };
				acc[2] <= ( acc_cnt == 0 ) ? { 22'h00_0000, 12'h7ff^mad_b0[11:0] } : acc[2] + { 22'h00_0000, 12'h7ff^mad_b0[11:0] };
				acc[3] <= ( acc_cnt == 0 ) ? { 22'h00_0000, 12'h7ff^mad_b1[11:0] } : acc[3] + { 22'h00_0000, 12'h7ff^mad_b1[11:0] };
				if( acc_cnt == 0 ) begin
					avg[0] <= acc[0][33-:12];
					avg[1] <= acc[1][33-:12];
					avg[2] <= acc[2][33-:12];
					avg[3] <= acc[3][33-:12];	
				end else begin
					avg <= avg;
				end
				acc_cnt <= acc_cnt + 1;
			end else begin
				avg <= avg;
				acc <= acc;
				acc_cnt <= acc_cnt;
			end
		end
	end
		
	// snapshot display values during vsync
	logic [11:0] value_1, value_2, value_3, value_4;
	logic [4:0] key_reg;
	always @(posedge clk) begin
		if( vsync ) begin
			value_1[11:0] <= avg[0]; // ad_a0;
			value_2[11:0] <= avg[1]; // ad_a1;
			value_3[11:0] <= avg[2]; // ad_b0;
			value_4[11:0] <= avg[3]; // ad_b1;
			key_reg <= key;
		end
	end
	
	// Overlay PSRAM ID and expected values
	logic [31:0] disp_id;
	//assign disp_id = { id_reg[34:31], id_reg[30:27],id_reg[25:22],id_reg[21:18],id_reg[16:13],id_reg[12: 9],id_reg[ 7: 4],id_reg[ 3: 0] };
	logic [4:0] id_str;
	//string_overlay #(.LEN(5)) _id0(.clk(hdmi_clk), .reset(reset), .char_x(char_x), .char_y(char_y),.ascii_char(ascii_char), .x('h48), .y('h09), .out( id_str[0]), .str( "PSRAM" ) );
	//hex_overlay    #(.LEN(8 )) _id1(.clk(hdmi_clk), .reset(reset), .char_x(char_x), .char_y(char_y),.hex_char(hex_char), .x('h50),.y('d58), .out( id_str[1]), .in( disp_id ) );
   //bin_overlay    #(.LEN(1 )) _id2(.clk(hdmi_clk), .reset(reset), .char_x(char_x), .char_y(char_y),.bin_char(bin_char), .x('h46),.y('h09), .out( id_str[2]), .in( disp_id == 32'h0E96_0001 ) );
	//string_overlay #(.LEN(12)) _id3(.clk(hdmi_clk), .reset(reset), .char_x(char_x), .char_y(char_y),.ascii_char(ascii_char), .x('d120),.y('d59), .out( id_str[3]), .str( "ERIC PEARSON" ) );
	string_overlay #(.LEN( 9)) _id4 (.clk(hdmi_clk), .reset(reset), .char_x(char_x), .char_y(char_y), .ascii_char(ascii_char), .x('h02),.y('h03), .out(id_str[4]), 
	.str(	( zoom == 0 ) ? "  4ms/div" :
			( zoom == 1 ) ? "  8ms/div" :
			( zoom == 2 ) ? " 16ms/div" :
			( zoom == 3 ) ? " 25ms/div" :
			( zoom == 4 ) ? " 50ms/div" :
			( zoom == 5 ) ? "100ms/div" :
			( zoom == 6 ) ? "250ms/div" :
			( zoom == 7 ) ? "500ms/div" :
			( zoom == 8 ) ? "  1 s/div" :
			( zoom == 9 ) ? "  2 s/div" :
			( zoom == 10) ? "  5 s/div" :
			( zoom == 11) ? " 10 s/div" :
			/*zoom == 12)*/ " 20 s/div" ) );

	
	// Overlay the Keystroke
	logic key_str, key_strg;
	hex_overlay #(.LEN(1)) _key  (.clk(hdmi_clk), .reset(reset), .char_x(char_x), .char_y(char_y), .hex_char(hex_char), .x(1),.y(58), .out( key_str  ), .in( key_reg[3:0] ) );
	assign key_strg = key_str & key_reg[4];

	// 4ch Oscilloscope mem & vga display
	logic [7:0] scope_red, scope_green, scope_blue;


	// 4ch Oscilloscope mem & vga display
	logic [7:0] tiny_red, tiny_green, tiny_blue;
	logic tiny;
	//tiny_scope #( 
	//	.V_HEIGHT( 192 ), // 96 or 192 options
	//	.V_START ( 80  ),
	//	.H_START	( 529 ),
	//	.H_END 	( 784 ),
	//	.N       ( 2   ), // 60 Hz frames per col pel
	//	.GD_COLOR( 24'h32006a /* smpte_deep_violet */ ), 
	//	.BG_COLOR( 24'h00214c /* smpte_oxford_blue */ ) //24'h1d1d1d /* smpte_eerie_black */ )	
	// ) _tiny_scope(
	//	.clk(   hdmi_clk ),
	//	.reset( reset ),
	//	// video sync 
	//	.blank( blank ), 
	//	.hsync( hsync ),
	//	.vsync( vsync ),
	//	// scroll halt input
	//	.halt ( mscroll_halt ),
	//	// capture inputs
	//	.ad_a0( mad_a0 ),
	//	.ad_a1( mad_a1 ),
	//	.ad_b0( mad_b0 ),
	//	.ad_b1( mad_b1 ),
	//	.ad_strobe( mad_strobe ),
	//	.ad_clk( clk ),
	//	// video output
	//	.red(   tiny_red ),
	//	.green( tiny_green ),
	//	.blue(  tiny_blue )
	//);
	assign tiny = |{ tiny_red, tiny_green, tiny_blue };

	// 8ch digital logic analyser mem & vga display
	logic [7:0] tinyb_red, tinyb_green, tinyb_blue;
	logic tinyb;
	//tiny_binary_scope #( 
	//	.V_HEIGHT( 64 ), // 96 or 192 options
	//	.V_START ( 400  ),
	//	.H_START	( 529 ),
	//	.H_END 	( 784 ),
	//	.N       ( 2   ), // 60 Hz frames per col pel
	//	.GD_COLOR( 24'h32006a /* smpte_deep_violet */ ), 
	//	.BG_COLOR( 24'h00214c /* smpte_oxford_blue */ ) //24'h1d1d1d /* smpte_eerie_black */ )	
	// ) _tinyb_scope(
	//	.clk(   hdmi_clk ),
	//	.reset( reset ),
	//	// video sync 
	//	.blank( blank ), 
	//	.hsync( hsync ),
	//	.vsync( vsync ),
	//	// scroll halt input
	//	.halt ( mscroll_halt ),
	//	// capture inputs
	//	.ad_data( dig_mon ),
	//
	//	.ad_strobe( mad_strobe ),
	//	.ad_clk( clk ),
	//	// video output
	//	.red(   tinyb_red ),
	//	.green( tinyb_green ),
	//	.blue(  tinyb_blue )
	//);
	assign tinyb = |{ tinyb_red, tinyb_green, tinyb_blue };	

	// 5ch digital oversampled scope on serial ADC inputs
	logic [7:0] fast_red, fast_green, fast_blue;
	logic fast;
	vga_fast_capture #(
		.V_HEIGHT( 40 ), // 96 or 192 options
		.V_START ( 320 ),
		.H_START	( 529 ),
		.H_END 	( 784 ),
		.N       ( 60   ), // 60 Hz frames per col pel
		.GD_COLOR( 24'h404040 /* smpte_deep_violet */ ), 
		.BG_COLOR( 24'h00214c /* smpte_oxford_blue */ ) //24'h1d1d1d /* smpte_eerie_black */ )	
	) i_fast_scope (
		.clk(   hdmi_clk ),
		.reset( reset ),
		// video sync 
		.blank( blank ), 
		.hsync( hsync ),
		.vsync( vsync ),
		// capture inputs
		.clk_fast( fast_clk ),
		.ad_cs( fast_cs ),
		.ad_data( fast_data ),
		// video output
		.red(   fast_red ),
		.green( fast_green ),
		.blue(  fast_blue )
	);	
	assign fast = |{fast_red, fast_green, fast_blue};	

	
	// 12 bit resistance number is 6.5. so 
	// plotting as 8.4 with { 2`b00, in[10:1] } will give Ohms. A decimal point woudl be nice
	logic [4:0] res_str;
	//string_overlay #(.LEN(8)) _res0 (.clk(hdmi_clk), .reset(reset), .char_x(char_x), .char_y(char_y), .ascii_char(ascii_char), .x('d100),.y('d5), .out( res_str[0] ), .str("Res $ 0x") );
	//hex_overlay    #(.LEN(2)) _res1 (.clk(hdmi_clk), .reset(reset), .char_x(char_x), .char_y(char_y), .hex_char(hex_char)    , .x('d108),.y('d5), .out( res_str[1] ), .in( { 2'b00, igniter_res[10:5] ^ 6'h3F } ) );
	//string_overlay #(.LEN(1)) _res2 (.clk(hdmi_clk), .reset(reset), .char_x(char_x), .char_y(char_y), .ascii_char(ascii_char), .x('d110),.y('d5), .out( res_str[2] ), .str(".") );
	//hex_overlay    #(.LEN(1)) _res3 (.clk(hdmi_clk), .reset(reset), .char_x(char_x), .char_y(char_y), .hex_char(hex_char)    , .x('d111),.y('d5), .out( res_str[3] ), .in( { igniter_res[4:1] ^ 4'hF } ) );
	//string_overlay #(.LEN(11))_res4 (.clk(hdmi_clk), .reset(reset), .char_x(char_x), .char_y(char_y), .ascii_char(ascii_char), .x('d117),.y('d5), .out( res_str[4] ), .str("(3E.E=Open)") );

	
	// Port Names
	logic [5:0] in_str;
   string_overlay #(.LEN(3)) _in0 (.clk(hdmi_clk), .reset(reset), .char_x(char_x), .char_y(char_y), .ascii_char(ascii_char), .x('h47),.y('h01), .out( in_str[0]), .str("Ch0") );
	string_overlay #(.LEN(3)) _in1 (.clk(hdmi_clk), .reset(reset), .char_x(char_x), .char_y(char_y), .ascii_char(ascii_char), .x('h47),.y('h03), .out( in_str[1]), .str("Ch1") );
	string_overlay #(.LEN(4)) _in2 (.clk(hdmi_clk), .reset(reset), .char_x(char_x), .char_y(char_y), .ascii_char(ascii_char), .x('h46),.y('h05), .out( in_str[2]), .str("Rms0") );
	string_overlay #(.LEN(4)) _in3 (.clk(hdmi_clk), .reset(reset), .char_x(char_x), .char_y(char_y), .ascii_char(ascii_char), .x('h46),.y('h07), .out( in_str[3]), .str("Rms1") );
	string_overlay #(.LEN(5)) _in4 (.clk(hdmi_clk), .reset(reset), .char_x(char_x), .char_y(char_y), .ascii_char(ascii_char), .x('h45),.y('h09), .out( in_str[4]), .str("fpga0") );
	string_overlay #(.LEN(5)) _in5 (.clk(hdmi_clk), .reset(reset), .char_x(char_x), .char_y(char_y), .ascii_char(ascii_char), .x('h45),.y('h0B), .out( in_str[5]), .str("fpga1") );
	
	// 12bit hex overlays(4)
	logic [5:0] hex_str;
	hex_overlay #(.LEN(3)) _hex0 (.clk(hdmi_clk), .reset(reset), .char_x(char_x), .char_y(char_y), .hex_char(hex_char), .x('h4B),.y('h01), .out( hex_str[0]), .in( dout0 ) );
	hex_overlay #(.LEN(3)) _hex1 (.clk(hdmi_clk), .reset(reset), .char_x(char_x), .char_y(char_y), .hex_char(hex_char), .x('h4B),.y('h03), .out( hex_str[1]), .in( dout1 ) );
	hex_overlay #(.LEN(8)) _hex2 (.clk(hdmi_clk), .reset(reset), .char_x(char_x), .char_y(char_y), .hex_char(hex_char), .x('h4B),.y('h05), .out( hex_str[2]), .in( rms_hold[0] ) );
	hex_overlay #(.LEN(8)) _hex3 (.clk(hdmi_clk), .reset(reset), .char_x(char_x), .char_y(char_y), .hex_char(hex_char), .x('h4B),.y('h07), .out( hex_str[3]), .in( rms_hold[1] ) );
	hex_overlay #(.LEN(8)) _hex4 (.clk(hdmi_clk), .reset(reset), .char_x(char_x), .char_y(char_y), .hex_char(hex_char), .x('h4B),.y('h09), .out( hex_str[4]), .in( fpga_probe ) );
	hex_overlay #(.LEN(8)) _hex5 (.clk(hdmi_clk), .reset(reset), .char_x(char_x), .char_y(char_y), .hex_char(hex_char), .x('h4B),.y('h0B), .out( hex_str[5]), .in( fpga_probe2 ) );
					
	// dump binary	values	
	logic [3:0] bin_str;
	//bin_overlay #(.LEN(12)) _bin0 (.clk(hdmi_clk), .reset(reset), .char_x(char_x), .char_y(char_y), .bin_char(bin_char), .x('h50), .y('h01), .out( bin_str[0] ), .in( value_1 ) );
	//bin_overlay #(.LEN(12)) _bin1 (.clk(hdmi_clk), .reset(reset), .char_x(char_x), .char_y(char_y), .bin_char(bin_char), .x('h50), .y('h03), .out( bin_str[1] ), .in( value_2 ) );
	//bin_overlay #(.LEN(12)) _bin2 (.clk(hdmi_clk), .reset(reset), .char_x(char_x), .char_y(char_y), .bin_char(bin_char), .x('h50), .y('h05), .out( bin_str[2] ), .in( value_3 ) );
	//bin_overlay #(.LEN(12)) _bin3 (.clk(hdmi_clk), .reset(reset), .char_x(char_x), .char_y(char_y), .bin_char(bin_char), .x('h50), .y('h07), .out( bin_str[3] ), .in( value_4 ) );

   // Text legend
   logic [7:0] leg_str;
   string_overlay #(.LEN(7)) i_leg00 (.clk(hdmi_clk), .reset(reset), .char_x(char_x), .char_y(char_y), .ascii_char(ascii_char), .x('d3),.y('d50+0), .out( leg_str[0] ), .str("Pump   ") );
   string_overlay #(.LEN(7)) i_leg01 (.clk(hdmi_clk), .reset(reset), .char_x(char_x), .char_y(char_y), .ascii_char(ascii_char), .x('d3),.y('d50+1), .out( leg_str[1] ), .str("Button ") );
   string_overlay #(.LEN(7)) i_leg02 (.clk(hdmi_clk), .reset(reset), .char_x(char_x), .char_y(char_y), .ascii_char(ascii_char), .x('d3),.y('d50+2), .out( leg_str[2] ), .str("timeout") );
   string_overlay #(.LEN(7)) i_leg03 (.clk(hdmi_clk), .reset(reset), .char_x(char_x), .char_y(char_y), .ascii_char(ascii_char), .x('d3),.y('d50+3), .out( leg_str[3] ), .str("period ") );
   string_overlay #(.LEN(7)) i_leg04 (.clk(hdmi_clk), .reset(reset), .char_x(char_x), .char_y(char_y), .ascii_char(ascii_char), .x('d3),.y('d50+4), .out( leg_str[4] ), .str("setup  ") );
   string_overlay #(.LEN(7)) i_leg05 (.clk(hdmi_clk), .reset(reset), .char_x(char_x), .char_y(char_y), .ascii_char(ascii_char), .x('d3),.y('d50+5), .out( leg_str[5] ), .str("Run    ") );
   string_overlay #(.LEN(7)) i_leg06 (.clk(hdmi_clk), .reset(reset), .char_x(char_x), .char_y(char_y), .ascii_char(ascii_char), .x('d3),.y('d50+6), .out( leg_str[6] ), .str("Fault  ") );
   string_overlay #(.LEN(7)) i_leg07 (.clk(hdmi_clk), .reset(reset), .char_x(char_x), .char_y(char_y), .ascii_char(ascii_char), .x('d3),.y('d50+7), .out( leg_str[7] ), .str("Time   ") );
							
	
	// Merge overlays
	logic overlay;
	assign overlay = (|bin_str ) |
						  (|hex_str ) |
						  (|in_str  ) |
						  ( text_ovl && text_color == 0 ) | // normal text
						  ( key_strg) |
						  (|res_str ) |
						  (|leg_str ) |						  
						  (|id_str  ) ;
	

	// Oscilloscope & vga display
	logic [7:0] wave_scope_red, wave_scope_green, wave_scope_blue;
	vga_wave_display _wave_scope (
		.clk(   hdmi_clk ),
		.reset( reset ),
		// video sync 
		.blank( blank ), 
		.hsync( hsync ),
		.vsync( vsync ),
		// Font data
		.ascii_char( ascii_char ),
		.char_x( char_x ),
		.char_y( char_y ),
		// AXI Sram Read port connection
		.psram_ready	( psram_ready 	 ) ,
		.rdata			( rdata 			 ) , 
		.rvalid			( rvalid		    ) ,
		.araddr			( araddr[24:0]	 ) ,
		.arvalid			( arvalid		 ) , 
		.arready			( arready		 ) ,
		.mem_clk			( clk ),
		// video output
		.red(   wave_scope_red ),
		.green( wave_scope_green ),
		.blue(  wave_scope_blue )	
	);	

	// Overlay Color
	logic [7:0] overlay_red, overlay_green, overlay_blue;
	
	assign { overlay_red, overlay_green, overlay_blue } =
			( overlay ) ? 24'hFFFFFF :
			( text_ovl && text_color == 4'h1 ) ? 24'hf00000 :
			( text_ovl && text_color == 4'h2 ) ? 24'hFFFFFF :
			( text_ovl && text_color == 4'h3 ) ? 24'hff0000 :			
			( text_ovl && text_color == 4'h4 ) ? 24'h00ff00 :
			( text_ovl && text_color == 4'h5 ) ? 24'h0000ff :
			( text_ovl && text_color == 4'h6 ) ? 24'hc0c0c0 :
			( text_ovl && text_color == 4'h7 ) ? 24'h0000c0 :
			( text_ovl && text_color == 4'h8 ) ? 24'h00c0c0 :
			( text_ovl && text_color == 4'h9 ) ? 24'h00c000 : 
			( text_ovl && text_color == 4'hA ) ? 24'hc0c000 : 
			( text_ovl                       ) ? 24'hf0f000 : 
															 24'h000000 ;

	// video encoder
	logic [7:0] hdmi_data;
	logic [7:0] dvi_data;
	video_encoder _encode2
	(
		.clk  ( hdmi_clk  ),
		.clk5 ( hdmi_clk5 ),
		.reset( reset ), //| charge ),  // battery limit during charging
		.blank( blank ),
		.hsync( hsync ),
		.vsync( vsync ),
		// HDMI encoding control
		.video_preamble( video_preamble ),
		.data_preamble ( data_preamble  ),
		.video_guard   ( video_guard    ),
		.data_guard    ( data_guard     ),
		.data_island   ( data_island    ),	
		// YUV mode input
		.yuv_mode		( blipvert ), // use YUV2 mode, cheap USb capture devices provice lossless YUV2 capture mode 
		// RBG Data
		.red	( (blipvert) ? bv_vdata[7:0]  : ((( tiny | tinyb | fast) ? (tiny_red   | tinyb_red  | fast_red  ) : wave_scope_red   ) | overlay_red   ) ),
		.green( (blipvert) ? bv_vdata[15:8] : ((( tiny | tinyb | fast) ? (tiny_green | tinyb_green| fast_green) : wave_scope_green ) | overlay_green ) ),
		.blue	( (blipvert) ? 8'h00          : ((( tiny | tinyb | fast) ? (tiny_blue  | tinyb_blue | fast_blue ) : wave_scope_blue  ) | overlay_blue  ) ),
		.hdmi_data( hdmi_data ),
		.dvi_data( dvi_data )
	);
		
	// HDMI or DVI output.
	hdmi_out _hdmi2_out ( // LDVS DDR outputs
		.outclock( hdmi_clk5 ),
		.din( hdmi_data ), // hdmi_data or dvi_data 
		.pad_out( {hdmi2_d2, hdmi2_d1, hdmi2_d0, hdmi2_ck} ), 
		.pad_out_b( )  // true differential, _b not req
	);
	

endmodule

// 1024 moving window debounce 80/20
// tick is about 1 per 480 cycles	
module debounce(
	input clk,
	input reset,
	input in,
	output out,	// fixed pulse 15ms after 5ms pressure
	output long // after fire held for > 2/3 sec, until release
	);
	
	logic [25:0] count1; // total 1.3 sec
	logic [22:0] count0;
	logic [2:0] state;
	logic [2:0] meta;
	logic       inm;

	
	always @(posedge clk) { inm, meta } <= { meta, in };
	
	// State Machine	
	localparam S_IDLE 		= 0;
	localparam S_WAIT_PRESS	= 1;
	localparam S_WAIT_PULSE	= 2;
	localparam S_WAIT_LONG	= 3;
	localparam S_LONG			= 4;
	localparam S_WAIT_OFF	= 5;
	localparam S_WAIT_LOFF	= 6;
	
	always @(posedge clk) begin
		if( reset ) begin
			state <= S_IDLE;
		end else begin
			case( state )
				S_IDLE 		 :	state <= ( inm ) ? S_WAIT_PRESS : S_IDLE;
				S_WAIT_PRESS :	state <= (!inm ) ? S_IDLE       : (count1 == ( 5  * 48000 )) ? S_WAIT_PULSE : S_WAIT_PRESS;
				S_WAIT_PULSE :	state <=                          (count1 == ( 25 * 48000 )) ? S_WAIT_LONG  : S_WAIT_PULSE; 
				S_WAIT_LONG	 :	state <= (!inm ) ? S_WAIT_OFF   : (count1 >= 26'h20_00000  ) ? S_LONG       : S_WAIT_LONG;
				S_LONG		 :	state <= (!inm ) ? S_WAIT_LOFF  :  S_LONG;
				S_WAIT_OFF	 :	state <= ( inm ) ? S_WAIT_LONG  : (count0 == ( 100 * 48000)) ? S_IDLE       : S_WAIT_OFF;
				S_WAIT_LOFF	 :	state <= ( inm ) ? S_LONG       : (count0 == ( 100 * 48000)) ? S_IDLE       : S_WAIT_LOFF;
				default: state <= S_IDLE;
			endcase
		end
	end
	
	assign out = (state == S_WAIT_PULSE) ? 1'b1 : 1'b0;
	assign long = (state == S_LONG || state == S_WAIT_LOFF) ? 1'b1 : 1'b0;
	
	// Counters
	always @(posedge clk) begin
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
	

module key_scan( 
	input [6:0] keypad_in,
	output [6:0] keypad_out,
	input	clk,
	input reset,
	output [4:0] key
	);
	
	
	logic [11:0] div;
	logic [2:0] col;
	logic [3:0] row;
	logic flag;
	always @(posedge clk) begin
		if( reset ) begin
			key <= 0;
			div <= 0;
			col <= 0;
			row <= 0;
			flag <= 0;
			keypad_out <= 0;
		end else begin
			div <= div + 1;
			// drive 4 rows
			keypad_out[1] <= ( div[11:10] == 0 ) ? 1'b0 : 1'b1;
			keypad_out[6] <= ( div[11:10] == 1 ) ? 1'b0 : 1'b1;
			keypad_out[5] <= ( div[11:10] == 2 ) ? 1'b0 : 1'b1;
			keypad_out[3] <= ( div[11:10] == 3 ) ? 1'b0 : 1'b1;
			// capture columns
				if( div[11:0] == 0 ) begin
					flag <= 0;
					col <= col;
					row <= row;
				end else if( div[11:0] == 12'hfff && flag == 0 ) begin
					col <= 0;
					row <= 0;
				end else if( div[9:0] == 10'h3F0 && { keypad_in[2], keypad_in[0], keypad_in[4]} != 3'b111 ) begin // key pressed
					flag  <= 1;
					col[2] <= !keypad_in[2];
					col[1] <= !keypad_in[0];
					col[0] <= !keypad_in[4];
					row[0] <= !keypad_in[1];
					row[1] <= !keypad_in[6];
					row[2] <= !keypad_in[5];
					row[3] <= !keypad_in[3];
				end else begin
					flag <= flag;
					col <= col;
					row <= row;
				end
			key <= ( col[2:0] == 3'b001 && row[0] ) ? 5'h13 :
					 ( col[2:0] == 3'b001 && row[1] ) ? 5'h16 :
					 ( col[2:0] == 3'b001 && row[2] ) ? 5'h19 :
					 ( col[2:0] == 3'b001 && row[3] ) ? 5'h1B :
					 ( col[2:1] == 3'b01  && row[0] ) ? 5'h12 :
					 ( col[2:1] == 3'b01  && row[1] ) ? 5'h15 :
					 ( col[2:1] == 3'b01  && row[2] ) ? 5'h18 :
					 ( col[2:1] == 3'b01  && row[3] ) ? 5'h10 :
					 ( col[2  ] == 3'b1   && row[0] ) ? 5'h11 :
					 ( col[2  ] == 3'b1   && row[1] ) ? 5'h14 :
					 ( col[2  ] == 3'b1   && row[2] ) ? 5'h17 :
					 ( col[2  ] == 3'b1   && row[3] ) ? 5'h1A : 5'h00;		
		end
	end	
endmodule

// BlipVert - From max headroom
// dump the entire memory as video pixels
// When enabled during active video line pels (!blank)
// writes address, end then burst reads 1kB to video each scanline

module blipvert (
	input clk,
	input reset,
	input enable,
	input [24:0] base, // starting block addr
	// Axi4 read Bus
	output logic [24:0] araddr,
	output logic [7:0]  arlen,
	output logic        arvalid,
	input  logic        arready,
	input  logic [17:0] rdata,
	input  logic        rvalid,
	// Video output data to fifo to hdmi live video
	output [16:0] vdata,
	output        vvalid
	);
	
	// State machine
	logic [1:0] state;
	localparam S_IDLE 	= 0;
	localparam S_ADDR 	= 1;
	localparam S_VALID   = 2;
	localparam S_WAIT		= 3;
	
	always @(posedge clk) begin
		if( reset ) begin
			state <= S_IDLE;
		end else begin
			case( state )
				S_IDLE : state <= ( enable ) ? S_ADDR : S_IDLE;
				S_ADDR : state <= ( enable ) ? S_VALID : S_IDLE;
				S_VALID: state <= ( !enable ) ? S_IDLE :
			                      ( arready && arvalid && addr[9:6] == 4'hF ) ? S_WAIT : S_VALID; 
				S_WAIT : state <= ( enable ) ? S_WAIT : S_IDLE;
			endcase
		end
	end
	assign arvalid = ( state == S_VALID ) ? 1'b1 : 1'b0;

	// Read Address
	logic [24:0] addr;
	logic [24:10] next_addr;
	
	assign next_addr[24:10] = addr[24:10] + 1;

	always @(posedge clk) begin
		if( reset ) begin
			addr <= 0;
		end else begin
			addr[5:0] <= 0;
			addr[9:6] <= ( state == S_ADDR ) ? 4'h0 :
			             ( state == S_VALID && arready && arvalid ) ? addr[9:6] + 4'h1 : addr[9:6];
			addr[24:10] <= ( state == S_ADDR ) ? next_addr[24:10] : addr[24:10];
		end
	end
	assign araddr[24:0] = addr[24:0];
	assign arlen[7:0] = 8'd32; 

	// Output
	always @(posedge clk) begin
		vvalid <= ( state == S_ADDR || ( enable && rvalid )) ? 1'b1 : 1'b0;
		vdata  <= ( state == S_ADDR ) ? { 2'b1, next_addr[24:10] == base[24:10], next_addr[24:10] } : // addr flag, start flag, addr 1k
		                                { 1'b0, rdata[16:9], rdata[7:0] }; // mem data
	end
	
endmodule



