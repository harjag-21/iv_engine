`timescale 1ns / 1ps

// =========================================================
// DPI-C Co-Simulation Testbench: tb_xdma_dpi (Exp 7 & 1B)
// Target Venue: ACM/SIGDA FPGA 2027
// =========================================================

import "DPI-C" function void sv_init_test_vectors(input int num_ticks, input int dataset_mode);
import "DPI-C" function int  sv_get_total_ticks();
import "DPI-C" function int  sv_get_bp_pct();
import "DPI-C" function int  sv_get_next_tick(
    input int core_id,
    output bit [255:0] tdata,
    input longint current_cycle
);
import "DPI-C" function void sv_record_accepted(
    input int core_id,
    input longint current_cycle
);
import "DPI-C" function void sv_push_result_128(
    input longint unsigned word_lo,
    input longint unsigned word_hi,
    input longint current_cycle
);
import "DPI-C" function void sv_print_report(input longint total_cycles);

module tb_xdma_dpi;

    // -------------------------------------------------------
    // Timing & Clock (100.00 MHz signoff clock)
    // -------------------------------------------------------
    localparam int CLK_HALF_NS = 5;         // 10.0 ns period = 100 MHz
    localparam int TIMEOUT_CYC = 10000000;  // 10M cycles watchdog (100 ms sim time)

    logic         aclk;
    logic         aresetn;

    // Ingress (H2C)
    logic         s_axis_tvalid;
    logic         s_axis_tready;
    logic [255:0] s_axis_tdata;
    logic         s_axis_tlast;

    // Egress (C2H)
    logic         m_axis_tvalid;
    logic         m_axis_tready;
    logic [127:0] m_axis_tdata;
    logic         m_axis_tlast;

    // -------------------------------------------------------
    // DUT Instantiation: Zero-BRAM vs BRAM Baseline
    // -------------------------------------------------------
`ifdef USE_BRAM_BASELINE
    iv_multi_engine_top_bram #(.NUM_ENGINES(4)) dut (
        .aclk           (aclk),
        .aresetn        (aresetn),
        .s_axis_tvalid  (s_axis_tvalid),
        .s_axis_tready  (s_axis_tready),
        .s_axis_tdata   (s_axis_tdata),
        .s_axis_tlast   (s_axis_tlast),
        .m_axis_tvalid  (m_axis_tvalid),
        .m_axis_tready  (m_axis_tready),
        .m_axis_tdata   (m_axis_tdata),
        .m_axis_tlast   (m_axis_tlast)
    );
`else
    iv_multi_engine_top #(.NUM_ENGINES(4)) dut (
        .aclk           (aclk),
        .aresetn        (aresetn),
        .s_axis_tvalid  (s_axis_tvalid),
        .s_axis_tready  (s_axis_tready),
        .s_axis_tdata   (s_axis_tdata),
        .s_axis_tlast   (s_axis_tlast),
        .m_axis_tvalid  (m_axis_tvalid),
        .m_axis_tready  (m_axis_tready),
        .m_axis_tdata   (m_axis_tdata),
        .m_axis_tlast   (m_axis_tlast)
    );
`endif

    // Clock generator: 100 MHz (10 ns period)
    initial aclk = 1'b0;
    always #(CLK_HALF_NS) aclk = ~aclk;

    // Reset sequence
    initial begin
        aresetn = 1'b0;
        repeat (10) @(posedge aclk);
        @(negedge aclk);
        aresetn = 1'b1;
        $display("[TB] Reset released at t=%0t ns (100 MHz clock)", $realtime);
    end

    // Parameters configurable via plusargs
    int num_ticks    = 10000;
    int dataset_mode = 0;
    int bp_pct       = 0;
    int total_ticks  = 0;

    int ticks_sent   = 0;
    int results_rcvd = 0;
    int target_core  = 0;
    longint cycle_cnt = 0;
    bit sim_done     = 1'b0;
    bit [255:0] dpi_tdata;

    // Cycle counter
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) cycle_cnt <= 0;
        else          cycle_cnt <= cycle_cnt + 1;
    end

    // Initialization
    initial begin
        s_axis_tvalid = 1'b0;
        s_axis_tdata  = '0;
        s_axis_tlast  = 1'b0;

        @(posedge aresetn);
        @(posedge aclk);

        sv_init_test_vectors(0, 0);
        total_ticks = sv_get_total_ticks();
        bp_pct      = sv_get_bp_pct();
        $display("[TB] Initialized simulation with %0d ticks, bp_pct=%0d%%",
                 total_ticks, bp_pct);
    end

    // Backpressure generator on m_axis_tready
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            m_axis_tready <= 1'b1;
        end else if (bp_pct == 0) begin
            m_axis_tready <= 1'b1;
        end else begin
            m_axis_tready <= (($urandom_range(1, 100)) > bp_pct) ? 1'b1 : 1'b0;
        end
    end

    // Next target core calculation
    int next_target_core;
    always_comb begin
        if (s_axis_tvalid && s_axis_tready)
            next_target_core = (target_core == 3) ? 0 : target_core + 1;
        else
            next_target_core = target_core;
    end

    // Master Driver (AXI4-Stream H2C)
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            s_axis_tvalid <= 1'b0;
            s_axis_tdata  <= '0;
            s_axis_tlast  <= 1'b0;
            target_core   <= 0;
            ticks_sent    <= 0;
        end else begin
            // On handshake: record accepted, increment ticks_sent, advance target_core
            if (s_axis_tvalid && s_axis_tready) begin
                sv_record_accepted(target_core, cycle_cnt);
                ticks_sent  <= ticks_sent + 1;
                target_core <= next_target_core;
            end

            // Drive new transaction if bus is idle or handshake just completed
            if (!s_axis_tvalid || s_axis_tready) begin
                if (ticks_sent + (s_axis_tvalid ? 1 : 0) < total_ticks &&
                    sv_get_next_tick(next_target_core, dpi_tdata, cycle_cnt)) begin
                    s_axis_tdata  <= dpi_tdata;
                    s_axis_tvalid <= 1'b1;
                    s_axis_tlast  <= 1'b1;
                end else begin
                    s_axis_tvalid <= 1'b0;
                    s_axis_tlast  <= 1'b0;
                end
            end
        end
    end

    // Slave Monitor (AXI4-Stream C2H)
    always @(posedge aclk) begin
        if (aresetn && m_axis_tvalid && m_axis_tready) begin
            sv_push_result_128(
                longint'(m_axis_tdata[63:0]),
                longint'(m_axis_tdata[127:64]),
                cycle_cnt
            );
            results_rcvd <= results_rcvd + 1;

            if ((results_rcvd + 1) % 10000 == 0 || results_rcvd + 1 == total_ticks) begin
                $display("[TB] Progress: %0d / %0d contracts retired at cycle %0d (t=%0t ns)",
                         results_rcvd + 1, total_ticks, cycle_cnt, $realtime);
            end
        end
    end

    // Watchdog and completion logic
    always @(posedge aclk) begin
        if (aresetn) begin
            if (results_rcvd >= total_ticks && !sim_done) begin
                sim_done <= 1'b1;
            end

            if (cycle_cnt >= TIMEOUT_CYC && !sim_done) begin
                $display("[TB] WATCHDOG TIMEOUT after %0d cycles!", TIMEOUT_CYC);
                $display("[TB] Sent: %0d / Received: %0d", ticks_sent, results_rcvd);
                sim_done <= 1'b1;
            end
        end
    end

    // Finish handler
    always @(posedge sim_done) begin
        @(posedge aclk);
        $display("");
        $display("[TB] ============================================================");
        $display("[TB] Simulation Complete: %0d ticks accepted, %0d results received",
                 ticks_sent, results_rcvd);
        $display("[TB] Sim Time: %0t ns | Total Cycles: %0d", $realtime, cycle_cnt);
        $display("[TB] ============================================================");

        sv_print_report(cycle_cnt);
        $display("[TB] ============================================================");
        $finish;
    end

    // Protocol Assertions
    property axis_valid_stable;
        @(posedge aclk) disable iff (!aresetn)
        (s_axis_tvalid && !s_axis_tready) |=> s_axis_tvalid;
    endproperty
    assert property (axis_valid_stable)
        else $error("[ASSERT] s_axis_tvalid dropped before tready at cycle %0d", cycle_cnt);

    property result_after_tick;
        @(posedge aclk) disable iff (!aresetn)
        m_axis_tvalid |-> (ticks_sent > 0);
    endproperty
    assert property (result_after_tick)
        else $error("[ASSERT] Result arrived before any tick sent at cycle %0d", cycle_cnt);

endmodule
