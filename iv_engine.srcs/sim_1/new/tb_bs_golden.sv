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
    logic signed [31:0] iv_done_delta;
    logic signed [31:0] iv_done_vega;
    logic signed [31:0] iv_done_gamma;

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
        .iv_done_tid   (iv_done_tid),
        .iv_done_delta (iv_done_delta),
        .iv_done_vega  (iv_done_vega),
        .iv_done_gamma (iv_done_gamma)
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

    // Expected analytical values: Sigma, Delta, Vega, Gamma
    real expected_sigmas[1:4];
    real expected_deltas[1:4];
    real expected_vegas[1:4];
    real expected_gammas[1:4];
    initial begin
        expected_sigmas[1] = 0.167217; expected_deltas[1] = 0.6490; expected_vegas[1] = 37.0783; expected_gammas[1] = 0.022174;
        expected_sigmas[2] = 0.294025; expected_deltas[2] = 0.5887; expected_vegas[2] = 27.5093; expected_gammas[2] = 0.018712;
        expected_sigmas[3] = 0.319475; expected_deltas[3] = 0.5505; expected_vegas[3] = 15.8299; expected_gammas[3] = 0.030969;
        expected_sigmas[4] = 0.150527; expected_deltas[4] = 0.5824; expected_vegas[4] = 19.5197; expected_gammas[4] = 0.051870;
    end

    // Monitor process
    always @(posedge clk) begin
        if (iv_done_valid) begin
            automatic real calc_sig   = from_q24(iv_done_sigma);
            automatic real calc_delta = from_q24(iv_done_delta);
            automatic real calc_vega  = from_q24(iv_done_vega);
            automatic real calc_gamma = from_q24(iv_done_gamma);

            test_count++;
            $display("[%0t ns] RESULT RECEIVED: TID=#%0d | sigma=%0.4f | Delta=%0.4f | Vega=%0.4f | Gamma=%0.6f",
                     $time, iv_done_tid, calc_sig, calc_delta, calc_vega, calc_gamma);

            if (iv_done_tid >= 1 && iv_done_tid <= 4) begin
                automatic real diff_sig   = (calc_sig > expected_sigmas[iv_done_tid]) ? (calc_sig - expected_sigmas[iv_done_tid]) : (expected_sigmas[iv_done_tid] - calc_sig);
                automatic real diff_delta = (calc_delta > expected_deltas[iv_done_tid]) ? (calc_delta - expected_deltas[iv_done_tid]) : (expected_deltas[iv_done_tid] - calc_delta);
                automatic real diff_vega  = (calc_vega > expected_vegas[iv_done_tid]) ? (calc_vega - expected_vegas[iv_done_tid]) : (expected_vegas[iv_done_tid] - calc_vega);
                automatic real diff_gamma = (calc_gamma > expected_gammas[iv_done_tid]) ? (calc_gamma - expected_gammas[iv_done_tid]) : (expected_gammas[iv_done_tid] - calc_gamma);

                if (diff_sig < 0.005 && diff_delta < 0.05 && diff_vega < 1.0 && diff_gamma < 0.005) begin
                    $display("  => PASS: Sigma diff=%0.6f, Delta diff=%0.4f, Vega diff=%0.4f, Gamma diff=%0.6f",
                             diff_sig, diff_delta, diff_vega, diff_gamma);
                    pass_count++;
                end else begin
                    $display("  => FAIL: Sigma diff=%0.6f, Delta diff=%0.4f, Vega diff=%0.4f, Gamma diff=%0.6f !!!",
                             diff_sig, diff_delta, diff_vega, diff_gamma);
                end
            end
        end
    end

endmodule
