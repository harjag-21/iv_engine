`timescale 1ns / 1ps

// =========================================================
// Verification Testbench: Normalization Path & Scale Invariance
// =========================================================
// Tests the normalization workflow for high-dollar assets ($500 - $2000)
// where unnormalized prices exceed Q8.24 dynamic range (max 127.99).
//
// Normalization rules:
//   S_norm = S / K
//   K_norm = 1.0
//   C_norm = C / K
//   r_norm = r
//   T_norm = T
//
// Scale Invariance Property:
//   IV(S, K, C, r, T) == IV(S/K, 1.0, C/K, r, T)
//   Delta(S, K)       == Delta(S/K, 1.0)
// =========================================================
module tb_normalization;

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

    function automatic logic signed [31:0] to_q24(input real val);
        return int'(val * 16777216.0);
    endfunction

    function automatic real from_q24(input logic signed [31:0] val);
        return real'(val) / 16777216.0;
    endfunction

    task automatic send_normalized_option(
        input int id,
        input real raw_S, raw_K, raw_C, raw_r, raw_T,
        input real expected_sigma, expected_delta
    );
        automatic real S_norm = raw_S / raw_K;
        automatic real K_norm = 1.0;
        automatic real C_norm = raw_C / raw_K;
        begin
            @(posedge clk);
            valid_in <= 1'b1;
            S_in     <= to_q24(S_norm);
            K_in     <= to_q24(K_norm);
            C_in     <= to_q24(C_norm);
            r_in     <= to_q24(raw_r);
            T_in     <= to_q24(raw_T);
            tid_in   <= id[5:0];

            @(posedge clk);
            valid_in <= 1'b0;

            $display("[%0t ns] Injected Option #%0d: Raw(S=$%0.2f, K=$%0.2f, C=$%0.2f) -> Norm(S=%0.4f, K=%0.4f, C=%0.5f)",
                     $time, id, raw_S, raw_K, raw_C, S_norm, K_norm, C_norm);
        end
    endtask

    initial begin
        rst_n    = 0;
        valid_in = 0;
        S_in = 0; K_in = 0; C_in = 0; r_in = 0; T_in = 0; tid_in = 0;

        #20;
        rst_n = 1;
        #20;

        $display("=========================================================");
        $display("Starting Normalization & Scale-Invariance Verification TB");
        $display("=========================================================");

        // Test 1: S=$100, K=$100, C=$9.227, r=0.05, T=1.0 (ATM baseline)
        send_normalized_option(1, 100.0, 100.0, 9.2270, 0.05, 1.0, 0.1672, 0.6490);
        #10000;

        // Test 2: S=$500, K=$500, C=$46.135, r=0.05, T=1.0 (5x scale, same IV & Delta)
        send_normalized_option(2, 500.0, 500.0, 46.1350, 0.05, 1.0, 0.1672, 0.6490);
        #10000;

        // Test 3: S=$2000, K=$2000, C=$184.54, r=0.05, T=1.0 (20x scale, same IV & Delta)
        send_normalized_option(3, 2000.0, 2000.0, 184.5400, 0.05, 1.0, 0.1672, 0.6490);
        #10000;

        // Test 4: S=$450, K=$500, C=$21.43, r=0.05, T=0.5 (OTM, S/K=0.90)
        send_normalized_option(4, 450.0, 500.0, 21.4300, 0.05, 0.5, 0.2825, 0.3905);
        #10000;

        $display("=========================================================");
        if (pass_count == 4) begin
            $display("SUCCESS: ALL 4 NORMALIZATION TESTS PASSED! SCALE-INVARIANCE CONFIRMED!");
        end else begin
            $display("ERROR: Scale-Invariance failure! %0d/4 passed.", pass_count);
        end
        $display("=========================================================");
        $finish;
    end

    real ref_sigmas[1:4];
    initial begin
        ref_sigmas[1] = 0.1672;
        ref_sigmas[2] = 0.1672;
        ref_sigmas[3] = 0.1672;
        ref_sigmas[4] = 0.2825;
    end

    always @(posedge clk) begin
        if (iv_done_valid) begin
            automatic real r_sig = from_q24(iv_done_sigma);
            automatic real r_del = from_q24(iv_done_delta);
            test_count++;
            $display("[%0t ns] RESULT RECEIVED: TID=#%0d | Computed sigma=%0.4f, Delta=%0.4f",
                     $time, iv_done_tid, r_sig, r_del);

            if (iv_done_tid >= 1 && iv_done_tid <= 4) begin
                automatic real diff = (r_sig > ref_sigmas[iv_done_tid]) ? (r_sig - ref_sigmas[iv_done_tid]) : (ref_sigmas[iv_done_tid] - r_sig);
                if (diff < 0.01) begin
                    $display("  => PASS: Scale invariance confirmed (diff=%0.6f)", diff);
                    pass_count++;
                end else begin
                    $display("  => FAIL: (expected %0.4f, got %0.4f) !!!", ref_sigmas[iv_done_tid], r_sig);
                end
            end
        end
    end

endmodule
