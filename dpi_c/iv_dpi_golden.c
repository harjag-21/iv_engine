/*
 * =========================================================
 * DPI-C Golden Model: Multi-Core RTL Verification Engine
 * Target Venue: ACM/SIGDA FPGA 2027
 * =========================================================
 */

#include "iv_dpi_golden.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    int      tick_index;
    uint64_t dispatch_cycle;
    int      core_id;
    int      is_active;
} ActiveTx;

static IvGoldenTick g_ticks[MAX_TRANSACTIONS];
static int          g_num_ticks   = 0;
static int          g_tick_rd_ptr = 0;

/* Scoreboard & TID Pools (16 TIDs per core) */
static int      g_free_tids[4][16];
static int      g_num_free[4];
static ActiveTx g_active_tx[64];

/* Transaction Integrity Counters */
static int      g_accepted_count  = 0;
static int      g_retired_count   = 0;
static int      g_mismatch_count  = 0;
static int      g_duplicate_count = 0;
static uint64_t g_first_accepted_cycle = 0;
static uint64_t g_last_retired_cycle   = 0;

/* Latencies */
static uint32_t g_latencies[MAX_TRANSACTIONS];

/* Active context occupancy tracking */
static int      g_current_active[4];
static int      g_max_active[4];
static uint64_t g_sum_active[4];
static uint64_t g_samples_active[4];

/* Results and errors */
static double   g_fpga_iv[MAX_TRANSACTIONS];
static double   g_fpga_delta[MAX_TRANSACTIONS];
static double   g_fpga_vega[MAX_TRANSACTIONS];
static double   g_fpga_gamma[MAX_TRANSACTIONS];
static double   g_all_abs_err_iv[MAX_TRANSACTIONS];
static double   g_all_abs_err_delta[MAX_TRANSACTIONS];
static double   g_all_abs_err_vega[MAX_TRANSACTIONS];
static double   g_all_abs_err_gamma[MAX_TRANSACTIONS];
static double   g_liq_abs_err_iv[MAX_TRANSACTIONS];
static double   g_wing_abs_err_iv[MAX_TRANSACTIONS];
static int      g_liq_cnt  = 0;
static int      g_wing_cnt = 0;

/* Output file paths */
static char g_metrics_json_path[512] = "sim_results/last_run_metrics.json";
static char g_results_csv_path[512]  = "sim_results/last_run_results.csv";

static int compare_doubles(const void *a, const void *b) {
    double da = *(const double *)a;
    double db = *(const double *)b;
    if (da < db) return -1;
    if (da > db) return 1;
    return 0;
}

static int compare_uint32(const void *a, const void *b) {
    uint32_t ua = *(const uint32_t *)a;
    uint32_t ub = *(const uint32_t *)b;
    if (ua < ub) return -1;
    if (ua > ub) return 1;
    return 0;
}

static inline uint32_t double_to_q824(double val) {
    int32_t fixed = (int32_t)round(val * 16777216.0);
    return (uint32_t)fixed;
}

static inline double q824_to_double(uint32_t fixed_val) {
    int32_t signed_val = (int32_t)fixed_val;
    return (double)signed_val / 16777216.0;
}

static double phi(double x) {
    return exp(-0.5 * x * x) / sqrt(2.0 * 3.14159265358979323846);
}

double norm_cdf(double x) {
    return 0.5 * erfc(-x / 1.41421356237309504880);
}

double bs_call_price(double S, double K, double r, double T, double sigma) {
    if (sigma <= 1e-8 || T <= 1e-8) return fmax(S - K * exp(-r * T), 0.0);
    double sqrt_T = sqrt(T);
    double d1 = (log(S / K) + (r + 0.5 * sigma * sigma) * T) / (sigma * sqrt_T);
    double d2 = d1 - sigma * sqrt_T;
    return S * norm_cdf(d1) - K * exp(-r * T) * norm_cdf(d2);
}

double bs_vega(double S, double K, double r, double T, double sigma) {
    if (sigma <= 1e-8 || T <= 1e-8) return 0.0;
    double sqrt_T = sqrt(T);
    double d1 = (log(S / K) + (r + 0.5 * sigma * sigma) * T) / (sigma * sqrt_T);
    return S * sqrt_T * phi(d1);
}

double bs_delta(double S, double K, double r, double T, double sigma) {
    if (sigma <= 1e-8 || T <= 1e-8) return (S >= K) ? 1.0 : 0.0;
    double sqrt_T = sqrt(T);
    double d1 = (log(S / K) + (r + 0.5 * sigma * sigma) * T) / (sigma * sqrt_T);
    return norm_cdf(d1);
}

double bs_gamma(double S, double K, double r, double T, double sigma) {
    if (sigma <= 1e-8 || T <= 1e-8 || S <= 1e-8) return 0.0;
    double sqrt_T = sqrt(T);
    double d1 = (log(S / K) + (r + 0.5 * sigma * sigma) * T) / (sigma * sqrt_T);
    double denom = S * sigma * sqrt_T;
    return (denom > 1e-10) ? phi(d1) / denom : 0.0;
}

double solve_iv(double S, double K, double C_market, double r, double T) {
    double sigma = 0.20;
    for (int iter = 0; iter < 8; iter++) {
        double price = bs_call_price(S, K, r, T, sigma);
        double vega  = bs_vega(S, K, r, T, sigma);
        if (fabs(vega) < 1e-10) break;
        double delta = (price - C_market) / vega;
        sigma -= delta;
        if (sigma < 0.001) sigma = 0.001;
        if (sigma > 5.0)   sigma = 5.0;
        double price_new = bs_call_price(S, K, r, T, sigma);
        if (fabs(price_new - C_market) < 0.01) break;
    }
    return sigma;
}

int golden_load_csv(const char *csv_path) {
    FILE *fp = fopen(csv_path, "r");
    if (!fp) {
        fprintf(stderr, "[GOLDEN] ERROR: Cannot open CSV %s\n", csv_path);
        return 0;
    }
    char line[512];
    if (!fgets(line, sizeof(line), fp)) {
        fclose(fp);
        return 0;
    }

    int count = 0;
    while (fgets(line, sizeof(line), fp) && count < MAX_TRANSACTIONS) {
        int tick_id = 0, is_liq = 0;
        double S = 0, K = 0, C = 0, r = 0, T = 0;
        double true_iv = 0, true_delta = 0, true_vega = 0, true_gamma = 0;

        int fields = sscanf(line, "%d,%lf,%lf,%lf,%lf,%lf,%lf,%lf,%lf,%lf,%d",
                            &tick_id, &S, &K, &C, &r, &T,
                            &true_iv, &true_delta, &true_vega, &true_gamma, &is_liq);
        if (fields >= 10) {
            g_ticks[count].S = S;
            g_ticks[count].K = K;
            g_ticks[count].C = C;
            g_ticks[count].r = r;
            g_ticks[count].T = T;
            g_ticks[count].ref_iv    = true_iv;
            g_ticks[count].ref_delta = true_delta;
            g_ticks[count].ref_vega  = true_vega;
            g_ticks[count].ref_gamma = true_gamma;
            g_ticks[count].is_liquid = is_liq;

            g_ticks[count].S_fixed = double_to_q824(S);
            g_ticks[count].K_fixed = double_to_q824(K);
            g_ticks[count].C_fixed = double_to_q824(C);
            g_ticks[count].r_fixed = double_to_q824(r);
            g_ticks[count].T_fixed = double_to_q824(T);
            count++;
        }
    }
    fclose(fp);
    g_num_ticks = count;
    printf("[GOLDEN] Successfully loaded %d contracts from %s\n", count, csv_path);
    fflush(stdout);
    return count;
}

int golden_get_total_ticks(void) {
    return g_num_ticks;
}

static int g_bp_pct = 0;

int golden_get_bp_pct(void) {
    return g_bp_pct;
}

void golden_init_test_vectors(int num_ticks, int dataset_mode) {
    const char *env_csv = getenv("DATASET_CSV");
    const char *env_json = getenv("OUTPUT_METRICS_JSON");
    const char *env_out_csv = getenv("OUTPUT_RESULTS_CSV");

    if (env_json) strncpy(g_metrics_json_path, env_json, sizeof(g_metrics_json_path)-1);
    if (env_out_csv) strncpy(g_results_csv_path, env_out_csv, sizeof(g_results_csv_path)-1);

    if (env_csv && strlen(env_csv) > 0) {
        golden_load_csv(env_csv);
    } else {
        const char *default_path = "experiments/data/dataset_a_canonical_10k.csv";
        if (dataset_mode == 1) default_path = "experiments/data/dataset_b_random_100k.csv";
        else if (dataset_mode == 2) default_path = "experiments/data/dataset_c_boundary_2500.csv";
        else if (dataset_mode == 3) default_path = "experiments/data/dataset_d_spx_1382.csv";
        golden_load_csv(default_path);
    }

    const char *env_ticks = getenv("NUM_TICKS");
    const char *env_bp    = getenv("BP_PCT");

    if (env_bp) g_bp_pct = atoi(env_bp);
    else        g_bp_pct = 0;

    if (env_ticks && strlen(env_ticks) > 0) {
        int t = atoi(env_ticks);
        if (t > 0 && t <= g_num_ticks) g_num_ticks = t;
    } else if (num_ticks > 0 && num_ticks < g_num_ticks) {
        g_num_ticks = num_ticks;
    }

    g_tick_rd_ptr = 0;
    g_accepted_count = 0;
    g_retired_count = 0;
    g_mismatch_count = 0;
    g_duplicate_count = 0;
    g_first_accepted_cycle = 0;
    g_last_retired_cycle = 0;
    g_liq_cnt = 0;
    g_wing_cnt = 0;

    for (int c = 0; c < 4; c++) {
        g_num_free[c] = 16;
        for (int m = 0; m < 16; m++) {
            g_free_tids[c][m] = 4 * m + c;
        }
        g_current_active[c] = 0;
        g_max_active[c] = 0;
        g_sum_active[c] = 0;
        g_samples_active[c] = 0;
    }

    for (int t = 0; t < 64; t++) {
        g_active_tx[t].is_active = 0;
        g_active_tx[t].tick_index = -1;
        g_active_tx[t].dispatch_cycle = 0;
        g_active_tx[t].core_id = -1;
    }

    srand(42);
    printf("[GOLDEN] Ready to simulate %d transactions. Signoff clock: 100 MHz (10.0 ns).\n", g_num_ticks);
    fflush(stdout);
}

int golden_get_next_tick(int core_id, IvGoldenTick *tick_out, uint64_t cycle) {
    if (g_tick_rd_ptr >= g_num_ticks) return 0;
    if (core_id < 0 || core_id >= 4) return 0;
    if (g_num_free[core_id] <= 0) return 0;

    int slot = rand() % g_num_free[core_id];
    int tid  = g_free_tids[core_id][slot];
    g_free_tids[core_id][slot] = g_free_tids[core_id][g_num_free[core_id] - 1];
    g_num_free[core_id]--;

    int idx = g_tick_rd_ptr;
    g_active_tx[tid].tick_index     = idx;
    g_active_tx[tid].dispatch_cycle = cycle;
    g_active_tx[tid].core_id        = core_id;
    g_active_tx[tid].is_active      = 1;

    g_current_active[core_id] = 16 - g_num_free[core_id];
    if (g_current_active[core_id] > g_max_active[core_id])
        g_max_active[core_id] = g_current_active[core_id];
    g_sum_active[core_id] += g_current_active[core_id];
    g_samples_active[core_id]++;

    *tick_out = g_ticks[idx];
    tick_out->tid = (uint8_t)(tid & 0x3F);

    g_tick_rd_ptr++;
    return 1;
}

void golden_record_accepted(int core_id, uint64_t cycle) {
    (void)core_id;
    g_accepted_count++;
    if (g_first_accepted_cycle == 0) {
        g_first_accepted_cycle = cycle;
    }
}

void golden_push_result_full(uint32_t result_sigma_q824,
                             int32_t  result_delta_q824,
                             int32_t  result_vega_q824,
                             int32_t  result_gamma_q824,
                             int      tid,
                             uint64_t cycle) {
    if (tid < 0 || tid >= 64 || !g_active_tx[tid].is_active) {
        g_duplicate_count++;
        fprintf(stderr, "[INTEGRITY ERROR] Unexpected/duplicate TID=%d at cycle %llu!\n", tid, (unsigned long long)cycle);
        return;
    }

    int expected_core = tid & 3;
    if (g_active_tx[tid].core_id != expected_core) {
        g_mismatch_count++;
        fprintf(stderr, "[INTEGRITY ERROR] TID=%d core mismatch (exp %d, got %d)!\n",
                tid, expected_core, g_active_tx[tid].core_id);
    }

    uint64_t lat = cycle - g_active_tx[tid].dispatch_cycle;
    g_latencies[g_retired_count] = (uint32_t)lat;
    g_last_retired_cycle = cycle;

    g_free_tids[expected_core][g_num_free[expected_core]] = tid;
    g_num_free[expected_core]++;
    g_current_active[expected_core] = 16 - g_num_free[expected_core];

    int tick_idx = g_active_tx[tid].tick_index;
    g_active_tx[tid].is_active = 0;

    double fpga_sigma = (double)((int32_t)result_sigma_q824) / 16777216.0;
    double fpga_delta = (double)result_delta_q824 / 16777216.0;
    double fpga_vega  = (double)result_vega_q824  / 16777216.0;
    double fpga_gamma = (double)result_gamma_q824 / 16777216.0;

    double ref_iv    = g_ticks[tick_idx].ref_iv;
    double ref_delta = g_ticks[tick_idx].ref_delta;
    double ref_vega  = g_ticks[tick_idx].ref_vega;
    double ref_gamma = g_ticks[tick_idx].ref_gamma;

    double err_iv    = fabs(fpga_sigma - ref_iv);
    double err_delta = fabs(fpga_delta - ref_delta);
    double err_vega  = fabs(fpga_vega  - ref_vega);
    double err_gamma = fabs(fpga_gamma - ref_gamma);

    g_fpga_iv[tick_idx]    = fpga_sigma;
    g_fpga_delta[tick_idx] = fpga_delta;
    g_fpga_vega[tick_idx]  = fpga_vega;
    g_fpga_gamma[tick_idx] = fpga_gamma;

    g_all_abs_err_iv[g_retired_count]    = err_iv;
    g_all_abs_err_delta[g_retired_count] = err_delta;
    g_all_abs_err_vega[g_retired_count]  = err_vega;
    g_all_abs_err_gamma[g_retired_count] = err_gamma;

    if (g_ticks[tick_idx].is_liquid) {
        g_liq_abs_err_iv[g_liq_cnt++] = err_iv;
    } else {
        g_wing_abs_err_iv[g_wing_cnt++] = err_iv;
    }

    g_retired_count++;
}

void golden_print_report(uint64_t total_cycles) {
    if (g_retired_count == 0) {
        printf("[GOLDEN] No results received to report!\n");
        return;
    }

    uint64_t elapsed_cycles = (g_last_retired_cycle >= g_first_accepted_cycle)
                              ? (g_last_retired_cycle - g_first_accepted_cycle + 1)
                              : total_cycles;
    double elapsed_sec = (double)elapsed_cycles * 10.0e-9;
    double sustained_mops = (elapsed_sec > 0) ? ((double)g_retired_count / elapsed_sec / 1.0e6) : 0.0;

    uint32_t *sorted_lat = (uint32_t *)malloc(g_retired_count * sizeof(uint32_t));
    memcpy(sorted_lat, g_latencies, g_retired_count * sizeof(uint32_t));
    qsort(sorted_lat, g_retired_count, sizeof(uint32_t), compare_uint32);

    uint32_t lat_min = sorted_lat[0];
    uint32_t lat_med = sorted_lat[g_retired_count / 2];
    uint32_t lat_p95 = sorted_lat[(int)(0.95 * g_retired_count)];
    uint32_t lat_p99 = sorted_lat[(int)(0.99 * g_retired_count)];
    uint32_t lat_max = sorted_lat[g_retired_count - 1];

    uint64_t sum_lat = 0;
    for (int i = 0; i < g_retired_count; i++) sum_lat += sorted_lat[i];
    double lat_mean = (double)sum_lat / g_retired_count;
    free(sorted_lat);

    double *sorted_iv_err = (double *)malloc(g_retired_count * sizeof(double));
    memcpy(sorted_iv_err, g_all_abs_err_iv, g_retired_count * sizeof(double));
    qsort(sorted_iv_err, g_retired_count, sizeof(double), compare_doubles);

    double sum_iv_err = 0.0, sum_sq_iv_err = 0.0;
    for (int i = 0; i < g_retired_count; i++) {
        sum_iv_err    += sorted_iv_err[i];
        sum_sq_iv_err += sorted_iv_err[i] * sorted_iv_err[i];
    }
    double iv_mae  = sum_iv_err / g_retired_count;
    double iv_rmse = sqrt(sum_sq_iv_err / g_retired_count);
    double iv_p50  = sorted_iv_err[g_retired_count / 2];
    double iv_p95  = sorted_iv_err[(int)(0.95 * g_retired_count)];
    double iv_p99  = sorted_iv_err[(int)(0.99 * g_retired_count)];
    double iv_max  = sorted_iv_err[g_retired_count - 1];
    free(sorted_iv_err);

    double sum_d = 0.0, sum_v = 0.0, sum_g = 0.0;
    double max_d = 0.0, max_v = 0.0, max_g = 0.0;
    for (int i = 0; i < g_retired_count; i++) {
        sum_d += g_all_abs_err_delta[i];
        sum_v += g_all_abs_err_vega[i];
        sum_g += g_all_abs_err_gamma[i];
        if (g_all_abs_err_delta[i] > max_d) max_d = g_all_abs_err_delta[i];
        if (g_all_abs_err_vega[i]  > max_v) max_v = g_all_abs_err_vega[i];
        if (g_all_abs_err_gamma[i] > max_g) max_g = g_all_abs_err_gamma[i];
    }
    double delta_mae = sum_d / g_retired_count;
    double vega_mae  = sum_v / g_retired_count;
    double gamma_mae = sum_g / g_retired_count;

    double liq_mae = 0.0;
    if (g_liq_cnt > 0) {
        double s = 0.0;
        for (int i = 0; i < g_liq_cnt; i++) s += g_liq_abs_err_iv[i];
        liq_mae = s / g_liq_cnt;
    }
    double wing_mae = 0.0;
    if (g_wing_cnt > 0) {
        double s = 0.0;
        for (int i = 0; i < g_wing_cnt; i++) s += g_wing_abs_err_iv[i];
        wing_mae = s / g_wing_cnt;
    }

    int n_lost = g_accepted_count - g_retired_count;

    printf("\n");
    printf("=================================================================\n");
    printf("  FOUR-CORE HARDWARE RTL VALIDATION & SYSTEM SATURATION REPORT\n");
    printf("  Target Device Signoff: Artix-7 200T @ 100.00 MHz (T_clk=10.0 ns)\n");
    printf("=================================================================\n");
    printf("  TRANSACTION INTEGRITY METRICS (First-Class Proof):\n");
    printf("    Contracts Accepted (N_acc)   : %d\n", g_accepted_count);
    printf("    Contracts Retired  (N_ret)   : %d\n", g_retired_count);
    printf("    Lost Transactions  (N_lost)  : %d  %s\n", n_lost, (n_lost == 0) ? "[PASS]" : "[FAIL]");
    printf("    Duplicate Output   (N_dup)   : %d  %s\n", g_duplicate_count, (g_duplicate_count == 0) ? "[PASS]" : "[FAIL]");
    printf("    TID / Core Mismatches        : %d  %s\n", g_mismatch_count, (g_mismatch_count == 0) ? "[PASS]" : "[FAIL]");
    printf("-----------------------------------------------------------------\n");
    printf("  SYSTEM THROUGHPUT & LATENCY PROFILING:\n");
    printf("    Total Clock Cycles           : %llu\n", (unsigned long long)total_cycles);
    printf("    Active Busy Window           : %llu cycles (%.3f ms)\n", (unsigned long long)elapsed_cycles, elapsed_sec * 1000.0);
    printf("    Sustained Throughput         : %.2f Mcontracts/s (%.2f MOps/s)\n", sustained_mops, sustained_mops);
    printf("    Latency Distribution (cycles): Min=%u | Mean=%.1f | Med=%u | P95=%u | P99=%u | Max=%u\n",
           lat_min, lat_mean, lat_med, lat_p95, lat_p99, lat_max);
    printf("    Latency Distribution (microsec): Min=%.2f | Mean=%.2f | Med=%.2f | P95=%.2f | P99=%.2f | Max=%.2f\n",
           lat_min * 0.010, lat_mean * 0.010, lat_med * 0.010, lat_p95 * 0.010, lat_p99 * 0.010, lat_max * 0.010);
    printf("    Max Active Contexts/Core     : C0=%d, C1=%d, C2=%d, C3=%d (Hardware Invariant <= 60)\n",
           g_max_active[0], g_max_active[1], g_max_active[2], g_max_active[3]);
    printf("-----------------------------------------------------------------\n");
    printf("  RTL-TO-GOLDEN NUMERICAL ACCURACY (Double-Precision FP64 vs Q8.24):\n");
    printf("    IV Mean Absolute Error (MAE) : %.6f (%.2f vol-bps)\n", iv_mae, iv_mae * 10000.0);
    printf("    IV Root Mean Square Error    : %.6f\n", iv_rmse);
    printf("    IV Median (P50) Error        : %.6f (%.2f vol-bps)\n", iv_p50, iv_p50 * 10000.0);
    printf("    IV 95th Percentile Error     : %.6f (%.2f vol-bps)\n", iv_p95, iv_p95 * 10000.0);
    printf("    IV 99th Percentile Error     : %.6f (%.2f vol-bps)\n", iv_p99, iv_p99 * 10000.0);
    printf("    IV Maximum Absolute Error    : %.6f\n", iv_max);
    printf("    - Liquid Near-The-Money MAE  : %.6f (%.2f vol-bps) [N=%d]\n", liq_mae, liq_mae * 10000.0, g_liq_cnt);
    printf("    - Deep Wing Regime MAE       : %.6f (%.2f vol-bps) [N=%d]\n", wing_mae, wing_mae * 10000.0, g_wing_cnt);
    printf("    Delta MAE                    : %.6f (Max: %.6f)\n", delta_mae, max_d);
    printf("    Vega  MAE                    : %.6f (Max: %.6f)\n", vega_mae, max_v);
    printf("    Gamma MAE                    : %.6f (Max: %.6f)\n", gamma_mae, max_g);
    printf("=================================================================\n");
    fflush(stdout);

    FILE *fjson = fopen(g_metrics_json_path, "w");
    if (fjson) {
        fprintf(fjson, "{\n");
        fprintf(fjson, "  \"accepted_count\": %d,\n", g_accepted_count);
        fprintf(fjson, "  \"retired_count\": %d,\n", g_retired_count);
        fprintf(fjson, "  \"lost_count\": %d,\n", n_lost);
        fprintf(fjson, "  \"duplicate_count\": %d,\n", g_duplicate_count);
        fprintf(fjson, "  \"mismatch_count\": %d,\n", g_mismatch_count);
        fprintf(fjson, "  \"total_cycles\": %llu,\n", (unsigned long long)total_cycles);
        fprintf(fjson, "  \"elapsed_cycles\": %llu,\n", (unsigned long long)elapsed_cycles);
        fprintf(fjson, "  \"sustained_mops\": %.4f,\n", sustained_mops);
        fprintf(fjson, "  \"latency_cycles\": {\"min\": %u, \"mean\": %.2f, \"med\": %u, \"p95\": %u, \"p99\": %u, \"max\": %u},\n",
                lat_min, lat_mean, lat_med, lat_p95, lat_p99, lat_max);
        fprintf(fjson, "  \"latency_us\": {\"min\": %.3f, \"mean\": %.3f, \"med\": %.3f, \"p95\": %.3f, \"p99\": %.3f, \"max\": %.3f},\n",
                lat_min * 0.010, lat_mean * 0.010, lat_med * 0.010, lat_p95 * 0.010, lat_p99 * 0.010, lat_max * 0.010);
        fprintf(fjson, "  \"max_active_contexts\": [%d, %d, %d, %d],\n",
                g_max_active[0], g_max_active[1], g_max_active[2], g_max_active[3]);
        fprintf(fjson, "  \"iv_mae\": %.8f,\n", iv_mae);
        fprintf(fjson, "  \"iv_mae_vol_bps\": %.4f,\n", iv_mae * 10000.0);
        fprintf(fjson, "  \"iv_rmse\": %.8f,\n", iv_rmse);
        fprintf(fjson, "  \"iv_p50_vol_bps\": %.4f,\n", iv_p50 * 10000.0);
        fprintf(fjson, "  \"iv_p95_vol_bps\": %.4f,\n", iv_p95 * 10000.0);
        fprintf(fjson, "  \"iv_p99_vol_bps\": %.4f,\n", iv_p99 * 10000.0);
        fprintf(fjson, "  \"iv_max\": %.8f,\n", iv_max);
        fprintf(fjson, "  \"liquid_mae_vol_bps\": %.4f,\n", liq_mae * 10000.0);
        fprintf(fjson, "  \"wing_mae_vol_bps\": %.4f,\n", wing_mae * 10000.0);
        fprintf(fjson, "  \"delta_mae\": %.8f,\n", delta_mae);
        fprintf(fjson, "  \"vega_mae\": %.8f,\n", vega_mae);
        fprintf(fjson, "  \"gamma_mae\": %.8f\n", gamma_mae);
        fprintf(fjson, "}\n");
        fclose(fjson);
        printf("[GOLDEN] Metrics written to %s\n", g_metrics_json_path);
    }

    FILE *fcsv = fopen(g_results_csv_path, "w");
    if (fcsv) {
        fprintf(fcsv, "tick,S,K,C,r,T,ref_iv,fpga_iv,iv_err_bps,ref_delta,fpga_delta,ref_vega,fpga_vega,ref_gamma,fpga_gamma,latency_cyc\n");
        for (int i = 0; i < g_retired_count; i++) {
            fprintf(fcsv, "%d,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.4f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%u\n",
                    i, g_ticks[i].S, g_ticks[i].K, g_ticks[i].C, g_ticks[i].r, g_ticks[i].T,
                    g_ticks[i].ref_iv, g_fpga_iv[i], g_all_abs_err_iv[i] * 10000.0,
                    g_ticks[i].ref_delta, g_fpga_delta[i],
                    g_ticks[i].ref_vega, g_fpga_vega[i],
                    g_ticks[i].ref_gamma, g_fpga_gamma[i],
                    g_latencies[i]);
        }
        fclose(fcsv);
        printf("[GOLDEN] Detailed results written to %s\n", g_results_csv_path);
    }
    fflush(stdout);
}
