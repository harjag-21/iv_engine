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
// Latency: 3 (Stages 1a/1b/1c) + 33 (Divider) + 13 (Horner 3a–4d) = 49 cycles.
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
    localparam signed [31:0] B5           = 32'sd22318398; // b5 ≈  1.33027443
    localparam signed [31:0] B4           = -32'sd30555546;// b4 ≈ -1.82125598
    localparam signed [31:0] B3           = 32'sd29888258; // b3 ≈  1.78147794
    localparam signed [31:0] B2           = -32'sd5982098; // b2 ≈ -0.35656378
    localparam signed [31:0] B1           = 32'sd5358908;  // b1 ≈  0.31938153

    // Safe absolute value with MIN_INT protection
    wire signed [31:0] safe_abs_x = (x_in == 32'sh80000000) ? 32'sh7FFFFFFF :
                                    (x_in[31] ? -x_in : x_in);

    // -------------------------------------------------------------
    // Stage 1a: Latch sign and compute safe_abs_x (1 cycle, pure logic)
    // -------------------------------------------------------------
    logic               v1a;
    logic               is_neg1a;
    logic signed [31:0] abs_x1a;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v1a      <= 1'b0;
            is_neg1a <= 1'b0;
            abs_x1a  <= 32'sd0;
        end else begin
            v1a      <= valid_in;
            is_neg1a <= x_in[31];
            abs_x1a  <= safe_abs_x;
        end
    end

    // -------------------------------------------------------------
    // Stage 1b: Parallel DSP multipliers for x^2/2 and p*|x| (1 cycle, pure DSP)
    // -------------------------------------------------------------
    logic               v1b;
    logic               is_neg1b;
    logic signed [31:0] abs_x1b;
    (* use_dsp = "yes" *) logic signed [31:0] x2_half1;
    (* use_dsp = "yes" *) logic signed [31:0] px_prod_1b;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v1b        <= 1'b0;
            is_neg1b   <= 1'b0;
            abs_x1b    <= 32'sd0;
            x2_half1   <= 32'sd0;
            px_prod_1b <= 32'sd0;
        end else begin
            v1b        <= v1a;
            is_neg1b   <= is_neg1a;
            abs_x1b    <= abs_x1a;
            x2_half1   <= signed'(((64'(signed'(abs_x1a)) * 64'(signed'(abs_x1a))) >>> 25));
            px_prod_1b <= signed'(((64'(signed'(P_CONST)) * 64'(signed'(abs_x1a))) >>> 24));
        end
    end

    // -------------------------------------------------------------
    // Stage 1c: Compute t_denom = 1 + p*|x| and feed divider (1 cycle, pure adder)
    // -------------------------------------------------------------
    logic               v1;
    logic               is_neg1;
    logic signed [31:0] abs_x1;
    logic signed [31:0] t_denom1;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v1       <= 1'b0;
            is_neg1  <= 1'b0;
            abs_x1   <= 32'sd0;
            t_denom1 <= 32'sd0;
        end else begin
            v1       <= v1b;
            is_neg1  <= is_neg1b;
            abs_x1   <= abs_x1b;
            t_denom1 <= Q24_ONE + px_prod_1b;
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

    // -------------------------------------------------------------
    // Pipelined PDF phi(x) Engine — 6 registered stages
    // Each stage contains at most ONE 32x32 DSP multiply on the critical path.
    //
    // Stage 2a (cy2): u2 = x2^2                           [1 multiply]
    // Stage 2b (cy3): u3 = u2 * x2                        [1 multiply]
    // Stage 2c (cy4): u4 = u2 * u2                        [1 multiply, parallel to 2b-output]
    // Stage 2d (cy5): u3/6 and u4/24                      [2 multiplies, independent/parallel]
    // Stage 2e (cy6): sum: 1 - u + u2/2 - u3/6 + u4/24   [adder only, no multiply]
    // Stage 2f (cy7): phi = INV_SQRT_2PI * exp            [1 multiply]
    //
    // Total: 6 cycles → delay chain = 33 - 6 = 27 taps
    // Constants in Q8.24:
    //   INV_6_Q24  = round(2^24 / 6)  = 2796203
    //   INV_24_Q24 = round(2^24 / 24) = 699051
    // -------------------------------------------------------------
    localparam signed [31:0] INV_6_Q24  = 32'sd2796203;
    localparam signed [31:0] INV_24_Q24 = 32'sd699051;

    // Stage 2a
    (* use_dsp = "yes" *) logic signed [31:0] u2_2a;
    logic signed [31:0] u_2a;

    // Stage 2b
    (* use_dsp = "yes" *) logic signed [31:0] u3_2b;
    logic signed [31:0] u2_2b, u_2b;

    // Stage 2c
    (* use_dsp = "yes" *) logic signed [31:0] u4_2c;
    logic signed [31:0] u3_2c, u2_2c, u_2c;

    // Stage 2d
    (* use_dsp = "yes" *) logic signed [31:0] u3d6_2d;
    (* use_dsp = "yes" *) logic signed [31:0] u4d24_2d;
    logic signed [31:0] u2_2d, u_2d;

    // Stage 2e (adder only)
    logic signed [31:0] exp_2e;
    logic signed [31:0] u_latched_2e;  // unused but kept for alignment clarity

    // Stage 2f
    (* use_dsp = "yes" *) logic signed [31:0] phi_2f;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            u2_2a     <= 32'sd0;  u_2a     <= 32'sd0;
            u3_2b     <= 32'sd0;  u2_2b    <= 32'sd0;  u_2b  <= 32'sd0;
            u4_2c     <= 32'sd0;  u3_2c    <= 32'sd0;  u2_2c <= 32'sd0; u_2c <= 32'sd0;
            u3d6_2d   <= 32'sd0;  u4d24_2d <= 32'sd0;  u2_2d <= 32'sd0; u_2d <= 32'sd0;
            exp_2e    <= 32'sd0;
            phi_2f    <= 32'sd0;
        end else begin
            // Stage 2a: u2 = x2_half1^2  (one DSP)
            u2_2a <= signed'((64'(signed'(x2_half1)) * 64'(signed'(x2_half1))) >>> 24);
            u_2a  <= x2_half1;

            // Stage 2b: u3 = u2 * u  (one DSP)
            u3_2b <= signed'((64'(signed'(u2_2a)) * 64'(signed'(u_2a))) >>> 24);
            u2_2b <= u2_2a;
            u_2b  <= u_2a;

            // Stage 2c: u4 = u2 * u2  (one DSP, independent of u3)
            u4_2c <= signed'((64'(signed'(u2_2b)) * 64'(signed'(u2_2b))) >>> 24);
            u3_2c <= u3_2b;
            u2_2c <= u2_2b;
            u_2c  <= u_2b;

            // Stage 2d: u3/6 and u4/24  (two independent DSPs — parallel, not serial)
            u3d6_2d   <= signed'((64'(signed'(u3_2c)) * 64'(signed'(INV_6_Q24)))  >>> 24);
            u4d24_2d  <= signed'((64'(signed'(u4_2c)) * 64'(signed'(INV_24_Q24))) >>> 24);
            u2_2d     <= u2_2c;
            u_2d      <= u_2c;

            // Stage 2e: sum — no multiply, pure adder tree
            begin
                logic signed [31:0] esum;
                esum   = Q24_ONE - u_2d + (u2_2d >>> 1) - u3d6_2d + u4d24_2d;
                if (u_2d > 32'sd50331648)      // |x| > 3.0 → exp ≈ 0
                    exp_2e <= 32'sd0;
                else
                    exp_2e <= (esum < 32'sd0) ? 32'sd0 : esum;
            end

            // Stage 2f: phi = (1/sqrt(2pi)) * exp  (one DSP)
            phi_2f <= signed'((64'(signed'(INV_SQRT_2PI)) * 64'(signed'(exp_2e))) >>> 24);
        end
    end

    // -----------------------------------------------------------------------
    // phi_2f is valid 6 cycles after v1 (which entered Stage 1 one cycle ago).
    // Divider latency from v1 = 33 cycles.
    // So phi_2f needs 33 - 6 = 27 more delay taps.
    // is_neg1, abs_x1 need 33 delay taps from v1 perspective.
    // -----------------------------------------------------------------------
    // (* SHREG_EXTRACT = "no" *) prevents SRL32 inference:
    // Without this Vivado packs the whole chain into one SRL32, creating a
    // combinational path from phi_2f → SRL32_D of depth 27 which fails timing.
    logic signed [31:0] phi_delay [0:28];
    logic               is_neg_delay [0:33];
    logic signed [31:0] abs_x_delay [0:33];

    assign phi_delay[0]    = phi_2f;
    assign is_neg_delay[0] = is_neg1;
    assign abs_x_delay[0]  = abs_x1;

    genvar g;
    generate
        for (g = 0; g < 28; g = g + 1) begin : phi_delay_gen
            always_ff @(posedge clk) begin
                phi_delay[g+1] <= phi_delay[g];
            end
        end
        for (g = 0; g < 33; g = g + 1) begin : meta_delay_gen
            always_ff @(posedge clk) begin
                is_neg_delay[g+1] <= is_neg_delay[g];
                abs_x_delay[g+1]  <= abs_x_delay[g];
            end
        end
    endgenerate

    // phi_delay[28], is_neg_delay[33], abs_x_delay[33] and t_div_out all aligned.
    wire signed [31:0] phi_aligned    = phi_delay[28];
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
    // Stage 3b_m: Horner Step 1 Multiplier — p4_mult = B5 * t (1 DSP)
    // -------------------------------------------------------------
    logic               v3b_m;
    logic               is_neg3b_m;
    logic signed [31:0] phi3b_m, t3b_m;
    (* use_dsp = "yes" *) logic signed [31:0] p4_mult_3b;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v3b_m        <= 1'b0;
            is_neg3b_m   <= 1'b0;
            phi3b_m      <= 32'sd0;
            t3b_m        <= 32'sd0;
            p4_mult_3b   <= 32'sd0;
        end else begin
            v3b_m        <= v3a;
            is_neg3b_m   <= is_neg3a;
            phi3b_m      <= phi3a;
            t3b_m        <= t3a;
            p4_mult_3b   <= signed'((64'(signed'(B5)) * 64'(signed'(t3a))) >>> 24);
        end
    end

    // -------------------------------------------------------------
    // Stage 3b_a: Horner Step 1 Adder — p4 = B4 + p4_mult (pure adder)
    // -------------------------------------------------------------
    logic               v3b;
    logic               is_neg3b;
    logic signed [31:0] phi3b, t3b;
    logic signed [31:0] p4_3b;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v3b   <= 1'b0;
            is_neg3b <= 1'b0;
            phi3b <= 32'sd0;
            t3b   <= 32'sd0;
            p4_3b <= 32'sd0;
        end else begin
            v3b      <= v3b_m;
            is_neg3b <= is_neg3b_m;
            phi3b    <= phi3b_m;
            t3b      <= t3b_m;
            p4_3b    <= signed'($signed(B4) + p4_mult_3b);
        end
    end

    // -------------------------------------------------------------
    // Stage 3c_m: Horner Step 2 Multiplier — p3_mult = p4 * t (1 DSP)
    // -------------------------------------------------------------
    logic               v3c_m;
    logic               is_neg3c_m;
    logic signed [31:0] phi3c_m, t3c_m;
    (* use_dsp = "yes" *) logic signed [31:0] p3_mult_3c;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v3c_m        <= 1'b0;
            is_neg3c_m   <= 1'b0;
            phi3c_m      <= 32'sd0;
            t3c_m        <= 32'sd0;
            p3_mult_3c   <= 32'sd0;
        end else begin
            v3c_m        <= v3b;
            is_neg3c_m   <= is_neg3b;
            phi3c_m      <= phi3b;
            t3c_m        <= t3b;
            p3_mult_3c   <= signed'((64'(signed'(p4_3b)) * 64'(signed'(t3b))) >>> 24);
        end
    end

    // -------------------------------------------------------------
    // Stage 3c_a: Horner Step 2 Adder — p3 = B3 + p3_mult (pure adder)
    // -------------------------------------------------------------
    logic               v3c;
    logic               is_neg3c;
    logic signed [31:0] phi3c, t3c;
    logic signed [31:0] p3_3c;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v3c   <= 1'b0;
            is_neg3c <= 1'b0;
            phi3c <= 32'sd0;
            t3c   <= 32'sd0;
            p3_3c <= 32'sd0;
        end else begin
            v3c      <= v3c_m;
            is_neg3c <= is_neg3c_m;
            phi3c    <= phi3c_m;
            t3c      <= t3c_m;
            p3_3c    <= signed'($signed(B3) + p3_mult_3c);
        end
    end

    // -------------------------------------------------------------
    // Stage 3d_m: Horner Step 3 Multiplier — p2_mult = p3 * t (1 DSP)
    // -------------------------------------------------------------
    logic               v3d_m;
    logic               is_neg3d_m;
    logic signed [31:0] phi3d_m, t3d_m;
    (* use_dsp = "yes" *) logic signed [31:0] p2_mult_3d;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v3d_m        <= 1'b0;
            is_neg3d_m   <= 1'b0;
            phi3d_m      <= 32'sd0;
            t3d_m        <= 32'sd0;
            p2_mult_3d   <= 32'sd0;
        end else begin
            v3d_m        <= v3c;
            is_neg3d_m   <= is_neg3c;
            phi3d_m      <= phi3c;
            t3d_m        <= t3c;
            p2_mult_3d   <= signed'((64'(signed'(p3_3c)) * 64'(signed'(t3c))) >>> 24);
        end
    end

    // -------------------------------------------------------------
    // Stage 3d_a: Horner Step 3 Adder — p2 = B2 + p2_mult (pure adder)
    // -------------------------------------------------------------
    logic               v3d;
    logic               is_neg3d;
    logic signed [31:0] phi3d, t3d;
    logic signed [31:0] p2_3d;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v3d   <= 1'b0;
            is_neg3d <= 1'b0;
            phi3d <= 32'sd0;
            t3d   <= 32'sd0;
            p2_3d <= 32'sd0;
        end else begin
            v3d      <= v3d_m;
            is_neg3d <= is_neg3d_m;
            phi3d    <= phi3d_m;
            t3d      <= t3d_m;
            p2_3d    <= signed'($signed(B2) + p2_mult_3d);
        end
    end

    // -------------------------------------------------------------
    // Stage 3e_m: Horner Step 4 Multiplier — p1_mult = p2 * t (1 DSP)
    // -------------------------------------------------------------
    logic               v3e_m;
    logic               is_neg3e_m;
    logic signed [31:0] phi3e_m, t3e_m;
    (* use_dsp = "yes" *) logic signed [31:0] p1_mult_3e;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v3e_m        <= 1'b0;
            is_neg3e_m   <= 1'b0;
            phi3e_m      <= 32'sd0;
            t3e_m        <= 32'sd0;
            p1_mult_3e   <= 32'sd0;
        end else begin
            v3e_m        <= v3d;
            is_neg3e_m   <= is_neg3d;
            phi3e_m      <= phi3d;
            t3e_m        <= t3d;
            p1_mult_3e   <= signed'((64'(signed'(p2_3d)) * 64'(signed'(t3d))) >>> 24);
        end
    end

    // -------------------------------------------------------------
    // Stage 3e_a: Horner Step 4 Adder — p1 = B1 + p1_mult (pure adder)
    // -------------------------------------------------------------
    logic               v3e;
    logic               is_neg3e;
    logic signed [31:0] phi3e, t3e;
    logic signed [31:0] p1_3e;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v3e   <= 1'b0;
            is_neg3e <= 1'b0;
            phi3e <= 32'sd0;
            t3e   <= 32'sd0;
            p1_3e <= 32'sd0;
        end else begin
            v3e      <= v3e_m;
            is_neg3e <= is_neg3e_m;
            phi3e    <= phi3e_m;
            t3e      <= t3e_m;
            p1_3e    <= signed'($signed(B1) + p1_mult_3e);
        end
    end

    // -------------------------------------------------------------
    // Stage 4a: Horner Step 5 — poly = p1 * t  (1 DSP)
    // -------------------------------------------------------------
    logic               v4a;
    logic               is_neg4a;
    logic signed [31:0] phi4a;
    (* use_dsp = "yes" *) logic signed [31:0] poly4a;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v4a      <= 1'b0;
            is_neg4a <= 1'b0;
            phi4a    <= 32'sd0;
            poly4a   <= 32'sd0;
        end else begin
            v4a      <= v3e;
            is_neg4a <= is_neg3e;
            phi4a    <= phi3e;
            poly4a   <= signed'((64'(signed'(p1_3e)) * 64'(signed'(t3e))) >>> 24);
        end
    end

    // -------------------------------------------------------------
    // Stage 4b: phi * poly multiplication (1 multiply, registered DSP)
    // -------------------------------------------------------------
    logic               v4b;
    logic               is_neg4b;
    logic signed [31:0] pdf4b;
    (* use_dsp = "yes" *) logic signed [31:0] phi_poly_4b;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v4b         <= 1'b0;
            is_neg4b    <= 1'b0;
            pdf4b       <= 32'sd0;
            phi_poly_4b <= 32'sd0;
        end else begin
            v4b         <= v4a;
            is_neg4b    <= is_neg4a;
            pdf4b       <= phi4a;
            phi_poly_4b <= signed'((64'(signed'(phi4a)) * 64'(signed'(poly4a))) >>> 24);
        end
    end

    // -------------------------------------------------------------
    // Stage 4c: Symmetry selection (1 cycle, single subtractor)
    // Mathematical Identity:
    //   If x >= 0: cdf = 1 - phi * poly
    //   If x < 0:  cdf = 1 - (1 - phi * poly) = phi * poly
    // -------------------------------------------------------------
    logic               v4c;
    logic signed [31:0] pdf4c;
    logic signed [31:0] raw_cdf_4c;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v4c        <= 1'b0;
            pdf4c      <= 32'sd0;
            raw_cdf_4c <= 32'sd0;
        end else begin
            v4c        <= v4b;
            pdf4c      <= pdf4b;
            raw_cdf_4c <= is_neg4b ? phi_poly_4b : signed'(Q24_ONE - phi_poly_4b);
        end
    end

    // -------------------------------------------------------------
    // Stage 4d: Output clamp & register (1 cycle, pure clamp)
    // -------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_out <= 1'b0;
            cdf_out   <= 32'sd0;
            pdf_out   <= 32'sd0;
        end else begin
            valid_out <= v4c;
            pdf_out   <= pdf4c;
            if (raw_cdf_4c < 32'sd0)
                cdf_out <= 32'sd0;
            else if (raw_cdf_4c > Q24_ONE)
                cdf_out <= Q24_ONE;
            else
                cdf_out <= raw_cdf_4c;
        end
    end

endmodule
