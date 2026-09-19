/*
 * =========================================================
 * DPI-C Golden Model Header (Experiment 7 / Full Validation)
 * Target Venue: ACM/SIGDA FPGA 2027
 * =========================================================
 */

#ifndef IV_DPI_GOLDEN_H
#define IV_DPI_GOLDEN_H

#include <stdint.h>

#define MAX_TRANSACTIONS 131072

typedef struct {
    /* Double-precision originals */
    double   S, K, C, r, T;
    uint8_t  tid;

    /* Q8.24 packed values (sent to RTL via 256-bit AXI4-Stream) */
    uint32_t S_fixed;
    uint32_t K_fixed;
    uint32_t C_fixed;
    uint32_t r_fixed;
    uint32_t T_fixed;

    /* Ground truth double-precision reference */
    double   ref_iv;
    double   ref_delta;
    double   ref_vega;
    double   ref_gamma;
    int      is_liquid;
} IvGoldenTick;

/* Public API */
int  golden_load_csv(const char *csv_path);
void golden_init_test_vectors(int num_ticks, int dataset_mode);
int  golden_get_next_tick(int core_id, IvGoldenTick *tick_out, uint64_t cycle);
int  golden_get_total_ticks(void);
int  golden_get_bp_pct(void);

void golden_record_accepted(int core_id, uint64_t cycle);

void golden_push_result_full(uint32_t result_sigma_q824,
                             int32_t  result_delta_q824,
                             int32_t  result_vega_q824,
                             int32_t  result_gamma_q824,
                             int      tid,
                             uint64_t cycle);

void golden_print_report(uint64_t total_cycles);

/* Exposed math utilities */
double norm_cdf(double x);
double bs_call_price(double S, double K, double r, double T, double sigma);
double bs_vega(double S, double K, double r, double T, double sigma);
double bs_delta(double S, double K, double r, double T, double sigma);
double bs_gamma(double S, double K, double r, double T, double sigma);
double solve_iv(double S, double K, double C_market, double r, double T);

#endif /* IV_DPI_GOLDEN_H */
