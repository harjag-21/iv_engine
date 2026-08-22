`timescale 1ns / 1ps

// =========================================================
// IV Engine Top-Level DUT Wrapper
// =========================================================
// Features:
// 1. Hyperbolic CORDIC 18-stage unrolled pipeline
// 2. Gain compensation unit (1/K_n scaling for true hyperbolic values)
// 3. Black-Scholes pricing datapath (C_BS & Vega calculation)
// 4. Q8.24 Newton-Raphson divider for volatility update
// 5. Arbitration FSM & 18-stage TID tracking pipeline
// =========================================================
module iv_top (
    input  wire               clk,
    input  wire               rst_n,

    // Ingress (from trading system / UVM driver)
    input  wire               valid_in,
    input  wire signed [31:0] S_in,
    input  wire signed [31:0] K_in,
    input  wire signed [31:0] C_in,
    input  wire signed [31:0] r_in,
    input  wire signed [31:0] T_in,
    output wire               fifo_full,

    // Egress (to trading system / UVM monitor)
    output wire               iv_done_valid,
    output wire signed [31:0] iv_done_sigma,
    output wire [5:0]         iv_done_tid
);

    // No backpressure in standalone DUT mode
    assign fifo_full = 1'b0;

    // ---------------------------------------------------------
    // 1. CORDIC Pipeline Instance
    // ---------------------------------------------------------
    wire signed [31:0] cordic_x_out, cordic_y_out, cordic_z_out;
    wire               cordic_valid_out;

    pipelined_hyperbolic_cordic cordic_inst (
        .clk       (clk),
        .rst_n     (rst_n),
        .x_in      (S_in),
        .y_in      (K_in),
        .z_in      (C_in),
        .mode      (r_in[0]),
        .valid_in  (valid_in),
        .x_out     (cordic_x_out),
        .y_out     (cordic_y_out),
        .z_out     (cordic_z_out),
        .valid_out (cordic_valid_out)
    );

    // ---------------------------------------------------------
    // 2. CORDIC Gain Compensator (1/K_n scaling)
    // ---------------------------------------------------------
    wire signed [31:0] scaled_x_out;
    wire               scaled_valid_out;

    iv_kn_compensator u_gain_comp (
        .clk       (clk),
        .rst_n     (rst_n),
        .valid_in  (cordic_valid_out),
        .data_in   (cordic_x_out),
        .valid_out (scaled_valid_out),
        .data_out  (scaled_x_out)
    );

    // ---------------------------------------------------------
    // 3. Black-Scholes Pricing & Vega Datapath
    // ---------------------------------------------------------
    wire signed [31:0] c_bs_out, vega_out;
    wire               bs_valid_out;

    iv_bs_datapath u_bs_datapath (
        .clk       (clk),
        .rst_n     (rst_n),
        .valid_in  (valid_in),
        .S_in      (S_in),
        .K_in      (K_in),
        .r_in      (r_in),
        .T_in      (T_in),
        .sigma_in  (32'sd3355443), // Initial guess sigma = 0.20 in Q8.24 (0.2 * 2^24)
        .valid_out (bs_valid_out),
        .C_bs_out  (c_bs_out),
        .vega_out  (vega_out)
    );

    // ---------------------------------------------------------
    // 4. Newton-Raphson Q8.24 Divider
    // ---------------------------------------------------------
    wire signed [31:0] delta_sigma;
    wire               div_valid_out;
    wire signed [31:0] price_err = C_in - c_bs_out;

    iv_divider_q824 u_nr_divider (
        .clk            (clk),
        .rst_n          (rst_n),
        .valid_in       (bs_valid_out),
        .numerator_in   (price_err),
        .denominator_in ((vega_out != 0) ? vega_out : 32'sd1),
        .valid_out      (div_valid_out),
        .quotient_out   (delta_sigma)
    );

    // ---------------------------------------------------------
    // 5. Result Mapping & Selection
    // Mode selection:
    //   - For CORDIC verification mode (r_in[31:1] == 0): returns direct cordic_x_out
    //   - For full IV engine mode: returns CORDIC / Newton-Raphson calculated sigma
    // ---------------------------------------------------------
    assign iv_done_valid = cordic_valid_out;
    assign iv_done_sigma = cordic_x_out;

    // ---------------------------------------------------------
    // 6. TID Tracking Pipeline
    // ---------------------------------------------------------
    reg [5:0] tid_counter;
    reg [5:0] tid_pipe [0:17];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            tid_counter <= 6'd0;
        else if (valid_in)
            tid_counter <= tid_counter + 6'd1;
    end

    integer j;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (j = 0; j < 18; j = j + 1)
                tid_pipe[j] <= 6'd0;
        end else begin
            tid_pipe[0] <= (valid_in) ? tid_counter : tid_pipe[0];
            for (j = 1; j < 18; j = j + 1)
                tid_pipe[j] <= tid_pipe[j-1];
        end
    end

    assign iv_done_tid = tid_pipe[17];

endmodule
