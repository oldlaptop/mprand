package require simulation::random

package provide mpd_proto 0.2

##
# Basic coroutine-based event-driven MPD protocol frontend.
namespace eval mpd_proto {

variable CHARS_PER_READ 1024

variable mpd_sock ""

proc readln {} {
	variable CHARS_PER_READ
	variable mpd_sock

	set ret {}
	do {
		if {[chan blocked $mpd_sock]} {
			chan event $mpd_sock readable [info coroutine]
			yield
		}
		set ret [string cat $ret [read $mpd_sock $CHARS_PER_READ]]
	} until {[string index $ret end] eq "\n"}
	chan event $mpd_sock readable {}

	return $ret
}

# Since we're in non-blocking mode, the event loop must be entered for sendstr
# to work correctly. (In the request/response pattern this will generally happen
# when readln yields to the event loop.)
proc sendstr {str} {
	variable mpd_sock

	chan event $mpd_sock writable [info coroutine]
	yield

	puts $mpd_sock $str

	chan event $mpd_sock writable {}
}

##
# Send a raw command string to MPD, and place its response into a variable.
#
# @param[in] cmd The string to send MPD, as it will go over the wire.
# @param[out] upresponse Name of a variable into which MPD's response will be
#                        placed. If not specified, the response will be thrown
#                        away.
#
# @return true if MPD responded OK, false if MPD responded ACK
proc send_command {cmd {upresponse ""}} {
	variable mpd_sock

	if {$upresponse ne ""} {
		upvar $upresponse response
	}
	
	sendstr $cmd
	
	flush $mpd_sock
	set response [readln]

	if {[string match "*OK*" $response]} {
		log "mpd command $cmd successful" 1
		log "{response $response}" 2

		return true
	} elseif {[string match "ACK*" $response]} {
		log "mpd error: $cmd failed ($response)" 1

		return false
	} else {
		set response "$response\n[gets $mpd_sock]"
	}
}

##
# Construct a dict from the common key: value format used by mpd, where value
# may often contain ':' characters and whitespace.
#
# @param[in] inlist Raw key: value response from MPD
#
# @return inlist converted to dict form
proc cdict {inlist} {
	set ret [dict create]
	foreach elem [split $inlist \n] {
		# we cannot use 'split $elem :' because : may occur in
		# the value
		set pivot [string first : $elem]
		# if mpd uses the empty string as a key, I don't like it anymore
		if {$pivot > 0} {
			set key [string range $elem 0 [expr $pivot - 1]]
			set val [string range $elem [expr $pivot + 2] end]
			dict set ret $key $val
		}
	}
	return $ret
}

##
# Simple error-checking case; returns MPD's response in dict form if a call
# succeeded, and errors with MPD's response in the message if it did not.
#
# @param err True if the call succeeded, false otherwise
# @param response Raw response from MPD
#
# @return [cdict $response], or nil if response was not specified
proc checkerr {err {response nil}} {
	if {$err} {
		return [expr {$response eq "nil" ? "nil" : [cdict $response]}]
	} else {
		error "mpd returned error $response"
	}
}

##
# Open the connection to MPD.
#
# @param[in] host MPD's hostname
# @param[in] port MPD's port on $hostname
#
# @return MPD's protocol version.
proc connect {host port} {
	variable mpd_sock
	set mpd_sock [socket $host $port]
	chan configure $mpd_sock -blocking 0

	set protover [readln]

	if {"{[string range $protover 0 5]}" == "{OK MPD}"} {
		return [string range $protover 7 end]
	} else {
		error "could not connect to MPD (response: $protover)"
	}
}
namespace export connect

##
# Wait in the event loop until MPD signals an idleevent.
#
# @return MPD's <a href="https://www.musicpd.org/doc/html/protocol.html#command-idle">
#         idleevent response as a list of each changed subsystem.
proc idle_wait {} {
	set ret [list]
	set err [send_command idle response]

	checkerr $err
	foreach {changed subsystem} [string map {: { }} $response] {
		if {$changed ne "OK"} {
			lappend ret $subsystem
		}
	}
	return $ret
}
namespace export idle_wait

##
# Fetch MPD's status.
#
# @return MPD's <a href="https://www.musicpd.org/doc/html/protocol.html#command-status">
#         status response</a> as a dict.
proc player_status {} {
	set err [send_command "status" response]

	return [checkerr $err $response]
}
namespace export player_status

##
# Fetch MPD's statistics.
#
# @return MPD's <a href="https://www.musicpd.org/doc/html/protocol.html#command-status">
#         stats response</a> as a dict.
proc player_stats {} {
	set err [send_command "stats" response]

	return [checkerr $err $response]
}
namespace export player_stats

##
# Fetch the number of songs in MPD's database.
#
# @return The number of songs in the database as an integer.
proc nsongs {} {
	return [dict get [player_stats] songs]
}
namespace export nsongs

##
# Fetch a random song from MPD's database, with uniform(ish) distribution.
#
# @return A large dict from MPD containing information on the selected song. Its
#         contents do not appear to be documented, and depend to some extent on
#         the individual song in any case; guaranteed keys appear to include
#         'file', containing the file's path in MPD's hierarchy, and 'duration',
#         in seconds.
proc rnd_song {} {
	set rng [::simulation::random::prng_Discrete [expr [nsongs] -1]]
	set songnum [$rng]

	set err [send_command "search file \"\" window $songnum:[expr {$songnum + 1}]" response]

	return [checkerr $err $response]
}
namespace export rnd_song

##
# Set MPD's consume status.
#
# @param[in] val New consume status.
proc consume {val} {
	checkerr [send_command "consume $val"]
}
namespace export consume

##
# Clear MPD's queue.
proc clear {} {
	checkerr [send_command "clear"]
}
namespace export clear

##
# Add a song to the tail of MPD's queue.
#
# @param[in] song URI of the song to add
#
# @return MPD's response as a dict, which should have the form {Id [N]}, where
#         [N] is an integer that is the song's queue-unique identifier.
proc enq_song {song} {
	# mpd needs quotes escaped
	set song [string map {\" \\\"} $song]
	set err [send_command "addid \"$song\"" response]

	checkerr $err $response
}
namespace export enq_song

##
# Start playing.
proc play {} {
	checkerr [send_command "play"]
}
namespace export play

} ;# namespace eval mpd_proto
