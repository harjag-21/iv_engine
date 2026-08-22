`timescale 1ns / 1ps

// =========================================================
// Black-Scholes Pricing & Vega Datapath (Q8.24 Fixed-Point)
// =========================================================
// Calculates:
//   d1 = (ln(S/K) + (r + sigma^2 / 2)*T) / (sigma * sqrt(T))
//   d2 = d1 - sigma * sqrt(T)
//   C_BS = S * N(d1) - K * exp(-r*T) * N(d2)
//   Vega = S * sqrt(T) * phi(d1)
//
// Integrates iv_norm_cdf module for N(d1), N(d2), and phi(d1).
// Pipelined for 250 MHz clock rate.
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

    // -------------------------------------------------------------
    // Intermediate pipeline registers
    // -------------------------------------------------------------
    logic               v_stg1, v_stg2, v_stg3;
    logic signed [31:0] S_r1, K_r1, r_r1, T_r1, sig_r1;
    logic signed [31:0] d1_r, d2_r;

    // Normal CDF instances for d1 and d2
    wire               cdf1_v, cdf2_v;
    wire signed [31:0] N_d1, N_d2, phi_d1, phi_d2;

    // Module-level temporary helper variables
    logic signed [63:0] s_k_diff, sig2, num, denom;
    logic signed [63:0] term1, term2, vega_calc, ert;

    iv_norm_cdf u_norm_d1 (
        .clk       (clk),
        .rst_n     (rst_n),
        .valid_in  (v_stg1),
        .x_in      (d1_r),
        .valid_out (cdf1_v),
        .cdf_out   (N_d1),
        .pdf_out   (phi_d1)
    );

    iv_norm_cdf u_norm_d2 (
        .clk       (clk),
        .rst_n     (rst_n),
        .valid_in  (v_stg1),
        .x_in      (d2_r),
        .valid_out (cdf2_v),
        .cdf_out   (N_d2),
        .pdf_out   (phi_d2)
    );

    // -------------------------------------------------------------
    // Pipeline execution
    // -------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v_stg1    <= 1'b0;
            v_stg2    <= 1'b0;
            valid_out <= 1'b0;
            S_r1 <= '0; K_r1 <= '0; r_r1 <= '0; T_r1 <= '0; sig_r1 <= '0;
            d1_r <= '0; d2_r <= '0;
            C_bs_out <= '0; vega_out <= '0;
        end else begin
            // ---------------------------------------------------------
            // Stage 1: Compute d1 & d2 estimates
            // d1 ≈ ( (S - K)/K + (r + sig^2/2)*T ) / (sig * sqrt(T))
            // ---------------------------------------------------------
            v_stg1 <= valid_in;
            S_r1   <= S_in;
            K_r1   <= K_in;
            r_r1   <= r_in;
            T_r1   <= T_in;
            sig_r1 <= sigma_in;

            s_k_diff = $signed(S_in) - $signed(K_in);
            sig2     = ($signed(sigma_in) * $signed(sigma_in)) >>> 25; // sig^2 / 2
            num      = s_k_diff + (( ($signed(r_in) + signed'(sig2)) * $signed(T_in) ) >>> 24);
            denom    = ($signed(sigma_in) * $signed(T_in)) >>> 24;

            if (denom != 0) begin
                d1_r <= signed'((num << 24) / denom);
                d2_r <= signed'(((num - denom) << 24) / denom);
            end else begin
                d1_r <= 32'sd0;
                d2_r <= 32'sd0;
            end

            // ---------------------------------------------------------
            // Stage 2: Evaluate BS Call price & Vega when CDF completes
            // C_BS = S * N(d1) - K * exp(-r*T) * N(d2)
            // Vega = S * sqrt(T) * phi(d1)
            // ---------------------------------------------------------
            valid_out <= cdf1_v;

            if (cdf1_v) begin
                ert = Q24_ONE - (($signed(r_r1) * $signed(T_r1)) >>> 24);
                if (ert < 0) ert = 64'sd0;

                term1     = ($signed(S_r1) * $signed(N_d1)) >>> 24;
                term2     = ($signed(K_r1) * ((signed'(ert) * $signed(N_d2)) >>> 24)) >>> 24;
                vega_calc = ($signed(S_r1) * $signed(phi_d1)) >>> 24;

                C_bs_out  <= signed'(term1 - term2);
                vega_out  <= signed'(vega_calc);
            end
        end
    end

endmodule
