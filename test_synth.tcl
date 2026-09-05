# Quick synthesis test script to verify LUT utilization
set PART       xc7a200tffg1156-3
set TOP        iv_multi_engine_top
set CLK_PERIOD 9.090
set CLK_NAME   aclk

create_project -in_memory -part $PART

read_verilog -sv [list \
    {iv_engine.srcs/sources_1/new/iv_divider_q824.sv}    \
    {iv_engine.srcs/sources_1/new/iv_sqrt_q824.sv}        \
    {iv_engine.srcs/sources_1/new/iv_cordic_pipeline.sv}  \
    {iv_engine.srcs/sources_1/new/iv_kn_compensator.sv}   \
    {iv_engine.srcs/sources_1/new/iv_norm_cdf.sv}         \
    {iv_engine.srcs/sources_1/new/iv_bs_datapath.sv}      \
    {iv_engine.srcs/sources_1/new/iv_arbitration_fsm.sv}  \
    {iv_engine.srcs/sources_1/new/iv_bs_initial_guess.sv} \
    {iv_engine.srcs/sources_1/new/iv_top.sv}              \
    {iv_engine.srcs/sources_1/new/iv_axis_wrapper.sv}     \
    {iv_engine.srcs/sources_1/new/iv_multi_engine_top.sv}
]

set_property top $TOP [current_fileset]

puts "============================================================"
puts "  Running Synthesis with AreaOptimized_high & SRL inference"
puts "============================================================"

synth_design \
    -top            $TOP  \
    -part           $PART \
    -mode           out_of_context \
    -flatten_hierarchy rebuilt \
    -directive      AreaOptimized_high

create_clock -period $CLK_PERIOD -name $CLK_NAME [get_ports $CLK_NAME]
set_false_path -from [get_ports aresetn]
set_property HD.CLK_SRC BUFGCTRL_X0Y0 [get_ports $CLK_NAME]

puts "============================================================"
puts "  Synthesis Complete. Utilization Summary:"
puts "============================================================"
report_utilization -summary
exit
