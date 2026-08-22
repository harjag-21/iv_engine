`timescale 1ns / 1ps

// =========================================================
// Pipelined Q8.24 Non-Restoring Divider
// =========================================================
// Computes: quotient = (numerator / denominator) in Q8.24 format.
// Latency: 32 clock cycles (fully pipelined, 1 bit per stage).
// Resource utilization: 0 DSP blocks (LUT/FF shift-subtract).
// =========================================================
module iv_divider_q824 (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               valid_in,
    input  wire signed [31:0] numerator_in,
    input  wire signed [31:0] denominator_in,

    output logic              valid_out,
    output logic signed [31:0] quotient_out
);

    // 32-stage shift-and-subtract pipeline
    logic signed [63:0] num_pipe  [0:32];
    logic signed [31:0] den_pipe  [0:32];
    logic signed [31:0] quot_pipe [0:32];
    logic               v_pipe    [0:32];

    assign num_pipe[0]  = (signed'(numerator_in) < 0) ? -($signed(numerator_in) << 24) : ($signed(numerator_in) << 24);
    assign den_pipe[0]  = (signed'(denominator_in) < 0) ? -$signed(denominator_in) : $signed(denominator_in);
    assign quot_pipe[0] = 32'sd0;
    assign v_pipe[0]    = valid_in;

    genvar k;
    generate
        for (k = 0; k < 32; k = k + 1) begin : div_stage
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    num_pipe[k+1]  <= 64'sd0;
                    den_pipe[k+1]  <= 32'sd0;
                    quot_pipe[k+1] <= 32'sd0;
                    v_pipe[k+1]    <= 1'b0;
                end else begin
                    v_pipe[k+1]   <= v_pipe[k];
                    den_pipe[k+1] <= den_pipe[k];

                    if (num_pipe[k] >= ($signed(den_pipe[k]) << (31 - k))) begin
                        num_pipe[k+1]  <= num_pipe[k] - ($signed(den_pipe[k]) << (31 - k));
                        quot_pipe[k+1] <= (quot_pipe[k] << 1) | 32'sd1;
                    end else begin
                        num_pipe[k+1]  <= num_pipe[k];
                        quot_pipe[k+1] <= (quot_pipe[k] << 1);
                    end
                end
            end
        end
    endgenerate

    // Final sign correction at stage 32
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_out    <= 1'b0;
            quotient_out <= 32'sd0;
        end else begin
            valid_out <= v_pipe[32];
            if ((numerator_in[31] ^ denominator_in[31]) && (quot_pipe[32] != 0)) begin
                quotient_out <= -quot_pipe[32];
            end else begin
                quotient_out <= quot_pipe[32];
            end
        end
    end

endmodule
