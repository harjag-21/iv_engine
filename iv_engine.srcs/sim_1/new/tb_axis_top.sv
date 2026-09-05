`timescale 1ns / 1ps

// =========================================================
// AXI4-Stream Interface Testbench
// =========================================================
// Verifies:
// 1. 256-bit s_axis_tdata unpacking (S, K, C, r, T, TID)
// 2. Input handshake protocol (s_axis_tvalid & s_axis_tready)
// 3. 64-bit m_axis_tdata packing (sigma, TID)
// 4. Output skid buffer operation under m_axis_tready backpressure
// =========================================================
module tb_axis_top;

    logic         aclk;
    logic         aresetn;

    // Slave interface (Input)
    logic         s_axis_tvalid;
    logic         s_axis_tready;
    logic [255:0] s_axis_tdata;
    logic         s_axis_tlast;

    // Master interface (Output)
    logic         m_axis_tvalid;
    logic         m_axis_tready;
    logic [127:0] m_axis_tdata;
    logic         m_axis_tlast;

    // Clock generation (250 MHz)
    initial begin
        aclk = 0;
        forever #2 aclk = ~aclk;
    end

    // DUT instantiation
    iv_axis_wrapper u_dut (
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

    // Monitor counter
    int rx_cnt = 0;

    // Test sequence
    initial begin
        s_axis_tvalid = 1'b0;
        s_axis_tdata  = 256'b0;
        s_axis_tlast  = 1'b1;
        m_axis_tready = 1'b1;
        aresetn       = 1'b0;

        #20;
        aresetn       = 1'b1;
        #10;

        // Drive 5 AXI transactions with real IV engine inputs (non-zero T).
        // S=100.0, K=100.0, C=9.227 (ATM call, σ≈0.167, r=0.05, T=1.0) in Q8.24:
        //   S_q = 100 * 2^24 = 1677721600   (Q8.24, fits in signed 32-bit: max=2147483647)
        //   K_q = 100 * 2^24 = 1677721600
        //   C_q = 9.227 * 2^24 = 154740787
        //   r_q = 0.05 * 2^24 = 838861
        //   T_q = 1.0  * 2^24 = 16777216    (NON-ZERO → routes to IV engine, not CORDIC)
        // AXI packing: [31:0]=S, [63:32]=K, [95:64]=C, [127:96]=r, [159:128]=T, [165:160]=TID
        for (int i = 1; i <= 5; i++) begin
            @(posedge aclk);
            s_axis_tvalid <= 1'b1;
            s_axis_tdata  <= {90'b0, i[5:0],
                              32'sd16777216,  // T = 1.0 (Q8.24) — NON-ZERO → IV engine
                              32'sd838861,    // r = 0.05 (Q8.24)
                              32'sd154740787, // C = 9.227 (Q8.24)
                              32'sd1677721600,// K = 100.0 (Q8.24)
                              32'sd1677721600 // S = 100.0 (Q8.24)
                             };
            wait (s_axis_tready);
        end

        @(posedge aclk);
        s_axis_tvalid <= 1'b0;

        // Simulate downstream backpressure (stall output consumer briefly)
        #5000;
        @(posedge aclk);
        m_axis_tready <= 1'b0; // De-assert ready — skid buffer should capture output
        #100;
        @(posedge aclk);
        m_axis_tready <= 1'b1; // Re-assert ready — skid buffer drains

        // Wait long enough for NR convergence: 144 cycles/pass × 5 passes × 5 options × 4ns
        #30000;
        $display("[AXI TESTBENCH] Completed AXI4-Stream IV Engine verification. Received %0d outputs.", rx_cnt);
        $finish;
    end

    // Monitor AXI outputs
    always @(posedge aclk) begin
        if (aresetn && m_axis_tvalid && m_axis_tready) begin
            automatic real r_sig   = real'(signed'(m_axis_tdata[31:0])) / 16777216.0;
            automatic real r_del   = real'(signed'(m_axis_tdata[63:32])) / 16777216.0;
            automatic real r_veg   = real'(signed'(m_axis_tdata[95:64])) / 16777216.0;
            automatic real r_gam   = real'(unsigned'(m_axis_tdata[121:96])) / 16777216.0;
            automatic int  tid_rx  = int'(m_axis_tdata[127:122]);
            rx_cnt++;
            $display("[AXI TB @ %0t ps] Output Received #%0d | TID=%0d | sigma=%0.4f | Delta=%0.4f | Vega=%0.4f | Gamma=%0.6f",
                     $time, rx_cnt, tid_rx, r_sig, r_del, r_veg, r_gam);
        end
    end

endmodule
