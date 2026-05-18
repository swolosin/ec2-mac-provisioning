-- JPMC-EC2-Enroll.applescript
-- Headless Jamf MDM enrollment for EC2 Mac instances
-- Supports: macOS 14 (Sonoma), 15 (Sequoia), 26 (Tahoe)
--
-- Key improvements over enroll-ec2-mac.scpt:
--   - IMDS retry logic (fixes boot-time exit code 7 failure)
--   - macOS 26 Device Management navigation (no sidebarTarget crash)
--   - No external dependencies (no cliclick)
--   - Hardcoded fallback is "mdmSecret" not "jamfSecret"
--   - Structured error logging throughout
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
-- CONFIGURATION
-- ============================================================

on getMMSecret()
	try
		return (do shell script "defaults read com.jpmc.ec2.mdm.enrollment MMSecret")
	on error
		return "mdmSecret"
	end try
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
				return (do shell script "PATH=" & awsPath & " ; curl -sf --connect-timeout 5 --max-time 10 -H 'X-aws-ec2-metadata-token: " & token & "' 'http://169.254.169.254/latest/meta-data/" & mdPath & "'")
			end if
		end try
		if attempt < maxAttempts then
			log "IMDS not ready (attempt " & attempt & "/" & maxAttempts & "), retrying in " & retryDelay & "s..."
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
	try
		set secretJSON to (do shell script "PATH=" & awsPath & " ; aws secretsmanager get-secret-value --region " & quoted form of secretRegion & " --secret-id " & quoted form of secretID & " --query SecretString --output text 2>&1")
		if secretJSON contains "Error" or secretJSON contains "error" then
			error "Secrets Manager returned error: " & secretJSON
		end if
		return (do shell script "echo " & quoted form of secretJSON & " | /usr/bin/python3 -c \"import sys,json; d=json.load(sys.stdin); print(d['" & keyName & "'])\"")
	on error errMsg
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
			return tok
		end if
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
		return tok
	on error errMsg
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
		return invID
	on error errMsg
		error "createJamfInvitation: " & errMsg
	end try
end createJamfInvitation

on buildEnrollmentProfile(invitationID, jamfURL)
	set payloadUUID to (do shell script "uuidgen | tr '[:upper:]' '[:lower:]'")
	set payloadID to (do shell script "uuidgen")
	return "<?xml version=\"1.0\" encoding=\"UTF-8\"?><!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\"><plist version=\"1.0\"><dict><key>PayloadUUID</key><string>" & payloadUUID & "</string><key>PayloadOrganization</key><string>JAMF Software</string><key>PayloadVersion</key><integer>1</integer><key>PayloadIdentifier</key><string>" & payloadID & "</string><key>PayloadDescription</key><string>MDM Profile</string><key>PayloadType</key><string>Profile Service</string><key>PayloadDisplayName</key><string>MDM Profile</string><key>PayloadContent</key><dict><key>Challenge</key><string>" & invitationID & "</string><key>URL</key><string>" & jamfURL & "enroll/profile</string><key>DeviceAttributes</key><array><string>UDID</string><string>PRODUCT</string><string>SERIAL</string><string>VERSION</string><string>DEVICE_NAME</string></array></dict></dict></plist>"
end buildEnrollmentProfile

-- ============================================================
-- PROFILE INSTALLATION: macOS 26 TAHOE
-- Opening Profiles.prefPane on Tahoe navigates directly to
-- Device Management — no sidebar navigation needed.
-- ============================================================

on installProfile_Tahoe(adminPass, localAdmin, settingsApp)
	-- Open profile — shows "Profile Downloaded" notification on Tahoe
	do shell script "open /tmp/enrollmentProfile.mobileconfig"
	delay 2

	-- Dismiss the notification (Return = blue OK button) and navigate to Device Management
	tell application "System Events" to key code 36
	delay 2

	tell application settingsApp to activate
	delay 1

	-- Wait for the profile cell in Tahoe's UI structure (group 3)
	set profileFound to false
	repeat 30 times
		try
			tell application "System Events" to tell process settingsApp
				get static text 2 of UI element 1 of row 2 of outline 1 of scroll area 1 of group 2 of scroll area 1 of group 1 of group 3 of splitter group 1 of group 1 of window 1
				set profileFound to true
				exit repeat
			end tell
		end try
		-- Some builds need a button click to enter Device Management sub-view
		try
			tell application "System Events" to tell process settingsApp
				click button 1 of group 6 of scroll area 1 of group 1 of group 2 of splitter group 1 of group 1 of window 1
			end tell
		end try
		delay 0.5
	end repeat

	if not profileFound then error "Tahoe: profile cell not found after 15 seconds"

	-- Click the profile cell to select it (two clicks = open detail view)
	tell application "System Events" to tell process settingsApp
		set profileCell to row 2 of outline 1 of scroll area 1 of group 2 of scroll area 1 of group 1 of group 3 of splitter group 1 of group 1 of window 1
		click profileCell
		delay 0.5
		click profileCell
		delay 1
	end tell

	my clickInstallButton(settingsApp)
	my enterAdminPassword(adminPass)
end installProfile_Tahoe

-- ============================================================
-- PROFILE INSTALLATION: macOS 14 (Sonoma) and 15 (Sequoia)
-- ============================================================

on installProfile_Ventura(adminPass, localAdmin, settingsApp, macMajor)
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
	do shell script "open /System/Library/PreferencePanes/Profiles.prefPane"
	delay 2

	-- macOS 14: navigate sidebar to "Profile" entry
	if macMajor is 14 then
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

	if profileCell is missing value then error "Sonoma/Sequoia: profile cell not found"

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
		if not clicked then error "Install button not found after 10 seconds"
		delay 0.5

		-- Confirmation Install / Enroll button
		repeat 20 times
			try
				click button "Install" of sheet 1 of window 1
				exit repeat
			end try
			try
				click button "Enroll" of sheet 1 of window 1
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
		log "WARNING: SecurityAgent password dialog did not appear — profile may have installed without authentication"
		return
	end if

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
end enterAdminPassword

-- ============================================================
-- WAIT FOR ENROLLMENT
-- Polls both CLI and UI for enrollment confirmation.
-- ============================================================

on waitForEnrollment(localAdmin, adminPass, settingsApp)
	log "Waiting for MDM enrollment to complete..."
	repeat 60 times
		-- CLI check (most reliable)
		try
			if (do shell script "/usr/bin/profiles status -type enrollment | /usr/bin/grep 'enrollment: Yes'") contains "Yes" then
				log "MDM enrollment confirmed."
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
					log "MDM enrollment confirmed (UI)."
					try
						do shell script "killall -m 'System Settings'" user name localAdmin password adminPass with administrator privileges
					end try
					return true
				end if
			end tell
		end try
		delay 5
	end repeat
	log "WARNING: enrollment not confirmed within 5 minutes"
	return false
end waitForEnrollment

-- ============================================================
-- CLEANUP (prodFlag = 1)
-- ============================================================

on runCleanup(localAdmin, adminPass)
	log "Running prodFlag cleanup..."
	set awsPath to "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/opt/homebrew/sbin"

	try
		do shell script "tccutil reset Accessibility" user name localAdmin password adminPass with administrator privileges
	end try
	try
		do shell script "tccutil reset AppleEvents" user name localAdmin password adminPass with administrator privileges
	end try
	try
		do shell script "sysadminctl -autologin off" user name localAdmin password adminPass with administrator privileges
	end try
	try
		do shell script "defaults delete com.jpmc.ec2.mdm.enrollment"
	end try
	try
		do shell script "rm -f /tmp/enrollmentProfile.mobileconfig" user name localAdmin password adminPass with administrator privileges
	end try
	try
		do shell script "PATH=" & awsPath & " ; export HOMEBREW_NO_AUTO_UPDATE=1 ; brew uninstall cliclick 2>/dev/null; true"
	end try
	try
		do shell script "launchctl unload -w /Library/LaunchAgents/com.jpmc.ec2.mdm.enrollment.plist" user name localAdmin password adminPass with administrator privileges
	end try

	log "Cleanup complete."
end runCleanup

-- ============================================================
-- LAUNCHAGENT INSTALLER
-- Called by stage-enrollment.sh via --launchagent --no-first-run.
-- Writes the plist directly without the firstrun dialog flow.
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
	<string>/tmp/MMErrors.log</string>
	<key>StandardOutPath</key>
	<string>/tmp/MMOutput.log</string>
</dict>
</plist>"

	try
		do shell script "launchctl unload -w /Library/LaunchAgents/com.jpmc.ec2.mdm.enrollment.plist 2>/dev/null; true" user name localAdmin password adminPass with administrator privileges
	end try
	do shell script "echo " & quoted form of plistXML & " > /Library/LaunchAgents/com.jpmc.ec2.mdm.enrollment.plist" user name localAdmin password adminPass with administrator privileges
	do shell script "chown root:wheel /Library/LaunchAgents/com.jpmc.ec2.mdm.enrollment.plist" user name localAdmin password adminPass with administrator privileges

	log return & "JPMC-EC2-Enroll LaunchAgent installed."
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

	log "JPMC-EC2-Enroll | macOS " & macMajor

	-- LaunchAgent installation mode (stage-enrollment.sh passes --launchagent --no-first-run)
	if argv contains "--launchagent" then
		set secretID to my getMMSecret()
		set region to my imdsGet("placement/region")
		set localAdmin to my getSecret(region, secretID, "localAdmin")
		set adminPass to my getSecret(region, secretID, "localAdminPassword")
		my installLaunchAgent(localAdmin, adminPass)
		return
	end if

	-- Enrollment mode (LaunchAgent fires at boot with no argv)

	-- Short-circuit if already enrolled
	try
		if (do shell script "/usr/bin/profiles status -type enrollment | /usr/bin/grep 'MDM enrollment: Yes'") contains "Yes" then
			log "Already enrolled — nothing to do."
			return
		end if
	end try

	-- Read configuration
	set secretID to my getMMSecret()
	set doProdCleanup to my getProdFlag()

	-- Get region with retry (key fix for boot-time IMDS failure)
	log "Getting instance region..."
	set instanceRegion to my imdsGet("placement/region")
	log "Region: " & instanceRegion

	-- Retrieve credentials from Secrets Manager
	log "Retrieving credentials..."
	set mdmDomain to my getSecret(instanceRegion, secretID, "mdmServerDomain")
	set mdmUser to my getSecret(instanceRegion, secretID, "mdmEnrollmentUser")
	set mdmPass to my getSecret(instanceRegion, secretID, "mdmEnrollmentPassword")
	set localAdmin to my getSecret(instanceRegion, secretID, "localAdmin")
	set adminPass to my getSecret(instanceRegion, secretID, "localAdminPassword")

	-- Normalize Jamf URL
	if mdmDomain starts with "https://" then
		set jamfURL to mdmDomain
	else
		set jamfURL to "https://" & mdmDomain
	end if
	if not (jamfURL ends with "/") then set jamfURL to jamfURL & "/"
	log "Jamf: " & jamfURL

	-- Set Jamf VM flag so EC2 Mac is not treated as a VM in Jamf records
	try
		do shell script "defaults write /Library/Preferences/com.jamfsoftware.jamf is_virtual_machine 0" user name localAdmin password adminPass with administrator privileges
		do shell script "defaults write com.jamfsoftware.jamf is_virtual_machine 0"
	end try

	-- Authenticate with Jamf Pro
	log "Authenticating with Jamf..."
	set jamfToken to my getJamfToken(jamfURL, mdmUser, mdmPass)

	-- Generate enrollment invitation
	log "Creating enrollment invitation..."
	set mgmtUser to "_enroll-ec2"
	set mgmtPass to (do shell script "uuidgen")
	set invitationID to my createJamfInvitation(jamfURL, jamfToken, mgmtUser, mgmtPass)
	log "Invitation: " & invitationID

	-- Write enrollment profile to disk
	do shell script "echo " & quoted form of (my buildEnrollmentProfile(invitationID, jamfURL)) & " > /tmp/enrollmentProfile.mobileconfig"
	log "Profile written to /tmp/enrollmentProfile.mobileconfig"

	-- Install profile (macOS version-specific UI flow)
	log "Installing profile (macOS " & macMajor & ")..."
	if macMajor >= 26 then
		my installProfile_Tahoe(adminPass, localAdmin, settingsApp)
	else
		my installProfile_Ventura(adminPass, localAdmin, settingsApp, macMajor)
	end if

	-- Wait for MDM enrollment to complete
	set enrolled to my waitForEnrollment(localAdmin, adminPass, settingsApp)

	if enrolled then
		log "JPMC-EC2-Enroll: SUCCESS"
		if doProdCleanup then my runCleanup(localAdmin, adminPass)
	else
		log "JPMC-EC2-Enroll: enrollment did not complete — check /tmp/MMErrors.log and Jamf Pro"
	end if
end run
