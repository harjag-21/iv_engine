`timescale 1ns / 1ps

// =========================================================
// Black-Scholes Pricing & Vega Datapath (Q8.24 Fixed-Point)
// =========================================================
// Calculates:
//   ln_sk = 2 * (S - K) / (S + K)           [Padé approximation]
//   sqrt_T = sqrt(T)                        [iv_sqrt_q824, 29 cycles + 4 align = 33 total]
//   d1    = (ln_sk + (r + sigma^2/2)*T) / (sigma * sqrt_T)
//   d2    = d1 - sigma * sqrt_T
//   C_BS  = S * N(d1) - K * (1 - r*T + (r*T)^2/2) * N(d2)
//   Vega  = S * sqrt_T * phi(d1)
//
// Modules:
//   1. iv_divider_q824: Padé ln(S/K) (33 cycles)
//   2. iv_sqrt_q824: sqrt(T) engine (28 stages + 1 output reg = 29 cycles; +4 align regs = 33 total)
//   3. iv_divider_q824: d1 divider (33 cycles)
//   4. iv_norm_cdf: 5-coefficient A&S Horner CDF, 7-stage pipeline (41 cycles: 1+33+7=41)
//
// Total Latency: 1 + 33 + 1 + 33 + 41 + 1 = 110 clock cycles
// =========================================================
module iv_bs_datapath (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               valid_in,
    input  wire signed [31:0] S_in,        // Spot price (Q8.24)
    input  wire signed [31:0] K_in,        // Strike price (Q8.24)
    input  wire signed [31:0] r_in,        // Risk-free rate (Q8.24)
    input  wire signed [31:0] T_in,        // Time to maturity (Q8.24)
    input  wire signed [31:0] sigma_in,    // Volatility estimate (Q8.24)

    output logic              valid_out,
    output logic signed [31:0] C_bs_out,    // Black-Scholes Call Price (Q8.24)
    output logic signed [31:0] vega_out     // Option Vega (Q8.24)
);

    localparam signed [31:0] Q24_ONE = 32'sd16777216; // 1.0 in Q8.24

    // =====================================================================
    // Stage 0: Pre-compute ln(S/K) & start sqrt(T) engine (1 cycle)
    // =====================================================================
    logic               v_stg0;
    logic signed [31:0] ln_num_r0, ln_den_r0;
    logic signed [31:0] S_r0, K_r0, r_r0, T_r0, sigma_r0;
    logic signed [31:0] diff_sk_var;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v_stg0    <= 1'b0;
            ln_num_r0 <= 32'sd0;
            ln_den_r0 <= 32'sd0;
            S_r0 <= 32'sd0; K_r0 <= 32'sd0; r_r0 <= 32'sd0;
            T_r0 <= 32'sd0; sigma_r0 <= 32'sd0;
        end else begin
            v_stg0   <= valid_in;
            S_r0     <= S_in;
            K_r0     <= K_in;
            r_r0     <= r_in;
            T_r0     <= T_in;
            sigma_r0 <= sigma_in;

            // Saturation protection for S - K > 63.99 to prevent 32-bit signed overflow when doubled
            diff_sk_var = $signed(S_in) - $signed(K_in);
            if (diff_sk_var > 32'sd1073741823) begin
                ln_num_r0 <= 32'sh7FFFFFFF;
            end else if (diff_sk_var < -32'sd1073741823) begin
                ln_num_r0 <= -32'sh7FFFFFFF;
            end else begin
                ln_num_r0 <= diff_sk_var <<< 1;
            end

            // Prevent S + K overflow for values >= 128.0 (Q8.24 max range)
            begin
                automatic logic signed [63:0] sum_sk_var;
                sum_sk_var = 64'(signed'(S_in)) + 64'(signed'(K_in));
                if (sum_sk_var > 64'sh7FFFFFFF) begin
                    ln_den_r0 <= 32'sh7FFFFFFF;
                end else if (sum_sk_var == 64'sd0) begin
                    ln_den_r0 <= 32'sd1;
                end else begin
                    ln_den_r0 <= 32'(sum_sk_var);
                end
            end
        end
    end

    // =====================================================================
    // Stage 1A: Pipelined Divider for ln(S/K) (33 cycles)
    // =====================================================================
    wire               ln_div_valid;
    wire signed [31:0] ln_sk_out;  // ln(S/K) in Q8.24

    iv_divider_q824 u_ln_divider (
        .clk            (clk),
        .rst_n          (rst_n),
        .valid_in       (v_stg0),
        .numerator_in   (ln_num_r0),
        .denominator_in (ln_den_r0),
        .valid_out      (ln_div_valid),
        .quotient_out   (ln_sk_out)
    );

    // =====================================================================
    // Stage 1B: Pipelined sqrt(T) Engine (28 stages + 1 output reg = 29 cycles)
    // =====================================================================
    wire               sqrt_valid_w;
    wire signed [31:0] sqrt_T_w;

    iv_sqrt_q824 u_sqrt_T (
        .clk       (clk),
        .rst_n     (rst_n),
        .valid_in  (v_stg0),
        .rad_in    (T_r0),
        .valid_out (sqrt_valid_w),
        .root_out  (sqrt_T_w)
    );

    // Delay sqrt_T through remaining 4 cycles to align with ln_sk_out (total 33 cycles)
    logic signed [31:0] sqrt_T_delay [0:4];
    assign sqrt_T_delay[0] = sqrt_T_w;

    genvar g;
    generate
        for (g = 0; g < 4; g = g + 1) begin : sqrt_align_gen
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) sqrt_T_delay[g+1] <= 32'sd0;
                else        sqrt_T_delay[g+1] <= sqrt_T_delay[g];
            end
        end
    endgenerate

    wire signed [31:0] sqrt_T_aligned = sqrt_T_delay[4];

    // Delay lines for S, K, r, T, sigma through 33-cycle ln divider
    logic signed [31:0] S_ln_pipe    [0:33];
    logic signed [31:0] K_ln_pipe    [0:33];
    logic signed [31:0] r_ln_pipe    [0:33];
    logic signed [31:0] T_ln_pipe    [0:33];
    logic signed [31:0] sigma_ln_pipe[0:33];

    assign S_ln_pipe[0]     = S_r0;
    assign K_ln_pipe[0]     = K_r0;
    assign r_ln_pipe[0]     = r_r0;
    assign T_ln_pipe[0]     = T_r0;
    assign sigma_ln_pipe[0] = sigma_r0;

    generate
        for (g = 0; g < 33; g = g + 1) begin : ln_delay_gen
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    S_ln_pipe[g+1]     <= 32'sd0;
                    K_ln_pipe[g+1]     <= 32'sd0;
                    r_ln_pipe[g+1]     <= 32'sd0;
                    T_ln_pipe[g+1]     <= 32'sd0;
                    sigma_ln_pipe[g+1] <= 32'sd0;
                end else begin
                    S_ln_pipe[g+1]     <= S_ln_pipe[g];
                    K_ln_pipe[g+1]     <= K_ln_pipe[g];
                    r_ln_pipe[g+1]     <= r_ln_pipe[g];
                    T_ln_pipe[g+1]     <= T_ln_pipe[g];
                    sigma_ln_pipe[g+1] <= sigma_ln_pipe[g];
                end
            end
        end
    endgenerate

    // =====================================================================
    // Stage 2: Pipelined d1 Numerator & Denominator (4 registered sub-stages)
    //   d1_num = ln(S/K) + (r + sigma^2/2) * T
    //   d1_den = sigma * sqrt(T)
    //
    // Sub-stage 2a (1 cycle):
    //   sig2_2a   = sigma * sigma >> 25                 [1 DSP]
    //   d1_den_2a = sigma * sqrt_T >> 24                [1 DSP, parallel]
    //   (carries through: ln_sk_out, r, T, S, K, sqrt_T)
    //
    // Sub-stage 2b (1 cycle):
    //   r_sig2_2b = r_2a + sig2_2a                      [pure adder]
    //   d1_den_2b = d1_den_2a
    //   (carries through: ln_sk, T, S, K, r, sqrt_T)
    //
    // Sub-stage 2c (1 cycle):
    //   prod_2c   = (r_sig2_2b * T_2b) >> 24            [1 DSP, registered inputs]
    //   d1_den_2c = d1_den_2b
    //   (carries through: ln_sk, S, K, r, T, sqrt_T)
    //
    // Sub-stage 2d (1 cycle):
    //   d1_num_r2 = ln_sk_2c + prod_2c                  [pure adder]
    //   d1_den_r2 = d1_den_2c
    //   (carries through: S, K, r, T, sqrt_T to d1_pipe)
    // =====================================================================
    logic               v_2a, v_2b, v_2c, v_stg2;
    (* use_dsp = "yes" *) logic signed [31:0] sig2_2a;
    (* use_dsp = "yes" *) logic signed [31:0] d1_den_2a;
    logic signed [31:0] ln_sk_2a, r_2a, T_2a, S_2a, K_2a, sqrt_T_2a;

    logic signed [31:0] r_sig2_2b;
    logic signed [31:0] d1_den_2b;
    logic signed [31:0] ln_sk_2b, S_2b, K_2b, r_2b, T_2b, sqrt_T_2b;

    (* use_dsp = "yes" *) logic signed [31:0] prod_2c;
    logic signed [31:0] d1_den_2c;
    logic signed [31:0] ln_sk_2c, S_2c, K_2c, r_2c, T_2c, sqrt_T_2c;

    logic signed [31:0] d1_num_r2, d1_den_r2;
    logic signed [31:0] S_r2, K_r2, r_r2, T_r2, sqrt_T_r2;

    // Sub-stage 2a: sigma^2/2 and sigma*sqrt(T) [DSP]
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v_2a       <= 1'b0;
            sig2_2a    <= 32'sd0;
            d1_den_2a  <= 32'sd0;
            ln_sk_2a   <= 32'sd0;
            r_2a       <= 32'sd0;
            T_2a       <= 32'sd0;
            S_2a       <= 32'sd0;
            K_2a       <= 32'sd0;
            sqrt_T_2a  <= 32'sd0;
        end else begin
            v_2a       <= ln_div_valid;
            ln_sk_2a   <= ln_sk_out;
            r_2a       <= r_ln_pipe[33];
            T_2a       <= T_ln_pipe[33];
            S_2a       <= S_ln_pipe[33];
            K_2a       <= K_ln_pipe[33];
            sqrt_T_2a  <= sqrt_T_aligned;

            sig2_2a    <= signed'((64'(signed'(sigma_ln_pipe[33])) * 64'(signed'(sigma_ln_pipe[33]))) >>> 25);
            d1_den_2a  <= signed'((64'(signed'(sigma_ln_pipe[33])) * 64'(signed'(sqrt_T_aligned)))     >>> 24);
        end
    end

    // Sub-stage 2b: r + sigma^2/2 [Pure Adder]
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v_2b       <= 1'b0;
            r_sig2_2b  <= 32'sd0;
            d1_den_2b  <= 32'sd0;
            ln_sk_2b   <= 32'sd0;
            S_2b       <= 32'sd0;
            K_2b       <= 32'sd0;
            r_2b       <= 32'sd0;
            T_2b       <= 32'sd0;
            sqrt_T_2b  <= 32'sd0;
        end else begin
            v_2b       <= v_2a;
            ln_sk_2b   <= ln_sk_2a;
            S_2b       <= S_2a;
            K_2b       <= K_2a;
            r_2b       <= r_2a;
            T_2b       <= T_2a;
            sqrt_T_2b  <= sqrt_T_2a;
            d1_den_2b  <= (d1_den_2a != 32'sd0) ? d1_den_2a : 32'sd1;

            r_sig2_2b  <= signed'(signed'(r_2a) + signed'(sig2_2a));
        end
    end

    // Sub-stage 2c: (r + sigma^2/2) * T [DSP Multiplier]
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v_2c       <= 1'b0;
            prod_2c    <= 32'sd0;
            d1_den_2c  <= 32'sd0;
            ln_sk_2c   <= 32'sd0;
            S_2c       <= 32'sd0;
            K_2c       <= 32'sd0;
            r_2c       <= 32'sd0;
            T_2c       <= 32'sd0;
            sqrt_T_2c  <= 32'sd0;
        end else begin
            v_2c       <= v_2b;
            ln_sk_2c   <= ln_sk_2b;
            S_2c       <= S_2b;
            K_2c       <= K_2b;
            r_2c       <= r_2b;
            T_2c       <= T_2b;
            sqrt_T_2c  <= sqrt_T_2b;
            d1_den_2c  <= d1_den_2b;

            prod_2c    <= signed'((64'(signed'(r_sig2_2b)) * 64'(signed'(T_2b))) >>> 24);
        end
    end

    // Sub-stage 2d: ln(S/K) + prod [Pure Adder]
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v_stg2     <= 1'b0;
            d1_num_r2  <= 32'sd0;
            d1_den_r2  <= 32'sd0;
            S_r2       <= 32'sd0;
            K_r2       <= 32'sd0;
            r_r2       <= 32'sd0;
            T_r2       <= 32'sd0;
            sqrt_T_r2  <= 32'sd0;
        end else begin
            v_stg2     <= v_2c;
            S_r2       <= S_2c;
            K_r2       <= K_2c;
            r_r2       <= r_2c;
            T_r2       <= T_2c;
            sqrt_T_r2  <= sqrt_T_2c;

            d1_num_r2  <= signed'($signed(ln_sk_2c) + $signed(prod_2c));
            d1_den_r2  <= d1_den_2c;
        end
    end

    // =====================================================================
    // Stage 3: Pipelined Divider for d1 (33 cycles)
    // =====================================================================
    wire               d1_div_valid;
    wire signed [31:0] d1_div_out;

    iv_divider_q824 u_d1_divider (
        .clk            (clk),
        .rst_n          (rst_n),
        .valid_in       (v_stg2),
        .numerator_in   (d1_num_r2),
        .denominator_in (d1_den_r2),
        .valid_out      (d1_div_valid),
        .quotient_out   (d1_div_out)
    );

    // Delay lines for S, K, r, T, sqrt_T, denom through 33-cycle d1 divider
    logic signed [31:0] S_d1_pipe      [0:33];
    logic signed [31:0] K_d1_pipe      [0:33];
    logic signed [31:0] r_d1_pipe      [0:33];
    logic signed [31:0] T_d1_pipe      [0:33];
    logic signed [31:0] sqrt_T_d1_pipe [0:33];
    logic signed [31:0] den_d1_pipe    [0:33];

    assign S_d1_pipe[0]      = S_r2;
    assign K_d1_pipe[0]      = K_r2;
    assign r_d1_pipe[0]      = r_r2;
    assign T_d1_pipe[0]      = T_r2;
    assign sqrt_T_d1_pipe[0] = sqrt_T_r2;
    assign den_d1_pipe[0]    = d1_den_r2;

    generate
        for (g = 0; g < 33; g = g + 1) begin : d1_delay_gen
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    S_d1_pipe[g+1]      <= 32'sd0;
                    K_d1_pipe[g+1]      <= 32'sd0;
                    r_d1_pipe[g+1]      <= 32'sd0;
                    T_d1_pipe[g+1]      <= 32'sd0;
                    sqrt_T_d1_pipe[g+1] <= 32'sd0;
                    den_d1_pipe[g+1]    <= 32'sd0;
                end else begin
                    S_d1_pipe[g+1]      <= S_d1_pipe[g];
                    K_d1_pipe[g+1]      <= K_d1_pipe[g];
                    r_d1_pipe[g+1]      <= r_d1_pipe[g];
                    T_d1_pipe[g+1]      <= T_d1_pipe[g];
                    sqrt_T_d1_pipe[g+1] <= sqrt_T_d1_pipe[g];
                    den_d1_pipe[g+1]    <= den_d1_pipe[g];
                end
            end
        end
    endgenerate

    // =====================================================================
    // Stage 4a: Register d1 and d2 = d1 - denom (1 cycle)
    // Breaks the subtractor + absolute-value + DSP-square chain into 2 cycles.
    // =====================================================================
    logic               d12_valid_reg;
    logic signed [31:0] d1_reg, d2_reg;
    logic signed [31:0] S_d12_reg, K_d12_reg, r_d12_reg, T_d12_reg, sqrt_T_d12_reg;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            d12_valid_reg  <= 1'b0;
            d1_reg         <= 32'sd0;
            d2_reg         <= 32'sd0;
            S_d12_reg      <= 32'sd0;
            K_d12_reg      <= 32'sd0;
            r_d12_reg      <= 32'sd0;
            T_d12_reg      <= 32'sd0;
            sqrt_T_d12_reg <= 32'sd0;
        end else begin
            d12_valid_reg  <= d1_div_valid;
            d1_reg         <= d1_div_out;
            d2_reg         <= d1_div_out - den_d1_pipe[33];
            S_d12_reg      <= S_d1_pipe[33];
            K_d12_reg      <= K_d1_pipe[33];
            r_d12_reg      <= r_d1_pipe[33];
            T_d12_reg      <= T_d1_pipe[33];
            sqrt_T_d12_reg <= sqrt_T_d1_pipe[33];
        end
    end

    // =====================================================================
    // Stage 4b: Dual Standard Normal CDF Evaluation (42 cycles)
    // =====================================================================
    wire               cdf1_v, cdf2_v;
    wire signed [31:0] N_d1, N_d2, phi_d1, phi_d2;

    iv_norm_cdf u_norm_d1 (
        .clk       (clk),
        .rst_n     (rst_n),
        .valid_in  (d12_valid_reg),
        .x_in      (d1_reg),
        .valid_out (cdf1_v),
        .cdf_out   (N_d1),
        .pdf_out   (phi_d1)
    );

    iv_norm_cdf u_norm_d2 (
        .clk       (clk),
        .rst_n     (rst_n),
        .valid_in  (d12_valid_reg),
        .x_in      (d2_reg),
        .valid_out (cdf2_v),
        .cdf_out   (N_d2),
        .pdf_out   (phi_d2)
    );

    // Delay lines for S, K, r, T, sqrt_T through the 49-cycle CDF module
    logic signed [31:0] S_cdf_pipe      [0:49];
    logic signed [31:0] K_cdf_pipe      [0:49];
    logic signed [31:0] r_cdf_pipe      [0:49];
    logic signed [31:0] T_cdf_pipe      [0:49];
    logic signed [31:0] sqrt_T_cdf_pipe [0:49];

    assign S_cdf_pipe[0]      = S_d12_reg;
    assign K_cdf_pipe[0]      = K_d12_reg;
    assign r_cdf_pipe[0]      = r_d12_reg;
    assign T_cdf_pipe[0]      = T_d12_reg;
    assign sqrt_T_cdf_pipe[0] = sqrt_T_d12_reg;

    generate
        for (g = 0; g < 49; g = g + 1) begin : cdf_delay_gen
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    S_cdf_pipe[g+1]      <= 32'sd0;
                    K_cdf_pipe[g+1]      <= 32'sd0;
                    r_cdf_pipe[g+1]      <= 32'sd0;
                    T_cdf_pipe[g+1]      <= 32'sd0;
                    sqrt_T_cdf_pipe[g+1] <= 32'sd0;
                end else begin
                    S_cdf_pipe[g+1]      <= S_cdf_pipe[g];
                    K_cdf_pipe[g+1]      <= K_cdf_pipe[g];
                    r_cdf_pipe[g+1]      <= r_cdf_pipe[g];
                    T_cdf_pipe[g+1]      <= T_cdf_pipe[g];
                    sqrt_T_cdf_pipe[g+1] <= sqrt_T_cdf_pipe[g];
                end
            end
        end
    endgenerate

    // =====================================================================
    // Stage 5: Pipelined BS Call Price & Vega — 5 registered sub-stages
    //
    // At the input (when cdf1_v fires), we have:
    //   N_d1, N_d2, phi_d1           — CDF/PDF outputs, valid now
    //   S/K/r/T/sqrt_T_cdf_pipe[49] — delay-matched inputs, valid now
    //
    // Sub-stage 5a (T→T+1): 4 parallel independent DSP multiplies
    //   rt       = r  * T
    //   term1    = S  * N_d1
    //   knd2     = K  * N_d2          (K*N(d2), to be scaled by ert later)
    //   vega1    = S  * sqrt_T
    //   (carry through: phi_d1)
    //
    // Sub-stage 5b (T+1→T+2): 2 parallel independent DSP multiplies
    //   rt2      = rt * rt >> 25      ((rT)^2 / 2)
    //   vega2    = vega1 * phi_d1
    //   (carry through: rt, term1, knd2)
    //
    // Sub-stage 5c (T+2→T+3): pure adder, no multiply
    //   ert      = 1 - rt + rt2
    //   (carry through: term1, knd2, vega2)
    //
    // Sub-stage 5d (T+3→T+4): 1 DSP multiply
    //   term2    = knd2 * ert
    //   (carry through: term1, vega2)
    //
    // Sub-stage 5e (T+4→T+5): pure adders, output registers
    //   C_bs_out = term1 - term2
    //   vega_out = vega2
    //
    // Total latency added vs original 1-stage: 4 extra cycles.
    // Max logic per critical path: 1 DSP (closed at 250 MHz).
    // =====================================================================

    // --- Sub-stage 5a ---
    (* use_dsp = "yes" *) logic signed [31:0] rt_5a;
    (* use_dsp = "yes" *) logic signed [31:0] term1_5a;
    (* use_dsp = "yes" *) logic signed [31:0] knd2_5a;
    (* use_dsp = "yes" *) logic signed [31:0] vega1_5a;
    logic signed [31:0] phi_d1_5a;      // carry-through
    logic               v5a;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rt_5a    <= 32'sd0;  term1_5a <= 32'sd0;
            knd2_5a  <= 32'sd0;  vega1_5a <= 32'sd0;
            phi_d1_5a<= 32'sd0;  v5a      <= 1'b0;
        end else begin
            v5a       <= cdf1_v;
            phi_d1_5a <= phi_d1;
            rt_5a     <= signed'((64'(signed'(r_cdf_pipe[49]))    * 64'(signed'(T_cdf_pipe[49])))      >>> 24);
            term1_5a  <= signed'((64'(signed'(S_cdf_pipe[49]))    * 64'(signed'(N_d1)))                >>> 24);
            knd2_5a   <= signed'((64'(signed'(K_cdf_pipe[49]))    * 64'(signed'(N_d2)))                >>> 24);
            vega1_5a  <= signed'((64'(signed'(S_cdf_pipe[49]))    * 64'(signed'(sqrt_T_cdf_pipe[49]))) >>> 24);
        end
    end

    // --- Sub-stage 5b ---
    (* use_dsp = "yes" *) logic signed [31:0] rt2_5b;
    (* use_dsp = "yes" *) logic signed [31:0] vega2_5b;
    logic signed [31:0] rt_5b, term1_5b, knd2_5b;
    logic               v5b;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rt2_5b   <= 32'sd0;  vega2_5b <= 32'sd0;
            rt_5b    <= 32'sd0;  term1_5b <= 32'sd0;
            knd2_5b  <= 32'sd0;  v5b      <= 1'b0;
        end else begin
            v5b      <= v5a;
            rt_5b    <= rt_5a;        // carry rt through for 5c
            term1_5b <= term1_5a;     // carry term1 through
            knd2_5b  <= knd2_5a;      // carry knd2 through
            rt2_5b   <= signed'((64'(signed'(rt_5a))    * 64'(signed'(rt_5a)))    >>> 25); // (rT)^2/2
            vega2_5b <= signed'((64'(signed'(vega1_5a)) * 64'(signed'(phi_d1_5a))) >>> 24);
        end
    end

    // --- Sub-stage 5c: ert = 1 - rT + (rT)^2/2  (pure adder, no multiply) ---
    logic signed [31:0] ert_5c;
    logic signed [31:0] term1_5c, knd2_5c, vega2_5c;
    logic               v5c;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ert_5c   <= 32'sd0;  term1_5c <= 32'sd0;
            knd2_5c  <= 32'sd0;  vega2_5c <= 32'sd0;
            v5c      <= 1'b0;
        end else begin
            v5c      <= v5b;
            term1_5c <= term1_5b;
            knd2_5c  <= knd2_5b;
            vega2_5c <= vega2_5b;
            begin
                // Pure adder: 1 - rt + rt2/2.  No multiply.
                logic signed [31:0] e;
                e = Q24_ONE - rt_5b + rt2_5b;
                if      (e < 32'sd0)   ert_5c <= 32'sd0;
                else if (e > Q24_ONE)  ert_5c <= Q24_ONE;
                else                   ert_5c <= e;
            end
        end
    end

    // --- Sub-stage 5d: term2 = knd2 * ert  (1 DSP) ---
    (* use_dsp = "yes" *) logic signed [31:0] term2_5d;
    logic signed [31:0] term1_5d, vega2_5d;
    logic               v5d;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            term2_5d <= 32'sd0;  term1_5d <= 32'sd0;
            vega2_5d <= 32'sd0;  v5d      <= 1'b0;
        end else begin
            v5d      <= v5c;
            term1_5d <= term1_5c;
            vega2_5d <= vega2_5c;
            term2_5d <= signed'((64'(signed'(knd2_5c)) * 64'(signed'(ert_5c))) >>> 24);
        end
    end

    // --- Sub-stage 5e: output — adders only ---
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_out <= 1'b0;
            C_bs_out  <= 32'sd0;
            vega_out  <= 32'sd0;
        end else begin
            valid_out <= v5d;
            C_bs_out  <= signed'(term1_5d - term2_5d);
            vega_out  <= vega2_5d;
        end
    end

endmodule
