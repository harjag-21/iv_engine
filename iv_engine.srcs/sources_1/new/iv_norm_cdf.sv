`timescale 1ns / 1ps

// =========================================================
// Standard Normal CDF N(x) & PDF phi(x) (Q8.24 Fixed-Point)
// =========================================================
// Implements 5-term Abramowitz & Stegun Horner scheme polynomial
// approximation for the standard normal Cumulative Distribution Function N(x).
//
// Formula (for x >= 0):
//   phi(x) = (1 / sqrt(2*pi)) * exp(-x^2 / 2)
//   t      = 1 / (1 + p * x)        [Evaluated via iv_divider_q824, 33 cycles]
//   poly   = t * (b1 + t * (b2 + t * (b3 + t * (b4 + t * b5))))
//   N(x)   = 1 - phi(x) * poly
//   For x < 0: N(x) = 1 - N(-x)
//
// Pipelined Horner Polynomial Implementation:
//   Stage 3a: latch t, phi, is_neg from delay lines          (1 cycle)
//   Stage 3b: p4 = B4 + B5 * t                               (1 multiply)
//   Stage 3c: p3 = B3 + p4 * t                               (1 multiply)
//   Stage 3d: p2 = B2 + p3 * t                               (1 multiply)
//   Stage 3e: p1 = B1 + p2 * t                               (1 multiply)
//   Stage 4a: poly = p1 * t                                  (1 multiply)
//   Stage 4b: N(x) = 1 - phi * poly; symmetry output         (1 multiply)
//
// Latency: 1 (Stage 1) + 33 (Divider) + 7 (Pipelined Horner 3a–4b) = 41 cycles.
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

    // Q8.24 Fixed-Point Constants (Abramowitz & Stegun 26.2.17)
    localparam signed [31:0] Q24_ONE      = 32'sd16777216; // 1.0
    localparam signed [31:0] INV_SQRT_2PI = 32'sd6693156;  // 1/sqrt(2*pi) ≈ 0.39894228
    localparam signed [31:0] P_CONST      = 32'sd3886284;  // p ≈ 0.2316419
    localparam signed [63:0] B5           = 32'sd22318398; // b5 ≈  1.33027443
    localparam signed [31:0] B4           = -32'sd30555546;// b4 ≈ -1.82125598
    localparam signed [31:0] B3           = 32'sd29888258; // b3 ≈  1.78147794
    localparam signed [31:0] B2           = -32'sd5982098; // b2 ≈ -0.35656378
    localparam signed [31:0] B1           = 32'sd5358908;  // b1 ≈  0.31938153

    // Safe absolute value with MIN_INT protection
    wire signed [31:0] safe_abs_x = (x_in == 32'sh80000000) ? 32'sh7FFFFFFF :
                                    (x_in[31] ? -x_in : x_in);

    // -------------------------------------------------------------
    // Stage 1: Input decomposition & t denominator computation (1 cycle)
    // -------------------------------------------------------------
    logic               v1;
    logic               is_neg1;
    logic signed [31:0] abs_x1;
    logic signed [31:0] x2_half1;
    logic signed [31:0] t_denom1;
    logic signed [63:0] px_var1;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v1       <= 1'b0;
            is_neg1  <= 1'b0;
            abs_x1   <= 32'sd0;
            x2_half1 <= 32'sd0;
            t_denom1 <= 32'sd0;
        end else begin
            v1       <= valid_in;
            is_neg1  <= x_in[31];
            abs_x1   <= safe_abs_x;
            // 64-bit cast prevents overflow when |x| >= 1.0
            x2_half1 <= signed'(( (64'(signed'(safe_abs_x)) * 64'(signed'(safe_abs_x))) >>> 25 ));

            px_var1  = (signed'(P_CONST) * signed'(safe_abs_x)) >>> 24;
            t_denom1 <= Q24_ONE + signed'(px_var1);
        end
    end

    // -------------------------------------------------------------
    // Stage 2: Pipelined Divider for t = 1 / (1 + p*|x|) (33 cycles)
    // -------------------------------------------------------------
    wire               t_div_valid;
    wire signed [31:0] t_div_out;

    iv_divider_q824 u_t_divider (
        .clk            (clk),
        .rst_n          (rst_n),
        .valid_in       (v1),
        .numerator_in   (Q24_ONE),
        .denominator_in ((t_denom1 != 0) ? t_denom1 : 32'sd1),
        .valid_out      (t_div_valid),
        .quotient_out   (t_div_out)
    );

    // Compute PDF phi(x) in parallel with divider start (1 cycle after Stage 1)
    logic signed [31:0] phi2;
    logic signed [63:0] u2_var, u3_var, u4_var, exp_approx_var;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phi2 <= 32'sd0;
        end else begin
            if (x2_half1 > 32'sd50331648) begin
                phi2 <= 32'sd0;
            end else begin
                // 4th-order minimax exp(-u)
                u2_var = (signed'(x2_half1) * signed'(x2_half1)) >>> 24;
                u3_var = (signed'(u2_var) * signed'(x2_half1)) >>> 24;
                u4_var = (signed'(u2_var) * signed'(u2_var)) >>> 24;
                exp_approx_var = Q24_ONE - x2_half1
                               + signed'(u2_var >>> 1)
                               - signed'(u3_var / 6)
                               + signed'(u4_var / 24);
                if (exp_approx_var < 0) exp_approx_var = 32'sd0;
                phi2 <= signed'((signed'(INV_SQRT_2PI) * signed'(exp_approx_var)) >>> 24);
            end
        end
    end

    // Delay lines for phi2, is_neg1, abs_x1 through 33-cycle divider
    // phi2 is produced 1 cycle after Stage 1, so it delays through 32 cycles.
    // is_neg1 and abs_x1 delay through 33 cycles.
    logic signed [31:0] phi_delay [0:32];
    logic               is_neg_delay [0:33];
    logic signed [31:0] abs_x_delay [0:33];

    assign phi_delay[0]    = phi2;
    assign is_neg_delay[0] = is_neg1;
    assign abs_x_delay[0]  = abs_x1;

    genvar g;
    generate
        for (g = 0; g < 32; g = g + 1) begin : phi_delay_gen
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) phi_delay[g+1] <= 32'sd0;
                else        phi_delay[g+1] <= phi_delay[g];
            end
        end
        for (g = 0; g < 33; g = g + 1) begin : meta_delay_gen
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    is_neg_delay[g+1] <= 1'b0;
                    abs_x_delay[g+1]  <= 32'sd0;
                end else begin
                    is_neg_delay[g+1] <= is_neg_delay[g];
                    abs_x_delay[g+1]  <= abs_x_delay[g];
                end
            end
        end
    endgenerate

    wire signed [31:0] phi_aligned    = phi_delay[32];
    wire               is_neg_aligned = is_neg_delay[33];
    wire signed [31:0] abs_x_aligned  = abs_x_delay[33];

    // =============================================================
    // Pipelined Horner Polynomial Evaluation — 6 stages (3a–4a), 1 output
    // Each stage has at most ONE 64-bit multiply for timing closure at 250 MHz.
    // =============================================================

    // -------------------------------------------------------------
    // Stage 3a: Latch t, phi, is_neg from aligned delay lines (1 cycle, no multiply)
    // -------------------------------------------------------------
    logic               v3a;
    logic               is_neg3a;
    logic signed [31:0] phi3a;
    logic signed [31:0] t3a;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v3a      <= 1'b0;
            is_neg3a <= 1'b0;
            phi3a    <= 32'sd0;
            t3a      <= 32'sd0;
        end else begin
            v3a      <= t_div_valid;
            is_neg3a <= is_neg_aligned;
            phi3a    <= phi_aligned;
            // Clamp t if |x| is large (|x| > 3.885 => phi ≈ 0, t ≈ 0)
            if (abs_x_aligned > 32'sd65184200) begin
                t3a <= 32'sd0;
            end else begin
                t3a <= t_div_out;
            end
        end
    end

    // -------------------------------------------------------------
    // Stage 3b: Horner Step 1 — p4 = B4 + B5 * t  (1 multiply)
    // -------------------------------------------------------------
    logic               v3b;
    logic               is_neg3b;
    logic signed [31:0] phi3b, t3b;
    logic signed [63:0] p4_3b;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v3b <= 1'b0; is_neg3b <= 1'b0; phi3b <= 32'sd0; t3b <= 32'sd0; p4_3b <= 64'sd0;
        end else begin
            v3b      <= v3a;
            is_neg3b <= is_neg3a;
            phi3b    <= phi3a;
            t3b      <= t3a;
            p4_3b    <= B4 + ((B5 * signed'(t3a)) >>> 24);
        end
    end

    // -------------------------------------------------------------
    // Stage 3c: Horner Step 2 — p3 = B3 + p4 * t  (1 multiply)
    // -------------------------------------------------------------
    logic               v3c;
    logic               is_neg3c;
    logic signed [31:0] phi3c, t3c;
    logic signed [63:0] p3_3c;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v3c <= 1'b0; is_neg3c <= 1'b0; phi3c <= 32'sd0; t3c <= 32'sd0; p3_3c <= 64'sd0;
        end else begin
            v3c      <= v3b;
            is_neg3c <= is_neg3b;
            phi3c    <= phi3b;
            t3c      <= t3b;
            p3_3c    <= B3 + ((signed'(p4_3b) * signed'(t3b)) >>> 24);
        end
    end

    // -------------------------------------------------------------
    // Stage 3d: Horner Step 3 — p2 = B2 + p3 * t  (1 multiply)
    // -------------------------------------------------------------
    logic               v3d;
    logic               is_neg3d;
    logic signed [31:0] phi3d, t3d;
    logic signed [63:0] p2_3d;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v3d <= 1'b0; is_neg3d <= 1'b0; phi3d <= 32'sd0; t3d <= 32'sd0; p2_3d <= 64'sd0;
        end else begin
            v3d      <= v3c;
            is_neg3d <= is_neg3c;
            phi3d    <= phi3c;
            t3d      <= t3c;
            p2_3d    <= B2 + ((signed'(p3_3c) * signed'(t3c)) >>> 24);
        end
    end

    // -------------------------------------------------------------
    // Stage 3e: Horner Step 4 — p1 = B1 + p2 * t  (1 multiply)
    // -------------------------------------------------------------
    logic               v3e;
    logic               is_neg3e;
    logic signed [31:0] phi3e, t3e;
    logic signed [63:0] p1_3e;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v3e <= 1'b0; is_neg3e <= 1'b0; phi3e <= 32'sd0; t3e <= 32'sd0; p1_3e <= 64'sd0;
        end else begin
            v3e      <= v3d;
            is_neg3e <= is_neg3d;
            phi3e    <= phi3d;
            t3e      <= t3d;
            p1_3e    <= B1 + ((signed'(p2_3d) * signed'(t3d)) >>> 24);
        end
    end

    // -------------------------------------------------------------
    // Stage 4a: Horner Step 5 — poly = p1 * t  (1 multiply, final accumulation)
    // -------------------------------------------------------------
    logic               v4a;
    logic               is_neg4a;
    logic signed [31:0] phi4a;
    logic signed [31:0] poly4a;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v4a <= 1'b0; is_neg4a <= 1'b0; phi4a <= 32'sd0; poly4a <= 32'sd0;
        end else begin
            v4a      <= v3e;
            is_neg4a <= is_neg3e;
            phi4a    <= phi3e;
            poly4a   <= signed'((signed'(p1_3e) * signed'(t3e)) >>> 24);
        end
    end

    // -------------------------------------------------------------
    // Stage 4b: N(x) = 1 - phi * poly & sign symmetry (1 multiply, output)
    // -------------------------------------------------------------
    logic signed [63:0] cdf_pos_var;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_out <= 1'b0;
            cdf_out   <= 32'sd0;
            pdf_out   <= 32'sd0;
        end else begin
            valid_out <= v4a;
            pdf_out   <= phi4a;

            cdf_pos_var = Q24_ONE - ((signed'(phi4a) * signed'(poly4a)) >>> 24);
            if (cdf_pos_var < 0) cdf_pos_var = 64'sd0;
            if (cdf_pos_var > Q24_ONE) cdf_pos_var = Q24_ONE;

            if (is_neg4a) begin
                cdf_out <= Q24_ONE - signed'(cdf_pos_var);
            end else begin
                cdf_out <= signed'(cdf_pos_var);
            end
        end
    end

endmodule
