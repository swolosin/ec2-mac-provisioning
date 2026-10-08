-- ============================================================
-- Author:  Stephen Wolosin
-- Team:
-- Date:    2026-05-21
--
-- WARNING: Test thoroughly in non-production environments before
-- deploying to production. This script drives System Settings UI
-- headlessly and interacts with MDM enrollment APIs. Misconfiguration
-- may result in failed enrollment, locked devices, or unintended
-- Jamf record changes. The author and team assume no liability for
-- damages arising from use outside of validated test environments.
-- ============================================================

-- JPMC-EC2-Enroll.applescript
-- Headless Jamf MDM enrollment for EC2 Mac instances
-- Supports: macOS 14 (Sonoma), 15 (Sequoia), 26 (Tahoe), 27 (Golden Gate)
-- macOS 14/15/26 are validated at 20/20. macOS 27 enrollment has succeeded
-- end-to-end on mac2-m2pro.metal; see README for the open items on 27.
--
-- Key improvements over enroll-ec2-mac.scpt:
--   - launchd xpc.activity gates the LaunchAgent until network is ready
--   - IMDS retry logic with --noproxy, scutil --nwi gate, elapsed timing
--   - macOS 26 Device Management navigation (no sidebarTarget crash)
--   - cliclick cached to /Users/Shared/._jpmc-tools/ (no Homebrew dep at boot)
--   - Defensive bootout of DiagnosticsReporter at top of installProfile
--     (handles "Computer was restarted" dialog left by SIP-disable panic)
--   - plutil + xmllint for JSON/XML parsing (native macOS, no Python eval)
--   - Timestamped logging to /Library/Logs/JPMC/
--   - Dismisses the internal-SSD FileVault unlock prompt that some dedicated
--     hosts present at every login (AWS case 179140454500900)
--   - Quits per-user Setup Assistant ("Buddy") before driving the UI, since it
--     holds the foreground and physical clicks would land on it
--   - Clicks the NEWEST downloaded profile rather than a stale one left behind
--     by an earlier failed attempt
--   - Top-level error handler, so an unhandled error still reports
--     ENROLLMENT_STATUS instead of leaving the pipeline polling forever
--
-- Configuration:
--   defaults write com.jpmc.ec2.mdm.enrollment MMSecret "your-secret-id"
--   defaults write com.jpmc.ec2.mdm.enrollment prodFlag "1"
--
-- Invoked at boot by LaunchAgent (no argv):
--   osascript /Users/Shared/JPMC-EC2-Enroll.scpt

-- ============================================================
-- SCRIPT-LEVEL CONSTANTS
-- ============================================================

-- Version of the JPMC enrollment script set. Kept in lockstep across
-- JPMC-setup-user.sh, JPMC-stage-enrollment.sh, and this script — bump
-- all three together on each release. Logged at startup and embedded in
-- the ENROLLMENT_STATUS JSON so every instance is traceable to a version.
property SCRIPT_VERSION : "1.1.0"

-- Shell PATH used for every `do shell script` invocation that needs aws,
-- curl, plutil, xmllint, etc. Broadest variant covers Homebrew installs
-- at either /opt/homebrew (Apple Silicon default) or /usr/local (Intel/legacy).
property AWS_PATH : "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/opt/homebrew/sbin"

-- Run context, captured as it becomes known so the top-level error handler in
-- `on run` can still report region and MDM URL when something throws before
-- logFinalStatus would normally be reached. If a failure happens before these
-- are set, the status object honestly reports "unknown" rather than guessing.
property RUN_REGION : "unknown"
property RUN_JAMF_URL : "unknown"

-- Holds the local admin password for the duration of the run, for one reason
-- only: so the error handler can scrub it out of an AppleScript error message
-- before that message reaches the log and the S3 status object. `do shell
-- script` failures can echo the failing command, and some of those commands
-- carry the password. Never written to disk, because osascript does not save
-- properties back into the compiled .scpt. Cleared when the run ends.
property RUN_ADMIN_PASS : ""

-- ============================================================
-- TEXT HELPERS
-- Plain AppleScript string utilities. Used by the logging and status paths,
-- so they are defined before anything that might need to report an error.
-- ============================================================

on replaceText(theText, searchStr, replaceStr)
	if searchStr is "" then return theText
	set savedDelims to AppleScript's text item delimiters
	set AppleScript's text item delimiters to searchStr
	set theParts to text items of theText
	set AppleScript's text item delimiters to replaceStr
	set theResult to theParts as text
	set AppleScript's text item delimiters to savedDelims
	return theResult
end replaceText

-- Remove anything secret from a string before it is logged or uploaded.
-- Currently just the local admin password, which is the only secret that can
-- end up inside a `do shell script` error message.
on scrubSecrets(msg)
	set out to msg as text
	if RUN_ADMIN_PASS is not "" then
		set out to my replaceText(out, RUN_ADMIN_PASS, "***REDACTED***")
	end if
	return out
end scrubSecrets

-- Escape a string for embedding in the ENROLLMENT_STATUS JSON. Error text can
-- contain quotes, backslashes and newlines, any of which would produce invalid
-- JSON that the pipeline could not parse.
on jsonEscape(s)
	set out to my replaceText(s as text, "\\", "\\\\")
	set out to my replaceText(out, "\"", "\\\"")
	set out to my replaceText(out, tab, " ")
	set out to my replaceText(out, return, " ")
	set out to my replaceText(out, linefeed, " ")
	return out
end jsonEscape

-- ============================================================
-- LOGGING
-- All log entries are timestamped. LaunchAgent captures stderr
-- (where AppleScript's `log` writes) to /Library/Logs/JPMC/EC2-Enroll.log.
-- ============================================================

on logMsg(msg)
	set ts to (do shell script "date '+%Y-%m-%d %H:%M:%S'")
	log ts & "  " & msg
end logMsg

-- ============================================================
-- CONFIGURATION
-- ============================================================

on getMMSecret()
	try
		set val to (do shell script "defaults read com.jpmc.ec2.mdm.enrollment MMSecret")
		if val is not "" then return val
	end try
	-- MMSecret not in defaults — stage-enrollment.sh may not have run
	my logMsg("WARNING: MMSecret not found in defaults — was stage-enrollment.sh run? Falling back to 'mdmSecret'")
	return "mdmSecret"
end getMMSecret

on getProdFlag()
	try
		if (do shell script "defaults read com.jpmc.ec2.mdm.enrollment prodFlag") is "1" then return true
	end try
	return false
end getProdFlag

-- ============================================================
-- IMDS WITH RETRY
-- LaunchAgent is gated by launchd xpc.activity RequireNetworkConnectivity
-- (see stage-enrollment.sh plist), so by the time this runs the network
-- interface is already up. Defense-in-depth here:
--   1. scutil --nwi passive gate — confirms SCDynamicStore shows an
--      active interface with an address. Reads same state launchd uses.
--      Cheap, no network traffic, won't burn IMDS attempts on boot noise.
--   2. IMDS retry loop — 12 attempts × 10s for true transient IMDS hiccups.
--   3. --noproxy on curl — link-local 169.254.169.254 must go direct,
--      not through any http_proxy env var (corporate proxy environments).
-- Elapsed time is logged on success and failure so the log shows exactly
-- how long the wait was if anything ever goes wrong.
-- ============================================================

on imdsGet(mdPath)
	set maxAttempts to 12
	set retryDelay to 10
	set startTime to (do shell script "date '+%s'")

	-- Passive network gate (24 × 5s = 2 min max). launchd already waited,
	-- but if for some reason the interface flapped after, hold here.
	set gateAttempts to 0
	repeat 24 times
		set gateAttempts to gateAttempts + 1
		try
			do shell script "/usr/sbin/scutil --nwi | /usr/bin/grep -q 'address'"
			exit repeat
		on error
			if gateAttempts is 1 then
				my logMsg("Network interface not ready (scutil --nwi) — waiting...")
			end if
			delay 5
		end try
	end repeat

	repeat with attempt from 1 to maxAttempts
		try
			set token to (do shell script "PATH=" & AWS_PATH & " ; curl -sf --noproxy '169.254.169.254' --connect-timeout 5 --max-time 10 -X PUT 'http://169.254.169.254/latest/api/token' -H 'X-aws-ec2-metadata-token-ttl-seconds: 300'")
			if length of token > 10 then
				set mdResult to (do shell script "PATH=" & AWS_PATH & " ; curl -sf --noproxy '169.254.169.254' --connect-timeout 5 --max-time 10 -H 'X-aws-ec2-metadata-token: " & token & "' 'http://169.254.169.254/latest/meta-data/" & mdPath & "'")
				set elapsed to (do shell script "echo $(( $(date '+%s') - " & startTime & " ))")
				my logMsg("IMDS ok (attempt " & attempt & "/" & maxAttempts & ", waited " & elapsed & "s): " & mdPath & " = " & mdResult)
				return mdResult
			end if
		on error errMsg
			my logMsg("IMDS attempt " & attempt & "/" & maxAttempts & " failed: " & errMsg)
		end try
		if attempt < maxAttempts then
			my logMsg("IMDS not ready (attempt " & attempt & "/" & maxAttempts & "), retrying in " & retryDelay & "s...")
			delay retryDelay
		end if
	end repeat
	set elapsed to (do shell script "echo $(( $(date '+%s') - " & startTime & " ))")
	error "IMDS unavailable after " & maxAttempts & " attempts (" & elapsed & "s elapsed) — network may not be ready"
end imdsGet

-- ============================================================
-- AWS SECRETS MANAGER
-- ============================================================

on getSecret(secretRegion, secretID, keyName)
	-- Fetch a single key from an AWS Secrets Manager SecretString (JSON).
	-- Parse with plutil — Apple-native JSON/plist tool, no third-party deps,
	-- no eval, smaller audit surface than Python. If aws CLI fails (non-zero
	-- exit) or plutil can't find the key, `do shell script` throws into the
	-- catch block; the substring "contains Error" heuristic is no longer needed.
	my logMsg("Fetching secret key: " & keyName & " from " & secretID & " in " & secretRegion)
	try
		set secretJSON to (do shell script "PATH=" & AWS_PATH & " ; aws secretsmanager get-secret-value --region " & quoted form of secretRegion & " --secret-id " & quoted form of secretID & " --query SecretString --output text")
		set val to (do shell script "echo " & quoted form of secretJSON & " | /usr/bin/plutil -extract " & keyName & " raw -")
		my logMsg("Secret key retrieved: " & keyName)
		return val
	on error errMsg
		my logMsg("ERROR getSecret(" & keyName & "): " & errMsg)
		error "getSecret(" & keyName & "): " & errMsg
	end try
end getSecret

-- ============================================================
-- JAMF API
-- ============================================================

on getJamfToken(jamfURL, apiUser, apiPass)
	-- Modern Jamf Pro API (10.49+) returns JSON:
	--   {"access_token":"...","scope":"...","token_type":"Bearer","expires_in":1200}
	-- Parse with plutil (native macOS JSON/plist tool) instead of fragile
	-- string-splitting on whitespace. The token is used immediately for the
	-- enrollment invitation call, so short token TTLs (JPMC uses ~60s) are fine.
	try
		set response to (do shell script "PATH=" & AWS_PATH & " ; curl -sf -X POST '" & jamfURL & "api/oauth/token' -H 'Content-Type: application/x-www-form-urlencoded' --data-urlencode 'client_id=" & apiUser & "' --data-urlencode 'client_secret=" & apiPass & "' --data-urlencode 'grant_type=client_credentials'")
		set tok to (do shell script "echo " & quoted form of response & " | /usr/bin/plutil -extract access_token raw -")
		if length of tok > 20 then
			my logMsg("Jamf auth: OAuth client credentials succeeded")
			return tok
		end if
		error "Token response did not contain a valid access_token: " & response
	on error errMsg
		my logMsg("ERROR: Jamf authentication failed: " & errMsg)
		error "Jamf authentication failed: " & errMsg
	end try
end getJamfToken

on createJamfInvitation(jamfURL, authToken, mgmtUser, mgmtPass)
	set expiryDate to (do shell script "date -v+2d '+%Y-%m-%d %H:%M:%S'")
	set invXML to "<?xml version=\"1.0\" encoding=\"UTF-8\"?><computer_invitation><invitation_type>DEFAULT</invitation_type><expiration_date>" & expiryDate & "</expiration_date><ssh_username>" & mgmtUser & "</ssh_username><ssh_password>" & mgmtPass & "</ssh_password><multiple_users_allowed>false</multiple_users_allowed><create_account_if_does_not_exist>true</create_account_if_does_not_exist><hide_account>true</hide_account></computer_invitation>"
	try
		set response to (do shell script "PATH=" & AWS_PATH & " ; curl -sf -X POST '" & jamfURL & "JSSResource/computerinvitations/id/id0' -H 'Content-Type: application/xml' -H 'Authorization: Bearer " & authToken & "' -d " & quoted form of invXML)
		-- Classic JSS API returns XML. Parse with xmllint XPath (native macOS)
		-- instead of fragile <invitation>...</invitation> string-splitting.
		set invID to (do shell script "echo " & quoted form of response & " | /usr/bin/xmllint --xpath 'string(//computer_invitation/invitation)' -")
		if length of invID < 1 then error "Empty invitation ID — response: " & response
		my logMsg("Enrollment invitation created: " & invID)
		return invID
	on error errMsg
		my logMsg("ERROR createJamfInvitation: " & errMsg)
		error "createJamfInvitation: " & errMsg
	end try
end createJamfInvitation

on buildEnrollmentProfile(invitationID, jamfURL)
	set payloadUUID to (do shell script "uuidgen | tr '[:upper:]' '[:lower:]'")
	set payloadID to (do shell script "uuidgen")
	return "<?xml version=\"1.0\" encoding=\"UTF-8\"?><!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\"><plist version=\"1.0\"><dict><key>PayloadUUID</key><string>" & payloadUUID & "</string><key>PayloadOrganization</key><string>JAMF Software</string><key>PayloadVersion</key><integer>1</integer><key>PayloadIdentifier</key><string>" & payloadID & "</string><key>PayloadDescription</key><string>MDM Profile</string><key>PayloadType</key><string>Profile Service</string><key>PayloadDisplayName</key><string>MDM Profile</string><key>PayloadContent</key><dict><key>Challenge</key><string>" & invitationID & "</string><key>URL</key><string>" & jamfURL & "enroll/profile</string><key>DeviceAttributes</key><array><string>UDID</string><string>PRODUCT</string><string>SERIAL</string><string>VERSION</string><string>DEVICE_NAME</string><string>COMPROMISED</string></array></dict></dict></plist>"
end buildEnrollmentProfile

-- ============================================================
-- CLICK PROFILE ROW
-- Coordinate-based double-click via cliclick. Coordinates come from
-- AppleScript's System Events position/size on the target row.
-- cliclick is cached to /Users/Shared/._jpmc-tools/ by stage-enrollment.sh
-- Phase 2 before AMI snapshot, so it is always present at boot.
-- Errors hard if cliclick is missing — staging is broken if that happens.
-- ============================================================

on clickRowWithFallback(targetRow, settingsApp)
	-- Resolve cliclick path
	set cliclick to ""
	repeat with p in {"/Users/Shared/._jpmc-tools/cliclick", "/opt/homebrew/bin/cliclick", "/usr/local/bin/cliclick"}
		try
			do shell script p & " -V 2>/dev/null"
			set cliclick to p
			exit repeat
		end try
	end repeat
	if cliclick is "" then
		my logMsg("ERROR: cliclick not found on any known path — cannot click profile row")
		error "cliclick not available"
	end if
	my logMsg("Using cliclick at: " & cliclick)

	-- Get row coordinates
	set clickX to 0
	set clickY to 0
	try
		tell application "System Events" to tell process settingsApp
			set {xPos, yPos} to position of targetRow
			set {xSz, ySz} to size of targetRow
			set clickX to xPos + (xSz div 2)
			set clickY to yPos + (ySz div 2)
		end tell
		my logMsg("Row coordinates: (" & clickX & ", " & clickY & ")")
	on error errMsg
		my logMsg("ERROR: could not get row coordinates: " & errMsg)
		error "Cannot click profile row without coordinates"
	end try

	-- Single surgical cliclick dc: — click once and hand off to clickInstallButton.
	-- clickInstallButton loops until the Install button appears and clicks it,
	-- matching AWS's approach. If the whole flow fails, the script exits with
	-- error and downstream pipeline detects failure via ENROLLMENT_STATUS:FAILED
	-- and terminates/rebuilds the instance.
	my logMsg("Row click: cliclick dc:(" & clickX & "," & clickY & ")...")
	tell application settingsApp to activate
	delay 1
	do shell script cliclick & " dc:" & clickX & "," & clickY
	delay 0.2
	my logMsg("cliclick dc executed")
end clickRowWithFallback

-- ============================================================
-- DISMISS THE INTERNAL-SSD DISK UNLOCK PROMPT
--
-- Some EC2 Mac dedicated hosts carry a FileVault-locked APFS volume group on
-- the Mac mini's own internal SSD (disk0 -> container disk3), left behind by a
-- previous tenancy. At every GUI login macOS tries to mount it, has no key,
-- and SecurityAgent presents a modal:
--
--     "Enter a password to unlock the disk 'InternalDisk - Data'"
--
-- There is no password. The volume is not ours, is not in our AMI (which
-- captures only /dev/sda1), and is not touched by any of our scripts.
--
-- It breaks enrollment two ways:
--   1. The modal owns the foreground, so cliclick's physical clicks land on it
--      instead of System Settings. Observed at 430x194 / (558,118), which
--      covers the exact coordinates we target for the MDM Profile row.
--   2. SecurityAgent serialises its auth sessions, so while this prompt holds
--      one, our own profile-install password prompt can never come forward.
--
-- WHY DISMISSAL AND NOT PREVENTION:
-- The obvious fix, an /etc/fstab "noauto" entry, does not work here. fstab is
-- read by diskarbitrationd when it decides whether to mount a filesystem, but
-- the FileVault unlock attempt happens upstream of that, so fstab is never
-- consulted for an encrypted volume. AWS suggested fstab in case
-- 178535629800759; it is the wrong mechanism for this disk. Deleting the volume
-- is also out: diskutil apfs deleteVolume commonly fails with -69888 on locked
-- volumes, and it would destroy host state we do not own.
--
-- Dismissing the dialog is the only guest-side option, and is what AWS's own
-- team recommended on 2026-08-12. The real fix has to come from AWS clearing
-- the volume during the Dedicated Host scrubbing workflow. Tracked in case
-- 179140454500900.
--
-- SecurityAgent blocks accessibility enumeration of its own window contents
-- (a deliberate anti-password-scraping measure), so "entire contents" returns
-- empty and we cannot walk the hierarchy. We address the button by name, which
-- does not require traversal, and fall back to Escape, which maps to Cancel on
-- a standard modal.
--
-- Safe to call repeatedly. On a healthy host SecurityAgent has no window and
-- this is a no-op.
-- ============================================================

on dismissDiskUnlockPrompt()
	try
		tell application "System Events"
			if exists process "SecurityAgent" then
				tell process "SecurityAgent"
					if (count of windows) > 0 then
						my logMsg("Disk unlock prompt detected — dismissing (internal SSD, not ours)")
						try
							click button "Cancel" of window 1
							my logMsg("Disk unlock prompt cancelled")
						on error
							-- Escape maps to Cancel on a standard modal sheet.
							key code 53
							my logMsg("Disk unlock prompt dismissed via Escape")
						end try
						delay 1
						-- Confirm it actually went away. If it did not, log it and
						-- continue; installProfile will fail with a clear error
						-- rather than silently clicking into the wrong window.
						if (count of windows) > 0 then
							my logMsg("WARNING: SecurityAgent still has a window after dismissal — host likely unusable for enrollment")
						end if
					end if
				end tell
			end if
		end tell
	on error errMsg
		-- Never fatal. A failure here must not stop an otherwise healthy run.
		my logMsg("WARNING: could not dismiss disk unlock prompt: " & errMsg)
	end try
end dismissDiskUnlockPrompt

-- ============================================================
-- QUIT SETUP ASSISTANT ("BUDDY")
--
-- THE PROBLEM
-- On a fresh AMI boot the per-user Setup Assistant presents a nine-pane wizard
-- and holds the foreground as com.apple.SetupAssistant. cliclick sends PHYSICAL
-- clicks, which land on whatever owns the screen, so the profile row click goes
-- to Buddy instead of System Settings. The symptom is always the same pair of
-- log lines: "MDM Profile found" succeeds, because accessibility queries do not
-- need focus, then "Install button not found after 10 seconds" fails, because
-- the click did.
--
-- WHY WE KILL IT RATHER THAN SUPPRESS IT
-- Phase 7.5 of JPMC-stage-enrollment.sh clears the loginwindow MiniBuddyLaunch
-- gate (Layer A) and pre-seeds every pane as already-seen (Layer B). Both were
-- verified, and both help, but on 2026-10-08 Buddy still appeared on
-- i-0193db62a18036255 through a second launch path that carries no
-- -MiniBuddyYes flag and has not been identified. Killing it here sidesteps the
-- need to find every launch path: whatever started it, it is gone before we
-- click.
--
-- Measured on that instance: killall succeeded, process count went to 0,
-- frontmost went to none, and it did NOT respawn.
--
-- `quit` via Apple events is not used. Buddy reasserts frontmostness
-- ("reasserting frontmostness for MiniBuddy!" appears in its log) and does not
-- honour a polite quit. killall is blunt and it works.
--
-- Nothing of value is lost. There is no Apple ID on these instances, no user to
-- onboard, and /var/db/.AppleSetupDone already marks device setup complete.
--
-- Safe to call repeatedly. On an instance where Layers A and B did their job
-- Buddy is not running and this is a no-op.
-- ============================================================

on quitSetupAssistant()
	set saRunning to false
	try
		tell application "System Events"
			if exists process "Setup Assistant" then set saRunning to true
		end tell
	on error errMsg
		-- If we cannot even query the process list, say so and carry on. A
		-- failure here must not stop an otherwise healthy run.
		my logMsg("WARNING: could not check for Setup Assistant: " & errMsg)
		return
	end try

	if not saRunning then return

	my logMsg("Setup Assistant is running and owns the foreground - quitting it")
	try
		do shell script "/usr/bin/killall 'Setup Assistant' 2>/dev/null || true"
	on error errMsg
		my logMsg("WARNING: killall Setup Assistant failed: " & errMsg)
	end try

	-- Confirm. If it comes back we want that in the log, because it means the
	-- second launch path is respawning it and the click is about to fail.
	delay 2
	set stillRunning to false
	try
		tell application "System Events"
			if exists process "Setup Assistant" then set stillRunning to true
		end tell
	end try
	if stillRunning then
		my logMsg("WARNING: Setup Assistant respawned after killall - clicks may land on it")
	else
		my logMsg("Setup Assistant quit - foreground is clear")
	end if
end quitSetupAssistant

-- ============================================================
-- PROFILE INSTALLATION — ALL macOS VERSIONS (14, 15, 26, 27)
-- Navigation is identical across all versions:
--   1. keystroke return dismisses the "Profile Downloaded" popup
--   2. URL scheme navigates directly to Device Management
-- Profile row found via fallback chain covering all known UI paths.
-- ============================================================

on installProfile(adminPass, localAdmin, settingsApp, macMajor)
	-- Defensive: bootout the macOS Diagnostics Reporter LaunchAgent so any
	-- "Your computer was restarted because of a problem" dialog (left over from
	-- the AMI's SIP-disable reboot panic) can't block System Settings UI.
	-- Idempotent — silently no-ops on healthy instances where it isn't loaded.
	try
		do shell script "launchctl bootout gui/$(id -u)/com.apple.DiagnosticsReporter 2>/dev/null || true"
	end try

	-- Defensive: clear the internal-SSD disk unlock prompt before we touch the UI.
	-- Must happen before the first open/keystroke/cliclick, otherwise our input
	-- lands on that modal instead of System Settings. See the handler above.
	my dismissDiskUnlockPrompt()

	-- Defensive: Buddy owns the foreground if it is up, and cliclick sends
	-- physical clicks. Must run before the first open/keystroke/cliclick for the
	-- same reason as dismissDiskUnlockPrompt above. See the handler for why this
	-- is a kill rather than a suppression.
	my quitSetupAssistant()

	my logMsg("Opening enrollment profile...")
	do shell script "open /tmp/enrollmentProfile.mobileconfig"
	delay 2

	-- Dismiss popup and navigate to Device Management
	-- macOS 15/26/27 show a "Profile Downloaded" popup — keystroke return dismisses it
	-- macOS 14 has no popup, so we skip keystroke return
	-- NOTE: this fires blind on anything that is not 14. If a future macOS drops
	-- the popup, the Return lands on whatever has focus instead. Verified present
	-- through 26; assumed for 27 until a real enrollment run confirms it.
	my logMsg("Dismissing popup and navigating to Device Management...")
	tell application settingsApp to activate
	delay 0.5
	if macMajor is not 14 then
		tell application "System Events" to keystroke return
		delay 2
	end if
	do shell script "open 'x-apple.systempreferences:com.apple.preferences.configurationprofiles'"
	delay 2
	tell application settingsApp to activate
	delay 1

	-- Find profile row — fallback chain covers macOS 14, 15, 26, and 27.
	-- The three paths are tried unconditionally, not gated on macMajor, so a new
	-- macOS release works automatically if its hierarchy matches an existing one.
	-- macOS 27 is expected to match the 26 path.
	--
	-- WHY THE LAST ROW AND NOT ROW 2
	-- Row 1 is the "Downloaded" section header, so the profiles start at row 2.
	-- This used to hardcode row 2, which is correct only on the first attempt.
	-- Every `open` of a .mobileconfig appends another entry to the Downloaded
	-- list and nothing removes the old ones, so after a failed attempt the list
	-- grows. Measured on i-0193db62a18036255 after nine attempts: 3 rows, being
	-- the header plus two "MDM Profile" entries both reading "Profile not
	-- installed. Double-click to review." Row 2 was therefore the OLDEST
	-- download, carrying a spent enrollment invitation, while the profile this
	-- run just created sat at the bottom. The last row is the one we wrote.
	--
	-- The row count is logged below so the next run tells us plainly how many
	-- stale downloads had accumulated.
	my logMsg("Waiting for MDM Profile row...")
	set targetRow to missing value
	set rowsSeen to 0
	repeat 20 times
		try
			-- Tahoe (macOS 26) and Golden Gate (macOS 27): outline in group 3
			tell application "System Events" to tell process settingsApp
				tell outline 1 of scroll area 1 of group 2 of scroll area 1 of group 1 of group 3 of splitter group 1 of group 1 of window 1
					set rowsSeen to count of rows
					if rowsSeen >= 2 then set targetRow to row rowsSeen
				end tell
			end tell
		end try
		-- First matching path wins. The guards matter now that rowsSeen is shared
		-- state: without them a later path could overwrite the row count that the
		-- path which actually matched had already set, and the log would lie.
		if targetRow is missing value then
			try
				-- Sequoia 15.0/15.1: outline in group 2
				tell application "System Events" to tell process settingsApp
					tell outline 1 of scroll area 1 of group 2 of scroll area 1 of group 1 of group 2 of splitter group 1 of group 1 of window 1
						set rowsSeen to count of rows
						if rowsSeen >= 2 then
							-- Probe that it really is a profile row before committing to
							-- it. If this raises, the enclosing try moves to the next path.
							get value of static text 1 of UI element 1 of row rowsSeen
							set targetRow to row rowsSeen
						end if
					end tell
				end tell
			end try
		end if
		if targetRow is missing value then
			try
				-- Sonoma (macOS 14): table in group 2 of scroll area
				tell application "System Events" to tell process settingsApp
					tell table 1 of scroll area 1 of group 2 of scroll area 1 of group 1 of group 2 of splitter group 1 of group 1 of window 1
						set rowsSeen to count of rows
						if rowsSeen >= 2 then set targetRow to row rowsSeen
					end tell
				end tell
			end try
		end if
		if targetRow is not missing value then exit repeat
		delay 0.5
	end repeat

	if targetRow is missing value then
		my logMsg("ERROR: MDM Profile row not found after 10 seconds")
		error "MDM Profile row not found"
	end if
	my logMsg("MDM Profile found - using the newest of " & (rowsSeen - 1) & " downloaded profile(s) - opening install sheet...")

	my clickRowWithFallback(targetRow, settingsApp)
	my clickInstallButton(settingsApp)
	my enterAdminPassword(adminPass)
end installProfile

-- ============================================================
-- CLICK INSTALL BUTTON
-- Handles both "Install" and "Install..." variants and the
-- confirmation sheet that follows.
-- ============================================================

on clickInstallButton(settingsApp)
	tell application "System Events" to tell process settingsApp
		-- First Install button.
		--
		-- The three named paths are tried first, on every attempt, and are
		-- unchanged. They are what macOS 14, 15 and 26 pass 20/20 with.
		--
		-- From attempt 11 onward a whole-window sweep is added as a last resort.
		-- It is deliberately NOT run on the early attempts: `entire contents`
		-- walks the full accessibility tree, which on the Device Management pane
		-- means the 39-row sidebar as well, and doing that twenty times would
		-- stretch this loop far past its nominal 10 seconds and slow down the
		-- versions that already work.
		--
		-- The sweep exists because the second path below,
		-- `button "Install…" of scroll area 1 of window 1`, provably cannot match
		-- on macOS 27. An accessibility dump of the Device Management pane on
		-- 27.0 (26A428) shows the content scroll area nested six levels down:
		--   window 1 > group 1 > splitter group 1 > group 3 > group 1 >
		--   scroll area 1
		-- so `scroll area 1 of window 1` resolves to nothing there. The path is
		-- kept because it is the one that matches on macOS 14 and 15.
		set clicked to false
		repeat with installAttempt from 1 to 20
			try
				click button "Install" of sheet 1 of window 1
				set clicked to true
				exit repeat
			end try
			try
				click button "Install…" of scroll area 1 of window 1
				set clicked to true
				exit repeat
			end try
			try
				click button 1 of group 1 of sheet 1 of window 1
				set clicked to true
				exit repeat
			end try
			if installAttempt > 10 then
				try
					repeat with el in (entire contents of window 1)
						if (role of el) as text is "AXButton" then
							set elName to ""
							try
								set elName to (name of el) as text
							end try
							if elName is "Install" or elName is "Install…" or elName is "Install..." then
								click el
								my logMsg("Install button located by whole-window sweep")
								set clicked to true
								exit repeat
							end if
						end if
					end repeat
				end try
				if clicked then exit repeat
			end if
			delay 0.5
		end repeat
		if not clicked then
			-- Wording kept verbatim. Every historical log, the README
			-- troubleshooting table and the pipeline's failure triage all key off
			-- this exact string. With the sweep running on the later attempts the
			-- real elapsed time can exceed 10 seconds; the message is a stable
			-- identifier, not a measurement.
			my logMsg("ERROR: Install button not found after 10 seconds")
			error "Install button not found after 10 seconds"
		end if
		my logMsg("Install button clicked")
		delay 0.5

		-- Confirmation Install / Enroll button
		repeat 20 times
			try
				click button "Install" of sheet 1 of window 1
				my logMsg("Confirmation Install button clicked")
				exit repeat
			end try
			try
				click button "Enroll" of sheet 1 of window 1
				my logMsg("Enroll button clicked")
				exit repeat
			end try
			delay 0.3
		end repeat
		delay 0.5
	end tell
end clickInstallButton

-- ============================================================
-- ENTER ADMIN PASSWORD IN SECURITY AGENT
-- No cliclick — uses clipboard paste + Return.
-- ============================================================

on enterAdminPassword(adminPass)
	-- Re-clear the internal-SSD unlock prompt before we trust any SecurityAgent
	-- window to be ours.
	--
	-- This matters: the wait loop below only tests that SecurityAgent HAS a
	-- window. It cannot tell which dialog that window is. If the disk unlock
	-- prompt is up, we would paste the ec2-user admin password into it and press
	-- Return. That fails harmlessly (the password cannot unlock a volume we have
	-- no key for) but the enrollment password never reaches the real prompt, the
	-- profile install goes unauthenticated, and enrollment quietly does not
	-- complete. Dismissing first means any window we find here is ours.
	my dismissDiskUnlockPrompt()

	-- Same reasoning for Buddy. If Setup Assistant respawned between the profile
	-- row click and here, it would hold the foreground while we type the admin
	-- password, and the keystrokes would go to it instead of SecurityAgent.
	-- Normally a no-op, because installProfile already cleared it.
	my quitSetupAssistant()

	-- Wait for SecurityAgent to present the password dialog
	my logMsg("Waiting for SecurityAgent password dialog...")
	set dialogReady to false
	repeat 30 times
		try
			tell application "System Events" to tell process "SecurityAgent"
				get window 1
				set dialogReady to true
				exit repeat
			end tell
		end try
		delay 0.5
	end repeat

	if not dialogReady then
		my logMsg("WARNING: SecurityAgent password dialog did not appear — profile may have installed without authentication")
		return
	end if

	my logMsg("SecurityAgent dialog ready — pasting password...")
	-- Paste password and submit
	set the clipboard to adminPass
	delay 0.3
	tell application "System Events"
		keystroke "v" using command down
		delay 0.2
		keystroke return
	end tell
	delay 0.3
	-- Clear clipboard immediately
	set the clipboard to ""
	set the clipboard to ""
	my logMsg("Password submitted to SecurityAgent")
end enterAdminPassword

-- ============================================================
-- WAIT FOR ENROLLMENT
-- Polls both CLI and UI for enrollment confirmation.
-- ============================================================

on waitForEnrollment(localAdmin, adminPass, settingsApp)
	my logMsg("Waiting for MDM enrollment to complete (up to 5 minutes)...")
	set pollCount to 0
	repeat 60 times
		set pollCount to pollCount + 1
		-- CLI check (most reliable)
		try
			if (do shell script "/usr/bin/profiles status -type enrollment | /usr/bin/grep 'enrollment: Yes'") contains "Yes" then
				my logMsg("MDM enrollment confirmed via CLI (poll " & pollCount & ")")
				try
					do shell script "killall -m 'System Settings'" user name localAdmin password adminPass with administrator privileges
				end try
				return true
			end if
		end try
		-- UI check (backup)
		try
			tell application "System Events" to tell process settingsApp
				set winText to value of static text 1 of group 1 of scroll area 1 of group 1 of group 2 of splitter group 1 of group 1 of window 1
				if winText contains "managed" then
					my logMsg("MDM enrollment confirmed via UI (poll " & pollCount & ")")
					try
						do shell script "killall -m 'System Settings'" user name localAdmin password adminPass with administrator privileges
					end try
					return true
				end if
			end tell
		end try
		if pollCount mod 6 is 0 then
			my logMsg("Still waiting for enrollment... (poll " & pollCount & "/60, " & (pollCount * 5) & "s elapsed)")
		end if
		delay 5
	end repeat
	my logMsg("WARNING: enrollment not confirmed within 5 minutes — check /Library/Logs/JPMC/EC2-Enroll.log and Jamf Pro")
	return false
end waitForEnrollment

-- ============================================================
-- CLEANUP (prodFlag = 1)
-- ============================================================

on runCleanup(localAdmin, adminPass)
	my logMsg("Running prodFlag cleanup...")
	try
		do shell script "tccutil reset Accessibility" user name localAdmin password adminPass with administrator privileges
		my logMsg("Cleanup: TCC Accessibility reset")
	end try
	try
		do shell script "tccutil reset AppleEvents" user name localAdmin password adminPass with administrator privileges
		my logMsg("Cleanup: TCC AppleEvents reset")
	end try
	try
		do shell script "sysadminctl -autologin off" user name localAdmin password adminPass with administrator privileges
		my logMsg("Cleanup: auto-login disabled")
	end try
	try
		do shell script "defaults delete com.jpmc.ec2.mdm.enrollment"
		my logMsg("Cleanup: enrollment defaults deleted")
	end try
	try
		do shell script "rm -f /tmp/enrollmentProfile.mobileconfig" user name localAdmin password adminPass with administrator privileges
		my logMsg("Cleanup: enrollment profile removed")
	end try
	try
		do shell script "rm -rf /Users/Shared/._jpmc-tools" user name localAdmin password adminPass with administrator privileges
		my logMsg("Cleanup: cliclick tools directory removed")
	end try
	try
		do shell script "rm -f /Users/Shared/JPMC-EC2-Enroll.scpt" user name localAdmin password adminPass with administrator privileges
		my logMsg("Cleanup: JPMC-EC2-Enroll.scpt removed")
	end try
	try
		do shell script "launchctl unload -w /Library/LaunchAgents/com.jpmc.ec2.mdm.enrollment.plist; rm -f /Library/LaunchAgents/com.jpmc.ec2.mdm.enrollment.plist" user name localAdmin password adminPass with administrator privileges
		my logMsg("Cleanup: LaunchAgent unloaded and removed")
	end try

	my logMsg("Cleanup complete.")
end runCleanup



-- ============================================================
-- FINAL STATUS LOGGER
-- Writes a machine-readable JSON status line to the log.
-- Downstream systems grep for ENROLLMENT_STATUS: and parse
-- the JSON to decide whether to keep or terminate the instance.
-- action: "none" = success, "terminate_and_rebuild" = failure
-- ============================================================

on logFinalStatus(statusResult, instanceRegion, jamfURL, failReason)
	-- failReason can carry raw AppleScript error text, which may contain quotes,
	-- backslashes or newlines. Escape it or the pipeline gets invalid JSON it
	-- cannot parse, and a failure would look like no status at all.
	set safeReason to my jsonEscape(my scrubSecrets(failReason))
	set instanceID to "unknown"
	try
		-- Reuse imdsGet so we get retry, --noproxy, and elapsed timing for free
		set instanceID to my imdsGet("instance-id")
	end try
	set statusJSON to ""
	if statusResult is "SUCCESS" then
		set statusJSON to "{\"status\":\"SUCCESS\",\"instance\":\"" & instanceID & "\",\"region\":\"" & instanceRegion & "\",\"mdm\":\"" & jamfURL & "\",\"script_version\":\"" & SCRIPT_VERSION & "\",\"action\":\"none\"}"
		my logMsg("ENROLLMENT_STATUS: " & statusJSON)
	else
		set statusJSON to "{\"status\":\"FAILED\",\"instance\":\"" & instanceID & "\",\"region\":\"" & instanceRegion & "\",\"reason\":\"" & safeReason & "\",\"script_version\":\"" & SCRIPT_VERSION & "\",\"action\":\"terminate_and_rebuild\"}"
		my logMsg("ENROLLMENT_STATUS: " & statusJSON)
	end if
	-- Upload status directly to S3 so test pipeline can detect completion without SSM polling
	try
		do shell script "PATH=" & AWS_PATH & " ; echo " & quoted form of statusJSON & " | aws s3 cp - s3://jpmc-ec2-enrollment-test-logs/enrollment-status/" & instanceID & ".json --region " & instanceRegion
	on error errMsg
		my logMsg("WARNING: S3 status upload failed: " & errMsg)
	end try
end logFinalStatus

-- ============================================================
-- MAIN
-- ============================================================

-- The whole enrollment flow. Called only by `on run` below, which wraps it so
-- that nothing can escape without writing a status. Kept as its own handler
-- purely so that wrapper can exist.
on runEnrollment()
	-- Detect macOS version
	set AppleScript's text item delimiters to "."
	set macMajor to (text item 1 of system version of (system info)) as integer
	set AppleScript's text item delimiters to ""
	set settingsApp to "System Settings"
	if macMajor < 13 then set settingsApp to "System Preferences"

	my logMsg("=== JPMC-EC2-Enroll v" & SCRIPT_VERSION & " started | macOS " & macMajor & " ===")

	-- Short-circuit if already enrolled
	try
		if (do shell script "/usr/bin/profiles status -type enrollment | /usr/bin/grep 'MDM enrollment: Yes'") contains "Yes" then
			my logMsg("Already enrolled — nothing to do.")
			return
		end if
	end try

	-- Read configuration
	set secretID to my getMMSecret()
	set doProdCleanup to my getProdFlag()
	my logMsg("Secret ID: " & secretID & " | prodFlag: " & doProdCleanup)

	-- Get region with retry (key fix for boot-time IMDS failure)
	my logMsg("Getting instance region...")
	set instanceRegion to my imdsGet("placement/region")
	set RUN_REGION to instanceRegion
	my logMsg("Region: " & instanceRegion)

	-- Retrieve credentials from Secrets Manager
	my logMsg("Retrieving credentials from Secrets Manager...")
	set mdmDomain to my getSecret(instanceRegion, secretID, "mdmServerDomain")
	set mdmUser to my getSecret(instanceRegion, secretID, "mdmEnrollmentUser")
	set mdmPass to my getSecret(instanceRegion, secretID, "mdmEnrollmentPassword")
	set localAdmin to my getSecret(instanceRegion, secretID, "localAdmin")
	set adminPass to my getSecret(instanceRegion, secretID, "localAdminPassword")
	-- Held only so the error handler in `on run` can redact it out of error
	-- text. See the RUN_ADMIN_PASS property comment.
	set RUN_ADMIN_PASS to adminPass
	my logMsg("All credentials retrieved.")

	-- Normalize Jamf URL
	if mdmDomain starts with "https://" then
		set jamfURL to mdmDomain
	else
		set jamfURL to "https://" & mdmDomain
	end if
	if not (jamfURL ends with "/") then set jamfURL to jamfURL & "/"
	set RUN_JAMF_URL to jamfURL
	my logMsg("Jamf URL: " & jamfURL)

	-- Set Jamf VM flag so EC2 Mac is not treated as a VM in Jamf records.
	-- Writes <false/> (proper CFBoolean) to /Library/Preferences/ — the only
	-- location the Jamf binary reads from. Absolute path on defaults matches
	-- the script's existing convention for shell tools.
	try
		do shell script "/usr/bin/defaults write /Library/Preferences/com.jamfsoftware.jamf.plist is_virtual_machine -bool false" user name localAdmin password adminPass with administrator privileges
		my logMsg("Jamf VM flag cleared (is_virtual_machine=false, system-wide plist)")
	end try

	-- Authenticate with Jamf Pro
	my logMsg("Authenticating with Jamf Pro...")
	set jamfToken to my getJamfToken(jamfURL, mdmUser, mdmPass)

	-- Generate enrollment invitation
	my logMsg("Creating enrollment invitation...")
	set mgmtUser to "_enroll-ec2"
	set mgmtPass to (do shell script "uuidgen")
	set invitationID to my createJamfInvitation(jamfURL, jamfToken, mgmtUser, mgmtPass)

	-- Write enrollment profile to disk
	my logMsg("Writing enrollment profile to /tmp/enrollmentProfile.mobileconfig...")
	do shell script "echo " & quoted form of (my buildEnrollmentProfile(invitationID, jamfURL)) & " > /tmp/enrollmentProfile.mobileconfig"
	my logMsg("Enrollment profile written.")

	-- Install profile
	my logMsg("Installing profile via UI (macOS " & macMajor & ")...")
	my installProfile(adminPass, localAdmin, settingsApp, macMajor)
	my logMsg("Profile install UI flow complete.")

	-- Wait for MDM enrollment to complete
	set enrolled to my waitForEnrollment(localAdmin, adminPass, settingsApp)

	if enrolled then
		my logMsg("=== JPMC-EC2-Enroll: SUCCESS ===")
		my logFinalStatus("SUCCESS", instanceRegion, jamfURL, "")

		-- Enable screen sharing so the instance is accessible via VNC after enrollment
		my logMsg("Enabling screen sharing...")
		try
			do shell script "launchctl enable system/com.apple.screensharing" user name localAdmin password adminPass with administrator privileges
			do shell script "launchctl load -w /System/Library/LaunchDaemons/com.apple.screensharing.plist" user name localAdmin password adminPass with administrator privileges
			my logMsg("Screen sharing enabled.")
		on error errMsg
			my logMsg("WARNING: could not enable screen sharing: " & errMsg)
		end try

		if doProdCleanup then my runCleanup(localAdmin, adminPass)
	else
		my logMsg("=== JPMC-EC2-Enroll: FAILED — enrollment did not complete. Check /Library/Logs/JPMC/EC2-Enroll.log and Jamf Pro ===")
		my logFinalStatus("FAILED", instanceRegion, jamfURL, "enrollment did not complete within 5 minutes")
	end if
end runEnrollment

-- ============================================================
-- MAIN ENTRY POINT
--
-- WHY THIS WRAPPER EXISTS
-- Every path through runEnrollment is supposed to end in logFinalStatus, which
-- writes the ENROLLMENT_STATUS line and uploads the status object to S3. An
-- uncaught AppleScript error skipped all of that: no status line, no S3 object,
-- and nothing in the staging state machine has a timeout, so its
-- test_wait_enrollment step would poll until something external intervened.
-- Observed on 2026-10-08, a run that errored out early sat for 27 minutes
-- holding a dedicated host.
--
-- With this wrapper, a crash is reported the same way a clean failure is, and
-- the pipeline can terminate and rebuild on its own.
--
-- The error is re-raised afterwards so osascript still exits non-zero and the
-- "execution error" line still appears in the log. The LaunchAgent retries on
-- its own ThrottleInterval either way; this only changes what gets reported,
-- not the retry behaviour.
-- ============================================================

on run argv
	try
		my runEnrollment()
	on error errMsg number errNum
		-- Scrub before anything else: error text from `do shell script` can echo
		-- the failing command, and some of those commands carry the admin
		-- password. Nothing unscrubbed may reach the log or S3.
		set safeMsg to my scrubSecrets(errMsg as text)
		my logMsg("=== JPMC-EC2-Enroll: ABORTED - unhandled error " & errNum & ": " & safeMsg & " ===")
		try
			my logFinalStatus("FAILED", RUN_REGION, RUN_JAMF_URL, "unhandled error " & errNum & ": " & safeMsg)
		on error statusErr
			-- If even status reporting fails the pipeline is blind, so make sure
			-- the local log records why.
			my logMsg("CRITICAL: logFinalStatus failed after an unhandled error: " & statusErr)
		end try
		set RUN_ADMIN_PASS to ""
		error safeMsg number errNum
	end try
	set RUN_ADMIN_PASS to ""
end run
