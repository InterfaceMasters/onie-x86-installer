#!/bin/sh

######################################################################
#  INTERFACE MASTERS CONFIDENTIAL & PROPRIETARY                      #
#  __________________                                                #
#                                                                    #
#   2022-present Interface Masters Technologies, Inc.                #
#                                                                    #
#  All information contained herein is                               #
#  the proprietary property of Interface Masters Technologies, Inc., #
#  and are protected by trade secret or copyright law.               #
#  Dissemination of this information or reproduction of this material#
#  is strictly forbidden unless prior written permission is obtained #
#  from Interface Masters Technologies.                              #
#                                                                    #
######################################################################

# IMT installer has restrictions on names for installer and image.
# But ONIE has inexact names that may not end with .sh.
# In this case image still should be ended with '-image.bin'.
image_location=`echo "${onie_exec_url}" | sed -e 's/[\.sh]*$/-image.bin/'`

# Note: to use traps below, just set to 1
DEBUG=0
# Note: For debug purposes use just one partition instead of creating dual-boot
DEBUG_USE_ONE_PARTITION=0

# Check for presence of installer image before repartitioning ssd.
echo "Check image file presence at ${image_location}..."
if ./curl --output /dev/null --silent --head --fail "${image_location}"; then
  echo "Image ${image_location} is OK..."
else
  echo "Image ${image_location} is not found! Aborting..."
  exit 1
fi

# Default ONIE block device
install_device_platform()
{
    # The problem we are trying to solve is:
    #
    #    How to determine the block device upon which to install ONIE?
    #
    # The question is complicated when multiple block devices are
    # present, i.e. perhaps the system has two hard drives installed
    # or maybe a USB memory stick is currently installed.  For example
    # the mSATA device usually shows up as /dev/sda under Linux, but
    # maybe with a USB drive connected the internal disk now shows as
    # /dev/sdb.
    #
    # The approach here is to look for the first drive that
    # is connected to AHCI SATA controller.

    for d in /sys/block/sd* ; do
        fname=`ls "$d/device/../../scsi_host/host"*"/proc_name"` 2>/dev/null
        if [ -e "$fname" ] ; then
            if grep -i "ahci" "$fname" > /dev/null ; then
                device="/dev/$(basename $d)"
                echo $device
                return 0
            fi
        fi
    done
    echo "WARNING: ${onie_platform}: Unable to find internal ONIE install device"
    echo "WARNING: expecting a hard drive connected to AHCI controller"
    return 1
}

target_dev=`install_device_platform`

echo "Target dev is ${target_dev}"

[ ! -b ${target_dev} ] && {
echo "No target device detected."
exit 1
}

################################################################################
# Select onie dev num in partition table (last partition)
# Note: This is hardcoded due to fixed befaviour
#
# In case legacy boot (MSDOS):
#    sda1 - "ONIE-BOOT" partition
#    sda2 - ROOT1 (ISS image for the first OS)
#    sda3 - ROOT2 (ISS image for the second OS) (optional)
# In case legacy boot (GPT):
#    sda1 - "GRUB-BOOT" partition
#    sda2 - "ONIE-BOOT" partition
#    sda3 - ROOT1 (ISS image for the first OS)
#    sda4 - ROOT2 (ISS image for the second OS) (optional)
# In case UEFI boot (GPT and MSDOS):
#    sda1 - "EFI System" (ESP) partition
#    sda2 - "ONIE-BOOT"
#    sda3 - ROOT1 (ISS image for the first OS)
#    sda4 - ROOT2 (ISS image for the second OS) (optional)
################################################################################
boot_dir="/boot"
onie_boot_dir="/mnt/onie-boot"
mount_dir="/mnt/iss_rootfs"
iss_boot_dir="${mount_dir}/boot"
if [[ "$(parted -l | grep -o 'gpt')" = "gpt" ]]; then
    partition_type="gpt"
else
    partition_type="msdos"
fi
iss_volume_label="ROOT"
if [ -d "/sys/firmware/efi/efivars" ]; then
    boot_mode="uefi"
    uefi_esp_mnt="${mount_dir}/efi"
    echo "Boot mode is UEFI"
    efi_dev_num=1
    onie_dev_num=2
    iss_inst_dev_num=3
    reserved_dev_num=4
else
    boot_mode="legacy"
    echo "Boot mode is Legacy"
    if [[ "${partition_type}" = "gpt" ]]; then
        onie_dev_num=2
        iss_inst_dev_num=3
        reserved_dev_num=4
    else
        onie_dev_num=1
        iss_inst_dev_num=2
        reserved_dev_num=3
    fi
fi

# Check the partition type, MBR (msdos) or GPT
echo "Unmount all partitions..."
if [ "${partition_type}" = "gpt" ] || [ "${boot_mode}" = "uefi" ]; then
    umount "${target_dev}3" 2>/dev/null
    umount "${target_dev}4" 2>/dev/null
    umount "${target_dev}5" 2>/dev/null
else
    umount "${target_dev}1" 2>/dev/null
    umount "${target_dev}2" 2>/dev/null
    umount "${target_dev}3" 2>/dev/null
    umount "${target_dev}4" 2>/dev/null
    umount "${target_dev}5" 2>/dev/null
fi

if [ "${boot_mode}" = "uefi" ]; then
    echo "Selected partition ${target_dev}${efi_dev_num} for EFI"
fi
echo "Selected partition ${target_dev}${onie_dev_num} for ONIE"
echo "Selected partition ${target_dev}${iss_inst_dev_num} for OS1"
echo "Selected partition ${target_dev}${reserved_dev_num} for OS2 (reserved)"

if [ "${partition_type}" = "gpt" ] || [ "${boot_mode}" = "uefi" ]; then
    # Delete the previous partitions for NOS, the onie and esp partitions are untouched
    echo "Removing partition ${target_dev}${iss_inst_dev_num}..."
    parted -ms "${target_dev}" \
     `parted -ms "${target_dev}" "unit s" "print" | \
     egrep "^[0-9]+:" | grep "^${iss_inst_dev_num}:" | cut -d: -f1 | sort -rn | \
     sed -e 's/^/"rm /' -e 's/:.\+$/"/' `
    echo "Removing partition ${target_dev}${reserved_dev_num}..."
    parted -ms "${target_dev}" \
     `parted -ms "${target_dev}" "unit s" "print" | \
     egrep "^[0-9]+:" | grep "^${reserved_dev_num}:" | cut -d: -f1 | sort -rn | \
     sed -e 's/^/"rm /' -e 's/:.\+$/"/' `
else
    parted -ms "${target_dev}" \
     `parted -ms "${target_dev}" "unit s" "print" | \
     egrep "^[0-9]+:" | egrep -v "^${onie_dev_num}:" | cut -d: -f1 | sort -rn | \
     sed -e 's/^/"rm /' -e 's/:.\+$/"/' `

    lastsector=`parted -ms "${target_dev}" "unit s" "print" | \
    egrep "^${onie_dev_num}:" | cut -d: -f3 | tr -d 's'`

    [ "$lastsector" = "" ] && {
      if [ -x /self-installer/format-installer.sh ] ; then
      /self-installer/format-installer.sh
      parted -ms "${target_dev}" \
      `parted -ms "${target_dev}" "unit s" "print" | \
      egrep "^[0-9]+:" | egrep -v "^${onie_dev_num}:" | cut -d: -f1 | sort -rn | \
       sed -e 's/^/"rm /' -e 's/:.\+$/"/' `
      lastsector=`parted -ms "${target_dev}" "unit s" "print" | \
      egrep "^${onie_dev_num}:" | cut -d: -f3 | tr -d 's'`
      [ "$lastsector" = "" ] && {
        echo "Installation failed."
        exit 1
        }
      else
        echo "Incompatible partition format on the device ${target_dev}."
        exit 1
      fi
    }
fi


if [ "${partition_type}" = "gpt" ] || \
    [ "${partition_type}" = "msdos" ] && [ "${boot_mode}" = "uefi" ]; then
    # Note: for GPT we will create two partitions in one shot
    total_sectors=$(parted -ms ${target_dev} "unit s print" | grep "^${target_dev}" | cut -d: -f2 | tr -d 's')
    free_sector_start=$(parted -ms ${target_dev} "unit s print"  | grep "^${onie_dev_num}:" | cut -d: -f3 | tr -d 's')
    first_part_start=$(( ${free_sector_start} + 1 ))
    first_part_end=$(( (${total_sectors} - ${free_sector_start}) / 2))
    second_part_start=$(( ${first_part_end} + 1 ))
    if [ "${partition_type}" = "msdos" ]; then
        second_part_end=$(( ${total_sectors} - 1 ))
    else
        # Note: (total_sectors - 34) - is magic number that fits the alignment rules, so use 100% instead...
        second_part_end=$(( ${total_sectors} - 34 ))
    fi
    echo "second_part_end=$second_part_end"
    if [[ "${DEBUG_USE_ONE_PARTITION}" = "1" ]]; then
        echo "Single partition mode selected."
        if [ "${partition_type}" = "msdos" ]; then
            parted -msaoptimal "$target_dev" "mkpart primary ext4 ${first_part_start}s 100%"
        else
            parted -msaoptimal "$target_dev" "mkpart ${iss_volume_label}1 ext4 ${first_part_start}s 100%"
        fi
    else
        echo "Dual-boot partitions selected."
        if [ "${partition_type}" = "msdos" ]; then
            parted -msaoptimal "$target_dev" "mkpart primary ext4 ${first_part_start}s ${first_part_end}s"
            parted -msaoptimal "$target_dev" "mkpart primary ext4 ${second_part_start}s 100%"
        else
            parted -msaoptimal "$target_dev" "mkpart ${iss_volume_label}1 ext4 ${first_part_start}s ${first_part_end}s"
            parted -msaoptimal "$target_dev" "mkpart ${iss_volume_label}2 ext4 ${second_part_start}s 100%"
        fi
    fi
else
    newsector="$((${lastsector}+1))"
    echo "New sector is ${newsector}"
    echo "Creating partition..."
    parted -msaoptimal "$target_dev" "mkpart primary ext4 ${newsector}s 100%"
fi

sync

if [[ "$DEBUG" = "1" ]]; then
    read -p "About to update partitions for kernel..."
fi

if [ "${boot_mode}" = "legacy" -a "${partition_type}" = "msdos" ]; then
    # In case legacy boot we are unmounting all partitions, so the EBUSY will not be triggered
    until blockdev --rereadpt "${target_dev}"
    do sleep 1
    done
else
    partprobe
fi

if [[ "$DEBUG" = "1" ]]; then
    read -p "About to create partitions for dual-boot mode..."
fi

if [ "${partition_type}" = "msdos" ] && [ "${boot_mode}" = "legacy" ]; then
    free_dev_start=$(fdisk -u -l $target_dev | grep "${target_dev}${iss_inst_dev_num}" | awk '{print $2}' | tr -d '\n')
    free_dev_end=$(fdisk -u -l $target_dev | grep "${target_dev}${iss_inst_dev_num}" | awk '{print $3}' | tr -d '\n')
    free_sector_range=$(( ${free_dev_end} - ${free_dev_start} ))
    if [ $((free_sector_range%2)) -ne 0 ]; then free_sector_range=$(( $free_sector_range - 1 )); fi
    iss_inst_dev_end=$(( $free_sector_range / 2 ))
    reserved_dev_start=$(( ${iss_inst_dev_end} + 1 ))
    reserved_dev_end=$(( ${free_dev_end} - 1 ))

    if [[ "${DEBUG_USE_ONE_PARTITION}" = "1" ]]; then
        echo "Formatting and splitting single partition..."
        echo "d
${iss_inst_dev_num}
n
p
${iss_inst_dev_num}
${free_dev_start}
${reserved_dev_end}

w" | fdisk -u $target_dev &>/dev/null
    else
        echo "Formatting and splitting partition for dual-boot mode..."
        echo "d
${iss_inst_dev_num}
n
p
${iss_inst_dev_num}
${free_dev_start}
${iss_inst_dev_end}
n
p
${reserved_dev_num}
${reserved_dev_start}
${reserved_dev_end}

w" | fdisk -u $target_dev &>/dev/null
    fi # DEBUG_USE_ONE_PARTITION
fi # partition_type

echo "Installing image from ${image_location}..."
./curl -s "${image_location}" | bzip2 -dc | ./partclone.restore -s - -o "${target_dev}${iss_inst_dev_num}" || {
    echo "Image installation failed."
    exit 1
}

mkdir -p ${mount_dir}

echo "Mounting target root filesystem..."
until mount -t ext4 "${target_dev}${iss_inst_dev_num}" ${mount_dir}
do sleep 1
done
echo "Done."

if [[ "$DEBUG" = "1" ]]; then
    read -p "Updating /boot dir - Done... Press <enter> key to continue..."
fi

echo "Saving $iss_boot_dir directory on the target root filesystem..."
tar -czf /tmp/boot-fs.tar.gz -C ${iss_boot_dir} .
echo "Done."

if [[ "$DEBUG" = "1" ]]; then
    read -p "About to remove ${iss_boot_dir}... Press <enter> key to continue..."
fi

echo "Removing ${iss_boot_dir} directory from the target root filesystem..."
rm -rf ${iss_boot_dir}
echo "Done."

if [ ! -d "${mount_dir}/boot" ]; then
    echo "Creating empty ${mount_dir}/boot directory on the target root filesystem..."
    mkdir -p ${mount_dir}/boot
    echo "Done."
fi

onie_is_mounted="$(mount | grep ${target_dev}${onie_dev_num} | grep ${mount_dir}/boot)"
if [ -z "${onie_is_mounted}" ]; then
    echo "Mounting target boot filesystem..."
    until mount -t ext2 "${target_dev}${onie_dev_num}" ${mount_dir}/boot
    do sleep 1
    done
    echo "Done."
fi

echo "Restoring /boot directory to the ONIE-BOOT filesystem"
tar -xzf /tmp/boot-fs.tar.gz -C ${iss_boot_dir}
rm /tmp/boot-fs.tar.gz
echo "Done."

if [[ "$DEBUG" = "1" ]]; then
    read -p "Updating /boot dir - Done... Press <enter> key to continue..."
fi

echo "Mounting /dev, /sys, /proc directories on the target root filesystem..."
mount -t tmpfs tmpfs-dev ${mount_dir}/dev
tar c /dev | tar x -C ${mount_dir}
mount --bind /sys ${mount_dir}/sys
mount --bind /proc ${mount_dir}/proc
echo "Done."

echo "Copying disk utilities..."
mkdir -p /tmp/utils
cp ${mount_dir}/sbin/resize2fs /tmp/utils/
cp -a ${mount_dir}/lib/x86_64-linux-gnu /lib/x86_64-linux-gnu
cp -a ${mount_dir}/lib64 /lib64
cp -a ${mount_dir}/sbin/e2fsck /tmp/utils/
cp -a ${mount_dir}/sbin/fsck.ext2 /tmp/utils/
cp -a ${mount_dir}/sbin/fsck.ext4 /tmp/utils/
echo "Done."

echo "Updating target filesystems UUIDs..."
if [ "${boot_mode}" = "legacy" ]; then
    /usr/sbin/tune2fs -U random "${target_dev}${onie_dev_num}"
    /usr/sbin/tune2fs -U random "${target_dev}${iss_inst_dev_num}"
fi
sync
BOOT_UUID=`/usr/sbin/tune2fs -l ${target_dev}${onie_dev_num} | grep -o "^Filesystem UUID: .*" | awk '{print $3}'`
ROOT_UUID=`/usr/sbin/tune2fs -l ${target_dev}${iss_inst_dev_num} | grep -o "^Filesystem UUID: .*" | awk '{print $3}'`
echo "Done."

echo "Generating list of mounted filesystems..."
rm -f ${mount_dir}/etc/mtab
egrep '^/dev/' /proc/mounts | grep '/mnt/' | sed -e 's@/mnt/@/@' > ${mount_dir}/etc/mtab
echo "Done."

echo "Generating /etc/fstab for the target root filesystem..."
cat > ${mount_dir}/etc/fstab <<___EOF___
# fstab
UUID=${ROOT_UUID}	/	ext4	discard,errors=continue,noatime	0	1
UUID=${BOOT_UUID}	${boot_dir}	ext2	defaults,noatime	0	1
___EOF___
echo "Done."

# iss has special console login
if [ ! -f ${mount_dir}/usr/bin/iss ] ; then
    echo "Enabling login on the serial console..."
    if [ -f ${mount_dir}/etc/inittab ] ; then
      sed -i -e 's/^#\+T0:/T0:/' -e 's/ttyS0 9600 vt100$/ttyS0 115200 vt100/' ${mount_dir}/etc/inittab
      echo "Done."
    else
      if [ -d ${mount_dir}/etc/init/ ] ; then
        cat > ${mount_dir}/etc/init/ttyS0.conf <<___EOF___
# ttyS0 - getty
#
# This service maintains a getty on tty1 from the point the system is
# started until it is shut down again.

start on stopped rc RUNLEVEL=[2345] and (
            not-container or
            container CONTAINER=lxc or
            container CONTAINER=lxc-libvirt)

stop on runlevel [!2345]

respawn
exec /sbin/getty -8 115200 ttyS0
___EOF___
        echo "Done."
      else
        echo "No recognizable login configuration found."
      fi
    fi
fi

if [[ "$DEBUG" = "1" ]]; then
    read -p "About to update GRUB. Press <enter> key to continue..."
fi

echo "Updating GRUB..."
grub_default_path="/tmp/grub-variables"
grub_onie_path="/tmp/50_onie_grub_imt"

# Import grub-variables from install package
cp grub-variables ${grub_default_path}

# Import script to add NOS entry and ONIE submenu
cp 50_onie_grub_imt ${grub_onie_path}

if [[ "$DEBUG" = "1" ]]; then
    read -p "About to grub-install. Press <enter> key to continue..."
fi

cp ${grub_onie_path} ${mount_dir}/etc/grub.d/50_onie_grub
cp ${grub_default_path} ${mount_dir}/etc/default/grub
chmod 755 ${mount_dir}/etc/grub.d/50_onie_grub

if [ "${boot_mode}" = "uefi" ]; then
    efi_root_path="/boot/efi"
    if [ ! -d "${efi_root_path}" ]; then
        mkdir -p "${efi_root_path}"
        mount -t vfat "${target_dev}${efi_dev_num}" "${efi_root_path}"
    fi
    grub-install \
        --target=x86_64-efi \
        --no-nvram \
        --bootloader-id="${iss_volume_label}1" \
        --efi-directory="${efi_root_path}" \
        --boot-directory="${mount_dir}/boot" \
        "${target_dev}" 2>&1 || {
        echo "ERROR: grub-install failed on: ${target_dev}"
    }
    chroot ${mount_dir} update-grub || echo "Error: update-grub failed with error $?"

    efibootmgr --quiet --create \
        --label "${iss_volume_label}1" \
        --disk ${target_dev} --part ${efi_dev_num} \
        --loader "/EFI/${iss_volume_label}1/grubx64.efi" || {
        echo "ERROR: efibootmgr failed to create new boot variable on: ${target_dev}"
    }

    boot_num=$(efibootmgr -v | grep "${iss_volume_label}1" | grep ')/File(' | \
        tail -n 1 | awk '{ print $1 }' | sed -e 's/Boot//' -e 's/\*//')
    boot_order=$(efibootmgr | grep BootOrder: | awk '{ print $2 }' | \
        sed -e s/,$boot_num// -e s/$boot_num,// -e s/$boot_num//)
    if [ -n "$boot_order" ] ; then
        boot_order="${boot_num},$boot_order"
    else
        boot_order="$boot_num"
    fi
    efibootmgr --quiet --bootorder "$boot_order" || {
        echo "ERROR: efibootmgr failed to set new boot order"
        return 1
    }
else
    if [[ "${partition_type}" = "gpt" ]]; then
        core_img="${iss_boot_dir}/grub/i386-pc/core.img"
        [ -f "${core_img}" ] && chattr -i ${core_img}
        grub-install --boot-directory="${iss_boot_dir}/" "${target_dev}" 2>&1 || {
            echo "ERROR: grub-install failed on: ${target_dev}"
        }
        chroot ${mount_dir} update-grub || echo "Error: update-grub failed with error $?"
        [ -f "${core_img}" ] && chattr +i ${core_img}
    else
        rm -rf ${boot_dir}/vmlinuz-00-onie
        rm -rf ${boot_dir}/initrd.img-00-onie
        [ -f "${iss_boot_dir}/grub/i386-pc/core.img" ] && chattr -i ${iss_boot_dir}/grub/i386-pc/core.img
        chroot ${mount_dir} grub-install "${target_dev}"
        chroot ${mount_dir} update-grub
        chroot ${mount_dir} grub-install "${target_dev}"
        [ -f "${iss_boot_dir}/grub/i386-pc/core.img" ] && chattr +i ${iss_boot_dir}/grub/i386-pc/core.img
    fi # partition_type
fi # boot_mode

if [[ "$DEBUG" = "1" ]]; then
    read -p "About to create ISS menuentry in GRUB. Press <enter> key to continue..."
fi

# Modify GRUB configuration file with the ISS custom entries
if [ -f ${mount_dir}/usr/bin/iss ] ; then
    # iss and iss-dbg packages has the same description, so take only the first version
    iss_image_version=$(chroot ${mount_dir} dpkg -l | grep "Switching platform" | awk '{print $3}' | head -n 1 | tr -d '\n')
    iss_image_name=$(echo "iss-release-$iss_image_version" | tr -d '\n')
    menuentry_id=0
    iss_kernel_file="`ls ${iss_boot_dir}/vmlinuz-*-im-amd64 | rev | cut -d'/' -f 1 | rev | tr -d '\n'`"
    iss_ramdisk_file="`ls ${iss_boot_dir}/initrd.img-*-im-amd64 | rev | cut -d'/' -f 1 | rev | tr -d '\n'`"

    fs_uuid=${BOOT_UUID}
    if [ "${partition_type}" = "gpt" ]; then
        menuentry_partition_module="part_gpt"
    else
        menuentry_partition_module="part_msdos"
    fi

    GRUB_LINUX_CMD="linux"
    GRUB_INITRD_CMD="initrd"
    GRUB_DEFAULT_CONSOLE_LINE=""
    GRUB_EFI_MODE=""
    if [ "$boot_mode" == "uefi" ]; then
        GRUB_LINUX_CMD="linuxefi"
        GRUB_INITRD_CMD="initrdefi"
        GRUB_EFI_MODE="efi"
        # Conga-MA5 uses ttyS2 console as default
        if [ "$(/usr/bin/dmidecode -t baseboard | grep -ow 'conga-MA5')" == "conga-MA5" ]; then
            GRUB_DEFAULT_CONSOLE_LINE="console=ttyS2,115200n8"
        fi
    fi
    cat > /tmp/grub_$menuentry_id.cfg <<___EOF___
### BEGIN /etc/grub.d/10_linux ###
menuentry '$iss_image_name' --unrestricted --class debian --class gnu-linux --class gnu --class os {
    entry_id=$menuentry_id
    insmod ext2
    insmod gzio
    insmod ${menuentry_partition_module}
    search --no-floppy --set=root --fs-uuid ${fs_uuid}
    echo    'Loading $iss_image_name ${GRUB_EFI_MODE}...'
    ${GRUB_LINUX_CMD}   /$iss_kernel_file root="${target_dev}${iss_inst_dev_num}" ro console=tty0 ${GRUB_DEFAULT_CONSOLE_LINE} console=ttyS0,115200n8 quiet nomodeset irqpoll hpet=disable fsck.mode=force fsck.repair=yes
    echo    'Loading initial ramdisk ${GRUB_EFI_MODE}...'
    ${GRUB_INITRD_CMD}  /$iss_ramdisk_file
}
### END /etc/grub.d/10_linux ###
___EOF___

    grub_cfg="/tmp/grub_base_${menuentry_id}.cfg"

    touch $grub_cfg

    if [[ "${partition_type}" = "gpt" ]]; then
        [ -f "${onie_boot_dir}/onie/grub/grub-extra.cfg" ] && cat ${onie_boot_dir}/onie/grub/grub-extra.cfg >> $grub_cfg
    else
        [ -f "${boot_dir}/onie/grub/grub-extra.cfg" ] && cat ${onie_boot_dir}/onie/grub/grub-extra.cfg >> $grub_cfg
    fi

    . ${grub_default_path}
    # cp ${grub_default_path} ${boot_dir}/onie/grub/grub-variables

    cat <<EOF >> $grub_cfg
if [ -s \$prefix/grubenv ]; then
load_env
fi
if [ "\${next_entry}" ] ; then
set default="\${next_entry}"
set next_entry=
save_env next_entry
fi

EOF

    cat <<EOF >> $grub_cfg
# begin: ONIE bootargs

onie_initargs="$GRUB_CMDLINE_LINUX"
onie_initargs_default="$GRUB_CMDLINE_LINUX_DEFAULT"
onie_platformargs="$GRUB_ONIE_PLATFORM_ARGS"
onie_debugargs="$GRUB_ONIE_DEBUG_ARGS"
GRUB_ONIE_CMDLINE_LINUX="$GRUB_ONIE_CMDLINE_LINUX"

# end: ONIE bootargs
EOF

    cat /tmp/grub_$menuentry_id.cfg >> $grub_cfg
    eval source ${grub_onie_path} >> $grub_cfg
    cp $grub_cfg ${iss_boot_dir}/grub/grub.cfg
fi

if [[ "$DEBUG" = "1" ]]; then
    read -p "About to copy onie kernel and rootfs. Press <enter> key to continue..."
fi

echo "Updating ONIE from target system"

# Do not make this to appear in ONIE menu.
onie_kernel_file="`ls ${iss_boot_dir}/onie/vmlinuz-*-onie | head -n 1`"
onie_ramdisk_file="`ls ${iss_boot_dir}/onie/initrd.img-*-onie | head -n 1`"
if [ -f "${onie_kernel_file}" -a -f "${onie_ramdisk_file}" ]
then
    echo "Adding ONIE files..."
    cp "${onie_kernel_file}" ${onie_boot_dir}/onie/vmlinuz-00-onie
    cp "${onie_ramdisk_file}" ${onie_boot_dir}/onie/initrd.img-00-onie
fi
echo "Done."

if [[ "$DEBUG" = "1" ]]; then
    read -p "About umount all partitions. Press <enter> key to continue..."
fi

echo "Un-mounting everything..."
until umount ${mount_dir}/proc ; do sleep 1 ; done
until umount ${mount_dir}/sys ; do sleep 1 ; done
until umount ${mount_dir}/dev ; do sleep 1 ; done
# umount ONIE-BOOT
until umount ${target_dev}${onie_dev_num} ; do sleep 1 ; done
# umount NOS
until umount ${target_dev}${iss_inst_dev_num} ; do sleep 1 ; done

echo "Done."

if [[ "$DEBUG" = "1" ]]; then
    read -p "About to fsck. Press <enter> key to continue..."
fi

echo "Resizing the target root filesystem..."
/tmp/utils/fsck.ext4 -f -y "${target_dev}${iss_inst_dev_num}"
/tmp/utils/resize2fs "${target_dev}${iss_inst_dev_num}"
echo "Done."
echo "Installation finished successfully."

if [[ "$DEBUG" = "1" ]]; then
    read -p "About to reboot the system. Press <enter> key to continue..."
fi

exit 0
