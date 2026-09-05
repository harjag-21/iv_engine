@echo off
set PATH=E:\AMDDesignTools\2025.2\Vivado\bin;%PATH%
echo "=== Compiling Design ==="
call xvlog --sv --relax -L uvm ^
    "iv_engine.srcs/sources_1/new/iv_divider_q824.sv" ^
    "iv_engine.srcs/sources_1/new/iv_sqrt_q824.sv" ^
    "iv_engine.srcs/sources_1/new/iv_norm_cdf.sv" ^
    "iv_engine.srcs/sources_1/new/iv_bs_datapath.sv" ^
    "iv_engine.srcs/sources_1/new/iv_cordic_pipeline.sv" ^
    "iv_engine.srcs/sources_1/new/iv_kn_compensator.sv" ^
    "iv_engine.srcs/sources_1/new/iv_arbitration_fsm.sv" ^
    "iv_engine.srcs/sources_1/new/iv_bs_initial_guess.sv" ^
    "iv_engine.srcs/sources_1/new/iv_top.sv" ^
    "iv_engine.srcs/sources_1/new/iv_axis_wrapper.sv" ^
    "iv_engine.srcs/sources_1/new/iv_multi_engine_top.sv" ^
    "iv_engine.srcs/sim_1/new/tb_axis_top.sv"

echo "=== Elaborating Design ==="
call xelab -top tb_axis_top -snapshot tb_axis_top_snapshot -debug typical

echo "=== Running Simulation ==="
call xsim tb_axis_top_snapshot -runall
