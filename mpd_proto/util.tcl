namespace eval mpd_proto {

if {[string length [array names env LOG_LEVEL]] > 0} {
	variable log_level $env(LOG_LEVEL)
} else {
	variable log_level 0
}

proc log {msg {priority 0}} {
	variable log_level
	if {$priority <= $log_level} {
		puts "mprand: $msg"
	}
}
namespace export log

proc assert {expression} {
	if {![uplevel 1 expr $expression]} {
		log "failed assert: $expression" -1
		exit 1
	}
}

proc do {body spec predicate} {
	switch $spec {
		while {}
		until { set predicate !($predicate) }
		default { error "unknown do-spec $spec" }
	}

	uplevel 1 $body
	while {[uplevel 1 [list expr $predicate]]} {
		uplevel 1 $body
	}
}

} ;# namespace eval mpd_proto
