`timescale 1ns / 1ps
import uvm_pkg::*;
`include "uvm_macros.svh"
import iv_agent_pkg::*;
import iv_env_pkg::*;

module tb_top;
    // ---- Clock & Reset ----
    logic clk, rst_n;
    initial begin clk = 0; forever #2 clk = ~clk; end  // 250 MHz
    initial begin rst_n = 0; #20 rst_n = 1; end         // 20 ns reset

    // ---- Portless Virtual Interface ----
    iv_if1 vif();
    assign vif.clk   = clk;
    assign vif.rst_n = rst_n;

    // ---- DUT Instance ----
    iv_top dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .valid_in       (vif.valid_in),
        .S_in           (vif.S_in),
        .K_in           (vif.K_in),
        .C_in           (vif.C_in),
        .r_in           (vif.r_in),
        .T_in           (vif.T_in),
        .tid_in         (vif.tid_in),
        .fifo_full      (vif.fifo_full),
        .iv_done_valid  (vif.iv_done_valid),
        .iv_done_sigma  (vif.iv_done_sigma),
        .iv_done_tid    (vif.iv_done_tid)
    );

    // ---- UVM Launch ----
    initial begin
        uvm_config_db#(virtual iv_if1)::set(null, "*", "vif", vif);
        run_test("iv_regression_test");
    end
endmodule