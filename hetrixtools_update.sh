#!/bin/bash
#
#
#	HetrixTools Server Monitoring Agent - Update Script
#	Copyright 2015 - 2026 @  HetrixTools
#	For support, please open a ticket on our website https://hetrixtools.com
#
#
#		DISCLAIMER OF WARRANTY
#
#	The Software is provided "AS IS" and "WITH ALL FAULTS," without warranty of any kind, 
#	including without limitation the warranties of merchantability, fitness for a particular purpose and non-infringement. 
#	HetrixTools makes no warranty that the Software is free of defects or is suitable for any particular purpose. 
#	In no event shall HetrixTools be responsible for loss or damages arising from the installation or use of the Software, 
#	including but not limited to any indirect, punitive, special, incidental or consequential damages of any character including, 
#	without limitation, damages for loss of goodwill, work stoppage, computer failure or malfunction, or any and all other commercial damages or losses. 
#	The entire risk as to the quality and performance of the Software is borne by you, the user.
#
#

# Set PATH
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Prefer IPv4 when fetching from GitHub, fallback to IPv6 if needed
github_wget() {
	local url=${!#}
	if ! wget -4 "$@"; then
		echo "IPv4 request failed for $url, retrying with IPv6..."
		if ! wget -6 "$@"; then
			echo "ERROR: Unable to fetch $url via IPv4 or IPv6." >&2
			return 1
		fi
	fi
	return 0
}

# Detect whether the currently installed agent is configured to run as
# 'root' or as the 'hetrixtools' user, using the existing cron/systemd setup.
detect_agent_run_user() {
	local detected_user=""
	local systemd_unit=""

	if command -v crontab >/dev/null 2>&1; then
		if crontab -u root -l 2>/dev/null | grep -q 'hetrixtools_agent.sh'; then
			detected_user=root
		elif id -u hetrixtools >/dev/null 2>&1 && crontab -u hetrixtools -l 2>/dev/null | grep -q 'hetrixtools_agent.sh'; then
			detected_user=hetrixtools
		fi
	fi

	if [ -z "$detected_user" ]; then
		for systemd_unit in \
			/etc/systemd/system/hetrixtools_agent.service \
			/lib/systemd/system/hetrixtools_agent.service \
			/usr/lib/systemd/system/hetrixtools_agent.service
		do
			if [ -f "$systemd_unit" ]; then
				detected_user=$(awk -F= '/^User=/{print $2; exit}' "$systemd_unit" 2>/dev/null)
				if [ -z "$detected_user" ]; then
					detected_user=$(awk '/hetrixtools_systemd_launcher\.sh/ {print $NF; exit}' "$systemd_unit" 2>/dev/null)
				fi
				if [ -z "$detected_user" ]; then
					detected_user=root
				fi
				break
			fi
		done
	fi

	if [ "$detected_user" != "root" ] && [ "$detected_user" != "hetrixtools" ]; then
		if id -u hetrixtools >/dev/null 2>&1; then
			detected_user=hetrixtools
		else
			detected_user=root
		fi
	fi

	echo "$detected_user"
}

# Old Agent Path
AGENT="/etc/hetrixtools/hetrixtools_agent.sh"

# Old Config Path
CONFIG="/etc/hetrixtools/hetrixtools.cfg"

BRANCH="master"
BRANCH_SET=0
FORCE_UPDATE=0

# Parse arguments
for ARG in "$@"
do
	case "$ARG" in
		-force|--force)
			FORCE_UPDATE=1
			;;
		-h|--help)
			echo "Usage: $0 [-force|--force] [branch]"
			exit 0
			;;
		-*)
			echo "ERROR: Unknown option: $ARG" >&2
			echo "Usage: $0 [-force|--force] [branch]" >&2
			exit 1
			;;
		*)
			if [ "$BRANCH_SET" -eq 1 ]
			then
				echo "ERROR: Multiple branches specified." >&2
				echo "Usage: $0 [-force|--force] [branch]" >&2
				exit 1
			fi
			BRANCH=$ARG
			BRANCH_SET=1
			;;
	esac
done

extract_agent_version() {
	sed -n "s/^[[:space:]]*Version[[:space:]]*=[[:space:]]*['\"]\\{0,1\\}\\([^'\"[:space:]#]*\\).*/\\1/p" "$1" 2>/dev/null | head -n 1
}

cleanup_update_tmp_dir() {
	if [ -n "$UPDATE_TMP_DIR" ] && [ -d "$UPDATE_TMP_DIR" ]
	then
		rm -rf "$UPDATE_TMP_DIR"
	fi
	if [ -n "$STAGED_AGENT" ] && [ -f "$STAGED_AGENT" ]
	then
		rm -f "$STAGED_AGENT"
	fi
	if [ -n "$STAGED_CONFIG" ] && [ -f "$STAGED_CONFIG" ]
	then
		rm -f "$STAGED_CONFIG"
	fi
	if [ -n "$STAGED_CONFIG" ] && [ -f "$STAGED_CONFIG.tmp" ]
	then
		rm -f "$STAGED_CONFIG.tmp"
	fi
}

copy_file_metadata() {
	local reference_file=$1
	local target_file=$2
	local file_owner=""
	local file_mode=""

	if [ ! -e "$reference_file" ]
	then
		return 0
	fi

	if ! chown --reference="$reference_file" "$target_file" >/dev/null 2>&1
	then
		file_owner=$(stat -c '%u:%g' "$reference_file" 2>/dev/null)
		if [ -n "$file_owner" ]
		then
			chown "$file_owner" "$target_file" >/dev/null 2>&1 || return 1
		fi
	fi

	if ! chmod --reference="$reference_file" "$target_file" >/dev/null 2>&1
	then
		file_mode=$(stat -c '%a' "$reference_file" 2>/dev/null)
		if [ -n "$file_mode" ]
		then
			chmod "$file_mode" "$target_file" >/dev/null 2>&1 || return 1
		fi
	fi
}

prepare_staged_file() {
	local source_file=$1
	local target_file=$2
	local staged_file=$3

	if ! cp "$source_file" "$staged_file"
	then
		return 1
	fi

	if id -u hetrixtools >/dev/null 2>&1
	then
		chown hetrixtools:hetrixtools "$staged_file" >/dev/null 2>&1 || return 1
		chmod 700 "$staged_file" >/dev/null 2>&1 || return 1
	elif [ -e "$target_file" ]
	then
		copy_file_metadata "$target_file" "$staged_file" || true
	fi

	return 0
}

extract_config_value() {
	local key=$1
	local file=$2

		awk -v key="$key" '
			$0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
				sub("^[[:space:]]*" key "[[:space:]]*=[[:space:]]*", "")
				gsub(/^[[:space:]]+|[[:space:]]+$/, "")
				if (($0 ~ /^".*"$/) || ($0 ~ /^'\''.*'\''$/)) {
					$0 = substr($0, 2, length($0) - 2)
			}
			print
			exit
		}
	' "$file" | tr -d '\r'
}

replace_config_line() {
	local file=$1
	local old_line=$2
	local new_line=$3
	local tmp_file="$file.tmp"

	if awk -v old_line="$old_line" -v new_line="$new_line" '
		$0 == old_line { print new_line; next }
		{ print }
	' "$file" > "$tmp_file"
	then
		if [ -e "$file" ]
		then
			copy_file_metadata "$file" "$tmp_file" || true
		fi
		if ! mv "$tmp_file" "$file"
		then
			echo "ERROR: Failed to update the staged agent configuration." >&2
			rm -f "$tmp_file"
			exit 1
		fi
	else
		echo "ERROR: Failed to update the staged agent configuration." >&2
		rm -f "$tmp_file"
		exit 1
	fi
}

# Check for wget
echo "Checking wget..."
command -v wget >/dev/null 2>&1 || { echo "ERROR: wget is required to run this agent." >&2; exit 1; }
echo "... done."

echo "Using $BRANCH branch..."
# Check if update script is run by root
echo "Checking root privileges..."
if [ "$EUID" -ne 0 ]
	then echo "ERROR: Please run the update script as root."
	exit
fi
echo "... done."

# Look for the old agent
echo "Looking for the old agent..."
if [ -f "$AGENT" ]
then
	echo "... done."
else
	echo "ERROR: No old agent found. Nothing to update." >&2; exit 1;
fi

UPDATE_TMP_DIR=$(mktemp -d /tmp/hetrixtools_update.XXXXXX 2>/dev/null || mktemp -d)
if [ -z "$UPDATE_TMP_DIR" ] || [ ! -d "$UPDATE_TMP_DIR" ]
then
	echo "ERROR: Unable to create a temporary update directory." >&2
	exit 1
fi
trap cleanup_update_tmp_dir EXIT
NEW_AGENT="$UPDATE_TMP_DIR/hetrixtools_agent.sh"
NEW_CONFIG="$UPDATE_TMP_DIR/hetrixtools.cfg"
STAGED_AGENT="$AGENT.update.$$"
STAGED_CONFIG="$CONFIG.update.$$"

# Fetching the available agent to check its version
echo "Checking available agent version..."
if ! github_wget -t 1 -T 30 -qO "$NEW_AGENT" https://raw.githubusercontent.com/hetrixtools/agent/$BRANCH/hetrixtools_agent.sh
then
	echo "ERROR: Failed to download the agent script from GitHub for branch/tag $BRANCH." >&2
	exit 1
fi
CURRENT_VERSION=$(extract_agent_version "$AGENT")
AVAILABLE_VERSION=$(extract_agent_version "$NEW_AGENT")
DISPLAY_CURRENT_VERSION=$CURRENT_VERSION
DISPLAY_AVAILABLE_VERSION=$AVAILABLE_VERSION
if [ -z "$DISPLAY_CURRENT_VERSION" ]
then
	DISPLAY_CURRENT_VERSION="unknown"
fi
if [ -z "$DISPLAY_AVAILABLE_VERSION" ]
then
	DISPLAY_AVAILABLE_VERSION="unknown"
fi
echo "Installed agent version: $DISPLAY_CURRENT_VERSION"
echo "Available agent version: $DISPLAY_AVAILABLE_VERSION"
if [ -z "$CURRENT_VERSION" ]
then
	echo "WARNING: Unable to determine the installed agent version; proceeding with update." >&2
fi
if [ -z "$AVAILABLE_VERSION" ]
then
	echo "WARNING: Unable to determine the available agent version; proceeding with update." >&2
fi
if [ -n "$CURRENT_VERSION" ] && [ -n "$AVAILABLE_VERSION" ] && [ "$CURRENT_VERSION" = "$AVAILABLE_VERSION" ]
then
	if [ "$FORCE_UPDATE" -eq 1 ]
	then
		echo "Force update requested; reinstalling the current version."
	else
		echo "HetrixTools agent is already at latest version ($CURRENT_VERSION). Use -force option to reinstall the current version."
		exit 0
	fi
else
	echo "Version differs or could not be determined; updating the agent."
fi
echo "... done."

# Check for required system utilities (either cron or systemd)
echo "Checking system utilities..."
USE_CRON=0
USE_SYSTEMD=0
SYSTEMCTL_AVAILABLE=0
EXISTING_CRON=0
CRON_ACTIVE=0
if command -v systemctl >/dev/null 2>&1; then
	if [ -d /run/systemd/system ] || systemctl list-units >/dev/null 2>&1; then
		SYSTEMCTL_AVAILABLE=1
	fi
fi
if command -v crontab >/dev/null 2>&1; then
	if crontab -u root -l 2>/dev/null | grep -q 'hetrixtools_agent.sh'; then
		EXISTING_CRON=1
	elif id -u hetrixtools >/dev/null 2>&1 && crontab -u hetrixtools -l 2>/dev/null | grep -q 'hetrixtools_agent.sh'; then
		EXISTING_CRON=1
	fi
	CRON_ACTIVE=$EXISTING_CRON
	if command -v pgrep >/dev/null 2>&1 && [ "$CRON_ACTIVE" -ne 1 ]; then
		for cron_process in cron crond cronie systemd-cron fcron busybox-cron busybox-crond; do
			if pgrep -x "$cron_process" >/dev/null 2>&1 || pgrep -f "$cron_process" >/dev/null 2>&1; then
				CRON_ACTIVE=1
				break
			fi
		done
	fi
	if [ "$CRON_ACTIVE" -ne 1 ] && [ "$SYSTEMCTL_AVAILABLE" -eq 1 ]; then
		for cron_service in cron crond cronie systemd-cron fcron busybox-cron busybox-crond; do
			if systemctl is-active --quiet "$cron_service"; then
				CRON_ACTIVE=1
				break
			fi
		done
		if [ "$CRON_ACTIVE" -ne 1 ]; then
			if systemctl list-units --type=service --state=active 2>/dev/null | grep -Ei '\bcron(ie)?\b' >/dev/null 2>&1; then
				CRON_ACTIVE=1
			fi
		fi
	fi
	if [ "$CRON_ACTIVE" -ne 1 ] && [ "$SYSTEMCTL_AVAILABLE" -ne 1 ]; then
		CRON_ACTIVE=1
	fi
	if [ "$CRON_ACTIVE" -eq 1 ]; then
		USE_CRON=1
	fi
fi
if [ "$USE_CRON" -ne 1 ] && [ "$SYSTEMCTL_AVAILABLE" -eq 1 ] && command -v systemd-run >/dev/null 2>&1; then
	USE_SYSTEMD=1
fi
if [ "$USE_CRON" -ne 1 ] && [ "$USE_SYSTEMD" -ne 1 ]; then
	echo "ERROR: Neither cron nor systemd with systemd-run is available to schedule the agent." >&2
	exit 1
fi
echo "... done."

# Look for the old config
echo "Looking for the old config file..."
if [ -f "$CONFIG" ]
then
	echo "... done."
	echo "Upgrading from v2..."
	EXTRACT=$CONFIG
else
	echo "... done."
	echo "Upgrading from v1..."
	EXTRACT=$AGENT
fi

# Detect the current runtime user before recreating cron/systemd entries later.
echo "Detecting the current agent runtime user..."
AGENT_RUNTIME_USER=$(detect_agent_run_user)
echo "... done."

# Extract data from the old agent
echo "Extracting configs from the old agent..."
# SID (Server ID)
SID=$(extract_config_value 'SID' "$EXTRACT")
# Network Interfaces
NetworkInterfaces=$(extract_config_value 'NetworkInterfaces' "$EXTRACT")
# Ignored Disks
IgnoredDisksLine=$(grep '^IgnoredDisks=' "$EXTRACT")
# Check Services
CheckServices=$(extract_config_value 'CheckServices' "$EXTRACT")
# Check Software RAID Health
CheckSoftRAID=$(extract_config_value 'CheckSoftRAID' "$EXTRACT" | tr -d '[:space:]')
if [ "$CheckSoftRAID" != "1" ]
then
	CheckSoftRAID=0
fi
# Check Drive Health
CheckDriveHealth=$(extract_config_value 'CheckDriveHealth' "$EXTRACT" | tr -d '[:space:]')
if [ "$CheckDriveHealth" != "1" ]
then
	CheckDriveHealth=0
fi
# Check Reboot Required
CheckReboot=$(extract_config_value 'CheckReboot' "$EXTRACT" | tr -d '[:space:]')
if [ "$CheckReboot" != "0" ]
then
	CheckReboot=1
fi
# RunningProcesses
RunningProcesses=$(extract_config_value 'RunningProcesses' "$EXTRACT" | tr -d '[:space:]')
if [ "$RunningProcesses" != "1" ]
then
	RunningProcesses=0
fi
echo "... done."
# Port Connections
ConnectionPorts=$(extract_config_value 'ConnectionPorts' "$EXTRACT")
if [ -f "$CONFIG" ]
then
	# Custom Variables
	CustomVars=$(extract_config_value 'CustomVars' "$EXTRACT")
	# Secured Connection
	SecuredConnection=$(extract_config_value 'SecuredConnection' "$EXTRACT")
	# CollectEveryXSeconds
	CollectEveryXSeconds=$(extract_config_value 'CollectEveryXSeconds' "$EXTRACT")
	# OutgoingPings
	OutgoingPings=$(extract_config_value 'OutgoingPings' "$EXTRACT")
	# OutgoingPingsCount
	OutgoingPingsCount=$(extract_config_value 'OutgoingPingsCount' "$EXTRACT")
fi

# Fetching the new config file
echo "Fetching the new config file..."
if ! github_wget -t 1 -T 30 -qO "$NEW_CONFIG" https://raw.githubusercontent.com/hetrixtools/agent/$BRANCH/hetrixtools.cfg
then
	echo "ERROR: Failed to download the agent configuration from GitHub." >&2
	exit 1
fi
echo "... done."

# Preparing the new agent and config file
echo "Preparing the new agent and config file..."
if ! prepare_staged_file "$NEW_AGENT" "$AGENT" "$STAGED_AGENT"
then
	echo "ERROR: Failed to prepare the new agent script." >&2
	exit 1
fi
if ! prepare_staged_file "$NEW_CONFIG" "$CONFIG" "$STAGED_CONFIG"
then
	echo "ERROR: Failed to prepare the new agent configuration." >&2
	exit 1
fi
echo "... done."

# Inserting Server ID (SID) into the agent config
echo "Inserting Server ID (SID) into agent config..."
replace_config_line "$STAGED_CONFIG" 'SID=""' "SID=\"$SID\""
echo "... done."

# Check if any network interfaces are specified
echo "Checking if any network interfaces are specified..."
if [ ! -z "$NetworkInterfaces" ]
then
	echo "Network interfaces found, inserting them into the agent config..."
	replace_config_line "$STAGED_CONFIG" 'NetworkInterfaces=""' "NetworkInterfaces=\"$NetworkInterfaces\""
fi
echo "... done."

# Check if any disks should be ignored
echo "Checking if any disks should be ignored..."
if [ -n "$IgnoredDisksLine" ]
then
	echo "Ignored disks found, inserting them into the agent config..."
	if awk -v replacement="$IgnoredDisksLine" '
		/^IgnoredDisks=/ { print replacement; next }
		{ print }
	' "$STAGED_CONFIG" > "$STAGED_CONFIG.tmp"
	then
		if [ -e "$STAGED_CONFIG" ]
		then
			copy_file_metadata "$STAGED_CONFIG" "$STAGED_CONFIG.tmp" || true
		fi
		mv "$STAGED_CONFIG.tmp" "$STAGED_CONFIG"
	else
		rm -f "$STAGED_CONFIG.tmp"
		echo "WARNING: Failed to preserve IgnoredDisks during update." >&2
	fi
fi
echo "... done."

# Check if any services are to be monitored
echo "Checking if any services should be monitored..."
if [ ! -z "$CheckServices" ]
then
	echo "Services found, inserting them into the agent config..."
	replace_config_line "$STAGED_CONFIG" 'CheckServices=""' "CheckServices=\"$CheckServices\""
fi
echo "... done."

# Check if Software RAID should be monitored
echo "Checking if software RAID should be monitored..."
if [ "$CheckSoftRAID" = "1" ]
then
	echo "Enabling software RAID monitoring in the agent config..."
	replace_config_line "$STAGED_CONFIG" 'CheckSoftRAID=0' 'CheckSoftRAID=1'
fi
echo "... done."

# Check if Drive Health should be monitored
echo "Checking if Drive Health should be monitored..."
if [ "$CheckDriveHealth" = "1" ]
then
	echo "Enabling Drive Health monitoring in the agent config..."
	replace_config_line "$STAGED_CONFIG" 'CheckDriveHealth=0' 'CheckDriveHealth=1'
fi
echo "... done."

# Check if reboot required should be checked
echo "Checking if reboot required should be checked..."
if [ "$CheckReboot" = "0" ]
then
	echo "Disabling reboot required check in the agent config..."
	replace_config_line "$STAGED_CONFIG" 'CheckReboot=1' 'CheckReboot=0'
fi
echo "... done."

# Check if 'View running processes' should be enabled
echo "Checking if 'View running processes' should be enabled..."
if [ "$RunningProcesses" = "1" ]
then
	echo "Enabling 'View running processes' in the agent config..."
	replace_config_line "$STAGED_CONFIG" 'RunningProcesses=0' 'RunningProcesses=1'
fi
echo "... done."

# Check if any ports to monitor number of connections on
echo "Checking if any ports to monitor number of connections on..."
if [ ! -z "$ConnectionPorts" ]
then
	echo "Ports found, inserting them into the agent config..."
	replace_config_line "$STAGED_CONFIG" 'ConnectionPorts=""' "ConnectionPorts=\"$ConnectionPorts\""
fi
echo "... done."

# Check if any custom variables are specified
echo "Checking if any custom variables are specified..."
if [ ! -z "$CustomVars" ]
then
	echo "Custom variables found, inserting them into the agent config..."
	replace_config_line "$STAGED_CONFIG" 'CustomVars="custom_variables.json"' "CustomVars=\"$CustomVars\""
fi
echo "... done."

# Check if secured connection is enabled
echo "Checking if secured connection is enabled..."
if [ ! -z "$SecuredConnection" ]
then
	echo "Inserting secured connection in the agent config..."
	replace_config_line "$STAGED_CONFIG" 'SecuredConnection=1' "SecuredConnection=$SecuredConnection"
fi
echo "... done."

# Check CollectEveryXSeconds
echo "Checking CollectEveryXSeconds..."
if [ ! -z "$CollectEveryXSeconds" ]
then
	echo "Inserting CollectEveryXSeconds in the agent config..."
	replace_config_line "$STAGED_CONFIG" 'CollectEveryXSeconds=3' "CollectEveryXSeconds=$CollectEveryXSeconds"
fi

# Check OutgoingPings
echo "Checking OutgoingPings..."
if [ ! -z "$OutgoingPings" ]
then
	echo "Inserting OutgoingPings in the agent config..."
	replace_config_line "$STAGED_CONFIG" 'OutgoingPings=""' "OutgoingPings=\"$OutgoingPings\""
fi

# Check OutgoingPingsCount
echo "Checking OutgoingPingsCount..."
if [ ! -z "$OutgoingPingsCount" ]
then
	echo "Inserting OutgoingPingsCount in the agent config..."
	replace_config_line "$STAGED_CONFIG" 'OutgoingPingsCount=20' "OutgoingPingsCount=$OutgoingPingsCount"
fi

# Atomically install the staged agent and config file
echo "Installing the new agent and config file..."
if ! mv "$STAGED_CONFIG" "$CONFIG"
then
	echo "ERROR: Failed to install the new agent configuration." >&2
	exit 1
fi
if ! mv "$STAGED_AGENT" "$AGENT"
then
	echo "ERROR: Failed to install the new agent script." >&2
	exit 1
fi
echo "... done."
rm -f /etc/hetrixtools/hetrixtools_reboot_check.cache >/dev/null 2>&1

# Refresh scheduler configuration (prefer cron when available)
if [ "$USE_CRON" -eq 1 ]
then
	echo "Ensuring cron schedule is configured..."
	CRON_TARGET_USER=""
	if crontab -u root -l 2>/dev/null | grep -q 'hetrixtools_agent.sh'; then
		CRON_TARGET_USER=root
	elif id -u hetrixtools >/dev/null 2>&1 && crontab -u hetrixtools -l 2>/dev/null | grep -q 'hetrixtools_agent.sh'; then
		CRON_TARGET_USER=hetrixtools
	fi
	if [ -z "$CRON_TARGET_USER" ]; then
		CRON_TARGET_USER=$AGENT_RUNTIME_USER
	fi
	if [ "$CRON_TARGET_USER" = "hetrixtools" ] && ! id -u hetrixtools >/dev/null 2>&1; then
		CRON_TARGET_USER=root
	fi
	crontab -u root -l 2>/dev/null | grep -v 'hetrixtools_agent.sh' | crontab -u root - >/dev/null 2>&1
	if id -u hetrixtools >/dev/null 2>&1; then
		crontab -u hetrixtools -l 2>/dev/null | grep -v 'hetrixtools_agent.sh' | crontab -u hetrixtools - >/dev/null 2>&1
	fi
	if [ "$CRON_TARGET_USER" = "root" ]; then
		crontab -u root -l 2>/dev/null | { cat; echo "* * * * * bash /etc/hetrixtools/hetrixtools_agent.sh >> /etc/hetrixtools/hetrixtools_cron.log 2>&1"; } | crontab -u root - >/dev/null 2>&1
	else
		crontab -u hetrixtools -l 2>/dev/null | { cat; echo "* * * * * bash /etc/hetrixtools/hetrixtools_agent.sh >> /etc/hetrixtools/hetrixtools_cron.log 2>&1"; } | crontab -u hetrixtools - >/dev/null 2>&1
	fi
	if [ "$SYSTEMCTL_AVAILABLE" -eq 1 ]; then
		systemctl stop hetrixtools_agent.timer >/dev/null 2>&1
		systemctl disable hetrixtools_agent.timer >/dev/null 2>&1
		systemctl stop hetrixtools_agent.service >/dev/null 2>&1
		systemctl disable hetrixtools_agent.service >/dev/null 2>&1
		systemctl daemon-reload >/dev/null 2>&1
	fi
	rm -f /etc/systemd/system/hetrixtools_agent.timer >/dev/null 2>&1
	rm -f /etc/systemd/system/hetrixtools_agent.service >/dev/null 2>&1
	rm -f /etc/hetrixtools/hetrixtools_systemd_launcher.sh >/dev/null 2>&1
	rm -f /usr/local/sbin/hetrixtools_systemd_launcher.sh >/dev/null 2>&1
	echo "... done."
elif [ "$USE_SYSTEMD" -eq 1 ]
then
	echo "Ensuring systemd service and timer schedule..."
	SERVICE_USER=$AGENT_RUNTIME_USER
	if [ "$SERVICE_USER" = "hetrixtools" ] && ! id -u hetrixtools >/dev/null 2>&1; then
		SERVICE_USER=root
	fi
	if command -v crontab >/dev/null 2>&1; then
		crontab -u root -l 2>/dev/null | grep -v 'hetrixtools_agent.sh' | crontab -u root - >/dev/null 2>&1
		if id -u hetrixtools >/dev/null 2>&1; then
			crontab -u hetrixtools -l 2>/dev/null | grep -v 'hetrixtools_agent.sh' | crontab -u hetrixtools - >/dev/null 2>&1
		fi
	fi
	cat > /usr/local/sbin/hetrixtools_systemd_launcher.sh <<-'EOF'
#!/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

ServiceUser=$1
if [ "$ServiceUser" != "root" ] && [ "$ServiceUser" != "hetrixtools" ]
then
	ServiceUser=root
fi

if ! command -v systemd-run >/dev/null 2>&1
then
	echo "ERROR: systemd-run is required for systemd timer scheduling." >&2
	exit 1
fi

RunID=$(date +%s)-$$
UnitName="hetrixtools_agent_${RunID}"
AgentCommand='exec /bin/bash /etc/hetrixtools/hetrixtools_agent.sh >> /etc/hetrixtools/hetrixtools_cron.log 2>&1'

if [ "$ServiceUser" = "root" ]
then
	systemd-run --quiet --collect --unit="$UnitName" /bin/bash -c "$AgentCommand"
else
	systemd-run --quiet --collect --unit="$UnitName" --property="User=$ServiceUser" /bin/bash -c "$AgentCommand"
fi
EOF
	chown root:root /usr/local/sbin/hetrixtools_systemd_launcher.sh >/dev/null 2>&1
	chmod 700 /usr/local/sbin/hetrixtools_systemd_launcher.sh
	cat > /etc/systemd/system/hetrixtools_agent.service <<-EOF
		[Unit]
		Description=HetrixTools Agent Launcher

		[Service]
		Type=oneshot
		ExecStart=/bin/bash /usr/local/sbin/hetrixtools_systemd_launcher.sh $SERVICE_USER
		EOF
	cat > /etc/systemd/system/hetrixtools_agent.timer <<-EOF
		[Unit]
		Description=Runs HetrixTools agent every minute

		[Timer]
		OnBootSec=1min
		OnCalendar=*-*-* *:*:00 UTC
		AccuracySec=1s
		RandomizedDelaySec=0
		Persistent=true
		Unit=hetrixtools_agent.service

		[Install]
		WantedBy=timers.target
		EOF
	systemctl daemon-reload >/dev/null 2>&1
	systemctl enable --now hetrixtools_agent.timer >/dev/null 2>&1
	systemctl restart hetrixtools_agent.timer >/dev/null 2>&1
	echo "... done."
fi

# Killing any running hetrixtools agents
echo "Making sure no hetrixtools agent scripts are currently running..."
ps aux | grep -ie hetrixtools_agent.sh | awk '{print $2}' | xargs -r kill -9
echo "... done."

# Assign permissions
echo "Assigning permissions for the hetrixtools user..."
if id -u hetrixtools >/dev/null 2>&1
then
	chown -R hetrixtools:hetrixtools /etc/hetrixtools
	chmod -R 700 /etc/hetrixtools
fi

# Cleaning up update file
echo "Cleaning up the update file..."
if [ -f $0 ]
then
	rm -f $0
fi
echo "... done."

# All done
echo "HetrixTools agent update completed. It can take up to two (2) minutes for new data to be collected."
