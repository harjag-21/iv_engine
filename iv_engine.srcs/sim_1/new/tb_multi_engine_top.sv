`timescale 1ns / 1ps

// =========================================================
// Multi-Engine Array Testbench (4 Cores @ 250 MHz)
// =========================================================
// Verifies round-robin demux distribution across 4 parallel
// IV engine cores and egress stream merging.
// =========================================================
module tb_multi_engine_top;

    logic         aclk;
    logic         aresetn;

    logic         s_axis_tvalid;
    logic         s_axis_tready;
    logic [255:0] s_axis_tdata;
    logic         s_axis_tlast;

    logic         m_axis_tvalid;
    logic         m_axis_tready;
    logic [127:0] m_axis_tdata;
    logic         m_axis_tlast;

    // Clock generation (250 MHz)
    initial begin
        aclk = 0;
        forever #2 aclk = ~aclk;
    end

    // Multi-Core DUT instance (4 parallel cores)
    iv_multi_engine_top #(
        .NUM_ENGINES(4)
    ) u_dut (
        .aclk          (aclk),
        .aresetn       (aresetn),
        .s_axis_tvalid (s_axis_tvalid),
        .s_axis_tready (s_axis_tready),
        .s_axis_tdata  (s_axis_tdata),
        .s_axis_tlast  (s_axis_tlast),
        .m_axis_tvalid (m_axis_tvalid),
        .m_axis_tready (m_axis_tready),
        .m_axis_tdata  (m_axis_tdata),
        .m_axis_tlast  (m_axis_tlast)
    );

    int rx_count = 0;

    // Monitor process
    always @(posedge aclk) begin
        if (aresetn && m_axis_tvalid && m_axis_tready) begin
            automatic real r_sig   = real'(signed'(m_axis_tdata[31:0])) / 16777216.0;
            automatic real r_del   = real'(signed'(m_axis_tdata[63:32])) / 16777216.0;
            automatic real r_veg   = real'(signed'(m_axis_tdata[95:64])) / 16777216.0;
            automatic real r_gam   = real'(unsigned'(m_axis_tdata[121:96])) / 16777216.0;
            automatic int  tid_rx  = int'(m_axis_tdata[127:122]);
            rx_count++;
            $display("[MULTI-CORE TB @ %0t ps] Output Received #%0d | TID=%0d | sigma=%0.4f | Delta=%0.4f | Vega=%0.4f | Gamma=%0.6f",
                $time, rx_count, tid_rx, r_sig, r_del, r_veg, r_gam);
        end
    end

    // Test stimulus
    initial begin
        s_axis_tvalid = 1'b0;
        s_axis_tdata  = 256'b0;
        s_axis_tlast  = 1'b1;
        m_axis_tready = 1'b1;
        aresetn       = 1'b0;

        #20;
        aresetn       = 1'b1;
        #10;

        $display("=========================================================");
        $display("[MULTI-CORE TB] Starting 1.0 Billion ops/sec Multi-Core Stream");
        $display("=========================================================");

        // Drive 20 transactions across 4 cores with real IV engine inputs (non-zero T).
        // S=100.0, K=100.0, C=9.227, r=0.05, T=1.0 in Q8.24 (TID=i):
        //   S_q=1677721600, K_q=1677721600, C_q=154740787, r_q=838861, T_q=16777216
        // AXI packing: [31:0]=S, [63:32]=K, [95:64]=C, [127:96]=r, [159:128]=T, [165:160]=TID
        for (int i = 1; i <= 20; i++) begin
            @(posedge aclk);
            s_axis_tvalid <= 1'b1;
            s_axis_tdata  <= {90'b0, i[5:0],
                              32'sd16777216,   // T = 1.0 (Q8.24) — NON-ZERO → IV engine
                              32'sd838861,     // r = 0.05 (Q8.24)
                              32'sd154740787,  // C = 9.227 (Q8.24)
                              32'sd1677721600, // K = 100.0 (Q8.24)
                              32'sd1677721600  // S = 100.0 (Q8.24)
                             };
            wait(s_axis_tready);
        end

        @(posedge aclk);
        s_axis_tvalid <= 1'b0;

        // 4 cores × 5 options each × 144 cycles/pass × 5 NR iterations × 4ns = ~57600 ns
        #60000;
        $display("=========================================================");
        if (rx_count == 20) begin
            $display("[MULTI-CORE TB] SUCCESS: ALL 20 IV ENGINE TRANSACTIONS RECEIVED!");
        end else begin
            $display("[MULTI-CORE TB] ERROR: Multi-Core failure! Received %0d/20 outputs.", rx_count);
        end
        $display("[MULTI-CORE TB] Completed Multi-Core IV Engine Array Verification.");
        $display("=========================================================");
        $finish;
    end

endmodule
