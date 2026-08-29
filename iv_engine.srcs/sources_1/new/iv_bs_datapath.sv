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
    // Stage 2: Compute d1 numerator & denominator (1 cycle)
    // d1_num = ln(S/K) + (r + sigma^2/2) * T
    // d1_den = sigma * sqrt(T)
    // =====================================================================
    logic               v_stg2;
    logic signed [31:0] d1_num_r2, d1_den_r2;
    logic signed [31:0] S_r2, K_r2, r_r2, T_r2, sqrt_T_r2;

    logic signed [63:0] sig2_var, d1_num_64, d1_den_64;
    logic signed [63:0] ert_var, term1_var, term2_var, vega_calc_var;
    logic signed [63:0] rt_var, rt2_var;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v_stg2    <= 1'b0;
            d1_num_r2 <= 32'sd0;
            d1_den_r2 <= 32'sd0;
            S_r2 <= 32'sd0; K_r2 <= 32'sd0; r_r2 <= 32'sd0; T_r2 <= 32'sd0; sqrt_T_r2 <= 32'sd0;
        end else begin
            v_stg2     <= ln_div_valid;
            S_r2       <= S_ln_pipe[33];
            K_r2       <= K_ln_pipe[33];
            r_r2       <= r_ln_pipe[33];
            T_r2       <= T_ln_pipe[33];
            sqrt_T_r2  <= sqrt_T_aligned;

            // d1 numerator: ln(S/K) + (r + sigma^2/2) * T
            sig2_var   = ($signed(sigma_ln_pipe[33]) * $signed(sigma_ln_pipe[33])) >>> 25;
            d1_num_64  = $signed(ln_sk_out)
                       + (( ($signed(r_ln_pipe[33]) + signed'(sig2_var)) * $signed(T_ln_pipe[33]) ) >>> 24);

            // d1 denominator: sigma * sqrt(T)
            d1_den_64  = ($signed(sigma_ln_pipe[33]) * $signed(sqrt_T_aligned)) >>> 24;

            d1_num_r2  <= signed'(d1_num_64);
            d1_den_r2  <= (d1_den_64 != 0) ? signed'(d1_den_64) : 32'sd1;
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
    // Stage 4: Compute d2 = d1 - denom, feeds CDF modules (41 cycles)
    // =====================================================================
    wire signed [31:0] d1_wire = d1_div_out;
    wire signed [31:0] d2_wire = d1_div_out - den_d1_pipe[33];

    wire               cdf1_v, cdf2_v;
    wire signed [31:0] N_d1, N_d2, phi_d1, phi_d2;

    iv_norm_cdf u_norm_d1 (
        .clk       (clk),
        .rst_n     (rst_n),
        .valid_in  (d1_div_valid),
        .x_in      (d1_wire),
        .valid_out (cdf1_v),
        .cdf_out   (N_d1),
        .pdf_out   (phi_d1)
    );

    iv_norm_cdf u_norm_d2 (
        .clk       (clk),
        .rst_n     (rst_n),
        .valid_in  (d1_div_valid),
        .x_in      (d2_wire),
        .valid_out (cdf2_v),
        .cdf_out   (N_d2),
        .pdf_out   (phi_d2)
    );

    // Delay lines for S, K, r, T, sqrt_T through the 41-cycle CDF module
    logic signed [31:0] S_cdf_pipe      [0:41];
    logic signed [31:0] K_cdf_pipe      [0:41];
    logic signed [31:0] r_cdf_pipe      [0:41];
    logic signed [31:0] T_cdf_pipe      [0:41];
    logic signed [31:0] sqrt_T_cdf_pipe [0:41];

    assign S_cdf_pipe[0]      = S_d1_pipe[33];
    assign K_cdf_pipe[0]      = K_d1_pipe[33];
    assign r_cdf_pipe[0]      = r_d1_pipe[33];
    assign T_cdf_pipe[0]      = T_d1_pipe[33];
    assign sqrt_T_cdf_pipe[0] = sqrt_T_d1_pipe[33];

    generate
        for (g = 0; g < 41; g = g + 1) begin : cdf_delay_gen
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
    // Stage 5: Evaluate BS Call price & Vega (1 cycle)
    // C_BS = S * N(d1) - K * (1 - r*T + (r*T)^2/2) * N(d2)
    // Vega = S * sqrt(T) * phi(d1)
    // =====================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_out <= 1'b0;
            C_bs_out  <= 32'sd0;
            vega_out  <= 32'sd0;
        end else begin
            valid_out <= cdf1_v;

            if (cdf1_v) begin
                // 2nd-order Taylor exp(-rT) ≈ 1 - rT + (rT)^2 / 2
                rt_var  = ($signed(r_cdf_pipe[41]) * $signed(T_cdf_pipe[41])) >>> 24;
                rt2_var = (rt_var * rt_var) >>> 25; // (rT)^2 / 2
                ert_var = Q24_ONE - rt_var + rt2_var;
                if (ert_var < 0) ert_var = 64'sd0;
                if (ert_var > Q24_ONE) ert_var = Q24_ONE;

                // C_BS = S * N(d1) - K * ert * N(d2)
                term1_var     = ($signed(S_cdf_pipe[41]) * $signed(N_d1)) >>> 24;
                term2_var     = ($signed(K_cdf_pipe[41]) * ((signed'(ert_var) * $signed(N_d2)) >>> 24)) >>> 24;

                // Vega = S * sqrt(T) * phi(d1)
                vega_calc_var = ($signed(S_cdf_pipe[41]) * $signed(sqrt_T_cdf_pipe[41])) >>> 24;
                vega_calc_var = (signed'(vega_calc_var) * $signed(phi_d1)) >>> 24;

                C_bs_out  <= signed'(term1_var - term2_var);
                vega_out  <= signed'(vega_calc_var);
            end
        end
    end

endmodule

