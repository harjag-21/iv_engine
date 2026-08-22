`timescale 1ns / 1ps

// =========================================================
// Pipelined Q8.24 Fixed-Point Square Root Engine
// =========================================================
// Computes: root_out = sqrt(rad_in) in Q8.24 format.
// Latency: 29 clock cycles (fully pipelined, 28 stages, 0 DSPs).
// =========================================================
module iv_sqrt_q824 (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               valid_in,
    input  wire signed [31:0] rad_in,       // Input radicand in Q8.24 format

    output logic              valid_out,
    output logic signed [31:0] root_out      // Output square root in Q8.24 format
);

    // 28-stage pipelined shift-and-subtract square root
    logic [55:0] val_pipe [0:28];
    logic [31:0] res_pipe [0:28];
    logic        v_pipe   [0:28];

    // Stage 0 initialization: scale input up by 2^24
    always_comb begin
        if (rad_in <= 32'sd0) begin
            val_pipe[0] = 56'd0;
        end else begin
            val_pipe[0] = 56'(unsigned'(rad_in)) << 24;
        end
        res_pipe[0] = 32'd0;
        v_pipe[0]   = valid_in;
    end

    genvar k;
    generate
        for (k = 0; k < 28; k = k + 1) begin : sqrt_stage
            localparam int M = 27 - k;

            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    val_pipe[k+1] <= 56'd0;
                    res_pipe[k+1] <= 32'd0;
                    v_pipe[k+1]   <= 1'b0;
                end else begin
                    v_pipe[k+1] <= v_pipe[k];

                    if (val_pipe[k] >= ((56'(res_pipe[k]) << (M + 1)) + (56'd1 << (2 * M)))) begin
                        val_pipe[k+1] <= val_pipe[k] - ((56'(res_pipe[k]) << (M + 1)) + (56'd1 << (2 * M)));
                        res_pipe[k+1] <= res_pipe[k] | (32'd1 << M);
                    end else begin
                        val_pipe[k+1] <= val_pipe[k];
                        res_pipe[k+1] <= res_pipe[k];
                    end
                end
            end
        end
    endgenerate

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_out <= 1'b0;
            root_out  <= 32'sd0;
        end else begin
            valid_out <= v_pipe[28];
            root_out  <= signed'(res_pipe[28]); // Scale is already Q8.24
        end
    end

endmodule
