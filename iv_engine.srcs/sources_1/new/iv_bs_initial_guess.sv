`timescale 1ns / 1ps

// =========================================================
// Brenner-Subrahmanyam Analytical Initial Guess Engine
// =========================================================
// Evaluates closed-form initial volatility guess:
//   sigma_0 approx (C * sqrt(2*pi)) / (((S + K) / 2) * sqrt(T))
//
// Pipeline:
//   Stage 1 (Cycles 0-29):  Square root engine computes sqrt(T) (29 cycles)
//   Stage 2 (Cycle 29-30):  Numerator (C * sqrt(2*pi)) & Denominator (((S+K)/2) * sqrt(T)) [2 DSPs]
//   Stage 3 (Cycles 30-63): Q8.24 non-restoring divider (33 cycles, 0 DSPs)
//   Stage 4 (Cycle 63-64):  Output register with range clamping [0.05, 3.0] & fallback
//
// Total Latency: 64 clock cycles (fully pipelined, 1 transaction/cycle)
// Total Resources: 2 DSP48E1, 0 BRAM
// =========================================================
module iv_bs_initial_guess (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               valid_in,
    input  wire signed [31:0] S_in,
    input  wire signed [31:0] K_in,
    input  wire signed [31:0] C_in,
    input  wire signed [31:0] T_in,
    input  wire [5:0]         tid_in,

    output logic              valid_out,
    output logic [5:0]        tid_out,
    output logic signed [31:0] sigma_0_out,
    output logic signed [31:0] sqrt_T_out
);

    // Constant: sqrt(2*pi) in Q8.24 format = 2.50662827 * 16777216 approx 42053744
    localparam signed [31:0] SQRT_2PI_Q24   = 32'sd42053744;
    localparam signed [31:0] MIN_SIGMA_Q24  = 32'sd838861;   // 0.05 in Q8.24
    localparam signed [31:0] MAX_SIGMA_Q24  = 32'sd50331648; // 3.00 in Q8.24
    localparam signed [31:0] FALLBACK_SIGMA = 32'sd3355443;  // 0.20 default

    // =====================================================
    // 1. Square Root Engine for sqrt(T) (29 cycles)
    // =====================================================
    wire               sqrt_valid_w;
    wire signed [31:0] sqrt_T_w;

    iv_sqrt_q824 u_sqrt_T (
        .clk       (clk),
        .rst_n     (rst_n),
        .valid_in  (valid_in),
        .rad_in    (T_in),
        .valid_out (sqrt_valid_w),
        .root_out  (sqrt_T_w)
    );

    // =====================================================
    // 2. Alignment Delay Lines across sqrt latency (29 cycles)
    // =====================================================
    localparam int SQRT_LATENCY = 29;
    logic signed [31:0] avg_sk_pipe [0:SQRT_LATENCY];
    logic signed [31:0] c_pipe      [0:SQRT_LATENCY];
    logic [5:0]         tid_pipe    [0:SQRT_LATENCY];

    // Compute (S + K) / 2 to avoid any dynamic range overflow
    assign avg_sk_pipe[0] = (S_in >>> 1) + (K_in >>> 1);
    assign c_pipe[0]      = C_in;
    assign tid_pipe[0]    = tid_in;

    genvar k;
    generate
        for (k = 0; k < SQRT_LATENCY; k = k + 1) begin : sqrt_delay_gen
            always_ff @(posedge clk) begin
                avg_sk_pipe[k+1] <= avg_sk_pipe[k];
                c_pipe[k+1]      <= c_pipe[k];
                tid_pipe[k+1]    <= tid_pipe[k];
            end
        end
    endgenerate

    // =====================================================
    // 3. Numerator & Denominator Pre-Multiplies (1 cycle, 2 DSPs)
    // =====================================================
    (* use_dsp = "yes" *) logic signed [31:0] num_reg;
    (* use_dsp = "yes" *) logic signed [31:0] den_reg;
    logic [5:0]         tid_mult_reg;
    logic               v_mult_reg;
    logic signed [31:0] sqrt_T_mult_reg;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            num_reg         <= 32'sd0;
            den_reg         <= 32'sd0;
            tid_mult_reg    <= 6'd0;
            v_mult_reg      <= 1'b0;
            sqrt_T_mult_reg <= 32'sd0;
        end else begin
            v_mult_reg      <= sqrt_valid_w;
            tid_mult_reg    <= tid_pipe[SQRT_LATENCY];
            sqrt_T_mult_reg <= sqrt_T_w;
            // num = C * sqrt(2*pi)
            num_reg         <= signed'((64'(signed'(c_pipe[SQRT_LATENCY]))      * 64'(signed'(SQRT_2PI_Q24))) >>> 24);
            // den = avg_sk * sqrt(T)
            den_reg         <= signed'((64'(signed'(avg_sk_pipe[SQRT_LATENCY])) * 64'(signed'(sqrt_T_w)))     >>> 24);
        end
    end

    // =====================================================
    // 4. Initial Guess Divider (33 cycles, 0 DSPs)
    // =====================================================
    wire signed [31:0] div_quotient;
    wire               div_valid_out;

    iv_divider_q824 u_init_divider (
        .clk            (clk),
        .rst_n          (rst_n),
        .valid_in       (v_mult_reg),
        .numerator_in   (num_reg),
        .denominator_in ((den_reg > 32'sd0) ? den_reg : 32'sd1),
        .valid_out      (div_valid_out),
        .quotient_out   (div_quotient)
    );

    // TID & sqrt(T) delay lines across 33-cycle divider
    localparam int DIV_LATENCY = 33;
    logic [5:0]         tid_div_pipe    [0:DIV_LATENCY];
    logic signed [31:0] sqrt_T_div_pipe [0:DIV_LATENCY];
    assign tid_div_pipe[0]    = tid_mult_reg;
    assign sqrt_T_div_pipe[0] = sqrt_T_mult_reg;

    generate
        for (k = 0; k < DIV_LATENCY; k = k + 1) begin : div_tid_delay_gen
            always_ff @(posedge clk) begin
                tid_div_pipe[k+1]    <= tid_div_pipe[k];
                sqrt_T_div_pipe[k+1] <= sqrt_T_div_pipe[k];
            end
        end
    endgenerate

    // =====================================================
    // 5. Output Clamping & Fallback Stage (1 cycle)
    // =====================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_out   <= 1'b0;
            tid_out     <= 6'd0;
            sigma_0_out <= FALLBACK_SIGMA;
            sqrt_T_out  <= 32'sd0;
        end else begin
            valid_out  <= div_valid_out;
            tid_out    <= tid_div_pipe[DIV_LATENCY];
            sqrt_T_out <= sqrt_T_div_pipe[DIV_LATENCY];

            if (div_valid_out) begin
                if (div_quotient <= 32'sd0) begin
                    sigma_0_out <= FALLBACK_SIGMA;
                end else if (div_quotient < MIN_SIGMA_Q24) begin
                    sigma_0_out <= MIN_SIGMA_Q24;
                end else if (div_quotient > MAX_SIGMA_Q24) begin
                    sigma_0_out <= MAX_SIGMA_Q24;
                end else begin
                    sigma_0_out <= div_quotient;
                end
            end
        end
    end

endmodule
