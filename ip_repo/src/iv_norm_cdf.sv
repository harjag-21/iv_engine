`timescale 1ns / 1ps

// =========================================================
// Standard Normal CDF N(x) & PDF phi(x) (Q8.24 Fixed-Point)
// =========================================================
// Implements the Abramowitz & Stegun polynomial approximation
// for the standard normal Cumulative Distribution Function N(x).
//
// Formula (for x >= 0):
//   phi(x) = (1 / sqrt(2*pi)) * exp(-x^2 / 2)
//   t      = 1 / (1 + p * x)
//   poly   = b1*t + b2*t^2 + b3*t^3 + b4*t^4 + b5*t^5
//   N(x)   = 1 - phi(x) * poly
//   For x < 0: N(x) = 1 - N(-x)
//
// All internal math performed in Q8.24 fixed-point (2^24 = 16,777,216).
// Latency: 4 clock cycles (fully pipelined).
// =========================================================
module iv_norm_cdf (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               valid_in,
    input  wire signed [31:0] x_in,         // Q8.24 input d1 or d2

    output logic              valid_out,
    output logic signed [31:0] cdf_out,      // N(x) in Q8.24
    output logic signed [31:0] pdf_out       // phi(x) in Q8.24
);

    // Q8.24 Fixed-Point Constants
    localparam signed [31:0] Q24_ONE      = 32'sd16777216; // 1.0
    localparam signed [31:0] INV_SQRT_2PI = 32'sd6693156;  // 1/sqrt(2*pi) ≈ 0.39894228
    localparam signed [31:0] P_CONST      = 32'sd3886284;  // p ≈ 0.2316419
    localparam signed [31:0] B1           = 32'sd5358908;  // b1 ≈  0.31938153
    localparam signed [31:0] B2           = -32'sd5982098; // b2 ≈ -0.35656378
    localparam signed [31:0] B3           = 32'sd29888258; // b3 ≈  1.78147794
    localparam signed [31:0] B4           = -32'sd30555546;// b4 ≈ -1.82125598
    localparam signed [31:0] B5           = 32'sd22318398; // b5 ≈  1.33027443

    // Pipelined Stage Registers
    logic               v1;
    logic               is_neg1;
    logic signed [31:0] abs_x1;
    logic signed [31:0] x2_half1;

    logic               v2;
    logic               is_neg2;
    logic signed [31:0] phi2;
    logic signed [31:0] t2;

    logic               v3;
    logic               is_neg3;
    logic signed [31:0] phi3;
    logic signed [31:0] poly3;

    // Intermediate Combinational Helper Variables (Module-level declaration for Vivado compliance)
    logic signed [63:0] u2;
    logic signed [31:0] exp_approx;
    logic signed [63:0] px;
    logic signed [31:0] denom;
    logic signed [63:0] p54, p543, p5432, p_full;
    logic signed [63:0] cdf_pos;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v1 <= 1'b0; is_neg1 <= 1'b0; abs_x1 <= 32'sd0; x2_half1 <= 32'sd0;
            v2 <= 1'b0; is_neg2 <= 1'b0; phi2 <= 32'sd0;   t2 <= 32'sd0;
            v3 <= 1'b0; is_neg3 <= 1'b0; phi3 <= 32'sd0;   poly3 <= 32'sd0;
            valid_out <= 1'b0; cdf_out <= 32'sd0; pdf_out <= 32'sd0;
        end else begin
            // -------------------------------------------------------------
            // Stage 1: Input decomposition
            // -------------------------------------------------------------
            v1      <= valid_in;
            is_neg1 <= x_in[31];
            abs_x1  <= x_in[31] ? -x_in : x_in;
            
            // x^2 / 2 calculation in Q8.24
            x2_half1 <= signed'(( (signed'(x_in[31] ? -x_in : x_in) * signed'(x_in[31] ? -x_in : x_in)) >>> 25 ));

            // -------------------------------------------------------------
            // Stage 2: PDF approximation & t term
            // -------------------------------------------------------------
            v2      <= v1;
            is_neg2 <= is_neg1;
            
            if (x2_half1 > 32'sd50331648) begin
                phi2 <= 32'sd0;
            end else begin
                u2 = (signed'(x2_half1) * signed'(x2_half1)) >>> 24;
                exp_approx = Q24_ONE - x2_half1 + signed'(u2 >>> 1);
                if (exp_approx < 0) exp_approx = 32'sd0;
                phi2 <= signed'((signed'(INV_SQRT_2PI) * signed'(exp_approx)) >>> 24);
            end

            px    = (signed'(P_CONST) * signed'(abs_x1)) >>> 24;
            denom = Q24_ONE + signed'(px);
            t2    <= Q24_ONE - signed'(px) + signed'(((px * px) >>> 24));

            // -------------------------------------------------------------
            // Stage 3: Polynomial evaluation
            // -------------------------------------------------------------
            v3      <= v2;
            is_neg3 <= is_neg2;
            phi3    <= phi2;

            p54   = B4 + ((signed'(B5) * signed'(t2)) >>> 24);
            p543  = B3 + ((signed'(p54) * signed'(t2)) >>> 24);
            p5432 = B2 + ((signed'(p543) * signed'(t2)) >>> 24);
            p_full= B1 + ((signed'(p5432) * signed'(t2)) >>> 24);
            poly3 <= signed'((signed'(p_full) * signed'(t2)) >>> 24);

            // -------------------------------------------------------------
            // Stage 4: N(x) calculation & symmetry
            // -------------------------------------------------------------
            valid_out <= v3;
            pdf_out   <= phi3;

            cdf_pos = Q24_ONE - ((signed'(phi3) * signed'(poly3)) >>> 24);
            
            if (is_neg3) begin
                cdf_out <= Q24_ONE - signed'(cdf_pos);
            end else begin
                cdf_out <= signed'(cdf_pos);
            end
        end
    end

endmodule
