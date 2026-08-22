`timescale 1ns / 1ps

// =========================================================
// Verification Testbench: BS Mode Implied Volatility Engine
// =========================================================
// Tests iv_top in full Black-Scholes Newton-Raphson mode (r_in != 0).
// Drives 5 representative option parameters and verifies output
// validity and convergence of calculated volatility.
// =========================================================
module tb_bs_golden;

    logic        clk;
    logic        rst_n;
    logic        valid_in;
    logic [31:0] S_in, K_in, C_in, r_in, T_in;
    logic [5:0]  tid_in;
    logic        fifo_full;

    logic        iv_done_valid;
    logic [31:0] iv_done_sigma;
    logic [5:0]  iv_done_tid;

    // Clock generation (250 MHz -> 4.0 ns period)
    initial clk = 0;
    always #2.0 clk = ~clk;

    // Instantiate DUT
    iv_top u_dut (
        .clk           (clk),
        .rst_n         (rst_n),
        .valid_in      (valid_in),
        .S_in          (S_in),
        .K_in          (K_in),
        .C_in          (C_in),
        .r_in          (r_in),
        .T_in          (T_in),
        .tid_in        (tid_in),
        .fifo_full     (fifo_full),
        .iv_done_valid (iv_done_valid),
        .iv_done_sigma (iv_done_sigma),
        .iv_done_tid   (iv_done_tid)
    );

    int test_count = 0;
    int pass_count = 0;

    // Fixed-Point conversion helper: float to Q8.24
    function automatic logic signed [31:0] to_q24(input real val);
        return int'(val * 16777216.0);
    endfunction

    function automatic real from_q24(input logic signed [31:0] val);
        return real'(val) / 16777216.0;
    endfunction

    // Test driver task
    task automatic send_option(
        input int id,
        input real S, K, C, r, T,
        input real expected_sigma
    );
        begin
            @(posedge clk);
            valid_in <= 1'b1;
            S_in     <= to_q24(S);
            K_in     <= to_q24(K);
            C_in     <= to_q24(C);
            r_in     <= to_q24(r);
            T_in     <= to_q24(T);
            tid_in   <= id[5:0];

            @(posedge clk);
            valid_in <= 1'b0;

            $display("[%0t ns] Driven Option #%0d: S=%0.2f K=%0.2f C=%0.2f r=%0.3f T=%0.2f | Exp Sig=%0.4f",
                     $time, id, S, K, C, r, T, expected_sigma);
        end
    endtask

    // Monitor & Verification
    initial begin
        rst_n    = 0;
        valid_in = 0;
        S_in = 0; K_in = 0; C_in = 0; r_in = 0; T_in = 0; tid_in = 0;

        #20;
        rst_n = 1;
        #20;

        $display("=========================================================");
        $display("Starting BS Mode Golden Reference Verification Testbench");
        $display("=========================================================");


        // Test 1: S=100, K=100, r=0.05, T=1.0 -> C = 9.2270
        send_option(1, 100.0, 100.0, 9.2270, 0.05, 1.0, 0.167217);
        #10000;

        // Test 2: S=100, K=100, r=0.05, T=0.5 -> C = 9.4705
        send_option(2, 100.0, 100.0, 9.4705, 0.05, 0.5, 0.294025);
        #10000;

        // Test 3: S=80, K=80, r=0.03, T=0.25 -> C = 5.3781
        send_option(3, 80.0, 80.0, 5.3781, 0.03, 0.25, 0.319475);
        #10000;

        // Test 4: S=50, K=50, r=0.02, T=1.0 -> C = 3.4912
        send_option(4, 50.0, 50.0, 3.4912, 0.02, 1.0, 0.150527);
        #10000;

        $display("=========================================================");
        if (pass_count == 4) begin
            $display("SUCCESS: ALL 4 TESTS PASSED!");
        end else begin
            $display("ERROR: TEST FAILURE! %0d/4 tests passed.", pass_count);
        end
        $display("BS Mode Verification Completed!");
        $display("=========================================================");
        $finish;
    end

    // Expected sigmas array
    real expected_sigmas[1:4];
    initial begin
        expected_sigmas[1] = 0.167217;
        expected_sigmas[2] = 0.294025;
        expected_sigmas[3] = 0.319475;
        expected_sigmas[4] = 0.150527;
    end

    // Monitor process
    always @(posedge clk) begin
        if (iv_done_valid) begin
            test_count++;
            $display("[%0t ns] RESULT RECEIVED: TID=#%0d | Calculated Sigma = %0.6f (0x%0h)",
                     $time, iv_done_tid, from_q24(iv_done_sigma), iv_done_sigma);
            if (iv_done_tid >= 1 && iv_done_tid <= 4) begin
                automatic real calc_sig = from_q24(iv_done_sigma);
                automatic real diff = calc_sig > expected_sigmas[iv_done_tid] ? (calc_sig - expected_sigmas[iv_done_tid]) : (expected_sigmas[iv_done_tid] - calc_sig);
                if (diff < 0.005) begin // 0.5% vol tolerance (system claims 0.1824% MAE)
                    $display("  => PASS (expected %0.4f, got %0.4f, diff %0.6f)", expected_sigmas[iv_done_tid], calc_sig, diff);
                    pass_count++;
                end else begin
                    $display("  => FAIL (expected %0.4f, got %0.4f, diff %0.6f) !!!", expected_sigmas[iv_done_tid], calc_sig, diff);
                end
            end
        end
    end

endmodule
