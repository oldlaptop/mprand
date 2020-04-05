namespace eval mpd_proto {

if {[info exists env(LOG_LEVEL)]} {
	##
	# Messages with a priority greater than this will not be logged.
	variable log_level $env(LOG_LEVEL)
} else {
	variable log_level 0
}

##
# Channel to which logs will be sent; defaults to stderr.
variable logchan stderr

##
# Send a message to the log. Does not require a coroutine context.
#
# @param[in] msg Message to send
# @param[in] priority Log priority (see log_level)
proc log {msg {priority 0}} {
	if {$priority <= $mpd_proto::log_level} {
		puts $mpd_proto::logchan "mprand: $msg"
	}
}
namespace export log

proc assert {expression} {
	if {![uplevel 1 expr $expression]} {
		error "failed assert: $expression"
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
