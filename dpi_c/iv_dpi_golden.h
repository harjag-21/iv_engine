/*
 * =========================================================
 * DPI-C Golden Model Header
 * =========================================================
 * Shared types and function declarations used by:
 *   - iv_dpi_golden.c  (B-S reference implementation)
 *   - iv_dpi_model.c   (DPI-C SV import function glue)
 * =========================================================
 */

#ifndef IV_DPI_GOLDEN_H
#define IV_DPI_GOLDEN_H

#include <stdint.h>

/* -------------------------------------------------------
 * IvGoldenTick: One test vector entry
 * Holds double-precision parameters AND the Q8.24 packed
 * values that are sent to the RTL via AXI4-Stream.
 * ------------------------------------------------------- */
typedef struct {
    /* Double-precision originals (for reference computation) */
    double   S, K, C, r, T;
    uint8_t  tid;

    /* Q8.24 packed values (sent to RTL via 256-bit AXI4-Stream) */
    uint32_t S_fixed;
    uint32_t K_fixed;
    uint32_t C_fixed;
    uint32_t r_fixed;
    uint32_t T_fixed;
} IvGoldenTick;

/* -------------------------------------------------------
 * Public API (called from iv_dpi_model.c via DPI-C bridge)
 * ------------------------------------------------------- */
void golden_init_test_vectors(int num_ticks);
int  golden_get_next_tick(IvGoldenTick *tick_out);

/* Original IV-only result push (still supported for backward compat) */
void golden_push_result(uint32_t result_sigma_q824, int tick_index);

/* Extended result push: IV + Delta + Vega + Gamma from 128-bit egress bus */
void golden_push_result_full(uint32_t result_sigma_q824,
                              int32_t  result_delta_q824,
                              int32_t  result_vega_q824,
                              int32_t  result_gamma_q824,
                              int      tick_index);

void golden_print_report(void);

/* -------------------------------------------------------
 * Exposed math utilities (used in accuracy benchmarks)
 * ------------------------------------------------------- */
double norm_cdf(double x);
double bs_call_price(double S, double K, double r, double T, double sigma);
double bs_vega(double S, double K, double r, double T, double sigma);
double bs_delta(double S, double K, double r, double T, double sigma);
double bs_gamma(double S, double K, double r, double T, double sigma);
double solve_iv(double S, double K, double C_market, double r, double T);

#endif /* IV_DPI_GOLDEN_H */
