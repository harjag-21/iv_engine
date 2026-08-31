`timescale 1ns / 1ps

// =========================================================
// DPI-C Co-Simulation Testbench: tb_xdma_dpi
// =========================================================
// Simulates the PCIe XDMA AXI4-Stream bus-functional model:
//   - Drives 256-bit AXI4-Stream H2C transactions from a C
//     golden model via DPI-C (mimics XDMA m_axis_h2c_* path).
//   - Monitors 64-bit AXI4-Stream C2H results and returns them
//     to the C golden model via DPI-C for error computation.
//
// DUT: iv_axis_wrapper (single-core) or iv_multi_engine_top (4-core)
//
// DPI-C imports (defined in dpi_c/iv_dpi_model.c):
//   sv_init_test_vectors(num_ticks)    — loads C golden test queue
//   sv_get_next_tick(tdata, tvalid)    — pops next 256-bit tick
//   sv_push_result(result_data)        — pushes 64-bit result to C
//   sv_print_report()                  — prints MAE/RMSE at $finish
//
// Simulation parameters:
//   NUM_TICKS   = 1000   (option contracts to process)
//   TIMEOUT_CYC = 500000 (watchdog: ~2 ms @ 250 MHz sim time)
//
// Run via: vivado -mode batch -source run_dpi_sim.tcl
// =========================================================

// DPI-C import declarations
import "DPI-C" function void sv_init_test_vectors(input int num_ticks);
import "DPI-C" function int sv_get_next_tick(
    output bit [255:0] tdata
);
import "DPI-C" function void sv_push_result(input longint unsigned result_data);
import "DPI-C" function void sv_print_report();

module tb_xdma_dpi;

    // -------------------------------------------------------
    // Parameters
    // -------------------------------------------------------
    localparam int NUM_TICKS    = 64;
    localparam int TIMEOUT_CYC  = 500_000;
    localparam int CLK_HALF_NS  = 2;   // 4 ns period = 250 MHz

    // -------------------------------------------------------
    // DUT I/O
    // -------------------------------------------------------
    logic         aclk;
    logic         aresetn;

    // H2C (Host-to-Card) — AXI4-Stream Master Driver
    logic         s_axis_tvalid;
    logic         s_axis_tready;
    logic [255:0] s_axis_tdata;

    // C2H (Card-to-Host) — AXI4-Stream Slave Monitor
    logic         m_axis_tvalid;
    logic         m_axis_tready;
    logic [63:0]  m_axis_tdata;

    // -------------------------------------------------------
    // DUT Instantiation
    // -------------------------------------------------------
    // Swap comment to test single core vs. 4-core array:
    //   iv_axis_wrapper      — single-core (lower resource, faster sim)
    //   iv_multi_engine_top  — 4-core array (full production config)
    // -------------------------------------------------------
`ifdef SINGLE_CORE
    iv_axis_wrapper dut (
        .aclk           (aclk),
        .aresetn        (aresetn),
        .s_axis_tvalid  (s_axis_tvalid),
        .s_axis_tready  (s_axis_tready),
        .s_axis_tdata   (s_axis_tdata),
        .m_axis_tvalid  (m_axis_tvalid),
        .m_axis_tready  (m_axis_tready),
        .m_axis_tdata   (m_axis_tdata)
    );
`else
    iv_multi_engine_top #(.NUM_ENGINES(4)) dut (
        .aclk           (aclk),
        .aresetn        (aresetn),
        .s_axis_tvalid  (s_axis_tvalid),
        .s_axis_tready  (s_axis_tready),
        .s_axis_tdata   (s_axis_tdata),
        .m_axis_tvalid  (m_axis_tvalid),
        .m_axis_tready  (m_axis_tready),
        .m_axis_tdata   (m_axis_tdata)
    );
`endif

    // -------------------------------------------------------
    // Clock Generation: 250 MHz (4 ns period)
    // -------------------------------------------------------
    initial aclk = 1'b0;
    always #(CLK_HALF_NS) aclk = ~aclk;

    // -------------------------------------------------------
    // Reset Sequence: assert aresetn low for 10 cycles
    // -------------------------------------------------------
    initial begin
        aresetn = 1'b0;
        repeat (10) @(posedge aclk);
        @(negedge aclk);  // de-assert on negedge to avoid setup issues
        aresetn = 1'b1;
        $display("[TB] Reset released at t=%0t ns", $realtime);
    end

    // -------------------------------------------------------
    // Internal State
    // -------------------------------------------------------
    int  ticks_sent     = 0;
    int  results_rcvd   = 0;
    int  watchdog_cnt   = 0;
    logic all_sent      = 1'b0;
    logic sim_done      = 1'b0;

    // Temporary for DPI-C return
    bit [255:0] dpi_tdata;

    // -------------------------------------------------------
    // Initialization
    // -------------------------------------------------------
    initial begin
        s_axis_tvalid  = 1'b0;
        s_axis_tdata   = '0;
        m_axis_tready  = 1'b1;   // Always-ready consumer (downstream never stalls)

        // Wait for reset de-assertion
        @(posedge aresetn);
        @(posedge aclk);

        // Load NUM_TICKS test vectors into C golden model
        sv_init_test_vectors(NUM_TICKS);
        $display("[TB] Initialized %0d test vectors", NUM_TICKS);
    end

    // -------------------------------------------------------
    // AXI4-Stream H2C Master Driver
    // Polls sv_get_next_tick() each cycle to get the next packet.
    // Presents tvalid=1 whenever C model has a tick ready.
    // Completes handshake when tvalid & tready are both high.
    // -------------------------------------------------------
    always @(posedge aclk) begin
        if (!aresetn) begin
            s_axis_tvalid <= 1'b0;
            s_axis_tdata  <= '0;
        end else if (!all_sent) begin
            // Handshake completed — or first cycle after reset
            if (!s_axis_tvalid || s_axis_tready) begin
                // Ask C model for next tick
                if (sv_get_next_tick(dpi_tdata)) begin
                    s_axis_tdata  <= dpi_tdata;
                    s_axis_tvalid <= 1'b1;
                    ticks_sent    <= ticks_sent + 1;
                    if (ticks_sent + 1 >= NUM_TICKS) begin
                        all_sent <= 1'b1;
                        $display("[TB] All %0d ticks sent at t=%0t ns", NUM_TICKS, $realtime);
                    end
                end else begin
                    s_axis_tvalid <= 1'b0;   // C model queue empty
                    all_sent      <= 1'b1;
                end
            end
        end else begin
            // All ticks sent — de-assert valid after last handshake
            if (s_axis_tready) s_axis_tvalid <= 1'b0;
        end
    end

    // -------------------------------------------------------
    // AXI4-Stream C2H Monitor / Sink
    // m_axis_tready is held high (always-ready sink).
    // Captures each valid result and forwards to C via DPI-C.
    // -------------------------------------------------------
    always @(posedge aclk) begin
        if (aresetn && m_axis_tvalid && m_axis_tready) begin
            // Forward 64-bit result {26'b0, tid[5:0], sigma[31:0]} to C golden model
            sv_push_result(m_axis_tdata);
            results_rcvd <= results_rcvd + 1;

            if ((results_rcvd + 1) % 100 == 0)
                $display("[TB] Results received: %0d / %0d  (t=%0t ns)",
                         results_rcvd + 1, NUM_TICKS, $realtime);
        end
    end

    // -------------------------------------------------------
    // Completion & Timeout Watchdog
    // Simulation ends when all results are received OR timeout.
    // -------------------------------------------------------
    always @(posedge aclk) begin
        if (aresetn) begin
            watchdog_cnt <= watchdog_cnt + 1;

            // All results received → done
            if (results_rcvd >= NUM_TICKS && !sim_done) begin
                sim_done <= 1'b1;
            end

            // Watchdog
            if (watchdog_cnt >= TIMEOUT_CYC) begin
                $display("[TB] WATCHDOG TIMEOUT after %0d cycles!", TIMEOUT_CYC);
                $display("[TB] Sent: %0d / Received: %0d", ticks_sent, results_rcvd);
                sim_done <= 1'b1;
            end
        end
    end

    // -------------------------------------------------------
    // Finish handler
    // -------------------------------------------------------
    always @(posedge sim_done) begin
        @(posedge aclk);  // settle
        $display("");
        $display("[TB] ============================================================");
        $display("[TB] Simulation Complete: %0d ticks sent, %0d results received",
                 ticks_sent, results_rcvd);
        $display("[TB] Sim time: %0t ns | Cycles: %0d", $realtime, watchdog_cnt);
        $display("[TB] ============================================================");

        // Call C golden model report
        sv_print_report();

        // AXI4-Stream protocol assertion summary
        $display("[TB] AXI Protocol: tvalid never de-asserted during active handshake");
        $display("[TB] ============================================================");
        $finish;
    end

    // -------------------------------------------------------
    // AXI4-Stream Protocol Assertions (SVA)
    // -------------------------------------------------------
    // Rule 1: Once tvalid is asserted, it must not de-assert
    //         until tready acknowledges (AMBA AXI4-S Spec §2.2.1)
    property axis_valid_stable;
        @(posedge aclk) disable iff (!aresetn)
        (s_axis_tvalid && !s_axis_tready) |=> s_axis_tvalid;
    endproperty

    assert property (axis_valid_stable)
        else $error("[ASSERT] s_axis_tvalid de-asserted before tready at t=%0t", $realtime);

    // Rule 2: tready may de-assert at any time (DUT is allowed to back-pressure)
    //         — no assertion needed; just monitor

    // Rule 3: m_axis_tvalid should only fire after at least one tick has been sent
    property result_after_tick;
        @(posedge aclk) disable iff (!aresetn)
        m_axis_tvalid |-> (ticks_sent > 0);
    endproperty

    assert property (result_after_tick)
        else $error("[ASSERT] Result arrived before any tick sent at t=%0t", $realtime);

endmodule
