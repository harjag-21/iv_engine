`timescale 1ns / 1ps

// =========================================================
// Pipelined Q8.24 Restoring Divider (Optimized 32-Bit Datapath)
// =========================================================
// Computes: quotient = (numerator / denominator) in Q8.24 format.
// Latency: 33 clock cycles (fully pipelined, 1 bit per stage).
// Resource utilization: 0 DSP blocks (32-bit compact subtractor).
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

    // 32-stage compact 32-bit shift-remainder pipeline
    logic [31:0] rem_pipe     [0:32];
    logic [30:0] num_low_pipe [0:32];
    logic [31:0] den_pipe     [0:32];
    logic [31:0] quot_pipe    [0:32];
    logic        v_pipe       [0:32];
    logic        sign_pipe    [0:32];
    logic        dbz_pipe     [0:32]; // Divide-by-zero flag

    wire [31:0] num_mag = (numerator_in[31]) ? 32'(-signed'(numerator_in)) : 32'(signed'(numerator_in));
    wire [31:0] den_abs = (denominator_in == 32'sh80000000) ? 32'sh7FFFFFFF :
                          (signed'(denominator_in) < 0) ? -$signed(denominator_in) : $signed(denominator_in);

    assign rem_pipe[0]     = {7'd0, num_mag[31:7]};
    assign num_low_pipe[0] = {num_mag[6:0], 24'd0};
    assign den_pipe[0]     = den_abs;
    assign quot_pipe[0]    = 32'd0;
    assign v_pipe[0]       = valid_in;
    assign sign_pipe[0]    = numerator_in[31] ^ denominator_in[31];
    assign dbz_pipe[0]     = (denominator_in == 32'sd0);

    genvar k;
    generate
        for (k = 0; k < 32; k = k + 1) begin : div_stage
            wire [31:0] sub_rem = rem_pipe[k] - den_pipe[k];
            wire        rem_ge_den = (rem_pipe[k] >= den_pipe[k]);

            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    rem_pipe[k+1]     <= 32'd0;
                    num_low_pipe[k+1] <= 31'd0;
                    den_pipe[k+1]     <= 32'd0;
                    quot_pipe[k+1]    <= 32'd0;
                    v_pipe[k+1]       <= 1'b0;
                    sign_pipe[k+1]    <= 1'b0;
                    dbz_pipe[k+1]     <= 1'b0;
                end else begin
                    v_pipe[k+1]    <= v_pipe[k];
                    sign_pipe[k+1] <= sign_pipe[k];
                    dbz_pipe[k+1]  <= dbz_pipe[k];
                    den_pipe[k+1]  <= den_pipe[k];

                    if (rem_ge_den) begin
                        rem_pipe[k+1]  <= {sub_rem[30:0], num_low_pipe[k][30]};
                        quot_pipe[k+1] <= {quot_pipe[k][30:0], 1'b1};
                    end else begin
                        rem_pipe[k+1]  <= {rem_pipe[k][30:0], num_low_pipe[k][30]};
                        quot_pipe[k+1] <= {quot_pipe[k][30:0], 1'b0};
                    end
                    num_low_pipe[k+1] <= {num_low_pipe[k][29:0], 1'b0};
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
