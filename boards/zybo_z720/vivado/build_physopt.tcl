# =============================================================================
# build_physopt.tcl - Aggressive phys_opt / net-delay impl re-run (RTL UNCHANGED)
# =============================================================================
# 50 MHz roadmap (step "phys_opt probe", 2026-06-21):  The routed worst path is
# IF fetch-translation-loop dominated and (per docs/freq_50mhz.md section 16)
# ROUTE-dominated (75.7%) from high-fanout nets (addr_q fo=96, imem_ready fo=81).
# Before committing to the large case-(A) decoupled-fetch rewrite, probe how much
# Vivado's own router/phys_opt can recover with a net-delay-aware placement and
# aggressive (high-fanout-driver-replicating) phys_opt -- NO RTL change.
#
# Reuses the EXISTING synth_1 checkpoint (tree is clean at the real-HW-verified
# commit) so only place/phys_opt/route re-run (~25 min, no re-synthesis).
#
# Usage (PowerShell, absolute path):
#   & "E:\Tools\Xilinx\Vivado\2024.2\bin\vivado.bat" -mode batch \
#       -source boards\zybo_z720\vivado\build_physopt.tcl *> boards\reports\build_physopt.log 2>&1
#
# Output: boards/reports/physopt_timing_routed.rpt (+ WNS printed to the log at
# each milestone: post-route, and post-route-phys_opt).  Compare WNS to the
# 30.303 MHz baseline (33 ns constraint, baseline routed WNS +3.478 ns).
# =============================================================================

set script_dir [file normalize [file dirname [info script]]]
set repo       [file normalize "$script_dir/../../.."]
set proj_name  "rv_riscv_zybo"
set proj_dir   "$script_dir/$proj_name"
set synth_dcp  "$proj_dir/$proj_name.runs/synth_1/bd_riscv_wrapper.dcp"
set rptdir     "$repo/boards/reports"

# ---- args: [period_ns] [mode] --------------------------------------------
#   period_ns : clock period to constrain (default 20.0 = 50 MHz target)
#   mode      : "aggr" (ExtraNetDelay_high place + AggressiveExplore route/physopt)
#               "def"  (Vivado-default directives = matches the real build_zybo flow)
set PERIOD 20.0
set MODE   aggr
if {$argc >= 1} { set PERIOD [lindex $argv 0] }
if {$argc >= 2} { set MODE   [lindex $argv 1] }
puts "INFO: build_physopt PERIOD=$PERIOD ns  MODE=$MODE"

if {![file exists $synth_dcp]} {
    error "synth checkpoint not found: $synth_dcp  (run build_zybo.tcl bit/synth first)"
}
file mkdir $rptdir

proc say_wns {tag} {
    set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
    puts "==== PHYSOPT_WNS \[$tag\] = $wns ns ===="
}

open_checkpoint $synth_dcp

# ---- ensure the PS7-generated PL clock constraint is present --------------
# A standalone synth checkpoint does NOT carry the auto-generated clk_fpga_0
# (FCLK_CLK0) create_clock (it is injected by the project/IP constraint set at
# impl time), so without this the design routes UNCONSTRAINED (WNS=inf, phys_opt
# skipped).  Re-create it to match the baseline (33.0 ns = 30.303 MHz) so the WNS
# is directly comparable to the baseline routed WNS (+3.478 / +3.413 ns).
if {[llength [get_clocks -quiet]] == 0} {
    set fclk [get_pins -quiet -hier -filter {NAME =~ *PS7_i/FCLKCLK[0]}]
    if {[llength $fclk] == 0} { error "could not find PS7 FCLKCLK[0] pin to constrain" }
    create_clock -name clk_fpga_0 -period $PERIOD $fclk
    puts "INFO: re-created clk_fpga_0 @ $PERIOD ns on $fclk"
}

# ---- opt + placement (mode-dependent) ------------------------------------
# aggr: ExtraNetDelay_high makes the placer pessimistic about net delays so it
#       pulls timing-critical high-fanout logic closer (targets route-dominated
#       paths); AggressiveExplore route/phys_opt push hardest.
# def : Vivado-default directives = matches the real build_zybo.tcl flow
#       (launch_runs impl_1, default strategy).  Isolates "tight constraint
#       alone" vs "aggressive strategy".
if {$MODE eq "aggr"} {
    opt_design -directive Explore
    place_design -directive ExtraNetDelay_high
    say_wns "post-place"
    phys_opt_design -directive AggressiveExplore
    say_wns "post-place-physopt"
    route_design -directive AggressiveExplore
    say_wns "post-route"
} else {
    opt_design
    place_design
    say_wns "post-place"
    route_design
    say_wns "post-route"
}

# ---- report the CLEAN routed worst paths FIRST (before post-route phys_opt,
# which can abnormally exit at large negative slack) so the binding path is
# always captured regardless of the phys_opt step's fate.
report_timing_summary -file "$rptdir/physopt_timing_routed_$MODE.rpt"
report_timing -max_paths 10 -nworst 10 -setup -file "$rptdir/physopt_worst_paths_$MODE.rpt"
write_checkpoint -force "$proj_dir/$proj_name.runs/impl_1/bd_riscv_wrapper_routed_$MODE.dcp"
puts "INFO: routed reports written.  See $rptdir/physopt_timing_routed_$MODE.rpt"

# ---- post-route phys_opt: only useful when WNS is above ~ -0.5 ns; below
# that it is ineffective (Vivado warns) AND has crashed this design (exit 116)
# at large negative slack, so skip it unless we are already close.
set cur_wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
if {$cur_wns > -0.5} {
    if {[catch {phys_opt_design -directive AggressiveExplore} emsg]} {
        puts "WARNING: post-route phys_opt bailed: $emsg"
    } else {
        say_wns "post-route-physopt"
        report_timing_summary -file "$rptdir/physopt_timing_routed_${MODE}_pp.rpt"
    }
} else {
    puts "INFO: skipping post-route phys_opt (WNS=$cur_wns ns < -0.5, ineffective)."
}
puts "INFO: phys_opt probe done (MODE=$MODE)."
