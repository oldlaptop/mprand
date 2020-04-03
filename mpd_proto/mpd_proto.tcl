package require simulation::random

package provide mpd_proto 0.2

namespace eval mpd_proto {

variable CHARS_PER_READ 1024

variable mpd_sock ""

# simple error-checking case
variable check_err {if $err {return true} else {return false}}

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

# construct an array from the common key: value format used by mpd, where value
# may often contain ':' characters and whitespace
proc carr {arrname inlist} {
	upvar $arrname arr
	set len [llength $inlist]
	foreach elem $inlist {
		# we cannot use 'split $elem :' because : may occur in
		# the value
		set pivot [string first : $elem]
		set key [string range $elem 0 [expr $pivot - 1]]
		set val [string range $elem [expr $pivot + 2] end]
		array set arr "\{$key\} \{$val\}"
	}
}

proc connect {host port} {
	variable mpd_sock
	set mpd_sock [socket $host $port]
	chan configure $mpd_sock -blocking 0

	set protover [readln]

	if {"{[string range $protover 0 5]}" == "{OK MPD}"} {
		return [string range $protover 7 end]
	} else {
		return false
	}
}
namespace export connect

proc send_command {cmd {upresponse ""}} {
	variable mpd_sock

	sendstr $cmd

	flush $mpd_sock
	set response [readln]

	while {1} {
		if {[string match "*OK*" $response]}\
		{
			log "mpd command $cmd successful" 1
			log "{response $response}" 2

			if {![string is false $upresponse]}\
			{
				#elide \nOK
				uplevel 1 set $upresponse "{[split [string range $response 0 end-3] \n]}"
			}

			return true
		} elseif {[string match "ACK*" $response]}\
		{
			log "mpd error: $cmd failed ($response)" 0
			return false
		} else {
			set response "$response\n[gets $mpd_sock]"
		}
	}

	assert false
}
namespace export send_command

proc idle_wait {} {
	set err [send_command idle response]

	if {$err} {
		return $response
	} else {
		return false
	}
}
namespace export idle_wait

# rather looks like associative arrays were glued on, doesn't it?
proc player_status {arrname} {
	upvar $arrname statarr
	set err [send_command "status" response]

	if {$err} {
		# construct an array with right-values as indices
		carr statarr $response
		return true
	} else {
		return false
	}
}
namespace export player_status

proc nsongs {} {
	set err [send_command "stats" response]

	if {$err} {
		return [string range [lsearch -inline $response "songs: *"] 7 end]
	} else {
		return -1
	}
}
namespace export nsongs

proc rnd_song {arrname} {
	upvar $arrname songinfo
	set rng [::simulation::random::prng_Discrete [expr [nsongs] -1]]
	set songnum [$rng]

	set err [send_command "search file \"\" window $songnum:[expr $songnum + 1]" response]

	if {$err} {
		carr songinfo $response
		return true
	} else {
		return false
	}
}
namespace export rnd_song

proc consume {val} {
	assert "$val == 0 || $val == 1"
	variable check_err

	set err [send_command "consume $val"]
	{*}$check_err
}
namespace export consume

proc clq {} {
	variable check_err
	set err [send_command "clear"]
	{*}$check_err
}
namespace export clq

proc enq_song {song} {
	# mpd needs quotes escaped
	set song [string map {\" \\\"} $song]
	set err [send_command "addid \"$song\"" response]

	if {$err} {
		set spc [string first ":" $response]
		return [string range $response $spc end]
	} else {
		return -1
	}
}
namespace export enq_song

proc play {} {
	variable check_err
	set err [send_command "play"]
	{*}$check_err
}
namespace export play

} ;# namespace eval mpd_proto
