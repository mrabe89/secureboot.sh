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
V=0.0.3

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

# Load defaults
ESP="${ESP:-/boot/efi/}"
DEST="${DEST:-${ESP}EFI/Linux/}"
CDEST="${CDEST:-${ESP}loader/entries/}"
KEYSDIR="${KEYSDIR:-/etc/secureboot/keys/}"
KEYTOOLDEST="${KEYTOOLDEST:-${ESP}EFI/KeyTool/}"
KEYTOOLLDCF="${KEYTOOLLDCF:-${ESP}loader/entries/keytool.conf}"
BOOTLOADER="${BOOTLOADER:-${ESP}EFI/systemd/systemd-bootx64.efi}"

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
	case "${DISTRO}" in
		arch)
			for i in `ls /usr/lib/modules/*/pkgbase`; do
				KVER="${i#'/usr/lib/modules/'}"
				KVER="${KVER%'/pkgbase'}"

				installKernel_do "${KVER}" ""

			done
			;;
		gentoo)
			for i in `ls /boot/vmlinuz-*`; do
				KVER="${i#'/boot/vmlinuz-'}"
				KVER="${KVER%'.old'}"
				APND="${i#'/boot/vmlinuz-'${KVER}}"

				installKernel_do "${KVER}" "${APND}"
			done
			;;
		*) echo "Unknown distro ${DISTRO}"; exit 1;;
	esac
}

function installKernel_do {
	BUILDDIR=`mktemp -d /tmp/secureboot.XXXXXX`

	KVER="$1"
	APND="$2"

	OUT="${DEST}sb-linux-${KVER}${APND}.efi"
	COUT="${CDEST}sb-linux-${KVER}${APND}.conf"

	case "${DISTRO}" in
		arch)
			UCODEIMG_SYS="/boot/intel-ucode.img"
			OSRELFILE="/usr/lib/os-release"
			VMLINUZFILE="/usr/lib/modules/${KVER}/vmlinuz"
			SPLASHFILE="/usr/share/systemd/bootctl/splash-arch.bmp"
			NAME="archlinux"
			;;
		gentoo)
			UCODEIMG_SYS="/boot/intel-uc.img"
			OSRELFILE="/etc/os-release"
			VMLINUZFILE="/boot/vmlinuz-${KVER}${APND}"
			NAME="Gentoo Linux"
			;;
		*) echo "Unknown distro ${DISTRO}"; exit 1;;
	esac

	echo $KVER
	echo $VMLINUZFILE

	echo ">> will build ${OUT} for ${KVER}"

	CMDLINEFILE="${BUILDDIR}/cmdline.txt"
	echo "== CREATING ${CMDLINEFILE}"
	echo "${CMDLINEOPTS}" >"${CMDLINEFILE}"

	UCODEIMG="${BUILDDIR}/intel-ucode.img"
	if [ -e "${UCODEIMG_SYS}" ]; then
		echo "== COPYING ${UCODEIMG_SYS} to ${UCODEIMG}"
		cp "${UCODEIMG_SYS}" "${UCODEIMG}"
	else
		UCODETXZ="${BUILDDIR}/intel-ucode.tar.xz"
		echo "== RECVING ${UCODEIMG}"
		curl -o "${UCODETXZ}" -L https://www.archlinux.org/packages/extra/any/intel-ucode/download
		tar xpf "${UCODETXZ}" -C "${BUILDDIR}" --strip-components 1 boot/intel-ucode.img
		rm "${UCODETXZ}"
	fi

	DRACUTFILE_SYS="/boot/initramfs-${KVER}.img"
	DRACUTFILE="${BUILDDIR}/initrd.dracut.img"
	if [ -e "${DRACUTFILE_SYS}" ]; then
		echo "== COPYING ${DRACUTFILE_SYS} to ${DRACUTFILE}"
		cp "${DRACUTFILE_SYS}" "${DRACUTFILE}"
	else
		echo "== CREATING ${DRACUTFILE}"
		dracut --kver ${KVER} ${DRACUTFILE}
	fi

	INITRDIMG="${BUILDDIR}/initrd.img"
	echo "== CREATING ${INITRDIMG}"
	cat ${UCODEIMG} ${DRACUTFILE} >${INITRDIMG}

	echo "== BUILDING ${OUT}"
	if [ "${SPLASHFILE}" != "" ]; then
		objcopy \
			--add-section   .osrel="${OSRELFILE}"		--change-section-vma   .osrel=0x0020000 \
			--add-section .cmdline="${CMDLINEFILE}"		--change-section-vma .cmdline=0x0030000 \
			--add-section  .splash="${SPLASHFILE}"		--change-section-vma  .splash=0x0040000 \
			--add-section   .linux="${VMLINUZFILE}"		--change-section-vma   .linux=0x2000000 \
			--add-section  .initrd="${INITRDIMG}"		--change-section-vma  .initrd=0x3000000 \
			"/usr/lib/systemd/boot/efi/linuxx64.efi.stub" "${OUT}"
	else
		objcopy \
			--add-section   .osrel="${OSRELFILE}"		--change-section-vma   .osrel=0x0020000 \
			--add-section .cmdline="${CMDLINEFILE}"		--change-section-vma .cmdline=0x0030000 \
			--add-section   .linux="${VMLINUZFILE}"		--change-section-vma   .linux=0x0040000 \
			--add-section  .initrd="${INITRDIMG}"		--change-section-vma  .initrd=0x3000000 \
			"/usr/lib/systemd/boot/efi/linuxx64.efi.stub" "${OUT}"
	fi

	echo "== SIGNING ${OUT}"
	sbsign --key "${KEYSDIR}db.key" --cert "${KEYSDIR}db.crt" --output "${OUT}" "${OUT}"

	echo "== VERIFING ${OUT}"
	sbverify --list "${OUT}"
	sbverify --cert "${KEYSDIR}db.crt" "${OUT}"

	echo ${OUT}
	echo ${ESP}
	echo "== CREATING ${COUT}"
	cat >${COUT} <<EOF
title ${NAME} (${KVER}${APND})
efi /${OUT#${ESP}}
EOF

	echo "== CLEANUP"
	rm ${CMDLINEFILE} ${UCODEIMG} ${DRACUTFILE} ${INITRDIMG}
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
