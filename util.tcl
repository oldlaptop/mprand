if {[string length [array names env LOG_LEVEL]] > 0}\
{
	set log_level $env(LOG_LEVEL)
}\
else\
{
	set log_level 0
}

proc log {msg {priority 0}}\
{
	global log_level
	if {$priority <= $log_level}\
	{
		puts "mprand: $msg"
	}
}

proc assert {expression}\
{
	if {![uplevel 1 expr $expression]}\
	{
		log "failed assert: $expression" -1
		exit 1
	}
}
