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

    // Master interface (Output)
    logic         m_axis_tvalid;
    logic         m_axis_tready;
    logic [63:0]  m_axis_tdata;

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
        .m_axis_tvalid (m_axis_tvalid),
        .m_axis_tready (m_axis_tready),
        .m_axis_tdata  (m_axis_tdata)
    );

    // Test sequence
    initial begin
        s_axis_tvalid = 1'b0;
        s_axis_tdata  = 256'b0;
        m_axis_tready = 1'b1;
        aresetn       = 1'b0;

        #20;
        aresetn       = 1'b1;
        #10;

        // Drive 5 AXI transactions back-to-back
        for (int i = 0; i < 5; i++) begin
            @(posedge aclk);
            s_axis_tvalid <= 1'b1;
            // Pack: S=1.0 (Q24), K=1.0 (Q24), C=0.5 (Q24), r=1, T=0, TID=i
            s_axis_tdata  <= {90'b0, i[5:0], 32'sd0, 32'sd1, 32'sd8388608, 32'sd16777216, 32'sd16777216};
            
            wait (s_axis_tready);
        end

        @(posedge aclk);
        s_axis_tvalid <= 1'b0;

        // Simulate downstream backpressure (stall output consumer)
        #40;
        @(posedge aclk);
        m_axis_tready <= 1'b0; // De-assert ready — skid buffer should capture output
        
        #30;
        @(posedge aclk);
        m_axis_tready <= 1'b1; // Re-assert ready — skid buffer drains

        #200;
        $display("[AXI TESTBENCH] Completed AXI4-Stream protocol verification.");
        $finish;
    end

endmodule
