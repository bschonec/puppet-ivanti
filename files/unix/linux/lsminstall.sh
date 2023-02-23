#!/bin/sh

set -o nounset
#DEBUG= //debugging is determined on the whether the DEBUG variable is exported with a value (preferably 1).
[ -n "${DEBUG:-}" ] && /bin/echo "debug($$): starting $0 as $$ at" `date "+%Y%m%d+%H%M%S"`

# set up the tmp directory and move the files there just like a push.
SOURCEDIR="`/usr/bin/dirname ${0##}`"
cd $SOURCEDIR

TMPDIR="`/bin/mktemp -d /tmp/LSMINST.XXXXXX`"

for file in "$SOURCEDIR/*"
do
	/bin/cp -a $file "$TMPDIR/"
done
cd "$TMPDIR"
bail()   { /bin/echo "SIG: Received ${1:-unknown}; bailing the installation"; exit 4; }
nobail() { /bin/echo "SIG: Received ${1:-unknown}; ignoring"; }
for SIG in INT QUIT KILL; do { eval trap "\"bail $SIG\"" $SIG; } done
for SIG in HUP; do { eval trap "\"nobail $SIG\"" $SIG; } done

LDSIG="_LdCfG_InStAlL_"
for LDLOCKDIR in /var/lock /var/locks /var/tmp /tmp; do
	[ -d "$LDLOCKDIR" ] && break
done
[ -n "${DEBUG:-}" ] && /bin/echo "debug($$): LDLOCKDIR=$LDLOCKDIR"

[ -n "${DEBUG:-}" ] && /bin/echo "debug($$): testing for write permissions in $LDLOCKDIR"
if [ ! -w "$LDLOCKDIR" ]; then
	/bin/echo "ERROR: user [`/usr/bin/id -nu`] has insufficient permissions to install."
	exit 13
fi
LDLOCKFILE="$LDLOCKDIR/$LDSIG"
[ -n "${DEBUG:-}" ] && /bin/echo "debug($$): lockfile is $LDLOCKFILE"

for HEAD in /bin/head /usr/bin/head /opt/bin/head /usr/local/bin/head; do
	[ -x "$HEAD" ] && break
done
[ -n "${DEBUG:-}" ] && /bin/echo "debug($$): HEAD=$HEAD"

LDPID_LOCK=0; LDPID_OLD=0; LDPID_COUNT=0
LDPID_PARENT=$$
LDPID_SLEEPTIME=60
LDPID_MATCHES=5
ACK=0; NAK=-1

getpid() {
	let LDPID_LOCK=$(( $($HEAD -n 1 "$LDLOCKFILE" 2> /dev/null) + 0 ))
	[ $LDPID_LOCK -gt 0 ] && return $ACK
	return $NAK
}

isvalid() {
	getpid || return $NAK
	[ -d "/proc/${LDPID_LOCK}" ] || return $NAK
	let RV=$(( $(/bin/grep "$LDSIG" /proc/$LDPID_LOCK/cmdline 2> /dev/null | /usr/bin/wc -l) + 0 ))
	[ $RV -gt 0 ] || return $NAK
	return $ACK
}

ismatch() {
	local LDPID_NEW=$1
	if [ $LDPID_NEW -eq $LDPID_OLD ]; then
		let LDPID_COUNT=$(( $LDPID_COUNT + 1 ))
	else
		LDPID_OLD=$LDPID_NEW
		LDPID_COUNT=0
	fi
	return $LDPID_COUNT
}

forcelock() {
	/bin/echo $$ > "$LDLOCKFILE" || exit $?
}

trylock() {
	if [ -f "$LDLOCKFILE" ]; then
		getpid || return $NAK
		[ $LDPID_LOCK -eq $$ ] && return $ACK
		[ $LDPID_LOCK -eq $LDPID_PARENT ] || return $NAK
	fi
	forcelock
	sleep 1
	getpid || return $NAK
	[ $LDPID_LOCK -eq $$ ] || return $NAK
	return $ACK
}

unlock() {
	let LDPID_LOCK=$(( $($HEAD -n 1 "$LDLOCKFILE" 2> /dev/null) + 0 ))
	[ $LDPID_LOCK -gt 0 ] && [ $LDPID_LOCK -ne $1 ] && /bin/echo "AARGH: was $LDPID_LOCK, expected $1" && return
	RemoveFiles "$LDLOCKFILE"
}

atexit() {
	[ $# -gt 0 ] && [ -z "${EXITFUNCS:-}" ] && trap doatexit EXIT &&
				[ -n "${DEBUG:-}" ] && /bin/echo "debug($$): trapping EXIT for atexit use"
	for A; do
				[ -n "${DEBUG:-}" ] && /bin/echo "debug($$): adding atexit for [$A]"
		[ -n "${EXITFUNCS:=}" ] && EXITFUNCS="$EXITFUNCS;
"
		EXITFUNCS="${EXITFUNCS:-}$A"
	done
}

doatexit() {
	[ -n "${EXITFUNCS:=}" ] && eval $EXITFUNCS
}

spawn() {
	local CMD="\"$1\" $LDSIG $$"
	shift
	for A; do CMD="$CMD \"$A\""; done
	if [ -n "${SPAWN_EXTRAS:-}" ]; then
				[ -n "${DEBUG:-}" ] && /bin/echo "debug($$): disabling cba8 via xinetd"
		cba_disable
		TMP="(sleep 1 && /bin/sh -l -c '$CMD' ${SPAWN_EXTRAS:-}) &"
				[ -n "${DEBUG:-}" ] && /bin/echo "debug($$): cloning self into background: $TMP"
		eval $TMP
		PID=$!
		RV=$?
		[ -n "${DEBUG:-}" ] && /bin/echo "debug($$): clone pid($PID) started with $RV"
		[ -n "${DEBUG:-}" ] && /bin/echo "debug($$): saving clone pid($PID) to $STDOUT_PID"
		/bin/echo "$PID" > $STDOUT_PID
		[ -n "${DEBUG:-}" ] && /bin/echo "debug($$): setting trap to killall cba processes on exit"
		atexit cba_down
		[ -n "${DEBUG:-}" ] && /bin/echo "debug($$): requesting that task-handler exec $STDOUT_SCRIPT to finish"
		/bin/echo "### LdReExEc: $STDOUT_SCRIPT"
	else
		[ -n "${DEBUG:-}" ] && /bin/echo "debug($$): cloning self and waiting ..."
		/bin/sh -l -c "$CMD"
		[ -n "${DEBUG:-}" ] && /bin/echo "debug($$): clone pid($PID) started with $RV"
		RV=$?
	fi
	[ -n "${DEBUG:-}" ] && /bin/echo "debug($$): exiting primary with $RV"
	exit $RV
}

hup() {
	for A; do
		[ -n "${DEBUG:-}" ] && /bin/echo "debug($$): hupping $A"
		if [ -x /sbin/service ]; then
			/sbin/service $A restart
		elif [ -x /etc/init.d/$A ]; then
			/etc/init.d/$A restart
		elif [ -x /etc/rc.d/init.d/$A ]; then
			/etc/rc.d/init.d/$A restart
		elif [ -x /sbin/init.d/$A ]; then
			/sbin/init.d/$A stop
			/sbin/init.d/$A start
		else
			killall -HUP $A
		fi
	done
}

cba_thumper() {
	FROM=$1; TO=$2; VERB=$3
	XINETD_CBA_ORIG="/etc/xinetd.d/cba8"
	[ -n "${DEBUG:-}" ] && /bin/echo "debug($$): cba xinetd.d orig $XINETD_CBA_ORIG"
	XINETD_CBA_SAVE="$XINETD_CBA_ORIG.tmp"
	[ -n "${DEBUG:-}" ] && /bin/echo "debug($$): cba xinetd.d save $XINETD_CBA_SAVE"
	if [ -f "$XINETD_CBA_ORIG" ]; then
	[ -n "${DEBUG:-}" ] && /bin/echo "debug($$): changing $XINETD_CBA_ORIG to $VERB cba"
		/bin/sed -e 's/\(disable[\t ]*=[\t ]*\)$FROM/\1$TO/i' < $XINETD_CBA_ORIG > $XINETD_CBA_SAVE
		/bin/mv -f "$XINETD_CBA_SAVE" "$XINETD_CBA_ORIG"
		hup xinetd
	else
	[ -n "${DEBUG:-}" ] && /bin/echo "debug($$): $XINETD_CBA_SAVE missing; unable to $VERB cba"
	fi
}

cba_disable() {
	cba_thumper no yes disable
}

cba_down() {
	[ -n "${DEBUG:-}" ] && /bin/echo "debug($$): slow-killing all in-memory cba processes"
	(sleep 2 && killall cba) &
	[ -n "${DEBUG:-}" ] && /bin/echo "debug($$): spawned cba-killer as pid($!)"
}

cba_up() {
	cba_thumper yes no enable
}

scribble_setup() {
	[ -n "${LDPWD:-}" ] || LDPWD=$(/bin/pwd)
	STDOUT_PATH="$LDPWD/.stdout"
				[ -n "${DEBUG:-}" ] && /bin/echo "debug($$): setting default stdout path to $STDOUT_PATH"
	STDOUT_LOG="$STDOUT_PATH.log"
				[ -n "${DEBUG:-}" ] && /bin/echo "debug($$): spawn logfile is $STDOUT_LOG"
	STDOUT_SCRIPT="$STDOUT_PATH.sh"
	STDOUT_PID="$STDOUT_PATH.pid"
	STDOUT_RV="$STDOUT_PATH.rv"
}

scribble() {
	let INTERVAL=5
	[ -n "${DEBUG:-}" ] && /bin/echo "debug($$): scribbling watcher script $STDOUT_SCRIPT"
	/bin/cat - > $STDOUT_SCRIPT <<-EOF.stdout
		#!/bin/sh
		DEBUG=${DEBUG:-}
		[ -n "\${DEBUG:-}" ] && /bin/echo "debug(\$\$): starting \$0 as \$\$ at" \`date "+%Y%m%d+%H%M%S"\`
		let TIMEOUT=$(( 60*60 ))
		[ -n "\${DEBUG:-}" ] && /bin/echo "debug(\$\$): setting timeout to \$TIMEOUT"
		LDPWD="$LDPWD"
		[ -n "\${DEBUG:-}" ] && /bin/echo "debug(\$\$): working in \$LDPWD"
		STDOUT_LOG="$STDOUT_LOG"
		[ -n "\${DEBUG:-}" ] && /bin/echo "debug(\$\$): logfile will be \$STDOUT_LOG"
		STDOUT_PID="$STDOUT_PID"
		[ -n "\${DEBUG:-}" ] && /bin/echo "debug(\$\$): using pid from file \$STDOUT_PID"
		PID=\$($HEAD -n 1 \$STDOUT_PID)
		[ -n "\${DEBUG:-}" ] && /bin/echo -n "debug(\$\$): waiting on pid \$PID: "
		while [ -f "\$STDOUT_PID" ]; do
			[ -n "\${DEBUG:-}" ] && /bin/echo -n "."
			sleep $INTERVAL
			let TIMEOUT=\$(( \$TIMEOUT-$INTERVAL ))
			[ \$TIMEOUT -gt 0 ] && [ -d "/proc/\${PID}" ] || /bin/rm -f \$STDOUT_PID
		done
 		[ -n "\${DEBUG:-}" ] && /bin/echo " done"
		[ \$TIMEOUT -gt 0 ] || /bin/echo "Timed out waiting for install to finish"
 		[ -n "\${DEBUG:-}" ] && /bin/echo "debug(\$\$): dumping log \$STDOUT_LOG"
		/bin/cat \$STDOUT_LOG
		STDOUT_RV="$STDOUT_RV"
		RV=99
		[ -f "\$STDOUT_RV" ] && RV=\$($HEAD -n 1 \$STDOUT_RV)
 		[ -n "\${DEBUG:-}" ] && /bin/echo "debug(\$\$): return value from \$STDOUT_RV was \$RV"
		exit \$RV
		# vim:ts=3:sw=3:nowrap
	EOF.stdout
	if [ -f $STDOUT_SCRIPT ]; then
		/bin/chmod a+x $STDOUT_SCRIPT
	else
		/bin/echo "Creation of watcher script $STDOUT_SCRIPT failed!"
	fi
	SPAWN_EXTRAS=">$STDOUT_LOG 2>&1"
	[ -n "${DEBUG:-}" ] && /bin/echo "debug($$): SPAWN_EXTRAS=${SPAWN_EXTRAS:-}"
}

clone_exit() {
	RV="$1"
	shift
	[ -z "${STDOUT_RV:=/tmp/landesk.missing.rv}" ] && /bin/echo "no valid $STDOUT_RV"
	/bin/echo "$RV" > ${STDOUT_RV}
	[ -n "${DEBUG:-}" ] && /bin/echo "debug($$): wrote rv($RV) to $STDOUT_RV"
	for A; do { /bin/echo "$A"; } done
	/bin/echo "Exiting with return code $RV"
	exit $RV
}

DoTarball() {
	cd "$STAGING" || clone_exit 20 "Unable to change to staging dir $STAGING"
				[ -n "${DEBUG:-}" ] && /bin/echo "debug($$): changed current working directory to" `/bin/pwd`
	/bin/echo "Expanding $TARBALL ..."
	/bin/tar xz${DEBUG:+v} -f "$BASEDIR/$TARBALL.tar.gz" || clone_exit $? "Failed to extract files from tarball $TARBALL"
	/bin/echo "Installing $TARBALL ..."
	"$STAGING/$1"
	RV=$?
	/bin/rm -fr $STAGING/*
	[ $RV -eq 0 ] || clone_exit $RV "Error $RV returned from executing $TARBALL's $1"
	/bin/echo "Finished with $TARBALL ..."
	cd "$BASEDIR" || clone_exit 20 "Unable to change to base dir $BASEDIR"
				[ -n "${DEBUG:-}" ] && /bin/echo "debug($$): changed current working directory to" `/bin/pwd`
}

RemoveAgents() {
	/bin/echo "Removing agents: $@ ..."
	REDIR="2> /dev/null"
	[ -n "${DEBUG:-}" ] && REDIR="2>&1"
	for R; do
		eval /bin/rpm -ev --allmatches '"$R"' $REDIR
	done
	/bin/echo "Finished removal."
}

CheckDir() {
	local _DIR="$1"
	[ -n "${DEBUG:-}" ] && /bin/echo "debug($$): Checking for directory $_DIR"
	[ -d "$_DIR" ] || clone_exit 20 "ERROR: directory $_DIR missing"
	[ -w "$_DIR" ] || clone_exit 1 "ERROR: no write access to directory $_DIR"
}

RemoveFiles() {
	for A; do
		if [ -e "$A" ]; then
			[ -n "${DEBUG:-}" ] && /bin/echo "debug($$):   removing file $A"
			/bin/rm -f "$A" 2> /dev/null
		fi
	done
}

RemoveDirs() {
	for A; do
		if [ -d "$A" ]; then
			[ -n "${DEBUG:-}" ] && /bin/echo "debug($$):   removing directory $A"
			/bin/rmdir "$A" 2> /dev/null
		fi
	done
}

#--------------------------------InstallCerts------------------------------------------
InstallCerts() {
	if [ -n "$CERTLIST" ] && [ -d "$CERTDIR" ]; then
		[ -n "${DEBUG:-}" ] && /bin/echo "debug($$): Installing certs to $CERTDIR"
		/bin/mv -f $CERTLIST $CERTDIR/ || clone_exit $? "Unable to move certificates ($CERTLIST) to $CERTDIR"
		CERTLIST=""
	fi
}

MoveProgressBar() {
	/bin/echo "INFO: Moving progress bar"
	/bin/echo - >> /tmp/lvl1counter
}
#--------------------------------MAIN------------------------------------------
for PYTHON in /usr/bin/python /opt/bin/python /usr/local/bin/python; do
	[ -x "$PYTHON" ] && break
done
if [ ! -x "$PYTHON" ]; then
	/bin/echo "*** ERROR!  Python is required for installation"
	/bin/echo "***   It does not appear to be on this machine."
	exit 126
fi
	[ -n "${DEBUG:-}" ] && /bin/echo "debug($$): PYTHON=$PYTHON"


RemoveFiles /tmp/lvl1counter
MoveProgressBar
BASEDIR="$TMPDIR"
export BASEDIR
[ -n "${DEBUG:-}" ] && /bin/echo "debug($$): BASEDIR=$BASEDIR"
[ -n "${DEBUG:-}" ] && atexit "/bin/cp -ax \"$BASEDIR\" /tmp/.ldcfg-last"
STAGING="$BASEDIR/tmp"
[ -n "${DEBUG:-}" ] && /bin/echo "debug($$): STAGING=$STAGING"
LDINST="/usr/LANDesk"
[ -n "${DEBUG:-}" ] && /bin/echo "debug($$): LDINST=$LDINST"

CMDLINE_EXPORTS="core corelanguage LDINST"
CMDLINE_EXPORTABLES="DEBUG ABORT"
CMDLINE_EXPORTS="$CMDLINE_EXPORTS managedby"
managedby=LDSM
CMDLINE_EXPORTS="$CMDLINE_EXPORTS cronperiod"
CMDLINE_EXPORTABLES="$CMDLINE_EXPORTABLES crontime"
cronperiod=daily
crontime=1
CMDLINE_EXPORTS="$CMDLINE_EXPORTS PYTHON"
CMDLINE_EXPORTABLES="$CMDLINE_EXPORTABLES BMCPW"
WUC_SCANDIR=/usr/LANDesk/ldms/Lvl1scans
CMDLINE_EXPORTABLES="$CMDLINE_EXPORTABLES WUC_SCANDIR"
CMDLINE_EXPORTABLES="$CMDLINE_EXPORTABLES NOOEM"
RemoveDirs "$WUC_SCANDIR"
RemoveAgents sendemail sendsnmp walkup-locale-enu walkup-locale-rus walkup-locale-esp walkup-locale-chs walkup-locale-cht walkup-locale-deu walkup-locale-fra walkup-locale-jpn walkup-locale-ptb walkup-ui walkup-core-srv walkup-core-ws
RemoveFiles $LDINST/install/*
RemoveAgents ldsmmonitor lsm-server lsm-admin lsm-client lsm-common Lbridge mgmtutilsSuSE mgmtutils ldipmi megalib ldnaSuSE ldna ldsmbios smbase 
RemoveAgents vulscan ldiscan cba8SuSE cba8 pds2
RemoveDirs $LDINST/lsm $LDINST/install /var/LANDesk

for A; do
	K="${A%%=*}"
	V="${A#*=}"
	if [ "x$K" != "x$V" ]; then
		[ -n "${DEBUG:-}" ] && /bin/echo "debug($$): found $K=$V"
		for M in $CMDLINE_EXPORTABLES; do
			if [ "x$K" = "x$M" ]; then
				[ -n "${DEBUG:-}" ] && /bin/echo "debug($$): accepting override: $K=$V"
				eval $K=\"$V\"
			fi
		done
	fi
done

for M in $CMDLINE_EXPORTS $CMDLINE_EXPORTABLES; do
	[ -n "${DEBUG:-}" ] && eval /bin/echo "exporting \$M="\${$M:-}""
	eval export $M=\"\${$M:=}\"
done

[ -n "${DEBUG:-}" ] && /bin/cp -ax "$BASEDIR" /tmp/.ldcfg-last
[ -n "${DEBUG:-}" ] && [ -n "${ABORT:=}" ] && clone_exit $(( ABORT + 0 )) "ABORT requested; abort code $ABORT"

/bin/mkdir -p "$STAGING"
[ -n "${DEBUG:-}" ] && /bin/echo "debug($$): mkdir -p $STAGING returned $?"
CheckDir "$STAGING"
cd "$STAGING" || clone_exit 20 "Unable to change to staging dir $STAGING"
[ -n "${DEBUG:-}" ] && /bin/echo "debug($$): cd $STAGING returned $?"
[ -n "${DEBUG:-}" ] && /bin/echo "debug($$): changed current working directory to" `/bin/pwd`

CERTDIR="$LDINST/common/cbaroot/certs"
CERTLIST="" 
if [ ! -z "$CERTLIST" ] ; then
	cd "$BASEDIR" || clone_exit 20 "Unable to change to base dir $BASEDIR"
	[ -n "${DEBUG:-}" ] && /bin/echo "debug($$): changed current working directory to" `/bin/pwd`
	[ -n "${DEBUG:-}" ] && /bin/echo "debug($$): Protecting certs $CERTLIST ..."
	[ -n "${DEBUG:-}" ] && /bin/echo "debug($$): Changing ownership"
	/bin/chown root:root $CERTLIST || clone_exit $? "Unable to set ownership of $CERTLIST"
	[ -n "${DEBUG:-}" ] && /bin/echo "debug($$): Changing rights"
	/bin/chmod 444 $CERTLIST || clone_exit $? "Unable to set file permissions of $CERTLIST"
	InstallCerts
fi

/bin/touch /etc/ldiscnux.conf
export lvl1Install=1
TARBALL="baseclient" DoTarball setup.sh
if [ ! -z "$CERTLIST" ] ; then
	CheckDir $CERTDIR
	InstallCerts
fi
[ -n "${DEBUG:-}" ] && /bin/echo "debug($$): re-enabling cba, if necessary"
cba_up

cd "$BASEDIR" || clone_exit 21 "Unable to change to base dir $BASEDIR"
[ -n "${DEBUG:-}" ] && /bin/echo "debug($$): changed current working directory to" `/bin/pwd`

RULES_DIR="$LDINST/common/cbaroot/alert"
RULES="./*.garbage"  # this intened to generate no ouput
RV=`ls -1 $RULES 2> /dev/null | wc -l`
if [ $RV -le 0 ]; then
	[ -n "${DEBUG:-}" ] && /bin/echo "debug($$): No rule-sets to install."
else
	CheckDir $RULES_DIR
	[ -n "${DEBUG:-}" ] && /bin/echo "debug($$): Installing rule-sets:" $RULES
	cd "$BASEDIR" || clone_exit 22 "Unable to change to base dir $BASEDIR"
	[ -n "${DEBUG:-}" ] && /bin/echo "debug($$): changed current working directory to" `/bin/pwd`
	[ -n "${DEBUG:-}" ] && /bin/echo "debug($$): Changing ownership"
	/bin/chown root:root $RULES || clone_exit $? "Unable to change ownership of $RULES"
	[ -n "${DEBUG:-}" ] && /bin/echo "debug($$): Changing rights"
	/bin/chmod 644 $RULES || clone_exit $? "Unable to change file permissions of $RULES"
	[ -n "${DEBUG:-}" ] && /bin/echo "debug($$): Installing rule-sets"
	/bin/mv -f $RULES "$RULES_DIR" || clone_exit $? "Unable to move rulesets ($RULES) to $RULES_DIR"
fi

CRUMBDIR="$LDINST/ldms/scan"
[ -n "${DEBUG:-}" ] && /bin/echo "debug($$): create crumb dir $CRUMBDIR"
/bin/mkdir -p "$CRUMBDIR"
[ -n "${DEBUG:-}" ] && /bin/echo "debug($$): mkdir -p $CRUMBDIR returned $?"
CheckDir "$CRUMBDIR"

LINKDIR="/etc/LDScan"
[ -n "${DEBUG:-}" ] && /bin/echo "debug($$): create link $LINKDIR to $CRUMBDIR"
ln -sfn "$CRUMBDIR" "$LINKDIR"
MoveProgressBar
TARBALL="lddetectsystem" DoTarball setup.sh
MoveProgressBar
TARBALL="monitoring" DoTarball setup.sh
cd "$BASEDIR" || clone_exit 23 "Unable to change to base dir $BASEDIR"
[ -n "${DEBUG:-}" ] && /bin/echo "debug($$): changed current working directory to" `/bin/pwd`
MRULES="$BASEDIR/*.ruleset.monitor.xml"
RV=`ls -1 $MRULES 2> /dev/null | wc -l`
if [ $RV -le 0 ]; then
	[ -n "${DEBUG:-}" ] && /bin/echo "debug($$): No rule-sets to install."
else
	MRULES_DIR="$LDINST/ldsm/LDClient"
	CheckDir $MRULES_DIR
	MRULES_FILENAME="$MRULES_DIR/masterconfig.ruleset.monitor.xml"
	if [ -e "$MRULES_FILENAME" ]; then
		[ -n "${DEBUG:-}" ] && /bin/echo "debug($$): Deleting rule-set:" $MRULES_FILENAME
		RemoveFiles "$MRULES_FILENAME"
	fi
	[ -n "${DEBUG:-}" ] && /bin/echo "debug($$): Installing rule-sets:" $MRULES
	cd "$BASEDIR" || clone_exit 24 "Unable to change to base dir $BASEDIR"
	[ -n "${DEBUG:-}" ] && /bin/echo "debug($$): changed current working directory to" `/bin/pwd`
	[ -n "${DEBUG:-}" ] && /bin/echo "debug($$): Changing ownership"
	/bin/chown root:root $MRULES || clone_exit $? "Unable to change ownership of $MRULES"
	[ -n "${DEBUG:-}" ] && /bin/echo "debug($$): Changing rights"
	/bin/chmod 644 $MRULES || clone_exit $? "Unable to change file permissions of $MRULES"
	[ -n "${DEBUG:-}" ] && /bin/echo "debug($$): Installing rule-sets"
	/bin/mv -f $MRULES "$MRULES_FILENAME" || clone_exit $? "Unable to move rulesets ($MRULES) to $MRULES_FILENAME"
fi
MoveProgressBar
TARBALL="vulscan" DoTarball setup.sh
/bin/mkdir -p "$WUC_SCANDIR"
[ -n "${DEBUG:-}" ] && /bin/echo "debug($$): mkdir -p $WUC_SCANDIR returned $?"
CheckDir "$WUC_SCANDIR"
MoveProgressBar
#TARBALL="walkup" DoTarball setup.sh

OEMDIR="$LDINST/oem"
/bin/mkdir -p "$OEMDIR"
[ -n "${DEBUG:-}" ] && /bin/echo "debug($$): mkdir -p $OEMDIR returned $?"
CheckDir "$OEMDIR"

#OEMSCRIPT="$BASEDIR/oemadd.py"
#if [ -z "${NOOEM:-}" ]; then
#				[ -n "${DEBUG:-}" ] && /bin/echo "debug($$): local OEM software install enabled"
#	cd "$BASEDIR" || clone_exit 65 "Unable to change to base dir $BASEDIR"
#				[ -n "${DEBUG:-}" ] && /bin/echo "debug($$): changed current working directory to" `/bin/pwd`
#	if [ -f "$OEMSCRIPT" ]; then
#		$PYTHON "$OEMSCRIPT"
#				[ -n "${DEBUG:-}" ] && /bin/echo "debug($$): $OEMSCRIPT exited with $?"
#		/bin/cat $BASEDIR/oemadd.log
#	else
#		clone_exit 66 "$OEMSCRIPT not present"
#	fi
#else
#				[ -n "${DEBUG:-}" ] && /bin/echo "debug($$): local OEM software install disabled"
#fi

COLLECTOR="/etc/init.d/collector"
[ -x "$COLLECTOR" ] && $COLLECTOR restart

LDISCAN="$LDINST/common/ldiscan.sh"
MoveProgressBar
[ -n "${DEBUG:-}" ] && /bin/echo "debug($$): checking for $LDISCAN so we can do a final inventory"
[ -x "$LDISCAN" ] && $LDISCAN || /bin/echo "Missing executable $LDISCAN"
MoveProgressBar
MoveProgressBar
[ -n "${DEBUG:-}" ] && /bin/echo "debug($$): final $LDISCAN returned $?"
# restart the collector so that the ui will work.
/etc/init.d/collector restart 
MoveProgressBar

/bin/echo "Notifying core of installation ..."
CBA_ALERT=$LDINST/common/alert
if [ -x "$CBA_ALERT" ]; then
	[ -n "${DEBUG:-}" ] && /bin/echo "debug($$): Kicking off CBA-start alert"
	"$CBA_ALERT" -f internal.cba8.install.complete
else
	clone_exit 2 "ERROR: alert mechanism ($CBA_ALERT) missing"
fi
MoveProgressBar
clone_exit 0 "Successfully finished installing client."
# vim:ts=3:sw=3:nowrap
