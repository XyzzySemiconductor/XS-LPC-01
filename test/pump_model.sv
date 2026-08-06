// vim: ts=4:
// A plant model of the pump and system for simulation
// In this case it is for runnig on the MAX 10 simulation accelerator, so is synthesizable.
// Tests run externally, and feed parameters to the model which is active whenever pump_out = 1;
// normal behavior, 1 sec pump start and 10 seconds normal, then drop to empty cavitatiosn
// The other behaviors can be builts on top.

module pump_model 
	#(

		parameter SP_STALL 	= 12'sd1103 ,		// >= 15 amps rms
		parameter SP_RUN 	= 12'sd735  ,			// typical 10 amps rms
		parameter SP_EMPTY 	= 12'sd663  ,		// empty say 9 amps rms
		parameter SP_OFF	= 12'sd7 			// Off still ac noise 0.1 amps rms
	) (
		// System
		input logic clk,
		input logic reset,
		// Pump Model Advance time passage (250 Msec)
		input logic tick,
		// System Inputs to model
		input pump_out,	// signal to turn on pump
		// Model to System Outputs (to 12bit input to ADC simulator
		output signed [11:0] ct,	// range +/-2000 is +/-30 Amps isntantaneous (typicaol 10Amp RMS = +/-15Amps
		// Fault inputs into Model:
		input logic empty, 	// change setpoint to empty current if not start current
		input logic stall, 	// change to the stall current (or keep it in stall after start)
		input logic n_empty, 	// change to the normal curretn (if not start current
		// Monitor output
		output logic [11:0] fpga_probe
	);
	
  	/////////////////////
	// 60 Hz sin/cos cordic
  	/////////////////////

	// create /16 sample flag
	reg [3:0] sample_count;
	wire sample_flag;
	always @(posedge clk)
		sample_count <= ( reset ) ? 0 : sample_count + 1;
	assign sample_flag = ( sample_count == 15 ) ? 1'b1 : 1'b0;
	
	// Create the -pi/2 to pi/2 angle sweep
    reg signed [15:0] angle;
    always @(posedge clk) begin
        if( reset ) begin
            angle <= -12500;
        end else if ( sample_flag ) begin
            angle <= ( angle == 12499 ) ? -12500 : angle + 1;
        end
    end

	// create polarity correction
    reg polarity;
    always @(posedge clk) begin
        if( reset ) begin
            polarity <= 1;
        end else if ( sample_flag ) begin
            polarity <= ( angle == 12499 ) ? !polarity : polarity;
        end
    end

	// Cordic 50K point = 2*PI
    wire [15:0] sin_out, cos_out;
    cordic_sincos_50000_core_20 i_tb_sin(
        .clk( clk ),
        .rst( reset ),
        .start( sample_flag ),
        .angle_in( angle ),
        .sin_out ( sin_out ),
        .cos_out ( cos_out ),
        .valid( ),
        .busy( )
    );

	// Corect polarity
   wire [15:0] cos_pol, sin_pol;
   assign cos_pol = ( polarity ) ? ~cos_out : cos_out;
   assign sin_pol = ( polarity ) ? ~sin_out : sin_out;
	// scale 3/8 so peaks at +/-1544, about 75% full scale
   wire signed [11:0] cos3x, sin3x;
   assign cos3x = cos_pol[15-:12] + { cos_pol[15], cos_pol[15-:11] };
   assign sin3x = sin_pol[15-:12] + { sin_pol[15], sin_pol[15-:11] };
	
	// Most basic of behavior
	// TODO add some slope to transistions
	logic signed [11:0] ct_scale_sp;
	logic signed [11:0] sp_auto;
	logic signed [21:0] ct_scale;
	assign ct_scale_sp = ( !pump_out ) ? SP_OFF : ( sp_auto == SP_STALL ) ? SP_STALL : ( empty ) ? SP_EMPTY : ( n_empty ) ? SP_RUN : ( stall ) ? SP_STALL : sp_auto;
	
	// ct_scale goes to the setpoint by 1 each cycle
	// moves at 800 stgeps pr 60 Hz cycle
    always @(posedge clk) 	
			ct_scale <= ( reset ) ? 0 : ( ct_scale[21-:12] < ct_scale_sp ) ? ct_scale + 1 :
			                            ( ct_scale[21-:12] > ct_scale_sp ) ? ct_scale - 1 : ct_scale;
	assign fpga_probe = ct_scale[21-:12];
	
	// Scale the sin3x output
	logic signed [23:0] ct_rms;
    always @(posedge clk) 	
		ct_rms <= (( ct_scale >>> 10 ) * cos3x ) >>> 10;
	
	assign ct[11:0] = { ct_rms[23], ct_rms[10:0] }; // scale can double teh +/-1544 sin. So max is 1.3 ish for this scale factor.
	
	// Expanded to standard cycle
	// When turned on pump will ramp to stall==start current, for 1 sec
	// then will fall to normal, for 10 sec (beyond the short cycle time
	// then will fall to empty, until pump is turned off
	logic [15:0] pump_time;
   always @(posedge clk) 	
		pump_time <= ( reset ) ? 0 : ( !pump_out ) ? 0 : ( tick ) ? pump_time + 1 : pump_time;
		
	assign sp_auto = 	( pump_out && pump_time <= 4 	) ? SP_STALL :
						( pump_time >  4 && pump_time <= 40 ) ? SP_RUN :
						( pump_time > 40                    ) ? SP_EMPTY : SP_OFF;
	
	

endmodule



