`timescale 1ns / 1ps

module iv_arbitration_fsm (
    input  wire               clk,
    input  wire               rst_n,
    
    // Lane 1: Loopback from end of pipeline (High Priority)
    input  wire               loopback_valid,
    input  wire [5:0]         loopback_tid,
    input  wire signed [31:0] loopback_sigma,
    input  wire signed [31:0] loopback_error, // |C_market - C_calculated|
    
    // Lane 2: Ingress FIFO (New NASDAQ Data)
    input  wire               fifo_empty,
    input  wire [5:0]         fifo_tid,       // Next available TID
    output logic              fifo_pop,       // Tell FIFO to advance
    
    // Outbound to Pipeline (The CORDIC entrance)
    output logic              pipe_valid,
    output logic [5:0]        pipe_tid,
    output logic signed [31:0] pipe_sigma,
    output logic              pipe_is_loopback,
    
    // Outputs to the Completion Bus (Sent back to trading algorithm)
    output logic              iv_done_valid,
    output logic [5:0]        iv_done_tid,
    output logic signed [31:0] iv_done_sigma
);

    // Convergence Threshold: $0.01 tick size in Q8.24 format
    // 0.01 * 2^24 = 167,772
    localparam signed [31:0] CONVERGENCE_THRESHOLD = 32'd167772;

    wire signed [31:0] abs_error = (loopback_error == 32'sh80000000) ? 32'sh7FFFFFFF :
                                   ((loopback_error < 0) ? -loopback_error : loopback_error);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pipe_valid       <= 1'b0;
            pipe_tid         <= 6'd0;
            pipe_sigma       <= 32'd0;
            pipe_is_loopback <= 1'b0;
            fifo_pop         <= 1'b0;
            iv_done_valid    <= 1'b0;
            iv_done_tid      <= 6'd0;
            iv_done_sigma    <= 32'd0;
        end else begin
            // Default assignments to prevent latch inference
            fifo_pop         <= 1'b0;
            pipe_valid       <= 1'b0;
            pipe_sigma       <= 32'sd0;  // Clear to prevent stale data
            pipe_is_loopback <= 1'b0;
            iv_done_valid    <= 1'b0;

            // -------------------------------------------------------------
            // PRIORITY 1: Check Loopback Lane
            // -------------------------------------------------------------
            if (loopback_valid) begin
                
                if (abs_error <= CONVERGENCE_THRESHOLD) begin
                    // 1A: CONVERGED! 
                    // Route to completion bus.
                    iv_done_valid <= 1'b1;
                    iv_done_tid   <= loopback_tid;
                    iv_done_sigma <= loopback_sigma;
                    
                    // Pipeline slot is free! Pop from FIFO if data exists.
                    if (!fifo_empty) begin
                        fifo_pop   <= 1'b1;
                        pipe_valid <= 1'b1;
                        pipe_tid   <= fifo_tid;
                        pipe_sigma <= 32'sd0; // Initial guess handled by iv_top
                    end
                end else begin
                    // 1B: NOT CONVERGED! 
                    // Route back into pipeline with updated sigma.
                    pipe_valid       <= 1'b1;
                    pipe_tid         <= loopback_tid;
                    pipe_sigma       <= loopback_sigma;
                    pipe_is_loopback <= 1'b1;
                end

            // -------------------------------------------------------------
            // PRIORITY 2: Check Ingress FIFO
            // -------------------------------------------------------------
            end else if (!fifo_empty) begin
                // No loopback traffic. Safe to ingest new market tick.
                fifo_pop   <= 1'b1;
                pipe_valid <= 1'b1;
                pipe_tid   <= fifo_tid;
                pipe_sigma <= 32'sd0; // Initial guess handled by iv_top
            end
        end
    end
endmodule