# Copyright (c) 2020 Peter Piwowarski <peterjpiwowarski@gmail.com>
#
# Permission to use, copy, modify, and distribute this software for any
# purpose with or without fee is hereby granted, provided that the above
# copyright notice and this permission notice appear in all copies.
#
# THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
# WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
# MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
# ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
# WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
# ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
# OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

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
