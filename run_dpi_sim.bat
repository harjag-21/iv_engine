@echo off
REM =========================================================
REM  DPI-C Co-Simulation Launcher (Windows)
REM  FPGA Implied Volatility Engine
REM =========================================================
REM  Usage:
REM    run_dpi_sim.bat              -- 4-core iv_multi_engine_top
REM    run_dpi_sim.bat SINGLE_CORE  -- single-core iv_axis_wrapper
REM =========================================================

set PATH=E:\AMDDesignTools\2025.2\Vivado\bin;%PATH%

REM Parse optional SINGLE_CORE argument
set SINGLE_CORE=0
if /I "%1"=="SINGLE_CORE" set SINGLE_CORE=1

REM Navigate to project root
pushd "%~dp0"

echo.
echo ============================================================
echo   FPGA IV Engine: DPI-C Co-Simulation
if "%SINGLE_CORE%"=="1" (
    echo   Mode: SINGLE_CORE  (iv_axis_wrapper)
) else (
    echo   Mode: MULTI_CORE   (iv_multi_engine_top x4)
)
echo ============================================================
echo.

if not exist "sim_results" mkdir "sim_results"

echo === [1/4] Compiling DPI-C C Sources with xsc ===
call xsc dpi_c/iv_dpi_golden.c dpi_c/iv_dpi_model.c -o dpi_c/iv_dpi --gcc_compile_options "-I./dpi_c" --gcc_compile_options "-O2"
if %ERRORLEVEL% NEQ 0 (
    echo [ERROR] xsc compilation failed with code %ERRORLEVEL%
    popd
    exit /b %ERRORLEVEL%
)

echo === [2/4] Compiling RTL SystemVerilog Sources with xvlog ===
set DEFINES=
if "%SINGLE_CORE%"=="1" set DEFINES=-d SINGLE_CORE

call xvlog --sv --relax -L uvm %DEFINES% ^
    "iv_engine.srcs/sources_1/new/iv_divider_q824.sv" ^
    "iv_engine.srcs/sources_1/new/iv_sqrt_q824.sv" ^
    "iv_engine.srcs/sources_1/new/iv_norm_cdf.sv" ^
    "iv_engine.srcs/sources_1/new/iv_bs_datapath.sv" ^
    "iv_engine.srcs/sources_1/new/iv_cordic_pipeline.sv" ^
    "iv_engine.srcs/sources_1/new/iv_kn_compensator.sv" ^
    "iv_engine.srcs/sources_1/new/iv_arbitration_fsm.sv" ^
    "iv_engine.srcs/sources_1/new/iv_top.sv" ^
    "iv_engine.srcs/sources_1/new/iv_axis_wrapper.sv" ^
    "iv_engine.srcs/sources_1/new/iv_multi_engine_top.sv" ^
    "iv_engine.srcs/sim_1/new/tb_xdma_dpi.sv"
if %ERRORLEVEL% NEQ 0 (
    echo [ERROR] xvlog compilation failed with code %ERRORLEVEL%
    popd
    exit /b %ERRORLEVEL%
)

echo === [3/4] Elaborating Design with xelab (DPI Link) ===
call xelab -top tb_xdma_dpi -sv_lib dpi_c/iv_dpi -snapshot tb_xdma_dpi_snapshot -debug typical
if %ERRORLEVEL% NEQ 0 (
    echo [ERROR] xelab elaboration failed with code %ERRORLEVEL%
    popd
    exit /b %ERRORLEVEL%
)

echo === [4/4] Running Simulation with xsim ===
call xsim tb_xdma_dpi_snapshot -runall -wdb sim_results/dpi_sim.wdb -log sim_results/dpi_sim.log

echo.
echo ============================================================
echo   DPI-C Co-Simulation Complete!
echo   Log:      sim_results\dpi_sim.log
echo   Waveform: sim_results\dpi_sim.wdb
echo ============================================================
echo.

popd

