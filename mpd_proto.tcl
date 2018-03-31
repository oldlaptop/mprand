package require simulation::random

set mpd_sock ""

# simple error-checking case
set check_err {if $err {return true} else {return false}}

# construct a dict from the common key: value format used by mpd, where value
# may often contain ':' characters and whitespace
proc cdict {inlist} {
	set ret ""
	set len [llength $inlist]
	foreach elem $inlist\
	{
		# we cannot use 'split $elem :' because : may occur in
		# the value
		set pivot [string first : $elem]
		set key [string range $elem 0 [expr $pivot - 1]]
		set val [string range $elem [expr $pivot + 2] end]
		dict set ret $key $val
	}
	return $ret
}

proc connect {host port} {
	global mpd_sock
	set mpd_sock [socket $host $port]
	#fconfigure $sock -blocking 0

	set protover [gets $mpd_sock]

	if {"{[string range $protover 0 5]}" == "{OK MPD}"} {
		return [string range $protover 7 end]
	} else {
		return false
	}
}

proc send_command {cmd {upresponse ""}} {
	global mpd_sock

	puts $mpd_sock $cmd

	flush $mpd_sock
	set response [gets $mpd_sock]

	while {1} {
		if {[string match "*OK*" $response]} {
			log "mpd command $cmd successful" 1
			log "{response $response}" 2

			if {![string is false $upresponse]} {
				#elide \nOK
				uplevel 1 set $upresponse "{[split [string range $response 0 end-3] \n]}"
			}

			return true
		} elseif {[string match "ACK*" $response]} {
			log "mpd error: $cmd failed ($response)" 0
			return false
		} else {
			set response "$response\n[gets $mpd_sock]"
		}
	}

	assert false
}

proc idle_wait {} {
	set err [send_command idle response]

	if {$err} {
		return $response
	} else {
		return false
	}
}

proc player_status {} {
	set err [send_command "status" response]

	if {$err} {
		# construct an array with right-values as indices
		return [cdict $response]
	} else {
		return false
	}
}

proc nsongs {} {
	set err [send_command "stats" response]

	if {$err} {
		return [string range [lsearch -inline $response "songs: *"] 7 end]
	} else {
		return -1
	}
}

proc rnd_song {} {
	set rng [::simulation::random::prng_Discrete [expr [nsongs] -1]]
	set songnum [$rng]

	set err [send_command "search file \"\" window $songnum:[expr $songnum + 1]" response]

	if {$err} {
		return [cdict $response]
	} else {
		return false
	}
}

proc consume {val} {
	assert "$val == 0 || $val == 1"
	global check_err

	set err [send_command "consume $val"]
	{*}$check_err
}

# Returns a list of dicts, one for each song in the queue
proc getq {} {
	set err [send_command "playlistinfo" response]
	if {$err} {
		set ret ""
		set files [lsearch -all $response file:*]
		set ids [lsearch -all $response Id:*]
		foreach file $files id $ids {
			lappend ret [cdict [lrange $response $file $id]]
		}
		return $ret
	} else {
		return false
	}
}

proc clq {} {
	global check_err
	set err [send_command "clear"]
	{*}$check_err
}

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

proc play {} {
	global check_err
	set err [send_command "play"]
	{*}$check_err
}

proc next {} {
	global check_err
	set err [send_command "next"]
	{*}$check_err
}
