`timescale 1ns / 1ps

// =========================================================
// Pipelined Q8.24 Non-Restoring Divider (Fixed Sign Pipeline)
// =========================================================
// Computes: quotient = (numerator / denominator) in Q8.24 format.
// Latency: 33 clock cycles (fully pipelined, 1 bit per stage).
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
    logic               sign_pipe [0:32];
    logic               dbz_pipe  [0:32]; // Divide-by-zero flag

    assign num_pipe[0]  = (numerator_in[31]) ? -(64'(signed'(numerator_in)) <<< 24) : (64'(signed'(numerator_in)) <<< 24);
    assign den_pipe[0]  = (denominator_in == 32'sh80000000) ? 32'sh7FFFFFFF :
                       (signed'(denominator_in) < 0) ? -$signed(denominator_in) : $signed(denominator_in);
    assign quot_pipe[0] = 32'sd0;
    assign v_pipe[0]    = valid_in;
    assign sign_pipe[0] = numerator_in[31] ^ denominator_in[31];
    assign dbz_pipe[0]  = (denominator_in == 32'sd0);

    genvar k;
    generate
        for (k = 0; k < 32; k = k + 1) begin : div_stage
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    num_pipe[k+1]  <= 64'sd0;
                    den_pipe[k+1]  <= 32'sd0;
                    quot_pipe[k+1] <= 32'sd0;
                    v_pipe[k+1]    <= 1'b0;
                    sign_pipe[k+1] <= 1'b0;
                    dbz_pipe[k+1]  <= 1'b0;
                end else begin
                    v_pipe[k+1]    <= v_pipe[k];
                    sign_pipe[k+1] <= sign_pipe[k];
                    dbz_pipe[k+1]  <= dbz_pipe[k];
                    den_pipe[k+1]  <= den_pipe[k];

                    if (num_pipe[k] >= (64'(signed'(den_pipe[k])) << (31 - k))) begin
                        num_pipe[k+1]  <= num_pipe[k] - (64'(signed'(den_pipe[k])) << (31 - k));
                        quot_pipe[k+1] <= (quot_pipe[k] << 1) | 32'sd1;
                    end else begin
                        num_pipe[k+1]  <= num_pipe[k];
                        quot_pipe[k+1] <= (quot_pipe[k] << 1);
                    end
                end
            end
        end
    endgenerate

    // Final sign & divide-by-zero correction at stage 32
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_out    <= 1'b0;
            quotient_out <= 32'sd0;
        end else begin
            valid_out <= v_pipe[32];
            if (dbz_pipe[32]) begin
                quotient_out <= 32'sd0; // Clamp divide-by-zero to 0
            end else begin
                automatic logic [31:0] clamped_quot;
                if (quot_pipe[32][31]) begin
                    clamped_quot = 32'h7FFFFFFF;
                end else begin
                    clamped_quot = quot_pipe[32];
                end

                if (sign_pipe[32] && (clamped_quot != 0)) begin
                    quotient_out <= -clamped_quot;
                end else begin
                    quotient_out <= clamped_quot;
                end
            end
        end
    end

endmodule
