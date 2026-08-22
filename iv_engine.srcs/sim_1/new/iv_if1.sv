`timescale 1ns / 1ps

interface iv_if1;
    logic               clk;
    logic               rst_n;

    // Ingress handshake
    logic               valid_in;
    logic signed [31:0] S_in;
    logic signed [31:0] K_in;
    logic signed [31:0] C_in;
    logic signed [31:0] r_in;
    logic signed [31:0] T_in;
    logic               fifo_full;

    // Egress completion
    logic               iv_done_valid;
    logic signed [31:0] iv_done_sigma;
    logic [5:0]         iv_done_tid;
endinterface