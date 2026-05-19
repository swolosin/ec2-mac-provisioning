-- JPMC-EC2-Enroll.applescript
-- Headless Jamf MDM enrollment for EC2 Mac instances
-- Supports: macOS 14 (Sonoma), 15 (Sequoia), 26 (Tahoe)
--
-- Key improvements over enroll-ec2-mac.scpt:
--   - IMDS retry logic (fixes boot-time exit code 7 failure)
--   - macOS 26 Device Management navigation (no sidebarTarget crash)
--   - No external dependencies (no cliclick)
--   - Hardcoded fallback is "mdmSecret" not "jamfSecret"
--   - Timestamped logging to /Library/Logs/JPMC/
--
-- Configuration:
--   defaults write com.jpmc.ec2.mdm.enrollment MMSecret "your-secret-id"
--   defaults write com.jpmc.ec2.mdm.enrollment prodFlag "1"
--
-- Used by stage-enrollment.sh:
--   osascript JPMC-EC2-Enroll.scpt --launchagent --no-first-run
--
-- Invoked at boot by LaunchAgent (no argv):
--   osascript /Users/Shared/JPMC-EC2-Enroll.scpt

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
-- Fixes the boot-time timing issue where curl returns exit code 7
-- because the network stack isn't fully ready when the LaunchAgent fires.
-- ============================================================

on imdsGet(mdPath)
	set maxAttempts to 6
	set retryDelay to 5
	set awsPath to "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
	repeat with attempt from 1 to maxAttempts
		try
			set token to (do shell script "PATH=" & awsPath & " ; curl -sf --connect-timeout 5 --max-time 10 -X PUT 'http://169.254.169.254/latest/api/token' -H 'X-aws-ec2-metadata-token-ttl-seconds: 300'")
			if length of token > 10 then
				set mdResult to (do shell script "PATH=" & awsPath & " ; curl -sf --connect-timeout 5 --max-time 10 -H 'X-aws-ec2-metadata-token: " & token & "' 'http://169.254.169.254/latest/meta-data/" & mdPath & "'")
				my logMsg("IMDS ok (attempt " & attempt & "/" & maxAttempts & "): " & mdPath & " = " & mdResult)
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
	error "IMDS unavailable after " & maxAttempts & " attempts — network may not be ready"
end imdsGet

-- ============================================================
-- AWS SECRETS MANAGER
-- ============================================================

on getSecret(secretRegion, secretID, keyName)
	set awsPath to "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/opt/homebrew/sbin"
	my logMsg("Fetching secret key: " & keyName & " from " & secretID & " in " & secretRegion)
	try
		set secretJSON to (do shell script "PATH=" & awsPath & " ; aws secretsmanager get-secret-value --region " & quoted form of secretRegion & " --secret-id " & quoted form of secretID & " --query SecretString --output text 2>&1")
		if secretJSON contains "Error" or secretJSON contains "error" then
			error "Secrets Manager returned error: " & secretJSON
		end if
		set val to (do shell script "echo " & quoted form of secretJSON & " | /usr/bin/python3 -c \"import sys,json; d=json.load(sys.stdin); print(d['" & keyName & "'])\"")
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
	set awsPath to "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
	-- Try OAuth client credentials first (modern Jamf)
	try
		set response to (do shell script "PATH=" & awsPath & " ; curl -sf -X POST '" & jamfURL & "api/oauth/token' -H 'Content-Type: application/x-www-form-urlencoded' --data-urlencode 'client_id=" & apiUser & "' --data-urlencode 'client_secret=" & apiPass & "' --data-urlencode 'grant_type=client_credentials' 2>&1")
		if response contains "access_token" then
			set AppleScript's text item delimiters to "access_token\":\""
			set tok to text item 2 of response
			set AppleScript's text item delimiters to "\""
			set tok to text item 1 of tok
			set AppleScript's text item delimiters to ""
			my logMsg("Jamf auth: OAuth client credentials succeeded")
			return tok
		end if
	on error errMsg
		my logMsg("Jamf OAuth attempt failed: " & errMsg & " — trying Basic auth")
	end try
	-- Fall back to Basic auth
	try
		set b64 to (do shell script "/usr/bin/printf '" & apiUser & ":" & apiPass & "' | /usr/bin/base64")
		set response to (do shell script "PATH=" & awsPath & " ; curl -sf -X POST '" & jamfURL & "api/v1/auth/token' -H 'Authorization: Basic " & b64 & "' 2>&1")
		set AppleScript's text item delimiters to "\"token\":\""
		set tok to text item 2 of response
		set AppleScript's text item delimiters to "\""
		set tok to text item 1 of tok
		set AppleScript's text item delimiters to ""
		my logMsg("Jamf auth: Basic auth succeeded")
		return tok
	on error errMsg
		my logMsg("ERROR: Jamf authentication failed: " & errMsg)
		error "Jamf authentication failed: " & errMsg
	end try
end getJamfToken

on createJamfInvitation(jamfURL, authToken, mgmtUser, mgmtPass)
	set awsPath to "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
	set expiryDate to (do shell script "date -v+2d '+%Y-%m-%d %H:%M:%S'")
	set invXML to "<?xml version=\"1.0\" encoding=\"UTF-8\"?><computer_invitation><invitation_type>DEFAULT</invitation_type><expiration_date>" & expiryDate & "</expiration_date><ssh_username>" & mgmtUser & "</ssh_username><ssh_password>" & mgmtPass & "</ssh_password><multiple_users_allowed>false</multiple_users_allowed><create_account_if_does_not_exist>true</create_account_if_does_not_exist><hide_account>true</hide_account></computer_invitation>"
	try
		set response to (do shell script "PATH=" & awsPath & " ; curl -sf -X POST '" & jamfURL & "JSSResource/computerinvitations/id/id0' -H 'Content-Type: application/xml' -H 'Authorization: Bearer " & authToken & "' -d " & quoted form of invXML & " 2>&1")
		set AppleScript's text item delimiters to "<invitation>"
		set invID to text item 2 of response
		set AppleScript's text item delimiters to "</"
		set invID to text item 1 of invID
		set AppleScript's text item delimiters to ""
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
-- PROFILE INSTALLATION: macOS 26 TAHOE
-- 1. Open mobileconfig — "Profile Downloaded" dialog appears and
--    auto-dismisses in ~10 seconds. Do not interact with it.
-- 2. Navigate directly to Device Management via URL scheme.
-- 3. Wait for profile row to appear, then double-click it.
-- ============================================================

on installProfile_Tahoe(adminPass, localAdmin, settingsApp)
	my logMsg("Tahoe: opening enrollment profile...")
	do shell script "open /tmp/enrollmentProfile.mobileconfig"
	delay 2

	-- Click the blue button on the "Profile Downloaded" popup.
	-- This navigates Settings directly to Device Management with the profile ready.
	my logMsg("Tahoe: clicking blue button on Profile Downloaded popup...")
	tell application settingsApp to activate
	delay 0.5
	tell application "System Events" to keystroke return
	delay 2

	-- Navigate to Device Management as a safety net in case Return landed elsewhere
	my logMsg("Tahoe: ensuring Device Management is open...")
	tell application "System Settings"
		reveal pane id "com.apple.Profiles-Settings.extension"
		activate
	end tell
	delay 2

	-- Wait for the MDM Profile row to appear in the outline
	my logMsg("Tahoe: waiting for MDM Profile row...")
	set profileFound to false
	repeat 20 times
		try
			tell application "System Events" to tell process settingsApp
				tell group 1 of window 1
					tell splitter group 1
						tell group 3
							tell group 1
								tell scroll area 1
									tell group 2
										tell scroll area 1
											tell outline 1
												if (count of rows) >= 2 then
													set profileFound to true
												end if
											end tell
										end tell
									end tell
								end tell
							end tell
						end tell
					end tell
				end tell
			end tell
		end try
		if profileFound then exit repeat
		delay 0.5
	end repeat

	if not profileFound then
		my logMsg("ERROR: Tahoe: no profile rows found in Device Management outline")
		error "Tahoe: MDM Profile not found"
	end if

	-- Find the profile row by name, fall back to first available row
	set targetRow to missing value
	set targetIdx to missing value
	set foundByName to false
	tell application "System Events" to tell process settingsApp
		tell group 1 of window 1
			tell splitter group 1
				tell group 3
					tell group 1
						tell scroll area 1
							tell group 2
								tell scroll area 1
									tell outline 1
										set rowCount to count of rows
										repeat with r from 1 to rowCount
											try
												if (value of static text 1 of UI element 1 of row r) contains "MDM Profile" then
													set targetRow to row r
													set targetIdx to r
													set foundByName to true
													exit repeat
												end if
											end try
											try
												if (title of row r) contains "MDM Profile" then
													set targetRow to row r
													set targetIdx to r
													set foundByName to true
													exit repeat
												end if
											end try
										end repeat
										if targetRow is missing value then
											set targetRow to row 1
											set targetIdx to 1
										end if
									end tell
								end tell
							end tell
						end tell
					end tell
				end tell
			end tell
		end tell
	end tell

	if targetRow is missing value then
		my logMsg("ERROR: Tahoe: could not identify profile row")
		error "Tahoe: profile row not found"
	end if

	if foundByName then
		my logMsg("Tahoe: MDM Profile found by name at row " & targetIdx & " — selecting and opening...")
	else
		my logMsg("Tahoe: WARNING: MDM Profile not found by name — falling back to row " & targetIdx)
	end if

	-- Select then double-click to open the install sheet
	tell application "System Events" to tell process settingsApp
		tell group 1 of window 1
			tell splitter group 1
				tell group 3
					tell group 1
						tell scroll area 1
							tell group 2
								tell scroll area 1
									tell outline 1
										select targetRow
										delay 0.5
										click targetRow
										delay 0.3
										click targetRow
									end tell
								end tell
							end tell
						end tell
					end tell
				end tell
			end tell
		end tell
	end tell
	delay 1

	my clickInstallButton(settingsApp)
	my enterAdminPassword(adminPass)
end installProfile_Tahoe

-- ============================================================
-- PROFILE INSTALLATION: macOS 14 (Sonoma) and 15 (Sequoia)
-- ============================================================

on installProfile_Ventura(adminPass, localAdmin, settingsApp, macMajor)
	my logMsg("Sonoma/Sequoia (macOS " & macMajor & "): opening enrollment profile...")
	-- Open profile, quit Settings, reopen to Profiles pane cleanly
	do shell script "open /tmp/enrollmentProfile.mobileconfig"
	delay 1
	try
		tell application settingsApp to quit
		delay 1
	end try
	try
		do shell script "killall -m BluetoothSetupAssistant 2>/dev/null; true"
	end try
	my logMsg("Sonoma/Sequoia: opening Profiles prefPane...")
	do shell script "open /System/Library/PreferencePanes/Profiles.prefPane"
	delay 2

	-- macOS 14: navigate sidebar to "Profile" entry
	if macMajor is 14 then
		my logMsg("Sonoma: navigating sidebar for Profile entry...")
		tell application "System Events" to tell process settingsApp
			repeat with sidebarIdx from 2 to 8
				try
					if (value of static text 1 of UI element 1 of row sidebarIdx of outline 1 of scroll area 1 of group 1 of splitter group 1 of group 1 of window 1) contains "Profile" then
						click (UI element 1 of row sidebarIdx of outline 1 of scroll area 1 of group 1 of splitter group 1 of group 1 of window 1)
						delay 1
						exit repeat
					end if
				end try
			end repeat
		end tell
	end if

	-- Wait for profile cell to appear
	my logMsg("Sonoma/Sequoia: waiting for profile cell...")
	set profileCell to missing value
	repeat 30 times
		try
			-- Sequoia 15.2+ path
			tell application "System Events" to tell process settingsApp
				click button 1 of group 6 of scroll area 1 of group 1 of group 2 of splitter group 1 of group 1 of window 1
			end tell
			delay 0.5
		end try
		try
			-- Sequoia 15.0 / 15.1 path
			tell application "System Events" to tell process settingsApp
				get value of static text 1 of UI element 1 of row 2 of outline 1 of scroll area 1 of group 2 of scroll area 1 of group 1 of group 2 of splitter group 1 of group 1 of window 1
				set profileCell to row 2 of outline 1 of scroll area 1 of group 2 of scroll area 1 of group 1 of group 2 of splitter group 1 of group 1 of window 1
				exit repeat
			end tell
		end try
		try
			-- Sonoma / Sequoia table path
			tell application "System Events" to tell process settingsApp
				get value of static text 1 of UI element 1 of row 2 of table 1 of scroll area 1 of group 1 of scroll area 1 of group 1 of group 1 of group 2 of splitter group 1 of group 1 of window 1
				set profileCell to row 2 of table 1 of scroll area 1 of group 1 of scroll area 1 of group 1 of group 1 of group 2 of splitter group 1 of group 1 of window 1
				exit repeat
			end tell
		end try
		delay 0.5
	end repeat

	if profileCell is missing value then
		my logMsg("ERROR: Sonoma/Sequoia: profile cell not found after 15 seconds")
		error "Sonoma/Sequoia: profile cell not found"
	end if
	my logMsg("Sonoma/Sequoia: profile cell found — clicking to open detail view...")

	-- Click the profile cell
	tell application "System Events" to tell process settingsApp
		click profileCell
		delay 0.5
		click profileCell
		delay 1
	end tell

	my clickInstallButton(settingsApp)
	my enterAdminPassword(adminPass)
end installProfile_Ventura

-- ============================================================
-- CLICK INSTALL BUTTON
-- Handles both "Install" and "Install..." variants and the
-- confirmation sheet that follows.
-- ============================================================

on clickInstallButton(settingsApp)
	tell application "System Events" to tell process settingsApp
		-- First Install button
		set clicked to false
		repeat 20 times
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
			delay 0.5
		end repeat
		if not clicked then
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
		do shell script "launchctl unload -w /Library/LaunchAgents/com.jpmc.ec2.mdm.enrollment.plist" user name localAdmin password adminPass with administrator privileges
		my logMsg("Cleanup: LaunchAgent unloaded and removed")
	end try

	my logMsg("Cleanup complete.")
end runCleanup

-- ============================================================
-- LAUNCHAGENT INSTALLER
-- Called by stage-enrollment.sh via --launchagent --no-first-run.
-- Writes the plist directly without the firstrun dialog flow.
-- Log directory /Library/Logs/JPMC/ is created by stage-enrollment.sh.
-- ============================================================

on installLaunchAgent(localAdmin, adminPass)
	set scriptPath to "/Users/Shared/JPMC-EC2-Enroll.scpt"
	set plistXML to "<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">
<plist version=\"1.0\">
<dict>
	<key>KeepAlive</key>
	<false/>
	<key>Label</key>
	<string>com.jpmc.ec2.mdm.enrollment</string>
	<key>ProgramArguments</key>
	<array>
		<string>/usr/bin/osascript</string>
		<string>" & scriptPath & "</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>StandardErrorPath</key>
	<string>/Library/Logs/JPMC/EC2-Enroll.log</string>
	<key>StandardOutPath</key>
	<string>/Library/Logs/JPMC/EC2-Enroll-out.log</string>
</dict>
</plist>"

	try
		do shell script "launchctl unload -w /Library/LaunchAgents/com.jpmc.ec2.mdm.enrollment.plist 2>/dev/null; true" user name localAdmin password adminPass with administrator privileges
	end try
	do shell script "echo " & quoted form of plistXML & " > /Library/LaunchAgents/com.jpmc.ec2.mdm.enrollment.plist" user name localAdmin password adminPass with administrator privileges
	do shell script "chown root:wheel /Library/LaunchAgents/com.jpmc.ec2.mdm.enrollment.plist" user name localAdmin password adminPass with administrator privileges

	my logMsg("JPMC-EC2-Enroll LaunchAgent installed.")
end installLaunchAgent

-- ============================================================
-- MAIN
-- ============================================================

on run argv
	-- Detect macOS version
	set AppleScript's text item delimiters to "."
	set macMajor to (text item 1 of system version of (system info)) as integer
	set AppleScript's text item delimiters to ""
	set settingsApp to "System Settings"
	if macMajor < 13 then set settingsApp to "System Preferences"

	my logMsg("=== JPMC-EC2-Enroll started | macOS " & macMajor & " ===")

	-- LaunchAgent installation mode (stage-enrollment.sh passes --launchagent --no-first-run)
	if argv contains "--launchagent" then
		my logMsg("Mode: LaunchAgent install")
		set secretID to my getMMSecret()
		my logMsg("Secret ID: " & secretID)
		set region to my imdsGet("placement/region")
		set localAdmin to my getSecret(region, secretID, "localAdmin")
		set adminPass to my getSecret(region, secretID, "localAdminPassword")
		my installLaunchAgent(localAdmin, adminPass)
		my logMsg("=== LaunchAgent install complete ===")
		return
	end if

	-- Enrollment mode (LaunchAgent fires at boot with no argv)
	my logMsg("Mode: enrollment")

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
	my logMsg("Region: " & instanceRegion)

	-- Retrieve credentials from Secrets Manager
	my logMsg("Retrieving credentials from Secrets Manager...")
	set mdmDomain to my getSecret(instanceRegion, secretID, "mdmServerDomain")
	set mdmUser to my getSecret(instanceRegion, secretID, "mdmEnrollmentUser")
	set mdmPass to my getSecret(instanceRegion, secretID, "mdmEnrollmentPassword")
	set localAdmin to my getSecret(instanceRegion, secretID, "localAdmin")
	set adminPass to my getSecret(instanceRegion, secretID, "localAdminPassword")
	my logMsg("All credentials retrieved.")

	-- Normalize Jamf URL
	if mdmDomain starts with "https://" then
		set jamfURL to mdmDomain
	else
		set jamfURL to "https://" & mdmDomain
	end if
	if not (jamfURL ends with "/") then set jamfURL to jamfURL & "/"
	my logMsg("Jamf URL: " & jamfURL)

	-- Set Jamf VM flag so EC2 Mac is not treated as a VM in Jamf records
	try
		do shell script "defaults write /Library/Preferences/com.jamfsoftware.jamf is_virtual_machine 0" user name localAdmin password adminPass with administrator privileges
		do shell script "defaults write com.jamfsoftware.jamf is_virtual_machine 0"
		my logMsg("Jamf VM flag cleared (is_virtual_machine=0)")
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

	-- Install profile (macOS version-specific UI flow)
	my logMsg("Installing profile via UI (macOS " & macMajor & ")...")
	if macMajor >= 26 then
		my installProfile_Tahoe(adminPass, localAdmin, settingsApp)
	else
		my installProfile_Ventura(adminPass, localAdmin, settingsApp, macMajor)
	end if
	my logMsg("Profile install UI flow complete.")

	-- Wait for MDM enrollment to complete
	set enrolled to my waitForEnrollment(localAdmin, adminPass, settingsApp)

	if enrolled then
		my logMsg("=== JPMC-EC2-Enroll: SUCCESS ===")

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
	end if
end run
