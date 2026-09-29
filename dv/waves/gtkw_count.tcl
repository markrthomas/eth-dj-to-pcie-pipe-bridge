# Headless GTKWave load check (used by wave_check.py): write the number and names
# of the traces GTKWave resolved from the .gtkw session, then quit.
set n [gtkwave::getTotalNumTraces]
set f [open $::env(GTKW_COUNT_OUT) w]
puts $f "traces=$n"
for {set i 0} {$i < $n} {incr i} { puts $f [gtkwave::getTraceNameFromIndex $i] }
close $f
gtkwave::/File/Quit
