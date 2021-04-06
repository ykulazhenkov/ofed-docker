#!/bin/bash -x


VENDOR=0x15b3

function set_driver_readiness() {
    touch /.driver-ready
}

function unset_driver_readiness() {
    rm -f /.driver-ready
}

function exit_on_error() {
    $@
    if [[ $? -ne 0 ]]; then
        echo "Error occured while executing: $1"
        exit 1
    fi
}

function mount_rootfs() {
    echo "Mounting OFED driver container rootfs..."
    mount --make-runbindable /sys
    mount --make-private /sys
    mkdir -p /run/mellanox/drivers
    mount --rbind / /run/mellanox/drivers
}

function unmount_rootfs() {
    if findmnt -r -o TARGET | grep "/run/mellanox/drivers" > /dev/null; then
      umount -l -R /run/mellanox/drivers
    fi
}

function handle_signal() {
    unset_driver_readiness
    echo "Unmounting Mellanox OFED driver rootfs..."
    unmount_rootfs
    echo "Stopping Mellanox OFED Driver..."
    /etc/init.d/openibd force-stop
    exit 0
}

function ofed_exist_for_kernel() {
    # check if mlx5_core exists in dkms under running kernel, this should be sufficient to hint us if
    # OFED drivers are installed for the running kernel
    local KVER=$(uname -r)
    if [[ -e /lib/modules/${KVER}/updates/dkms/mlx5_core.ko ]]; then
        echo "OFED driver found for kernel"
        return 0
    fi
    echo "No OFED driver found for kernel ${KVER}"
    return 1

}

function rebuild_driver() {
    # Rebuild driver in case installed driver kernel version differs from running kernel
    local KVER=$(uname -r)
    echo "Rebuilding driver"
    apt-get -yq update
    apt-get -yq install linux-headers-${KVER} linux-modules-${KVER}
    dkms autoinstall
}

function start_driver() {
    /etc/init.d/openibd restart
    if [[ $? -ne 0 ]]; then
        echo "Error occured while restarting driver"
        return 1
    fi
    ofed_info -s
}

function unload_modules() {
    local module
    for module in $@; do
        grep -q "^${module} " /proc/modules || continue
        unload_modules $(awk '$1=="'${module}'"{print $4}' /proc/modules | tr , ' ')
        echo "Unloading module ${module}..."
        rmmod ${module}
    done
}

function find_mlx_devs() {
    local ethpath
    for ethpath in /sys/class/net/*; do
        if (grep $VENDOR "$ethpath"/device/vendor >/dev/null 2>&1); then
            echo "$ethpath"
        fi
    done
}

function find_mlx_pfs() {
    for mlnx_dev in $(find_mlx_devs); do
        if [[ ! -L $mlnx_dev/device/physfn ]]; then
            pf_name=$(basename "$mlnx_dev") && [[ -n $pf_name ]] || return 1
            echo "$pf_name"
        fi
    done
}

function set_link_up() {
    local pf_name=$1
    ip link set dev "$pf_name" up
}

function set_pf_links_up() {
    local pf_data
    if ! pf_data=$(find_mlx_pfs); then
        echo "Failed to read info about PFs"
        return 1
    fi
    local pf
    for pf in $pf_data;do
        echo "set $pf link up"
        if ! set_link_up "$pf"; then
            echo "failed to set PF $pf_name up"
            return 1
        fi
    done
}

# Unset driver readiness in case it was set in a previous run of this container
# and container was killed
unset_driver_readiness
ofed_exist_for_kernel
if [[ $? -ne 0 ]]; then
    rebuild_driver
fi

unload_modules rpcrdma rdma_cm
exit_on_error start_driver
mount_rootfs
set_pf_links_up
set_driver_readiness
trap "echo 'Caught signal'; exit 1" HUP INT QUIT PIPE TERM
trap "handle_signal" EXIT
sleep infinity & wait
