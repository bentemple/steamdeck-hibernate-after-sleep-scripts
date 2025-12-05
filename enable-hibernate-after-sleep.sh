#!/bin/bash

#Config
TargetSwapFileSizeInGbs=20
HibernateDelay="61min"

#Script

ScriptDir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)

TargetSwapFileSizeInBytes=$(($TargetSwapFileSizeInGbs*1073741824))

#Force will force some files to be written and system files to be loaded. Useful for updating any of the systemd unit files, as will copy and reinstall them.
if [[ "$1" == "--force" ]]; then
	FORCE=1
else
	FORCE=0
fi

swapFileSize=$(stat -c %s /home/swapfile)
if [[ $swapFileSize != $TargetSwapFileSizeInBytes ]]; then
	echo "Swapfile wrong size, rebuilding"

	swapoff -a
	dd if=/dev/zero of=/home/swapfile bs=1G count=$TargetSwapFileSizeInGbs
	mkswap /home/swapfile
	swapon /home/swapfile
	e4defrag /home/swapfile
else
	echo "Swapfile correct size"
fi

SwapFileUUID=$(findmnt -no UUID -T /home/swapfile)
SwapFileOffset=$(filefrag -v /home/swapfile | awk '$1=="0:" {print substr($4, 1, length($4)-2)}')

RESUME="`cat /etc/default/grub|grep "GRUB_CMDLINE_LINUX_DEFAULT"|grep "resume=/dev/disk/by-uuid"`"
if [[ "$RESUME" == "" ]]; then
	sed -i "s/\\(GRUB_CMDLINE_LINUX_DEFAULT.*\\)\"\$/\\1 resume=\\/dev\\/disk\\/by-uuid\\/$SwapFileUUID resume_offset=$SwapFileOffset\"/" /etc/default/grub
	update-grub
	echo "Grub patched."
else
	echo "Grub already has resume set"
fi

GrubResumeUUID=$(cat /etc/default/grub|grep "GRUB_CMDLINE_LINUX_DEFAULT"|sed -e 's/.*resume=\/dev\/disk\/by-uuid\/\([^ ]*\).*/\1/')
GrubResumeOffset=$(cat /etc/default/grub|grep "GRUB_CMDLINE_LINUX_DEFAULT"|sed -e 's/.*resume_offset=\([0-9]*\).*/\1/')

if [[ "$GrubResumeUUID" != "$SwapFileUUID" || "$GrubResumeOffset" != "$SwapFileOffset" ]]; then
	echo "Grub uuid/offset not correct, updating to match calculated values."

	echo "Grub resume UUID: $GrubResumeUUID"
	echo "Calculated UUID: $SwapFileUUID"
	echo "Grub resume Offset: $GrubResumeOffset"
	echo "Calculated Offset: $SwapFileOffset"

	sed -i "s/\\(.*GRUB_CMDLINE_LINUX_DEFAULT.*resume=\\/dev\\/disk\\/by-uuid\\/\\)[^ ]*\\( resume_offset=\\)[0-9]*\\(.*\\)/\\1$SwapFileUUID\\2$SwapFileOffset\\3/" /etc/default/grub
	update-grub
	echo "Grub patched."
fi


echo 
if [[ ! -f "/etc/systemd/system/systemd-logind.service.d/override.conf" ]]; then
	echo "[Service]" >> /etc/systemd/system/systemd-logind.service.d/override.conf
	echo "Environment=SYSTEMD_BYPASS_HIBERNATION_MEMORY_CHECK=1" >> /etc/systemd/system/systemd-logind.service.d/override.conf
	systemctl daemon-reload
else
	echo "Systemd-logind settings already set."
fi

echo 
if [[ ! -f "/etc/systemd/system/fix-bluetooth-resume.service" || $FORCE == 1 ]]; then
	#Ensure bluetooth resume service file points at the correct script location
	BTScriptDir=$(cat $ScriptDir/fix-bluetooth-resume.service|grep ExecStart|sed 's/ExecStart=\(.*\)\/fix-bluetooth.sh$/\1/')
	if [[ "$BTScriptDir" != "$ScriptDir" ]]; then
		echo "Bluetooth ScriptDir not set to correct location, updating to $ScriptDir"
		sed -i "s|ExecStart=.*|ExecStart=$ScriptDir/fix-bluetooth.sh|" $ScriptDir/fix-bluetooth-resume.service
	fi
	cp $ScriptDir/fix-bluetooth-resume.service /etc/systemd/system/fix-bluetooth-resume.service
	systemctl daemon-reload
	systemctl enable fix-bluetooth-resume.service
	echo "Enabled fix bluetooth on resume from hibernation."
else
	echo "Fix bluetooth on resume already setup"
fi

echo 
if [[ ! -f "/etc/systemd/system/mark-boot-good-after-resume.service" || $FORCE == 1 ]]; then
	#Ensure mark-boot-good after resume service file points at the correct script location
	MBGScriptDir=$(cat $ScriptDir/mark-boot-good-after-resume.service|grep ExecStart|sed 's/ExecStart=\(.*\)\/mark-boot-good.sh$/\1/')
	if [[ "$MBGScriptDir" != "$ScriptDir" ]]; then
		echo "MarkBootGood ScriptDir not set to correct location, updating to $ScriptDir"
		sed -i "s|ExecStart=.*|ExecStart=$ScriptDir/mark-boot-good.sh|" $ScriptDir/mark-boot-good-after-resume.service
	fi
	cp $ScriptDir/mark-boot-good-after-resume.service /etc/systemd/system/mark-boot-good-after-resume.service
	systemctl daemon-reload
	systemctl enable mark-boot-good-after-resume.service
	echo "Enabled marking boot good after resume from hibernation."
else
	echo "Marking boot good after resume already setup"

fi

echo 

if [[ ! -f "/etc/systemd/system/systemd-suspend.service" ]]; then
	ln -s /usr/lib/systemd/system/systemd-suspend-then-hibernate.service /etc/systemd/system/systemd-suspend.service
	echo "Enabled suspend then hibernate"
	systemctl daemon-reload
else
	echo "Suspend then hibernate already enabled."
fi

echo

echo "[Sleep]
AllowSuspend=yes
AllowHibernation=yes
AllowSuspendThenHibernate=yes
HibernateDelaySec=$HibernateDelay" > /etc/systemd/sleep.conf
echo "Updated hibernation after suspend delay to $HibernateDelay"
