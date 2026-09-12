/*
 * =========================================================
 * DPI-C Golden Model: Black-Scholes IV Solver (Pure C)
 * =========================================================
 * Provides double-precision reference implementation of:
 *   - Standard normal CDF  (using erfc)
 *   - Black-Scholes call price
 *   - Black-Scholes vega
 *   - Newton-Raphson IV solver (max 8 iterations, matches RTL)
 *
 * Used by iv_dpi_model.c to:
 *   1. Generate test vectors (Q8.24 packed IvMarketTick structs)
 *   2. Compute reference IV for each transaction
 *   3. Accumulate error metrics: MAE, RMSE, MRE at end of sim
 *
 * No external dependencies beyond C99 standard library.
 * =========================================================
 */

#include "iv_dpi_golden.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* -------------------------------------------------------
 * Internal storage: test vector queue + error accumulators
 * ------------------------------------------------------- */
#define MAX_TRANSACTIONS 65536

static IvGoldenTick  g_ticks[MAX_TRANSACTIONS];   /* generated test vectors    */
static double        g_ref_iv[MAX_TRANSACTIONS];   /* reference IV per tick     */
static double        g_ref_delta[MAX_TRANSACTIONS];/* reference Delta per tick  */
static double        g_ref_vega[MAX_TRANSACTIONS]; /* reference Vega per tick   */
static double        g_ref_gamma[MAX_TRANSACTIONS];/* reference Gamma per tick  */
static int           g_num_ticks   = 0;            /* total transactions loaded */
static int           g_tick_rd_ptr = 0;            /* read cursor (SV driver)   */
static int           g_result_cnt  = 0;            /* results received from SV  */

/* Error accumulators — IV */
static double g_sum_abs_err  = 0.0;
static double g_sum_sq_err   = 0.0;
static double g_sum_rel_err  = 0.0;
static int    g_pass_1pct    = 0;   /* |err| < 0.01 */
static int    g_pass_10pct   = 0;   /* |err| < 0.10 */

/* Error accumulators — Greeks */
static double g_delta_sum_abs = 0.0;
static double g_delta_sum_sq  = 0.0;
static double g_vega_sum_abs  = 0.0;
static double g_vega_sum_sq   = 0.0;
static double g_gamma_sum_abs = 0.0;
static double g_gamma_sum_sq  = 0.0;
static int    g_greek_cnt     = 0;  /* results with full Greek data */

static double g_all_abs_err[MAX_TRANSACTIONS];
static double g_liq_abs_err[MAX_TRANSACTIONS];
static double g_wing_abs_err[MAX_TRANSACTIONS];
static double g_fpga_iv[MAX_TRANSACTIONS];
static double g_fpga_delta[MAX_TRANSACTIONS];
static double g_fpga_vega[MAX_TRANSACTIONS];
static double g_fpga_gamma[MAX_TRANSACTIONS];
static int    g_liq_cnt  = 0;
static int    g_wing_cnt = 0;

static int compare_doubles(const void *a, const void *b) {
    double da = *(const double *)a;
    double db = *(const double *)b;
    if (da < db) return -1;
    if (da > db) return 1;
    return 0;
}

/* -------------------------------------------------------
 * Standard Normal PDF: phi(x) = exp(-x^2/2) / sqrt(2*pi)
 * ------------------------------------------------------- */
static double phi(double x) {
    return exp(-0.5 * x * x) / sqrt(2.0 * 3.14159265358979323846);
}

/* -------------------------------------------------------
 * Standard Normal CDF: N(x) = 0.5 * erfc(-x / sqrt(2))
 * ------------------------------------------------------- */
double norm_cdf(double x) {
    return 0.5 * erfc(-x / 1.41421356237309504880);
}

/* -------------------------------------------------------
 * Black-Scholes European Call Price
 * -------------------------------------------------------
 *   C = S*N(d1) - K*exp(-r*T)*N(d2)
 *   d1 = (ln(S/K) + (r + sigma^2/2)*T) / (sigma*sqrt(T))
 *   d2 = d1 - sigma*sqrt(T)
 * ------------------------------------------------------- */
double bs_call_price(double S, double K, double r, double T, double sigma) {
    if (sigma <= 1e-8 || T <= 1e-8) return fmax(S - K * exp(-r * T), 0.0);

    double sqrt_T = sqrt(T);
    double d1 = (log(S / K) + (r + 0.5 * sigma * sigma) * T) / (sigma * sqrt_T);
    double d2 = d1 - sigma * sqrt_T;

    return S * norm_cdf(d1) - K * exp(-r * T) * norm_cdf(d2);
}

/* -------------------------------------------------------
 * Black-Scholes Vega
 * -------------------------------------------------------
 *   Vega = S * sqrt(T) * phi(d1)
 * ------------------------------------------------------- */
double bs_vega(double S, double K, double r, double T, double sigma) {
    if (sigma <= 1e-8 || T <= 1e-8) return 0.0;

    double sqrt_T = sqrt(T);
    double d1 = (log(S / K) + (r + 0.5 * sigma * sigma) * T) / (sigma * sqrt_T);

    return S * sqrt_T * phi(d1);
}

/* -------------------------------------------------------
 * Black-Scholes Delta: Delta = N(d1)
 * ------------------------------------------------------- */
double bs_delta(double S, double K, double r, double T, double sigma) {
    if (sigma <= 1e-8 || T <= 1e-8) return (S >= K) ? 1.0 : 0.0;

    double sqrt_T = sqrt(T);
    double d1 = (log(S / K) + (r + 0.5 * sigma * sigma) * T) / (sigma * sqrt_T);
    return norm_cdf(d1);
}

/* -------------------------------------------------------
 * Black-Scholes Gamma: Gamma = phi(d1) / (S * sigma * sqrt(T))
 * ------------------------------------------------------- */
double bs_gamma(double S, double K, double r, double T, double sigma) {
    if (sigma <= 1e-8 || T <= 1e-8 || S <= 1e-8) return 0.0;

    double sqrt_T = sqrt(T);
    double d1 = (log(S / K) + (r + 0.5 * sigma * sigma) * T) / (sigma * sqrt_T);
    double denom = S * sigma * sqrt_T;
    return (denom > 1e-10) ? phi(d1) / denom : 0.0;
}

/* -------------------------------------------------------
 * Newton-Raphson IV Solver
 * -------------------------------------------------------
 * Mirrors the RTL FSM exactly:
 *   - sigma_0 = 0.20 (static initial guess, same as RTL)
 *   - Max 8 iterations
 *   - Convergence threshold: |delta_sigma| < 0.001
 *     (RTL uses Q8.24 ~= 0.0001 but golden uses 0.001 for
 *      double-precision representation of fixed-point limit)
 *   - Clamp sigma to [0.001, 5.0] after each step
 * ------------------------------------------------------- */
double solve_iv(double S, double K, double C_market, double r, double T) {
    double sigma = 0.20;   /* matches RTL static initial guess */

    for (int iter = 0; iter < 8; iter++) {
        double price = bs_call_price(S, K, r, T, sigma);
        double vega  = bs_vega(S, K, r, T, sigma);

        if (fabs(vega) < 1e-10) break;   /* degenerate: zero vega */

        double delta = (price - C_market) / vega;
        sigma -= delta;

        /* Clamp to valid range */
        if (sigma < 0.001) sigma = 0.001;
        if (sigma > 5.0)   sigma = 5.0;

        double price_new = bs_call_price(S, K, r, T, sigma);
        if (fabs(price_new - C_market) < 0.01) break;  /* converged: |price_error| < $0.01 matches RTL */
    }
    return sigma;
}

/* -------------------------------------------------------
 * Q8.24 Fixed-Point Conversion Helpers
 * ------------------------------------------------------- */
static inline uint32_t double_to_q824(double val) {
    /* Signed Q8.24: multiply by 2^24 and round */
    int32_t fixed = (int32_t)round(val * 16777216.0);
    return (uint32_t)fixed;
}

static inline double q824_to_double(uint32_t fixed_val) {
    /* Interpret as signed 32-bit first */
    int32_t signed_val = (int32_t)fixed_val;
    return (double)signed_val / 16777216.0;
}

/* -------------------------------------------------------
 * Public API: Initialize test vector queue
 * Called once from SV via DPI-C import.
 * Generates reproducible pseudo-random option parameters.
 * ------------------------------------------------------- */
void golden_init_test_vectors(int num_ticks) {
    if (num_ticks > MAX_TRANSACTIONS) num_ticks = MAX_TRANSACTIONS;

    g_num_ticks   = num_ticks;
    g_tick_rd_ptr = 0;
    g_result_cnt  = 0;
    g_sum_abs_err = 0.0;
    g_sum_sq_err  = 0.0;
    g_sum_rel_err = 0.0;
    g_pass_1pct   = 0;
    g_pass_10pct  = 0;
    g_liq_cnt     = 0;
    g_wing_cnt    = 0;
    /* Reset Greek accumulators */
    g_delta_sum_abs = 0.0; g_delta_sum_sq = 0.0;
    g_vega_sum_abs  = 0.0; g_vega_sum_sq  = 0.0;
    g_gamma_sum_abs = 0.0; g_gamma_sum_sq = 0.0;
    g_greek_cnt     = 0;

    /* Seed for reproducibility — same pattern as benchmark_accuracy.py */
    srand(42);

    for (int i = 0; i < num_ticks; i++) {
        /* S ∈ [20.0, 80.0] - safe within Q8.24 range */
        double S = 20.0 + (60.0 * rand()) / (double)RAND_MAX;
        /* Moneyness K/S ∈ [0.70, 1.40] */
        double k_ratio = 0.70 + (0.70 * rand()) / (double)RAND_MAX;
        double K = S * k_ratio;
        /* T ∈ [0.1, 1.5] years */
        double T = 0.10 + (1.40 * rand()) / (double)RAND_MAX;
        /* r ∈ [0.02, 0.06] */
        double r = 0.02 + (0.04 * rand()) / (double)RAND_MAX;
        /* True IV ∈ [0.15, 0.55] */
        double true_iv = 0.15 + (0.40 * rand()) / (double)RAND_MAX;
        double C = bs_call_price(S, K, r, T, true_iv);

        /* Store double-precision parameters for reference */
        g_ticks[i].S  = S;
        g_ticks[i].K  = K;
        g_ticks[i].C  = C;
        g_ticks[i].r  = r;
        g_ticks[i].T  = T;
        g_ticks[i].tid = (uint8_t)(i & 0x3F);

        /* Pack to Q8.24 for the 256-bit AXI4-Stream payload */
        g_ticks[i].S_fixed = double_to_q824(S);
        g_ticks[i].K_fixed = double_to_q824(K);
        g_ticks[i].C_fixed = double_to_q824(C);
        g_ticks[i].r_fixed = double_to_q824(r);
        g_ticks[i].T_fixed = double_to_q824(T);

        /* Store true reference IV (exact ground truth) */
        g_ref_iv[i] = true_iv;

        /* Pre-compute reference Greeks at the true IV */
        g_ref_delta[i] = bs_delta(S, K, r, T, true_iv);
        g_ref_vega[i]  = bs_vega(S, K, r, T, true_iv);
        g_ref_gamma[i] = bs_gamma(S, K, r, T, true_iv);
    }

    printf("[GOLDEN] Initialized %d test vectors with K/S in [0.70, 1.40] (seed=42).\n", num_ticks);
    fflush(stdout);
}

/* -------------------------------------------------------
 * Public API: Get next test tick for SV AXI driver
 * Returns 1 if a tick is available, 0 if queue is empty.
 * ------------------------------------------------------- */
int golden_get_next_tick(IvGoldenTick *tick_out) {
    if (g_tick_rd_ptr >= g_num_ticks) return 0;
    *tick_out = g_ticks[g_tick_rd_ptr++];
    return 1;
}

/* -------------------------------------------------------
 * Public API: Push FPGA result back; compare with reference
 * result_sigma_q824 : Q8.24 fixed-point sigma from FPGA
 * tick_index        : index into g_ticks[] for reference lookup
 * ------------------------------------------------------- */
void golden_push_result(uint32_t result_sigma_q824, int tick_index) {
    if (tick_index < 0 || tick_index >= g_num_ticks) {
        fprintf(stderr, "[GOLDEN] ERROR: tick_index %d out of range!\n", tick_index);
        return;
    }

    double fpga_sigma = q824_to_double(result_sigma_q824);
    double ref_sigma  = g_ref_iv[tick_index];
    double abs_err    = fabs(fpga_sigma - ref_sigma);
    double rel_err    = (ref_sigma > 1e-6) ? abs_err / ref_sigma : 0.0;

    g_sum_abs_err += abs_err;
    g_sum_sq_err  += abs_err * abs_err;
    g_sum_rel_err += rel_err;
    if (abs_err < 0.01)  g_pass_1pct++;
    if (abs_err < 0.10)  g_pass_10pct++;

    g_all_abs_err[g_result_cnt] = abs_err;
    g_fpga_iv[tick_index] = fpga_sigma;

    double sk = g_ticks[tick_index].S / g_ticks[tick_index].K;
    if (sk >= 0.85 && sk <= 1.15) {
        g_liq_abs_err[g_liq_cnt++] = abs_err;
    } else {
        g_wing_abs_err[g_wing_cnt++] = abs_err;
    }

    g_result_cnt++;
}

/* -------------------------------------------------------
 * Public API: Push full 128-bit FPGA result (IV + Greeks)
 * Signed Q8.24 for delta, vega, gamma (sign-extended from RTL).
 * gamma_q824 is sign-extended from the 26-bit RTL field.
 * ------------------------------------------------------- */
void golden_push_result_full(uint32_t result_sigma_q824,
                              int32_t  result_delta_q824,
                              int32_t  result_vega_q824,
                              int32_t  result_gamma_q824,
                              int      tick_index) {
    /* First do the IV accounting (identical to golden_push_result) */
    golden_push_result(result_sigma_q824, tick_index);

    if (tick_index < 0 || tick_index >= g_num_ticks) return;

    /* Convert Q8.24 Greek fields to double */
    double fpga_delta = (double)result_delta_q824 / 16777216.0;
    double fpga_vega  = (double)result_vega_q824  / 16777216.0;
    double fpga_gamma = (double)result_gamma_q824 / 16777216.0;

    double ref_delta = g_ref_delta[tick_index];
    double ref_vega  = g_ref_vega[tick_index];
    double ref_gamma = g_ref_gamma[tick_index];

    double d_err = fabs(fpga_delta - ref_delta);
    double v_err = fabs(fpga_vega  - ref_vega);
    double g_err = fabs(fpga_gamma - ref_gamma);

    g_delta_sum_abs += d_err;  g_delta_sum_sq += d_err * d_err;
    g_vega_sum_abs  += v_err;  g_vega_sum_sq  += v_err * v_err;
    g_gamma_sum_abs += g_err;  g_gamma_sum_sq += g_err * g_err;

    g_fpga_delta[tick_index] = fpga_delta;
    g_fpga_vega[tick_index]  = fpga_vega;
    g_fpga_gamma[tick_index] = fpga_gamma;
    g_greek_cnt++;
}

/* -------------------------------------------------------
 * Public API: Print summary report at end of simulation
 * ------------------------------------------------------- */
void golden_print_report(void) {
    if (g_result_cnt == 0) {
        printf("[GOLDEN] No results received — nothing to report.\n");
        return;
    }

    double mae  = g_sum_abs_err / g_result_cnt;
    double rmse = sqrt(g_sum_sq_err / g_result_cnt);
    double mre  = g_sum_rel_err  / g_result_cnt * 100.0;
    double pct_1   = 100.0 * g_pass_1pct  / g_result_cnt;
    double pct_10  = 100.0 * g_pass_10pct / g_result_cnt;

    /* Sort arrays for exact percentiles */
    qsort(g_all_abs_err, g_result_cnt, sizeof(double), compare_doubles);
    if (g_liq_cnt > 0) qsort(g_liq_abs_err, g_liq_cnt, sizeof(double), compare_doubles);
    if (g_wing_cnt > 0) qsort(g_wing_abs_err, g_wing_cnt, sizeof(double), compare_doubles);

    double p50_all = g_all_abs_err[g_result_cnt / 2];
    double p95_all = g_all_abs_err[(int)(0.95 * g_result_cnt)];
    double p99_all = g_all_abs_err[(int)(0.99 * g_result_cnt)];
    double max_all = g_all_abs_err[g_result_cnt - 1];

    /* Liquid statistics */
    double liq_mae = 0.0, liq_p50 = 0.0, liq_p95 = 0.0, liq_max = 0.0;
    int liq_1pct = 0;
    if (g_liq_cnt > 0) {
        double liq_sum = 0.0;
        for (int i = 0; i < g_liq_cnt; i++) {
            liq_sum += g_liq_abs_err[i];
            if (g_liq_abs_err[i] < 0.01) liq_1pct++;
        }
        liq_mae = liq_sum / g_liq_cnt;
        liq_p50 = g_liq_abs_err[g_liq_cnt / 2];
        liq_p95 = g_liq_abs_err[(int)(0.95 * g_liq_cnt)];
        liq_max = g_liq_abs_err[g_liq_cnt - 1];
    }

    /* Wing statistics */
    double wing_mae = 0.0, wing_p50 = 0.0, wing_p95 = 0.0, wing_max = 0.0;
    int wing_1pct = 0;
    if (g_wing_cnt > 0) {
        double wing_sum = 0.0;
        for (int i = 0; i < g_wing_cnt; i++) {
            wing_sum += g_wing_abs_err[i];
            if (g_wing_abs_err[i] < 0.01) wing_1pct++;
        }
        wing_mae = wing_sum / g_wing_cnt;
        wing_p50 = g_wing_abs_err[g_wing_cnt / 2];
        wing_p95 = g_wing_abs_err[(int)(0.95 * g_wing_cnt)];
        wing_max = g_wing_abs_err[g_wing_cnt - 1];
    }

    printf("\n");
    printf("=================================================================\n");
    printf("  DPI-C Co-Simulation Accuracy Report (Wide Moneyness: K/S in [0.70, 1.40])\n");
    printf("  Transactions: %d sent / %d results received\n",
           g_num_ticks, g_result_cnt);
    printf("-----------------------------------------------------------------\n");
    printf("  Overall Population (%d contracts):\n", g_result_cnt);
    printf("    Mean Absolute Error (MAE)  : %.6f  (%.4f%% vol)\n",
           mae, mae * 100.0);
    printf("    Root Mean Square Error     : %.6f\n", rmse);
    printf("    Mean Relative Error (MRE)  : %.4f%%\n", mre);
    printf("    Median Absolute Error      : %.6f  (%.4f%% vol)\n",
           p50_all, p50_all * 100.0);
    printf("    95th Percentile Error      : %.6f\n", p95_all);
    printf("    99th Percentile Error      : %.6f\n", p99_all);
    printf("    Maximum Absolute Error     : %.6f\n", max_all);
    printf("    Within 1.0%% vol error     : %.1f%% of contracts\n", pct_1);
    printf("    Within 10.0%% vol error    : %.1f%% of contracts\n", pct_10);
    printf("-----------------------------------------------------------------\n");
    printf("  Regime Breakdown:\n");
    printf("  - Liquid Regime (0.85 <= S/K <= 1.15): %d contracts (%.1f%%)\n",
           g_liq_cnt, 100.0 * g_liq_cnt / g_result_cnt);
    printf("      MAE: %.6f (%.4f%% vol)\n", liq_mae, liq_mae * 100.0);
    printf("      Median: %.6f, 95th-Pct: %.6f, Max: %.6f\n", liq_p50, liq_p95, liq_max);
    printf("      Within 1.0%% vol: %.1f%%\n", 100.0 * liq_1pct / (g_liq_cnt > 0 ? g_liq_cnt : 1));
    printf("  - Deep Wings (S/K < 0.85 or S/K > 1.15): %d contracts (%.1f%%)\n",
           g_wing_cnt, 100.0 * g_wing_cnt / g_result_cnt);
    printf("      MAE: %.6f (%.4f%% vol)\n", wing_mae, wing_mae * 100.0);
    printf("      Median: %.6f, 95th-Pct: %.6f, Max: %.6f\n", wing_p50, wing_p95, wing_max);
    printf("      Within 1.0%% vol: %.1f%%\n", 100.0 * wing_1pct / (g_wing_cnt > 0 ? g_wing_cnt : 1));
    printf("=================================================================\n");
    printf("  PASS criterion: MAE < 0.005 (0.5%% vol) — %s\n",
           mae < 0.005 ? "*** PASS ***" : "!!! FAIL !!!");
    printf("=================================================================\n");

    /* Greek accuracy summary */
    if (g_greek_cnt > 0) {
        double n = (double)g_greek_cnt;
        printf("\n");
        printf("=================================================================\n");
        printf("  Greeks Accuracy Summary (%d contracts with full RTL output)\n", g_greek_cnt);
        printf("-----------------------------------------------------------------\n");
        printf("  Delta  MAE : %.6f   RMSE: %.6f\n",
               g_delta_sum_abs / n, sqrt(g_delta_sum_sq / n));
        printf("  Vega   MAE : %.6f   RMSE: %.6f\n",
               g_vega_sum_abs  / n, sqrt(g_vega_sum_sq  / n));
        printf("  Gamma  MAE : %.6f   RMSE: %.6f\n",
               g_gamma_sum_abs / n, sqrt(g_gamma_sum_sq / n));
        printf("=================================================================\n");
    }

    /* Export full results to CSV */
    FILE *fcsv = fopen("sim_results/dpi_10k_results.csv", "w");
    if (fcsv) {
        /* Header — IV + Greek columns */
        fprintf(fcsv, "tick,S,K,moneyness_SK,moneyness_KS,T,r,"
                      "true_iv,fpga_iv,abs_err,"
                      "true_delta,fpga_delta,delta_err,"
                      "true_vega,fpga_vega,vega_err,"
                      "true_gamma,fpga_gamma,gamma_err,"
                      "is_liquid\n");
        for (int i = 0; i < g_result_cnt; i++) {
            double s = g_ticks[i].S;
            double k = g_ticks[i].K;
            double sk = s / k;
            double ks = k / s;
            double t = g_ticks[i].T;
            double r = g_ticks[i].r;
            double t_iv = g_ref_iv[i];
            double f_iv = g_fpga_iv[i];
            double err  = fabs(f_iv - t_iv);
            int is_liq  = (sk >= 0.85 && sk <= 1.15) ? 1 : 0;

            /* Greek values (0 if not captured by full-result path) */
            double t_delta = g_ref_delta[i];
            double f_delta = g_fpga_delta[i];
            double t_vega  = g_ref_vega[i];
            double f_vega  = g_fpga_vega[i];
            double t_gamma = g_ref_gamma[i];
            double f_gamma = g_fpga_gamma[i];

            fprintf(fcsv, "%d,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,"
                          "%.6f,%.6f,%.6f,"
                          "%.6f,%.6f,%.6f,"
                          "%.6f,%.6f,%.6f,"
                          "%.6f,%.6f,%.6f,"
                          "%d\n",
                    i, s, k, sk, ks, t, r,
                    t_iv, f_iv, err,
                    t_delta, f_delta, fabs(f_delta - t_delta),
                    t_vega,  f_vega,  fabs(f_vega  - t_vega),
                    t_gamma, f_gamma, fabs(f_gamma - t_gamma),
                    is_liq);
        }
        fclose(fcsv);
        printf("[GOLDEN] Exported full tick results (+Greeks) to sim_results/dpi_10k_results.csv\n");
    }
    fflush(stdout);
}
