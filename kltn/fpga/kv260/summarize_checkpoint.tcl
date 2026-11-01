# Regenerate reports/vivado/kv260_core_if/run_summary.txt from the last routed
# checkpoint, without re-running synthesis and implementation (about a minute).
set script_dir [file dirname [file normalize [info script]]]
set kltn_root  [file normalize [file join $script_dir ../..]]

open_checkpoint [file join $kltn_root build vivado kv260_core_if post_route.dcp]
source [file join $script_dir write_summary.tcl]
write_run_summary [file join $kltn_root reports vivado kv260_core_if run_summary.txt] \
    "(out-of-context, registered-I/O wrapper around core, no RAMs)"
exit
