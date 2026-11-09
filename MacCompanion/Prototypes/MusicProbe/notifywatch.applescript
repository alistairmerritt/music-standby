-- notifywatch.applescript — observe Music.app's playerInfo distributed notification.
--
-- AppleScriptObjC through osascript, so it runs with no compiler and no Xcode.
--   osascript notifywatch.applescript 20
-- Logs each notification to stderr. Read-only: it never touches playback.

use framework "Foundation"
use scripting additions

on gotNote:aNotification
	set noteName to (aNotification's |name|()) as text
	log "NOTE name=" & noteName
	try
		log "  object=" & ((aNotification's object()) as text)
	end try
	set ui to aNotification's userInfo()
	if ui is missing value then
		log "  userInfo=(none)"
		return
	end if
	try
		set ks to (ui's allKeys()) as list
		set AppleScript's text item delimiters to ", "
		log "  keys=" & (ks as text)
		set AppleScript's text item delimiters to ""
		repeat with k in ks
			try
				log "  " & (k as text) & " = " & ((ui's objectForKey:k) as text)
			end try
		end repeat
	on error e
		log "  userInfo unreadable: " & e
	end try
end gotNote:

on run argv
	set secs to 20
	try
		set secs to (item 1 of argv) as integer
	end try
	set nc to current application's NSDistributedNotificationCenter's defaultCenter()
	nc's addObserver:me selector:"gotNote:" |name|:"com.apple.Music.playerInfo" object:(missing value)
	log "OBSERVER REGISTERED, listening " & secs & "s"
	set endTime to (current application's NSDate's dateWithTimeIntervalSinceNow:secs)
	current application's NSRunLoop's currentRunLoop()'s runUntilDate:endTime
	log "OBSERVER DONE"
end run
