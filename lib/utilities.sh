#!/bin/bash

# Installs from a local file in current folder, but previously
# it installs the same snap from the store to ensure connections
# are set in the first place.
# $1: name of the snap
# $2: reference channel for the store snap
snap_install_from_file() {
    name=$1
    ref_channel=$2
    # We need first to install from the store to get all necessary
    # assertions into place. Second local install will then bring in
    # our locally built snap.
    if ! snap list "$name" &> /dev/null; then
	    if ! snap install "$name" --channel="$ref_channel"; then
            # ignore error if snap info produces nothing
            # this can happen for first publishes
            if snap info "$name" | grep "$ref_channel"; then
                echo "failed to install $name"
                exit 1
            fi
        fi
        # Avoid race conditions that seem to happen when doing two
        # consecutive installations - probably because of netplan
        # re-starting daemons.
        sleep 20
    fi
    snap install --dangerous "$PROJECT_PATH"/"$name"*_amd64.snap
}

switch_netplan_to_network_manager() {
    if [ -e /etc/netplan/00-default-nm-renderer.yaml ] ; then
	return 0
    fi

    # set 'defaultrenderer' in case the snap is already installed
    if snap list network-manager &> /dev/null; then
	snap set network-manager defaultrenderer=true
	# Leave some time for NM wrapper to write netplan config
	repeat_until_done "test -e /etc/netplan/00-default-nm-renderer.yaml"
    else
	cat << EOF > /etc/netplan/00-default-nm-renderer.yaml
network:
  renderer: NetworkManager
EOF
    fi
}

switch_netplan_to_networkd() {
    if [ ! -e /etc/netplan/00-default-nm-renderer.yaml ] ; then
	return 0
    fi

    # unset 'defaultrenderer' in case the snap is already installed
    if snap list network-manager &> /dev/null; then
	snap set network-manager defaultrenderer=false
	# Leave some time for NM wrapper to remove netplan config
	repeat_until_done "test ! -e /etc/netplan/00-default-nm-renderer.yaml"
    else
	rm /etc/netplan/00-default-nm-renderer.yaml
    fi
}

# waits for a service to be active. Besides that, waits enough
# time after detecting it to be active to prevent restarting
# same service too quickly several times.
# $1 service name
# $2 start limit interval in seconds (default set to 10. Exec
#    `systemctl show THE_SERVICE -p StartLimitInterval` to verify)
# $3 start limit burst. Times allowed to start the service in
#    start_limit_interval time (default set to 5. Exec
#    `systemctl show THE_SERVICE -p StartLimitBurst` to verify)
wait_for_systemd_service() {
    while ! systemctl status "$1"; do
	sleep 1
    done
    # As debian services default limit is to allow 5 restarts in a 10sec period
    # (StartLimitInterval=10000000 and StartLimitBurst=5), having enough wait time we
    # prevent "service: Start request repeated too quickly" error.
    #
    # You can check those values for certain service by typing:
    #   $systemctl show THE_SERVICE -p StartLimitInterval,StartLimitBurst
    #
    if [ $# -ge 2 ]; then
        start_limit_interval=$2
    else
        start_limit_interval=$(systemctl show "$1" -p StartLimitInterval | sed 's/StartLimitInterval=//')
        # original limit interval is provided in microseconds.
        start_limit_interval=$((start_limit_interval / 1000000))
    fi

    if [ $# -eq 3 ]; then
        start_limit_burst=$3
    else
        start_limit_burst=$(systemctl show "$1" -p StartLimitBurst | sed 's/StartLimitBurst=//')
    fi

    # adding 1 to be sure we exceed the limit
    sleep_time=$((1 + start_limit_interval/start_limit_burst))
    sleep $sleep_time
}

wait_for_network_manager() {
    wait_for_systemd_service snap.network-manager.networkmanager
}

stop_after_first_reboot() {
    if [ "$SPREAD_REBOOT" -gt 0 ] ; then
	exit 0
    fi
}

mac_to_ipv6() {
    mac=$1
    ipv6_address=fe80::$(printf %02x $((0x${mac%%:*} ^ 2)))
    mac=${mac#*:}
    ipv6_address=$ipv6_address${mac%:*:*:*}ff:fe
    mac=${mac#*:*:}
    ipv6_address=$ipv6_address${mac%:*}${mac##*:}
    echo "$ipv6_address"
}

# Creates an AP using NM on wlan0
# $1: SSID name
# $2: Passphrase. If present, AP will use WPA2, otherwise it will be open.
create_ap() {
    if [ $# -lt 1 ]; then
        echo "Not enough arguments for $0"
        return 1
    fi

    if [ $# -ge 2 ]; then
        # The NM system connection is named Hotspot by default
        network-manager.nmcli d wifi hotspot ifname wlan0 ssid "$1" password "$2"
    else
        # Open connection
        network-manager.nmcli c add type wifi ifname wlan0 con-name "Hotspot" \
                              autoconnect yes wifi.mode ap wifi.ssid "$1" \
                              ipv4.method shared ipv6.method shared
    fi

    # Wait to make sure the AP sends the beacon frames so wpa_supplicant
    # detects the AP changes and reports the right environment to NM.
    sleep 30
}

remove_ap() {
    network-manager.nmcli c del "Hotspot"
}


# $1 instruction to execute repeatedly until complete or max times
# $2 sleep time between retries. Default 1sec
# $3 max_iterations. Default 20
repeat_until_done() {
    timeout=1
    if [ $# -ge 2 ]; then
        timeout=$2
    fi

    max_iterations=20
    if [ $# -ge 3 ]; then
        max_iterations=$3
    fi

    i=0
    while [ "$i" -lt "$max_iterations" ] ; do
        if eval "$1"; then
            break
        fi
        sleep "$timeout"
        i=$((i + 1))
    done
    test "$i" -lt "$max_iterations"
}

# Returns name of ethernet interface for qemu vm
# $1: name of variable where to store the interface name
get_qemu_eth_iface() {
    local _net_dev
    _net_dev=$(find /sys/class/net/ -print0 -type l | xargs -0 readlink |
                   grep -v virtual | head -n 1)
    _net_dev=${_net_dev##*/}
    eval "$1"="$_net_dev"
}

# Find out name of essential snaps in the system
# $1: name of variable where to store the gadget snap name
# $2: name of variable where to store the kernel snap name
get_snap_names() {
    local _gadget_name _kernel_name
    _gadget_name=$(snap list | sed -n 's/^\(pc\|pi[23]\|dragonboard\) .*/\1/p')
    _kernel_name=$_gadget_name-kernel
    if [ "$_kernel_name" = "pi3-kernel" ] ; then
	_kernel_name=pi2-kernel
    fi
    eval "$1"="$_gadget_name"
    eval "$2"="$_kernel_name"
}
