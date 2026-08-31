/*
 * =========================================================
 * DPI-C Model: AXI4-Stream Driver/Sink Bridge for xsim
 * =========================================================
 * This file exports four DPI-C functions imported by tb_xdma_dpi.sv:
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
 *   sv_push_result(result_data[63:0])
 *       Called by the SV AXI-Stream monitor when m_axis_tvalid fires.
 *       Unpacks:
 *         [31:0]  = iv_done_sigma (Q8.24 implied volatility)
 *         [37:32] = iv_done_tid   (6-bit transaction ID)
 *       Forwards to golden_push_result() for error accumulation.
 *
 *   sv_print_report()
 *       Called at $finish time to print MAE/RMSE/MRE summary.
 *
 * Compile with Vivado xsc:
 *   xsc dpi_c/iv_dpi_model.c dpi_c/iv_dpi_golden.c -o dpi_c/iv_dpi
 * =========================================================
 */

#include "svdpi.h"
#include "iv_dpi_golden.h"

#include <stdio.h>
#include <string.h>

/*
 * svBitVecVal is defined in svdpi.h as uint32_t.
 * A 256-bit SV vector maps to svBitVecVal[8] (8 × 32-bit words).
 * Index 0 = bits [31:0] (LSW), Index 7 = bits [255:224] (MSW).
 * This matches the little-endian word order used by Vivado xsim.
 */

/* Track which tick index produced each TID using a FIFO queue per TID (0..63)
 * Because each core/context executes transactions for a given TID in FIFO order,
 * a per-TID queue guarantees exact reference matching even when transactions
 * complete out-of-order across different TIDs. */
#define TID_QUEUE_SIZE 256
static int g_tid_queue[64][TID_QUEUE_SIZE];
static int g_tid_head[64];
static int g_tid_tail[64];
static int g_total_sent = 0;

/* -------------------------------------------------------
 * DPI-C Export: sv_init_test_vectors
 * ------------------------------------------------------- */
void sv_init_test_vectors(int num_ticks) {
    memset(g_tid_queue, 0, sizeof(g_tid_queue));
    memset(g_tid_head, 0, sizeof(g_tid_head));
    memset(g_tid_tail, 0, sizeof(g_tid_tail));
    g_total_sent = 0;
    golden_init_test_vectors(num_ticks);
}

/* -------------------------------------------------------
 * DPI-C Export: sv_get_next_tick
 * Outputs:
 *   tdata  : pointer to svBitVecVal[8] (256-bit bit vector)
 * Returns:
 *   1 if a tick is available, 0 if queue is empty
 * ------------------------------------------------------- */
int sv_get_next_tick(svBitVecVal *tdata) {
    IvGoldenTick tick;

    if (!golden_get_next_tick(&tick)) {
        memset(tdata, 0, 8 * sizeof(svBitVecVal));
        return 0;
    }

    /* Pack tick fields into 256-bit vector (8 × 32-bit words) */
    memset(tdata, 0, 8 * sizeof(svBitVecVal));

    tdata[0] = tick.S_fixed;          /* bits [31:0]   */
    tdata[1] = tick.K_fixed;          /* bits [63:32]  */
    tdata[2] = tick.C_fixed;          /* bits [95:64]  */
    tdata[3] = tick.r_fixed;          /* bits [127:96] */
    tdata[4] = tick.T_fixed;          /* bits [159:128]*/
    /* bits [165:160] = tid (6 bits), [191:166] = 0    */
    tdata[5] = (uint32_t)(tick.tid & 0x3F);  /* bits [191:160]*/
    tdata[6] = 0;                     /* bits [223:192]*/
    tdata[7] = 0;                     /* bits [255:224]*/

    /* Push tick global index to the per-TID queue */
    int tid = tick.tid & 0x3F;
    g_tid_queue[tid][g_tid_tail[tid] % TID_QUEUE_SIZE] = g_total_sent;
    g_tid_tail[tid]++;
    g_total_sent++;

    return 1;
}

/* -------------------------------------------------------
 * DPI-C Export: sv_push_result
 * Input: 64-bit result word from m_axis_tdata
 *   [31:0]  = iv_done_sigma (Q8.24)
 *   [37:32] = iv_done_tid   (6-bit)
 *   [63:38] = 0             (reserved)
 * ------------------------------------------------------- */
void sv_push_result(uint64_t result_data) {
    uint32_t sigma_q824 = (uint32_t)(result_data & 0xFFFFFFFFULL);
    uint8_t  tid        = (uint8_t)((result_data >> 32) & 0x3FULL);

    if (g_tid_head[tid] < g_tid_tail[tid]) {
        int tick_idx = g_tid_queue[tid][g_tid_head[tid] % TID_QUEUE_SIZE];
        g_tid_head[tid]++;
        golden_push_result(sigma_q824, tick_idx);
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

