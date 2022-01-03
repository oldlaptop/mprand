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

package require simulation::random

package provide mpd_proto 0.2

##
# Basic coroutine-based event-driven MPD protocol frontend. All procs exported
# by this namespace, unless otherwise noted, must be called from a coroutine
# context.
#
# The minimum supported MPD version should in principle be 0.13, but this
# severely restricts the functionality available. Commands that use features
# introduced since that time check the version of the connected MPD and throw an
# error if it's insufficient.
namespace eval mpd_proto {

variable CHARS_PER_READ 1024
variable TIMEOUT 10000

variable mpd_sock {}
variable mpd_version {}
variable idling false

proc yield_or_die {after_id chanevent} {
	variable mpd_sock

	set ret [yield]

	after cancel $after_id
	chan event $mpd_sock $chanevent {}

	switch $ret {
		die {
			rename [info coroutine] ""
			yield ;# will immediately terminate the coroutine context
		}
		timeout {
			error "mpd did not respond after $mpd_proto::TIMEOUT ms"
		}
		default {
		}
	}
	return $ret
}

proc readln {{timeout true}} {
	variable CHARS_PER_READ
	variable mpd_sock

	set ret {}
	do {
		if {[chan eof $mpd_sock]} {
			disconnect
			set ret {lost connection}
			break
		}

		if {[chan blocked $mpd_sock]} {
			chan event $mpd_sock readable [info coroutine]
			if {$timeout} {
				set timeout_id [after $mpd_proto::TIMEOUT [info coroutine] timeout]
			} else {
				set timeout_id {} ;# cancelling this is a nop
			}
			yield_or_die $timeout_id readable
		}
		set ret [string cat $ret [read $mpd_sock $CHARS_PER_READ]]
	} until {[string match "*OK\n" $ret] ||
	         [string match "OK MPD *\n" $ret] ||
	         [string match "ACK \\\[*@*\\\] \{*\} *\n" $ret]}

	return $ret
}

# Since we're in non-blocking mode, the event loop must be entered for sendstr
# to work correctly. (In the request/response pattern this will generally happen
# when readln yields to the event loop.)
proc sendstr {str} {
	variable mpd_sock

	chan event $mpd_sock writable [info coroutine]
	set timeout_id [after $mpd_proto::TIMEOUT [info coroutine] timeout]
	yield_or_die $timeout_id writable

	puts $mpd_sock $str
}

##
# Send a raw command string to MPD, and place its response into a variable. If
# there was a pending idle event, it is cancelled; the caller is advised to
# restart any idle_wait loop that may have been ongoing.
#
# @param[in] cmd The string to send MPD, as it will go over the wire.
# @param[out] upresponse Name of a variable into which MPD's response will be
#                        placed. If not specified, the response will be thrown
#                        away.
# @param[in] timeout Whether to enable timeouts for the reply
#
# @return true if MPD responded OK, false if MPD responded ACK
proc send_command {cmd {upresponse ""} {timeout true}} {
	if {$mpd_proto::idling && $cmd ne "noidle" && $cmd ne "idle"} {
		log "leaving idle loop" 1
		send_command noidle
		set mpd_proto::idling false
	}
	variable mpd_sock

	if {$upresponse ne ""} {
		upvar $upresponse response
	}

	sendstr $cmd
	
	flush $mpd_sock
	set response [readln $timeout]

	if {[string match "*OK*" $response]} {
		log "mpd command $cmd successful" 1
		log "{response [string trim $response]}" 2

		return true
	} elseif {[string match "ACK*" $response]} {
		log "mpd error: $cmd failed ([string trim $response])" 1

		return false
	} elseif {$response == "lost connection"} {
		log "mpd: lost connection"
		return false
	} else {
		error "incomprehensible response from MPD: [string trim $response]"
	}
}

##
# Construct a dict from the common key: value format used by mpd, where value
# may often contain ':' characters and whitespace.
#
# @param[in] inlist Raw key: value response from MPD
#
# @return inlist converted to dict form, with keys normalized to all-lowercase;
#         values are lists, with repeated keys stored as multiple elements.
#         Most of these lists will generally have a single element, and values
#         that are specified in the protocol as a single integer or word (i.e.
#         that contain no whitespace) should be safe to use directly without
#         [lindex $foo 0].
proc cdict {inlist} {
	set ret [dict create]
	foreach elem [split $inlist \n] {
		# we cannot use 'split $elem :' because : may occur in
		# the value
		set pivot [string first : $elem]
		# if mpd uses the empty string as a key, I don't like it anymore
		if {$pivot > 0} {
			set key [string tolower [string range $elem 0 [expr $pivot - 1]]]
			set val [string range $elem [expr $pivot + 2] end]

			if {[dict exists $ret $key]} {
				log "warning: duplicate keys from mpd: $key (values [dict get $ret $key], $val)" 2
			}

			dict lappend ret $key $val
		}
	}
	return $ret
}

##
# Quote a parameter (such as a filename) for sending over the wire to MPD.
#
# @param str String to quote
#
# @return str quoted for MPD
proc quote {str} {
	return "\"[string map {\" \\\" \\ \\\\} $str]\""
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
		error "mpd returned error [string trim $response]"
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
	if {![isconnected]} {
		variable mpd_sock
		variable mpd_version
		set mpd_sock [socket $host $port]
		chan configure $mpd_sock -blocking 0 -translation binary

		set protover [readln]

		if {"{[string range $protover 0 5]}" == "{OK MPD}"} {
			log "connected to mpd: [string trim $protover]" 1
			return [set mpd_version [string range $protover 7 end-1]]
		} else {
			error "could not connect to MPD (response: $protover)"
		}
	} else {
		error "already connected; call disconnect first?"
	}
}
namespace export connect

##
# Disconnect from MPD.
proc disconnect {} {
	chan close $mpd_proto::mpd_sock
	set mpd_proto::mpd_sock ""
	set mpd_proto::mpd_version ""
	set mpd_proto::idling false
	aacache::flush
}
namespace export disconnect

##
# Does not require a coroutine context.
#
# @return true if the connection is open to the best of our knowledge, false
#         otherwise
proc isconnected {} {
	expr {$mpd_proto::mpd_sock ne ""}
}
namespace export isconnected

##
# Wait in the event loop until MPD signals an idleevent. Requires MPD >=0.14.
#
# @return MPD's <a href="https://www.musicpd.org/doc/html/protocol.html#command-idle">
#         idleevent response as a list of each changed subsystem.
proc idle_wait {} {
	if {$mpd_proto::idling} {
		error "already idling"
	}
	if {$mpd_proto::mpd_version < 0.14} {
		error "this mpd doesn't support idle"
	}

	set ret [list]

	set mpd_proto::idling true
	set err [send_command idle response false]
	set mpd_proto::idling false

	checkerr $err $response
	foreach {changed subsystem} [string map {: { }} $response] {
		if {$changed ne "OK"} {
			lappend ret $subsystem
		}
	}

	log "mpd reports change(s) in: $ret" 1

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
# Requires MPD >= 0.20.
#
# @return A large dict from MPD containing information on the selected song. Its
#         contents do not appear to be documented, and depend to some extent on
#         the individual song in any case; guaranteed keys appear to include
#         'file', containing the file's path in MPD's hierarchy, and 'duration',
#         in seconds.
proc rnd_song {} {
	if {$mpd_proto::mpd_version < 0.20} {
		error "this mpd doesn't support search windows"
	}

	set rng [::simulation::random::prng_Discrete [expr [nsongs] -1]]
	set songnum [$rng]

	set err [send_command "search file \"\" window $songnum:[expr {$songnum + 1}]" response]

	return [checkerr $err $response]
}
namespace export rnd_song

##
# Fetch a song from the queue, by id
#
# @param id A song's queue-unique identifier
#
# @return A large dict from MPD containing information on the selected song.
proc song_by_queueid {id} {
	set err [send_command "playlistid $id" response]
	return [checkerr $err $response]
}

##
# Get a song's title from a song-dict. Does not require a coroutine context.
#
# @param song A song-dict as returned from rnd_song, song_by_queueid, etc.
#
# @return The song's title, or its filename if there is no title tag.
proc song_name {song} {
	lindex [expr {
		[dict exists $song title]
			? [dict get $song title]
			: [file tail [dict get $song file]]
	}] 0
}

##
# Fetch a song's albumart image. Throws an error if the song has no albumart.
# The retrieved image will be stored in a permanent (for the life of the
# connection) cache, and this proc serves images from the cache in strict
# preference to making network requests; a new network request, overwriting the
# cached value, may be forced by setting the second parameter to false.
# Requires MPD >= 0.21.
#
# @param song URI of the song
#
# @return A dict of the form {size <N> binary <blob>}, where <N> is the image's
# size as reported by MPD and <blob> is the raw image binary.
proc albumart {song {use_cache yes}} {
	if {$mpd_proto::mpd_version < 0.21} {
		error "this mpd doesn't support albumart"
	}

	set song [quote $song]

	if {$use_cache} {
		return [aacache::get $song]
	} else {
		return [aacache::miss $song]
	}
}
namespace export albumart

namespace eval aacache {
	# the default path is documented as empty, but perhaps that'll change
	namespace path [concat ::mpd_proto [namespace path]]

	# Names are MPD song URIs, values are result-dicts as defined in
	# mpd_proto::albumart's comment block
	array set cache {}

	# Clear the cache.
	proc flush {} { array unset mpd_proto::aacache::cache *}

	# Retrieve a song through the cache
	proc get {song} {
		variable cache

		if {[array names cache $song] eq ""} {
			miss $song
		}

		return [lindex [array get cache $song] 1]
	}

	# Add a song to the cache from MPD, overwriting any existing value
	proc miss {song} {
		variable cache

		log "note: albumart cache miss for $song" 1

		set ret [dict create]
		set offs 0
		dict set ret binary {}

		do {
			set err [send_command "albumart $song $offs" response]
			if {!$err} {
				error "mpd returned error [string trim $response]"
			}

			set size_end [string first \n $response]
			dict set ret size [string trim [lindex [split [string range $response 0 $size_end-1] :] 1]]

			set offs_start [expr {$size_end + 1}]
			set offs_end [string first \n $response $offs_start]
			set chunksize [string trim [lindex [split [string range $response $offs_start $offs_end-1] :] 1]]
			incr offs $chunksize

			set bin_start [expr {$offs_end + 1}]
			# for bin_end we must not include the specified trailing
			# newline; for now we just believe mpd...
			set bin_end [expr {$bin_start + $chunksize}]
			dict set ret binary [
				string cat [dict get $ret binary] [string range $response $bin_start $bin_end-1]
			]
		} while {$offs < [dict get $ret size]}

		array set cache [list $song $ret]
		return $ret
	}
} ;# namespace eval aacache

##
# Set MPD's consume status. Requires MPD >= 0.15.
#
# @param[in] val New consume status.
proc consume {status} {
	if {$mpd_proto::mpd_version < 0.15} {
		error "this mpd doesn't support consume"
	}
	if {!($status == 0 || $status == 1)} {
		error "invalid consume status $status"
	}

	checkerr [send_command "consume $status"]
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
	# mpd needs whitespace quoted and quotes escaped
	set song [quote $song]
	set err [send_command "addid $song" response]

	checkerr $err $response
}
namespace export enq_song

##
# Start playing.
proc play {} {
	checkerr [send_command "play"]
}
namespace export play

##
# Set pause status, or just pause if given no arguments.
#
# @param[in] status New pause status
proc pause {{status 1}} {
	if {!($status == 0 || $status == 1)} {
		error "invalid pause status $status"
	}

	checkerr [send_command "pause $status"]
}
namespace export pause

##
# Skip to the next song.
proc next {} {
	checkerr [send_command "next"]
}
namespace export next

##
# Stop playback.
proc stop {} {
	checkerr [send_command "stop"]
}
namespace export stop

} ;# namespace eval mpd_proto
