/*
 * =========================================================
 * DPI-C Model: AXI4-Stream Driver/Sink Bridge for xsim
 * =========================================================
 * This file exports DPI-C functions imported by tb_xdma_dpi.sv:
 *
 *   sv_init_test_vectors(num_ticks)
 *       Called once at t=0 to load test vectors from golden model.
 *
 *   sv_get_next_tick(tdata[255:0], tvalid)
 *       Called each cycle by the SV AXI-Stream master driver.
 *       Packs the next IvGoldenTick into a 256-bit vector in
 *       the exact bit mapping expected by iv_axis_wrapper.sv:
 *         [31:0]    = S_fixed    (Q8.24 spot price)
 *         [63:32]   = K_fixed    (Q8.24 strike price)
 *         [95:64]   = C_fixed    (Q8.24 market call price)
 *         [127:96]  = r_fixed    (Q8.24 risk-free rate)
 *         [159:128] = T_fixed    (Q8.24 time-to-maturity)
 *         [165:160] = tid        (6-bit transaction ID)
 *         [255:166] = 0          (reserved/zero-padded)
 *
 *   sv_push_result_128(word_lo[63:0], word_hi[63:0])
 *       Called by the SV AXI-Stream monitor when m_axis_tvalid fires.
 *       Receives full 128-bit m_axis_tdata split into two 64-bit words:
 *         word_lo = m_axis_tdata[63:0]:
 *           [31:0]  = iv_done_sigma (Q8.24)
 *           [63:32] = iv_done_delta (Q8.24)
 *         word_hi = m_axis_tdata[127:64]:
 *           [31:0]  = iv_done_vega  (Q8.24)
 *           [57:32] = iv_done_gamma (26-bit signed, sign-extended to [57:32])
 *           [63:58] = iv_done_tid   (6-bit)
 *       Forwards to golden_push_result_full() for full IV+Greek error accounting.
 *
 *   sv_print_report()
 *       Called at $finish time to print MAE/RMSE/MRE summary.
 * =========================================================
 */

#include <svdpi.h>
#include "iv_dpi_golden.h"
#include <stdint.h>
#include <stdio.h>
#include <string.h>

/* -------------------------------------------------------
 * TID queue: maps 6-bit TID -> tick_index in test vector array
 * Allows out-of-order result matching without a global counter.
 * ------------------------------------------------------- */
#define TID_QUEUE_SIZE 4096
static int g_tid_queue[64][TID_QUEUE_SIZE];
static int g_tid_head[64];
static int g_tid_tail[64];
static int g_total_sent = 0;

/* -------------------------------------------------------
 * DPI-C Export: sv_init_test_vectors
 * Called once from SV at t=0 before stimuli begin.
 * ------------------------------------------------------- */
void sv_init_test_vectors(int num_ticks) {
    memset(g_tid_head, 0, sizeof(g_tid_head));
    memset(g_tid_tail, 0, sizeof(g_tid_tail));
    memset(g_tid_queue, 0, sizeof(g_tid_queue));
    g_total_sent = 0;
    golden_init_test_vectors(num_ticks);
}

/* -------------------------------------------------------
 * DPI-C Export: sv_get_next_tick
 * Packs next test vector into 256-bit AXI4-S tdata word.
 * Returns 1 if a tick was available, 0 if queue exhausted.
 * ------------------------------------------------------- */
int sv_get_next_tick(svBitVecVal *tdata) {
    IvGoldenTick tick;
    if (!golden_get_next_tick(&tick)) return 0;

    /* Clear all 256 bits */
    memset(tdata, 0, 32);

    /* Pack fields into little-endian 32-bit words */
    tdata[0] = tick.S_fixed;            /* [31:0]   */
    tdata[1] = tick.K_fixed;            /* [63:32]  */
    tdata[2] = tick.C_fixed;            /* [95:64]  */
    tdata[3] = tick.r_fixed;            /* [127:96] */
    tdata[4] = tick.T_fixed;            /* [159:128]*/
    tdata[5] = (uint32_t)(tick.tid & 0x3F); /* [165:160] */

    /* Record TID -> tick_index mapping */
    int tid = tick.tid & 0x3F;
    g_tid_queue[tid][g_tid_tail[tid] % TID_QUEUE_SIZE] = g_total_sent;
    g_tid_tail[tid]++;
    g_total_sent++;

    return 1;
}

/* -------------------------------------------------------
 * DPI-C Export: sv_push_result_128
 * Receives full 128-bit m_axis_tdata as two 64-bit halves.
 *
 * RTL egress bus layout (iv_axis_wrapper.sv line 60):
 *   packed_output = {tid[5:0], gamma[25:0], vega[31:0], delta[31:0], sigma[31:0]}
 *
 * Mapping to 128-bit word (LSB = bit 0):
 *   [31:0]   = sigma (Q8.24)
 *   [63:32]  = delta (Q8.24)
 *   [95:64]  = vega  (Q8.24)
 *   [121:96] = gamma (Q8.24, 26-bit signed)
 *   [127:122]= tid   (6-bit)
 *
 * DPI convention: word_lo = m_axis_tdata[63:0], word_hi = m_axis_tdata[127:64]
 * ------------------------------------------------------- */
void sv_push_result_128(uint64_t word_lo, uint64_t word_hi) {
    /* Extract fields */
    uint32_t sigma_q824 = (uint32_t)(word_lo & 0xFFFFFFFFULL);
    int32_t  delta_q824 = (int32_t)((word_lo >> 32) & 0xFFFFFFFFULL);
    int32_t  vega_q824  = (int32_t)(word_hi & 0xFFFFFFFFULL);

    /* gamma is 26-bit signed at [121:96] -> bits [57:32] of word_hi
       Sign-extend from bit 25 to int32_t */
    uint32_t gamma_raw  = (uint32_t)((word_hi >> 32) & 0x3FFFFFFULL); /* 26 bits */
    int32_t  gamma_q824 = (gamma_raw & 0x2000000U)
                          ? (int32_t)(gamma_raw | 0xFC000000U)   /* sign extend */
                          : (int32_t)gamma_raw;

    /* TID is at bits [63:58] of word_hi -> [127:122] of full 128-bit word */
    uint8_t tid = (uint8_t)((word_hi >> 58) & 0x3FULL);

    /* Look up tick index from TID queue */
    if (g_tid_head[tid] < g_tid_tail[tid]) {
        int tick_idx = g_tid_queue[tid][g_tid_head[tid] % TID_QUEUE_SIZE];
        g_tid_head[tid]++;
        golden_push_result_full(sigma_q824, delta_q824, vega_q824, gamma_q824, tick_idx);
    } else {
        fprintf(stderr,
            "[DPI] WARNING: Received result for TID=%u but queue is empty!\n",
            (unsigned)tid);
    }
}

/* -------------------------------------------------------
 * DPI-C Export: sv_print_report
 * ------------------------------------------------------- */
void sv_print_report(void) {
    golden_print_report();
}
