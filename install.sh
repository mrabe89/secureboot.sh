#!/usr/bin/env bash

set -e

install -o root -g root -m 700	secureboot.sh	/usr/bin/secureboot.sh
install -o root -g root -m 644	secureboot.hook /usr/share/libalpm/hooks/90-secureboot.hook
