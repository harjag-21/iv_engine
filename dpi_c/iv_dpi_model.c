/*
 * =========================================================
 * DPI-C Model: AXI4-Stream Driver/Sink Bridge for xsim
 * Target Venue: ACM/SIGDA FPGA 2027
 * =========================================================
 */

#include <svdpi.h>
#include "iv_dpi_golden.h"
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

void sv_init_test_vectors(int num_ticks, int dataset_mode) {
    golden_init_test_vectors(num_ticks, dataset_mode);
}

int sv_get_total_ticks(void) {
    return golden_get_total_ticks();
}

int sv_get_bp_pct(void) {
    return golden_get_bp_pct();
}

int sv_get_next_tick(int core_id, svBitVecVal *tdata, long long current_cycle) {
    IvGoldenTick tick;
    if (!golden_get_next_tick(core_id, &tick, (uint64_t)current_cycle)) {
        return 0;
    }

    memset(tdata, 0, 32);
    tdata[0] = tick.S_fixed;
    tdata[1] = tick.K_fixed;
    tdata[2] = tick.C_fixed;
    tdata[3] = tick.r_fixed;
    tdata[4] = tick.T_fixed;
    tdata[5] = (uint32_t)(tick.tid & 0x3F);
    return 1;
}

void sv_record_accepted(int core_id, long long current_cycle) {
    golden_record_accepted(core_id, (uint64_t)current_cycle);
}

void sv_push_result_128(uint64_t word_lo, uint64_t word_hi, long long current_cycle) {
    uint32_t sigma_q824 = (uint32_t)(word_lo & 0xFFFFFFFFULL);
    int32_t  delta_q824 = (int32_t)((word_lo >> 32) & 0xFFFFFFFFULL);
    int32_t  vega_q824  = (int32_t)(word_hi & 0xFFFFFFFFULL);

    uint32_t gamma_raw  = (uint32_t)((word_hi >> 32) & 0x3FFFFFFULL);
    int32_t  gamma_q824 = (gamma_raw & 0x2000000U)
                          ? (int32_t)(gamma_raw | 0xFC000000U)
                          : (int32_t)gamma_raw;

    uint8_t tid = (uint8_t)((word_hi >> 58) & 0x3FULL);

    golden_push_result_full(sigma_q824, delta_q824, vega_q824, gamma_q824, (int)tid, (uint64_t)current_cycle);
}

void sv_print_report(long long total_cycles) {
    golden_print_report((uint64_t)total_cycles);
}
