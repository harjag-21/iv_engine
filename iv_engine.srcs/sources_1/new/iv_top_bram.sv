`timescale 1ns / 1ps

// =========================================================
// IV Engine Top-Level — Block RAM Context Storage Baseline
// =========================================================
// Controlled architectural baseline for Experiment 1:
// Identical datapath and numerical convergence to iv_top.sv,
// but maps context memory arrays (ctx_S, ctx_K, ctx_C, ctx_r,
// ctx_T, ctx_bs_guess, ctx_sqrt_T) to dedicated Block RAM
// (RAMB18E1/RAMB36E1) via (* ram_style = "block" *) with
// synchronous 1-cycle registered read staging.
// =========================================================
module iv_top_bram #(
    parameter bit USE_BS_INITIAL_GUESS = 1'b1
)(
    input  wire               clk,
    input  wire               rst_n,

    // Ingress (from trading system / UVM driver / AXI wrapper)
    input  wire               valid_in,
    input  wire signed [31:0] S_in,
    input  wire signed [31:0] K_in,
    input  wire signed [31:0] C_in,
    input  wire signed [31:0] r_in,
    input  wire signed [31:0] T_in,
    input  wire [5:0]         tid_in,
    output wire               fifo_full,

    // Egress (to trading system / UVM monitor / AXI wrapper)
    output wire               iv_done_valid,
    output wire signed [31:0] iv_done_sigma,
    output wire [5:0]         iv_done_tid,
    output wire signed [31:0] iv_done_delta,
    output wire signed [31:0] iv_done_vega,
    output wire signed [31:0] iv_done_gamma
);

    // Mode Detection: T_in == 0 is CORDIC test mode; T_in != 0 is IV Engine Mode
    wire is_cordic_mode = (T_in == 32'sd0);

    // Forward declaration of FSM done signals
    wire               fsm_done_valid;
    wire [5:0]         fsm_done_tid;
    wire signed [31:0] fsm_done_sigma;
    wire signed [31:0] fsm_done_delta;
    wire signed [31:0] fsm_done_vega;
    wire signed [31:0] fsm_done_gamma;

    // In-flight transaction counter: tracks how many TIDs are currently being computed.
    logic [6:0] in_flight_count;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            in_flight_count <= 7'd0;
        end else begin
            case ({(valid_in && !is_cordic_mode), fsm_done_valid})
                2'b10: in_flight_count <= in_flight_count + 7'd1; // new entry
                2'b01: in_flight_count <= in_flight_count - 7'd1; // convergence done
                default: ; // both or neither: count unchanged
            endcase
        end
    end

    // ---------------------------------------------------------
    // 1. CORDIC Pipeline Instance (18 stages)
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
    // 2. CORDIC Gain Compensator (1/K_n scaling, 2 cycles)
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
    // 3. TID Assignment
    // ---------------------------------------------------------
    wire [5:0] active_tid = tid_in;

    // ---------------------------------------------------------
    // 4. CORDIC TID Pipeline (20 stages: 18 CORDIC + 2 gain comp)
    // ---------------------------------------------------------
    logic [5:0] tid_pipe_cordic [0:20];
    assign tid_pipe_cordic[0] = active_tid;

    genvar k;
    generate
        for (k = 0; k < 20; k = k + 1) begin : cordic_tid_gen
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) tid_pipe_cordic[k+1] <= 6'd0;
                else        tid_pipe_cordic[k+1] <= tid_pipe_cordic[k];
            end
        end
    endgenerate

    // =========================================================
    // IV ENGINE MODE — Block RAM Context Storage Baseline
    // =========================================================

    // ---------------------------------------------------------
    // 5. Context Memory — Store market data per TID in BRAM
    // ---------------------------------------------------------
    wire       ctx_iter_inc_en;
    wire [5:0] ctx_iter_inc_tid;

    (* ram_style = "block" *) logic signed [31:0] ctx_S [0:63];
    (* ram_style = "block" *) logic signed [31:0] ctx_K [0:63];
    (* ram_style = "block" *) logic signed [31:0] ctx_C [0:63];
    (* ram_style = "block" *) logic signed [31:0] ctx_r [0:63];
    (* ram_style = "block" *) logic signed [31:0] ctx_T [0:63];
    logic [3:0]                                   ctx_iter [0:63];

    // Single write port for market context
    always_ff @(posedge clk) begin
        if (valid_in && !is_cordic_mode) begin
            ctx_S[active_tid]    <= S_in;
            ctx_K[active_tid]    <= K_in;
            ctx_C[active_tid]    <= C_in;
            ctx_r[active_tid]    <= r_in;
            ctx_T[active_tid]    <= T_in;
        end
    end

    // Iteration tracking: collision-safe dual-event commit (registers)
    // Preserves both loopback increment and new ingress initialization even if coinciding on the same clock cycle.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < 64; i++) begin
                ctx_iter[i] <= 4'd0;
            end
        end else begin
            if (ctx_iter_inc_en) begin
                ctx_iter[ctx_iter_inc_tid] <= ctx_iter[ctx_iter_inc_tid] + 4'd1;
            end
            if (valid_in && !is_cordic_mode) begin
                ctx_iter[active_tid] <= 4'd0;
            end
        end
    end

    // ---------------------------------------------------------
    // 6. Initial Guess Engine & Ingress Queue
    // ---------------------------------------------------------
    (* ram_style = "block" *) logic signed [31:0] ctx_bs_guess [0:63];
    (* ram_style = "block" *) logic signed [31:0] ctx_sqrt_T   [0:63];

    wire               init_guess_valid;
    wire [5:0]         init_guess_tid;
    wire signed [31:0] init_guess_sigma;
    wire signed [31:0] init_guess_sqrt_T;

    generate
        if (USE_BS_INITIAL_GUESS) begin : gen_init_guess
            iv_bs_initial_guess u_init_guess (
                .clk         (clk),
                .rst_n       (rst_n),
                .valid_in    (valid_in && !is_cordic_mode),
                .S_in        (S_in),
                .K_in        (K_in),
                .C_in        (C_in),
                .T_in        (T_in),
                .tid_in      (active_tid),
                .valid_out   (init_guess_valid),
                .tid_out     (init_guess_tid),
                .sigma_0_out (init_guess_sigma),
                .sqrt_T_out  (init_guess_sqrt_T)
            );
        end else begin : gen_no_init_guess
            assign init_guess_valid  = valid_in && !is_cordic_mode;
            assign init_guess_tid    = active_tid;
            assign init_guess_sigma  = 32'sd3355443; // 0.20 static fallback
            assign init_guess_sqrt_T = 32'sd16777216; // 1.0 default
        end
    endgenerate

    // Store computed initial guess and sqrt(T) in Block RAM
    always_ff @(posedge clk) begin
        if (init_guess_valid) begin
            ctx_bs_guess[init_guess_tid] <= init_guess_sigma;
            ctx_sqrt_T[init_guess_tid]   <= init_guess_sqrt_T;
        end
    end

    // Ingress Queue: holds transactions ready to be ingested into BS datapath
    (* ram_style = "distributed" *) logic [5:0] ingress_q_tids [0:63];
    logic [5:0] q_wr_ptr;
    logic [5:0] q_rd_ptr;
    logic [6:0] q_count;

    wire fsm_fifo_pop;
    wire q_push = init_guess_valid;
    wire q_pop  = fsm_fifo_pop && (q_count != 7'd0);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            q_wr_ptr <= 6'd0;
            q_rd_ptr <= 6'd0;
            q_count  <= 7'd0;
        end else begin
            if (q_push) begin
                ingress_q_tids[q_wr_ptr] <= init_guess_tid;
                q_wr_ptr                 <= q_wr_ptr + 6'd1;
            end
            if (q_pop) begin
                q_rd_ptr <= q_rd_ptr + 6'd1;
            end
            case ({q_push, q_pop})
                2'b10: q_count <= q_count + 7'd1;
                2'b01: q_count <= q_count - 7'd1;
                default: ;
            endcase
        end
    end

    // ---------------------------------------------------------
    // 6B. Arbitration FSM — Controls pipeline input selection
    // ---------------------------------------------------------
    wire               fsm_pipe_valid;
    wire [5:0]         fsm_pipe_tid;
    wire signed [31:0] fsm_pipe_sigma;
    wire               fsm_pipe_is_loopback;

    // Loopback signals from pipeline end
    logic               loopback_valid;
    logic [5:0]         loopback_tid;
    logic signed [31:0] loopback_sigma;
    logic signed [31:0] loopback_error;
    logic signed [31:0] loopback_delta;
    logic signed [31:0] loopback_vega;
    logic signed [31:0] loopback_gamma;

    // Active In-Flight TID Scoreboard
    logic [63:0] tid_busy_mask;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tid_busy_mask <= 64'd0;
        end else begin
            if (fsm_done_valid) begin
                tid_busy_mask[fsm_done_tid] <= 1'b0;
            end
            if (valid_in && !is_cordic_mode) begin
                tid_busy_mask[active_tid] <= 1'b1;
            end
        end
    end

    wire tid_busy = tid_busy_mask[active_tid] &&
                    !(fsm_done_valid && (fsm_done_tid == active_tid));

    assign fifo_full = (in_flight_count >= 7'd60) || (q_count >= 7'd58) || tid_busy;

    iv_arbitration_fsm u_arb_fsm (
        .clk              (clk),
        .rst_n            (rst_n),
        .loopback_valid   (loopback_valid),
        .loopback_tid     (loopback_tid),
        .loopback_error   (loopback_error),
        .loopback_sigma   (loopback_sigma),
        .loopback_delta   (loopback_delta),
        .loopback_vega    (loopback_vega),
        .loopback_gamma   (loopback_gamma),
        .fifo_empty       (q_count == 7'd0),
        .fifo_tid         (ingress_q_tids[q_rd_ptr]),
        .fifo_pop         (fsm_fifo_pop),
        .pipe_valid       (fsm_pipe_valid),
        .pipe_tid         (fsm_pipe_tid),
        .pipe_sigma       (fsm_pipe_sigma),
        .pipe_is_loopback (fsm_pipe_is_loopback),
        .iv_done_valid    (fsm_done_valid),
        .iv_done_tid      (fsm_done_tid),
        .iv_done_sigma    (fsm_done_sigma),
        .iv_done_delta    (fsm_done_delta),
        .iv_done_vega     (fsm_done_vega),
        .iv_done_gamma    (fsm_done_gamma)
    );

    // ---------------------------------------------------------
    // 7. Synchronous Block RAM Read & Pipeline Alignment Stage
    // ---------------------------------------------------------
    // Block RAM requires 1 clock cycle read latency.
    // We register read addresses and capture data on posedge clk.
    // Control signals (valid, tid, sigma, is_loopback) are delayed
    // by 1 cycle to align with BRAM synchronous read data.
    // ---------------------------------------------------------
    logic signed [31:0] ctx_S_rd;
    logic signed [31:0] ctx_K_rd;
    logic signed [31:0] ctx_C_rd;
    logic signed [31:0] ctx_r_rd;
    logic signed [31:0] ctx_T_rd;
    logic signed [31:0] ctx_sqrt_T_rd;
    logic signed [31:0] ctx_bs_guess_rd;

    always_ff @(posedge clk) begin
        ctx_S_rd        <= ctx_S[fsm_pipe_tid];
        ctx_K_rd        <= ctx_K[fsm_pipe_tid];
        ctx_C_rd        <= ctx_C[fsm_pipe_tid];
        ctx_r_rd        <= ctx_r[fsm_pipe_tid];
        ctx_T_rd        <= ctx_T[fsm_pipe_tid];
        ctx_sqrt_T_rd   <= ctx_sqrt_T[fsm_pipe_tid];
        ctx_bs_guess_rd <= ctx_bs_guess[fsm_pipe_tid];
    end

    logic               pipe_valid_d1;
    logic [5:0]         pipe_tid_d1;
    logic signed [31:0] pipe_sigma_d1;
    logic               pipe_is_loopback_d1;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pipe_valid_d1       <= 1'b0;
            pipe_tid_d1         <= 6'd0;
            pipe_sigma_d1       <= 32'sd0;
            pipe_is_loopback_d1 <= 1'b0;
        end else begin
            pipe_valid_d1       <= fsm_pipe_valid;
            pipe_tid_d1         <= fsm_pipe_tid;
            pipe_sigma_d1       <= fsm_pipe_sigma;
            pipe_is_loopback_d1 <= fsm_pipe_is_loopback;
        end
    end

    wire signed [31:0] bs_sigma_in = pipe_is_loopback_d1 ? pipe_sigma_d1 : ctx_bs_guess_rd;

    // ---------------------------------------------------------
    // 8. Black-Scholes Pricing, Vega & Greeks Datapath (126 cycles)
    // ---------------------------------------------------------
    wire signed [31:0] c_bs_out, vega_out_w;
    wire signed [31:0] delta_out_w;
    wire signed [31:0] phi_d1_out_w;
    wire signed [31:0] den_d1_out_w;
    wire signed [31:0] gamma_den_out_w;
    wire signed [31:0] S_out_w;
    wire               bs_valid_out;

    iv_bs_datapath u_bs_datapath (
        .clk           (clk),
        .rst_n         (rst_n),
        .valid_in      (pipe_valid_d1),
        .S_in          (ctx_S_rd),
        .K_in          (ctx_K_rd),
        .r_in          (ctx_r_rd),
        .T_in          (ctx_T_rd),
        .sigma_in      (bs_sigma_in),
        .sqrt_T_in     (ctx_sqrt_T_rd),
        .valid_out     (bs_valid_out),
        .C_bs_out      (c_bs_out),
        .vega_out      (vega_out_w),
        .delta_out     (delta_out_w),
        .phi_d1_out    (phi_d1_out_w),
        .den_d1_out    (den_d1_out_w),
        .gamma_den_out (gamma_den_out_w),
        .S_out         (S_out_w)
    );

    // ---------------------------------------------------------
    // 9. Delay Pipelines for Market Price & Sigma & TID (126 cycles)
    // ---------------------------------------------------------
    localparam int BS_LATENCY = 126;

    logic signed [31:0] C_market_pipe [0:BS_LATENCY];
    logic signed [31:0] sigma_pipe    [0:BS_LATENCY];
    logic [5:0]         tid_bs_pipe   [0:BS_LATENCY];

    assign C_market_pipe[0] = ctx_C_rd;
    assign sigma_pipe[0]    = bs_sigma_in;
    assign tid_bs_pipe[0]   = pipe_tid_d1;

    generate
        for (k = 0; k < BS_LATENCY; k = k + 1) begin : bs_delay_gen
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    C_market_pipe[k+1] <= 32'sd0;
                    sigma_pipe[k+1]    <= 32'sd0;
                    tid_bs_pipe[k+1]   <= 6'd0;
                end else begin
                    C_market_pipe[k+1] <= C_market_pipe[k];
                    sigma_pipe[k+1]    <= sigma_pipe[k];
                    tid_bs_pipe[k+1]   <= tid_bs_pipe[k];
                end
            end
        end
    endgenerate

    // ---------------------------------------------------------
    // 10. Price Error & Newton-Raphson & Gamma Q8.24 Dividers (33 cycles)
    // ---------------------------------------------------------
    wire signed [31:0] price_err = C_market_pipe[BS_LATENCY] - c_bs_out;
    wire signed [31:0] delta_sigma;
    wire               div_valid_out;

    iv_divider_q824 u_nr_divider (
        .clk            (clk),
        .rst_n          (rst_n),
        .valid_in       (bs_valid_out),
        .numerator_in   (price_err),
        .denominator_in ((vega_out_w != 0) ? vega_out_w : 32'sd1),
        .valid_out      (div_valid_out),
        .quotient_out   (delta_sigma)
    );

    wire signed [31:0] gamma_div_quotient;
    wire               gamma_div_valid;

    iv_divider_q824 u_gamma_divider (
        .clk            (clk),
        .rst_n          (rst_n),
        .valid_in       (bs_valid_out),
        .numerator_in   (phi_d1_out_w),
        .denominator_in ((gamma_den_out_w > 32'sd0) ? gamma_den_out_w : 32'sd1),
        .valid_out      (gamma_div_valid),
        .quotient_out   (gamma_div_quotient)
    );

    localparam int DIV_LATENCY = 33;
    logic signed [31:0] sigma_div_pipe  [0:DIV_LATENCY];
    logic [5:0]         tid_div_pipe    [0:DIV_LATENCY];
    logic signed [31:0] price_err_pipe  [0:DIV_LATENCY];
    logic signed [31:0] delta_div_pipe  [0:DIV_LATENCY];
    logic signed [31:0] vega_div_pipe   [0:DIV_LATENCY];

    assign sigma_div_pipe[0]  = sigma_pipe[BS_LATENCY];
    assign tid_div_pipe[0]    = tid_bs_pipe[BS_LATENCY];
    assign price_err_pipe[0]  = price_err;
    assign delta_div_pipe[0]  = delta_out_w;
    assign vega_div_pipe[0]   = vega_out_w;

    generate
        for (k = 0; k < DIV_LATENCY; k = k + 1) begin : div_delay_gen
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    sigma_div_pipe[k+1]  <= 32'sd0;
                    tid_div_pipe[k+1]    <= 6'd0;
                    price_err_pipe[k+1]  <= 32'sd0;
                    delta_div_pipe[k+1]  <= 32'sd0;
                    vega_div_pipe[k+1]   <= 32'sd0;
                end else begin
                    sigma_div_pipe[k+1]  <= sigma_div_pipe[k];
                    tid_div_pipe[k+1]    <= tid_div_pipe[k];
                    price_err_pipe[k+1]  <= price_err_pipe[k];
                    delta_div_pipe[k+1]  <= delta_div_pipe[k];
                    vega_div_pipe[k+1]   <= vega_div_pipe[k];
                end
            end
        end
    endgenerate

    // ---------------------------------------------------------
    // 11. Sigma Update & Greeks Loopback to FSM (1 cycle)
    // ---------------------------------------------------------
    localparam signed [31:0] MIN_SIGMA_Q24 = 32'sd167772;    // 0.01
    localparam signed [31:0] MAX_SIGMA_Q24 = 32'sd83886080;  // 5.0
    localparam signed [31:0] MAX_STEP_Q24  = 32'sd4194304;   // 0.25 step clamp
    localparam int MAX_ITERATIONS = 8;

    logic signed [31:0] sig_calc_var;
    logic signed [31:0] clamped_step;

    wire [3:0] current_iter = ctx_iter[tid_div_pipe[DIV_LATENCY]];
    wire       max_iter_reached = (current_iter >= MAX_ITERATIONS);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            loopback_valid <= 1'b0;
            loopback_tid   <= 6'd0;
            loopback_sigma <= 32'sd0;
            loopback_error <= 32'sd0;
            loopback_delta <= 32'sd0;
            loopback_vega  <= 32'sd0;
            loopback_gamma <= 32'sd0;
        end else begin
            loopback_valid <= div_valid_out;
            loopback_tid   <= tid_div_pipe[DIV_LATENCY];
            loopback_delta <= delta_div_pipe[DIV_LATENCY];
            loopback_vega  <= vega_div_pipe[DIV_LATENCY];
            loopback_gamma <= (gamma_div_quotient > 32'sd0) ? gamma_div_quotient : 32'sd0;

            if (div_valid_out && max_iter_reached) begin
                loopback_error <= 32'sd0; // Force FSM to output
            end else begin
                loopback_error <= price_err_pipe[DIV_LATENCY];
            end

            if (div_valid_out) begin
                clamped_step = delta_sigma;
                if (delta_sigma > MAX_STEP_Q24)  clamped_step = MAX_STEP_Q24;
                if (delta_sigma < -MAX_STEP_Q24) clamped_step = -MAX_STEP_Q24;

                sig_calc_var = sigma_div_pipe[DIV_LATENCY] + clamped_step;

                if (sig_calc_var < MIN_SIGMA_Q24)      sig_calc_var = MIN_SIGMA_Q24;
                else if (sig_calc_var > MAX_SIGMA_Q24)  sig_calc_var = MAX_SIGMA_Q24;

                loopback_sigma <= sig_calc_var;
            end
        end
    end

    assign ctx_iter_inc_en  = div_valid_out;
    assign ctx_iter_inc_tid = tid_div_pipe[DIV_LATENCY];

    // ---------------------------------------------------------
    // 12. Dual-Mode Result Mapping & Selection
    // ---------------------------------------------------------
    assign iv_done_valid = is_cordic_mode ? scaled_valid_out    : fsm_done_valid;
    assign iv_done_sigma = is_cordic_mode ? scaled_x_out        : fsm_done_sigma;
    assign iv_done_tid   = is_cordic_mode ? tid_pipe_cordic[20] : fsm_done_tid;
    assign iv_done_delta = is_cordic_mode ? 32'sd0              : fsm_done_delta;
    assign iv_done_vega  = is_cordic_mode ? 32'sd0              : fsm_done_vega;
    assign iv_done_gamma = is_cordic_mode ? 32'sd0              : fsm_done_gamma;

endmodule
