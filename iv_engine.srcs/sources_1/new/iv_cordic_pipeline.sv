`timescale 1ns / 1ps

// =========================================================
// MODULE 1: The Single CORDIC Stage (Combinational)
// =========================================================
module cordic_hyperbolic_stage #(
    parameter integer STAGE_IDX = 0,
    parameter integer SHIFT_VAL = 1,
    parameter signed [31:0] ATANH_CONST = 32'd0
)(
    input  wire signed [31:0] x_in,
    input  wire signed [31:0] y_in,
    input  wire signed [31:0] z_in,
    input  wire               mode,  // 1 = Rotation (e^z), 0 = Vectoring (ln)
    
    output logic signed [31:0] x_out,
    output logic signed [31:0] y_out,
    output logic signed [31:0] z_out
);

    logic dir; // 1 = positive rotation, 0 = negative

    always_comb begin
        // Hardware Direction Decision
        if (mode == 1'b1) begin
            dir = (z_in >= 0) ? 1'b1 : 1'b0; // Rotation Mode: Drive Z to zero
        end else begin
            dir = (y_in < 0) ? 1'b1 : 1'b0;  // Vectoring Mode: Drive Y to zero (corrected)
        end

        // Shift-and-Add ALU Logic
        if (dir) begin
            x_out = x_in + (y_in >>> SHIFT_VAL);
            y_out = y_in + (x_in >>> SHIFT_VAL);
            z_out = z_in - ATANH_CONST;
        end else begin
            x_out = x_in - (y_in >>> SHIFT_VAL);
            y_out = y_in - (x_in >>> SHIFT_VAL);
            z_out = z_in + ATANH_CONST;
        end
    end
endmodule

// =========================================================
// MODULE 2: The 18-Stage Pipelined Wrapper (Sequential)
// =========================================================
module pipelined_hyperbolic_cordic (
    input  wire               clk,
    input  wire               rst_n,
    
    input  wire signed [31:0] x_in,
    input  wire signed [31:0] y_in,
    input  wire signed [31:0] z_in,
    input  wire               mode,     
    input  wire               valid_in, 
    
    output logic signed [31:0] x_out,
    output logic signed [31:0] y_out,
    output logic signed [31:0] z_out,
    output logic               valid_out 
);

    // --- FIX APPLIED HERE: Changed 'int' to 'localparam int' ---
    // Hardware Requirement: Repeat iterations 4 and 13
    localparam int SHIFTS [0:17] = '{1, 2, 3, 4, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 13, 14, 15, 16};
    
    // Atanh LUT in Q8.24 Format (Matches Python Golden Model)
    localparam int ATANH_LUT [0:17] = '{
        32'd9213465, 32'd4285819, 32'd2091932, 32'd1039863, 32'd1039863, 
        32'd519097,  32'd259345,  32'd129643,  32'd64817,   32'd32408, 
        32'd16204,   32'd8102,    32'd4051,    32'd2025,    32'd2025, 
        32'd1013,    32'd506,     32'd253
    };
    // -----------------------------------------------------------

    // Pipeline Interconnect Wires
    logic signed [31:0] x_pipe [0:18];
    logic signed [31:0] y_pipe [0:18];
    logic signed [31:0] z_pipe [0:18];
    logic               v_pipe [0:18];
    logic               m_pipe [0:18];  // Mode must travel with data

    // Map inputs to the start of the pipeline
    assign x_pipe[0] = x_in;
    assign y_pipe[0] = y_in;
    assign z_pipe[0] = z_in;
    assign v_pipe[0] = valid_in;
    assign m_pipe[0] = mode;

    // Generate the Unrolled Pipeline
    genvar i;
    generate
        for (i = 0; i < 18; i = i + 1) begin : cordic_pipeline
            
            logic signed [31:0] stage_x_out, stage_y_out, stage_z_out;
            
            // 1. Instantiate the Combinational Math block
            cordic_hyperbolic_stage #(
                .STAGE_IDX(i),
                .SHIFT_VAL(SHIFTS[i]),
                .ATANH_CONST(ATANH_LUT[i])
            ) math_stage (
                .x_in(x_pipe[i]),
                .y_in(y_pipe[i]),
                .z_in(z_pipe[i]),
                .mode(m_pipe[i]),    // Use pipelined mode, not raw input
                .x_out(stage_x_out),
                .y_out(stage_y_out),
                .z_out(stage_z_out)
            );
            
            // 2. Insert Clocked Pipeline Registers
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    x_pipe[i+1] <= '0;
                    y_pipe[i+1] <= '0;
                    z_pipe[i+1] <= '0;
                    v_pipe[i+1] <= 1'b0;
                    m_pipe[i+1] <= 1'b0;
                end else begin
                    x_pipe[i+1] <= stage_x_out;
                    y_pipe[i+1] <= stage_y_out;
                    z_pipe[i+1] <= stage_z_out;
                    v_pipe[i+1] <= v_pipe[i]; // Valid flag travels with data
                    m_pipe[i+1] <= m_pipe[i]; // Mode travels with data
                end
            end
        end
    endgenerate

    // Map outputs from the end of the pipeline
    assign x_out = x_pipe[18];
    assign y_out = y_pipe[18];
    assign z_out = z_pipe[18];
    assign valid_out = v_pipe[18];

endmodule