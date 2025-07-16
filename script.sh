#!/bin/bash
#
# Проверка, запущен ли скрипт от имени root

if [[ "$EUID" -ne 0 ]]; then
  echo "Пожалуйста, запустите скрипт с правами root (например, с помощью sudo)"
  exit 1
fi

sed -i '/^deb cdrom:/s/^/#/' /etc/apt/sources.list

# Добавляем строки в /etc/apt/sources.list, если их ещё нет
grep -qxF 'deb http://10.11.4.23/os/astralinux/1.7.5/main stable main contrib non-free' /etc/apt/sources.list || \
echo 'deb http://10.11.4.23/os/astralinux/1.7.5/main stable main contrib non-free' >> /etc/apt/sources.list

grep -qxF 'deb http://10.11.4.23/os/astralinux/1.7.5/devel stable main contrib non-free' /etc/apt/sources.list || \
echo 'deb http://10.11.4.23/os/astralinux/1.7.5/devel stable main contrib non-free' >> /etc/apt/sources.list

echo "Источники успешно добавлены."

# Обновляем список пакетов
echo "Обновление списка пакетов..."
apt-get update


systemctl stop ntp

ntpd -gq

systemctl start ntp

hwclock -u -w

set -e

# Application name
APPLICATION="largocodec"
# Application main package
APPLICATION_PACKAGES="${APPLICATION}"
# Application log file
APPLICATION_LOG="/var/log/${APPLICATION}/install_$(date +%Y-%m-%d__%H-%M-%S).log"
# Basic repository directory
APPLICATION_REPOSITORY="repository"

# Special file names
SOURCES_FILE="sources.list"
PREFERENCES_FILE="preferences"
REPOSITORY_FILE="Packages"
TRUSTED_FILE="trusted.gpg"

# Repository settings
SOURCES_DIR="/etc/apt/sources.list.d"
PREFERENCES_DIR="/etc/apt/preferences.d"
TRUSTED_DIR="/etc/apt/trusted.gpg.d"

# Other settings
export DEBIAN_FRONTEND=noninteractive
#export TERM=xterm

#================================================
#================================================

# Initializing repository
function init_repository() {
	echo "Initializing repository..."

	[ ! -f ${APPLICATION_REPOSITORY}/${REPOSITORY_FILE} ] && \
		echo "Repository list file: ${APPLICATION_REPOSITORY}/${REPOSITORY_FILE} - not found!" && exit 1

	[ ! -f ${APPLICATION_REPOSITORY}/${SOURCES_FILE} ] && \
		echo "Sources file: ${APPLICATION_REPOSITORY}/${SOURCES_FILE} - not found!" && exit 1

	[ ! -f ${APPLICATION_REPOSITORY}/${PREFERENCES_FILE} ] && \
		echo "Preferences file: ${APPLICATION_REPOSITORY}/${PREFERENCES_FILE} - not found!" && exit 1

	local repository_dir=$(cat ${APPLICATION_REPOSITORY}/${SOURCES_FILE} | tr ' ' '\n' | grep -e '^file:/' | cut -d ':' -f 2)

	(( ! ${OPT_OVERWRITE} )) && [ -d ${repository_dir} ] && \
		echo "Repository directory: ${repository_dir} - already exists!" && exit 1

	# Delete old repository and symlinks
	rm -rf ${repository_dir}
	rm -rf ${SOURCES_DIR}/${APPLICATION}.${SOURCES_FILE##*.}
	rm -rf ${PREFERENCES_DIR}/${APPLICATION}
	rm -rf ${TRUSTED_DIR}/${APPLICATION}.${TRUSTED_FILE##*.}

	# Create new repository and symlinks
	mkdir -p ${repository_dir}
	command -v setfacl >/dev/null || apt install --yes acl
	# https://wiki.astralinux.ru/pages/viewpage.action?pageId=144311245
	setfacl -m u:_apt:rwx ${repository_dir}

	cp ${APPLICATION_REPOSITORY}/* ${repository_dir}
	ln -sv ${repository_dir}/${SOURCES_FILE} ${SOURCES_DIR}/${APPLICATION}.${SOURCES_FILE##*.}
	ln -sv ${repository_dir}/${PREFERENCES_FILE} ${PREFERENCES_DIR}/${APPLICATION}
	[ -f ${repository_dir}/${TRUSTED_FILE} ] && \
		ln -sv ${repository_dir}/${TRUSTED_FILE} ${TRUSTED_DIR}/${APPLICATION}.${TRUSTED_FILE##*.}

	apt-get update
}

# Uninstall the previous version
function uninstall() {
	local application_packages=$1
	local is_uninstall=0
	for package in ${application_packages}; do
		if dpkg -s ${package} &> /dev/null ; then
			echo "uninstall: ${package}"
			apt-get autoremove --purge --yes ${package}
			is_uninstall=1
		fi
	done
	if (( ${is_uninstall} )); then
		apt-get autoremove --yes
		apt-get autoclean
	fi
}

#================================================
#================================================

(( ${UID} != 0 )) && echo "Installation requires elevation of access rights, run again using sudo." && exit 1

# Restart for start write log
if [ -z "${RESTART_LOG_STATUS}" ]; then
	APPLICATION_LOG_DIR=$(dirname ${APPLICATION_LOG})
	mkdir -p "${APPLICATION_LOG_DIR}"
	script --return --flush --command "RESTART_LOG_STATUS=1 bash $0 $*" ${APPLICATION_LOG}
	exit $?
fi


# Route flags
OPT_ANSWER=1
OPT_UNINSTALL=0
OPT_UPGRADE=0
OPT_REBOOT=0
OPT_DROP_DATABASE=0
OPT_APT_INSTALL="-o Debug::pkgProblemResolver=true --yes"
OPT_APT_UPGRADE="-o Debug::pkgProblemResolver=true --enable-upgrade --yes"
OPT_OVERWRITE=0

while (( $# )); do
	case "$1" in
		--yes|-y)
			OPT_ANSWER=0
		;;
		--uninstall)
			OPT_UNINSTALL=1
		;;
		--upgrade)
			OPT_UPGRADE=1
		;;
		--reboot)
			OPT_REBOOT=1
		;;
		--drop-database)
			OPT_DROP_DATABASE=1
		;;
		--overwrite)
			OPT_OVERWRITE=1
		;;
		--no-install-recommends)
			OPT_APT_INSTALL="${OPT_APT_INSTALL} --no-install-recommends"
		;;
		*)
			echo "Unknown options: $1"
			exit 1
		;;
	esac
	shift
done

export UNINSTALL_DROP_DATABASE=${OPT_DROP_DATABASE}

echo "================================================"
uname -a
lsb_release -a 2>/dev/null
[ -f /etc/astra?version ] && echo -e "Astra version:\t$(cat /etc/astra?version)"
echo "================================================"

if (( ${OPT_ANSWER} )); then
	read -n1 -p "Are you sure you want to continue? (Y)es/(N)o " ANSWER ; echo
	[[ "${ANSWER}" != "y" && "${ANSWER}" != "Y" ]] && exit 0
fi

# Uninstall application
(( ${OPT_UNINSTALL} )) && uninstall "${APPLICATION_PACKAGES}" && exit 0

if (( ${OPT_UPGRADE} )); then
	# --- transition solution --- !!!
	systemctl stop largo-common.target || true
	sleep 5
	uninstall "largo-web largo largo-common"
	rm -f /etc/apt/sources.list.d/largo.list
	rm -rf /var/largo_repo
	rm -rf /var/largo-home/?/var/largo/data/*
	rm -rf /var/largo/data/*
	apt-get update
	# ------------------------------- !!!

	init_repository # move line before: if
	echo "Upgrade"
	apt-get upgrade ${OPT_APT_UPGRADE}

	# --- transition solution --- !!!
	if ! dpkg -s ${package} &> /dev/null ; then
		apt-get install ${OPT_APT_INSTALL} ${APPLICATION_PACKAGES}
	fi
	# ------------------------------- !!!
else
	init_repository # move line before: if
	echo "Install"
	apt-get install ${OPT_APT_INSTALL} ${APPLICATION_PACKAGES}
fi

echo "-----------------------------------------------"
if (( $OPT_REBOOT )); then
	echo "Reboot..."
	reboot
else
	echo "Reboot the system to complete the installation."
fi

