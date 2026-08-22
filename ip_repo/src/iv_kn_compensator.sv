`timescale 1ns / 1ps

// =========================================================
// Hyperbolic CORDIC Gain Compensator (Q8.24 Fixed-Point)
// =========================================================
// Hyperbolic CORDIC accumulative scale factor K_n ≈ 0.82815936.
// To recover true hyperbolic values (cosh, sinh, exp), output
// must be scaled by 1/K_n ≈ 1.207497063.
//
// In Q8.24 format:
// 1.207497063 * 2^24 = 20,258,170 (32'sd20258170)
//
// Latency: 1 clock cycle (registered multiplier for 250 MHz)
// =========================================================
module iv_kn_compensator (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               valid_in,
    input  wire signed [31:0] data_in,

    output logic              valid_out,
    output logic signed [31:0] data_out
);

    localparam signed [31:0] INV_KN_Q24 = 32'sd20258170; // 1.207497063 in Q8.24

    logic signed [63:0] mult_result;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mult_result <= 64'sd0;
            data_out    <= 32'sd0;
            valid_out   <= 1'b0;
        end else begin
            valid_out   <= valid_in;
            mult_result <= $signed(data_in) * $signed(INV_KN_Q24);
            data_out    <= signed'(mult_result >>> 24);
        end
    end

endmodule
