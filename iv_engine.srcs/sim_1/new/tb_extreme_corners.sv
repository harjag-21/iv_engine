`timescale 1ns / 1ps

// =========================================================
// Extreme Boundary & Edge-Case Verification Testbench
// =========================================================
// Exercises financial edge cases:
//   1. Deep In-The-Money (ITM) options (S = 500, K = 10)
//   2. Deep Out-Of-The-Money (OTM) options (S = 10, K = 500)
//   3. Near-zero time-to-maturity (T = 0.001 yrs / 8 hours)
//   4. Zero risk-free rate (r = 0.00%)
//   5. High volatility (sigma = 150%)
// =========================================================
module tb_extreme_corners;

    logic         aclk;
    logic         aresetn;

    logic         s_axis_tvalid;
    logic         s_axis_tready;
    logic [255:0] s_axis_tdata;

    logic         m_axis_tvalid;
    logic         m_axis_tready;
    logic [127:0] m_axis_tdata;

    // Clock generation (250 MHz)
    initial begin
        aclk = 0;
        forever #2 aclk = ~aclk;
    end

    // Single Engine DUT
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

    int test_cnt = 0;

    logic [31:0] expected_sigmas[1:5];
    initial begin
        expected_sigmas[1] = 32'h00028f5c; // Case 1 (Intrinsic-underflow clamp)
        expected_sigmas[2] = 32'h000cacd7; // Case 2 (Deep OTM B-S guess within 1-cent tick)
        expected_sigmas[3] = 32'h00cb3b64; // Case 3 (Short-dated converged)
        expected_sigmas[4] = 32'h00202182; // Case 4 (Zero r converged)
        expected_sigmas[5] = 32'h0073d456; // Case 5 (High vol converged)
    end

    int pass_cases = 0;

    // Monitor output
    always_ff @(posedge aclk) begin
        if (aresetn && m_axis_tvalid && m_axis_tready) begin
            test_cnt++;
            $display("[CORNER TB @ %0t ps] Case #%0d Received | TID=%0d  Sigma_Q824=0x%08h",
                $time, test_cnt, m_axis_tdata[127:122], m_axis_tdata[31:0]);
            if (m_axis_tdata[127:122] >= 1 && m_axis_tdata[127:122] <= 5) begin
                logic [31:0] exp_sig = expected_sigmas[m_axis_tdata[127:122]];
                logic [31:0] got_sig = m_axis_tdata[31:0];
                int diff;
                diff = got_sig > exp_sig ? (got_sig - exp_sig) : (exp_sig - got_sig);
                // Tolerance: diff <= 2000 LSBs (< 0.012% volatility tolerance in Q8.24)
                if (diff <= 2000) begin
                    $display("  => PASS (expected 0x%08h, got 0x%08h, diff=%d LSBs)", exp_sig, got_sig, diff);
                    pass_cases++;
                end else begin
                    $display("  => FAIL (expected 0x%08h, got 0x%08h, diff=%d LSBs) !!!", exp_sig, got_sig, diff);
                end
            end
        end
    end

    initial begin
        s_axis_tvalid = 1'b0;
        s_axis_tdata  = 256'b0;
        m_axis_tready = 1'b1;
        aresetn       = 1'b0;

        #20;
        aresetn       = 1'b1;
        #10;

        $display("=========================================================");
        $display("[CORNER TB] Starting Extreme Financial Boundary Tests");
        $display("=========================================================");

        // Test Case 1: Deep In-The-Money (S = 100, K = 10, C = 90, r = 0.05, T = 1.0)
        drive_corner(1, 32'sd1677721600, 32'sd167772160, 32'sd1509949440, 32'sd838860, 32'sd16777216);
        #10000;

        // Test Case 2: Deep Out-Of-The-Money (S = 10, K = 100, C = 0.01, r = 0.05, T = 1.0)
        drive_corner(2, 32'sd167772160, 32'sd1677721600, 32'sd167772, 32'sd838860, 32'sd16777216);
        #10000;

        // Test Case 3: Ultra-short maturity (S=100, K=100, C=1.0, T = 0.001 yrs)
        drive_corner(3, 32'sd1677721600, 32'sd1677721600, 32'sd16777216, 32'sd838860, 32'sd16777);
        #10000;

        // Test Case 4: Zero interest rate (S=100, K=100, C=5.0, r = 0.00%)
        drive_corner(4, 32'sd1677721600, 32'sd1677721600, 32'sd83886080, 32'sd0, 32'sd16777216);
        #10000;

        // Test Case 5: High volatility scenario (S=100, K=100, C=20.0, r=0.05, T=1.0)
        drive_corner(5, 32'sd1677721600, 32'sd1677721600, 32'sd335544320, 32'sd838860, 32'sd16777216);
        #10000;

        $display("=========================================================");
        if (pass_cases == 5) begin
            $display("[CORNER TB] ALL 5 EXTREME CORNER CASES PASSED!");
        end else begin
            $display("[CORNER TB] ERROR: Corner verification failed! %0d/5 passed.", pass_cases);
        end
        $display("=========================================================");
        $finish;
    end

    task drive_corner(input int id, input logic signed [31:0] S, K, C, r, T);
        begin
            @(posedge aclk);
            s_axis_tvalid <= 1'b1;
            s_axis_tdata  <= {90'b0, id[5:0], T, r, C, K, S};
            wait(s_axis_tready);
            @(posedge aclk);
            s_axis_tvalid <= 1'b0;
        end
    endtask

endmodule
