#!/usr/bin/env bash
#
# Copyright (c) 2020 Matthias Rabe <mrabe@hatdev.de>
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
#
V=0.0.2

set -e

CONFFILE="/etc/secureboot/config"
if [ "$USER" != "root" ] && [ -e "./conf/devel" ]; then
	CONFFILE="./conf/devel"
fi

set +e
source "${CONFFILE}"
set -e

if [ "${CMDLINEOPTS}" == "" ]; then
	echo "$0: cmdline not configured; please check ${CONFFILE}"
	exit 1
fi

function usage {
	echo "$0: cmd "
	echo "available cmds:"
	echo -e "\tall"
	echo -e "\tgenKeys <CNBASE>"
	echo -e "\tenrollKeys (via efi-updatevar)"
	echo -e "\tinstallKeyTool"
	echo -e "\tinstallKernel"
	echo -e "\tsignBootloader (${BOOTLOADER})"
	echo -e "\tsignFwupd (${FWUPDEFI})"
	echo -e "\tshowInstalledKeys (via efi-readvar)"
	echo -e "\twasSecureBooted"
	echo "installed version: ${V}"
	echo "used conffile: ${CONFFILE}"
	exit 1
}

function genKeys {
	mkdir -p ${KEYSDIR}
	chmod 700 ${KEYSDIR}

	echo "== Generating GUID"
	uuidgen --random >"${KEYSDIR}GUID.txt"

	function genKey {
		echo "== Generating $1 $2"
		openssl req -newkey rsa:2048 -nodes -keyout "$4.key" -new -x509 -sha256 -days 3650 \
			-subj "/CN=$1 $2/" -out "$4.crt"
		cert-to-efi-sig-list -g "$3" "$4.crt" "$4.esl"
		sign-efi-sig-list -g "$3" -c "$5.crt" -k "$5.key" "$2" "$4.esl" "$4.auth"
	}
	genKey "$1" "PK"  "$(< ${KEYSDIR}GUID.txt)" "${KEYSDIR}PK"  "${KEYSDIR}PK" 
	genKey "$1" "KEK" "$(< ${KEYSDIR}GUID.txt)" "${KEYSDIR}KEK" "${KEYSDIR}PK" 
	genKey "$1" "db"  "$(< ${KEYSDIR}GUID.txt)" "${KEYSDIR}db"  "${KEYSDIR}KEK" 
}

function enrollKeys {
	echo "== enrolling Keys"
	mount -o rw,remount /sys/firmware/efi/efivars

	efi-updatevar -e -f ${KEYSDIR}db.esl db
	efi-updatevar -e -f ${KEYSDIR}KEK.esl KEK
	efi-updatevar -f ${KEYSDIR}PK.auth PK

	mount -o ro,remount /sys/firmware/efi/efivars
}

function installKeyTool {
	echo "== Deploying/Signing KeyTool (+ keys)"
	mkdir -p ${KEYTOOLDEST}
	cat >${KEYTOOLLDCF} <<EOF
title KeyTool
efi /EFI/KeyTool/KeyTool.efi
EOF
	sbsign --key "${KEYSDIR}db.key" --cert "${KEYSDIR}db.crt" \
		--output "${KEYTOOLDEST}KeyTool.efi" "/usr/share/efitools/efi/KeyTool.efi"
	sbverify --cert "${KEYSDIR}db.crt" "${KEYTOOLDEST}KeyTool.efi"
	cp "${KEYSDIR}"*.auth "${KEYSDIR}"*.esl "${KEYTOOLDEST}/"
}

function installKernel {
	BUILDDIR=`mktemp -d /tmp/secureboot.XXXXXX`

	for i in `ls /usr/lib/modules/*/pkgbase`; do
		KVER="${i#'/usr/lib/modules/'}"
		KVER="${KVER%'/pkgbase'}"
		OUT="${DEST}`cat $i`.efi"
	done
	echo ">> will build ${OUT} for ${KVER}"

	CMDLINEFILE="${BUILDDIR}/cmdline.txt"
	echo "== CREATING ${CMDLINEFILE}"
	cat >${CMDLINEFILE} <<EOF
${CMDLINEOPTS}
EOF

	UCODETXZ=${BUILDDIR}/intel-ucode.tar.xz
	UCODEIMG=${BUILDDIR}/intel-ucode.img
	echo "== Getting ${UCODEIMG}"
	curl -o ${UCODETXZ} -L https://www.archlinux.org/packages/extra/any/intel-ucode/download
	tar xpf ${UCODETXZ} -C ${BUILDDIR} --strip-components 1 boot/intel-ucode.img

	DRACUTFILE="${BUILDDIR}/initrd.dracut.img"
	echo "== CREATING ${DRACUTFILE}"
	dracut --kver ${KVER} ${DRACUTFILE}

	INITRDIMG="${BUILDDIR}/initrd.img"
	echo "== CREATING ${INITRDIMG}"
	cat ${UCODEIMG} ${DRACUTFILE} >${INITRDIMG}

	echo "== BUILDING ${OUT}"

	objcopy \
		--add-section   .osrel="/usr/lib/os-release"				--change-section-vma   .osrel=0x0020000 \
		--add-section .cmdline="${CMDLINEFILE}"					--change-section-vma .cmdline=0x0030000 \
		--add-section  .splash="/usr/share/systemd/bootctl/splash-arch.bmp"	--change-section-vma  .splash=0x0040000 \
		--add-section   .linux="/usr/lib/modules/${KVER}/vmlinuz"		--change-section-vma   .linux=0x2000000 \
		--add-section  .initrd="${INITRDIMG}"					--change-section-vma  .initrd=0x3000000 \
		"/usr/lib/systemd/boot/efi/linuxx64.efi.stub" "${OUT}"

	echo "== SIGNING ${OUT}"
	sbsign --key "${KEYSDIR}db.key" --cert "${KEYSDIR}db.crt" --output "${OUT}" "${OUT}"

	echo "== VERIFING ${OUT}"
	sbverify --list "${OUT}"
	sbverify --cert "${KEYSDIR}db.crt" "${OUT}"

	echo "== CLEANUP"
	rm ${CMDLINEFILE} ${UCODETXZ} ${UCODEIMG} ${DRACUTFILE} ${INITRDIMG}
	rmdir ${BUILDDIR}
}

function signBootloader {
	echo "== Signing Bootloader ${BOOLOADER} (if needed)"
	sbverify --cert "${KEYSDIR}db.crt" "${BOOTLOADER}" || (
		sbsign --key "${KEYSDIR}db.key" --cert "${KEYSDIR}db.crt" \
			--output "${BOOTLOADER}" "${BOOTLOADER}" &&
		sbverify --cert "${KEYSDIR}db.crt" "${BOOTLOADER}" \
	)
}

function signFwupd {
	echo "== Signing fwupd loader ${FWUPDEFI}"
	sbsign --key "${KEYSDIR}db.key" --cert "${KEYSDIR}db.crt" "${FWUPDEFI}"
	sbverify --cert "${KEYSDIR}db.crt" "${FWUPDEFI}.signed"
}

function showInstalledKeys {
	efi-readvar
}

function wasSecureBooted {
	state=`od --address-radix=n --format=u1 /sys/firmware/efi/efivars/SecureBoot* | cut -c 20`
	desc="No"
	if [ "${state}" == "1" ]; then
		desc="Yes"
	fi
	echo "${desc}(${state})"
}

[ $# -ne 0 ] || usage

case $1 in
	all)		[ $# -eq 2 ] || (echo "Missing or Additional Argument"; usage) ;;
	genKeys)	[ $# -eq 2 ] || (echo "Missing or Additional Argument"; usage) ;;
	*)		[ $# -eq 1 ] || (echo "Additional Argument given"; usage) ;;
esac

case $1 in
	all) 			genKeys "$2"; installKeyTool; installKernel; signBootloader ;;
	genKeys)		genKeys "$2" ;;
	enrollKeys)		enrollKeys ;;
	installKeyTool)		installKeyTool ;;
	installKernel)		installKernel ;;
	signBootloader)		signBootloader ;;
	signFwupd)		signFwupd ;;
	showInstalledKeys)	showInstalledKeys ;;
	wasSecureBooted)	wasSecureBooted ;;
	*) echo "Unkown command: $1"; usage ;;
esac
