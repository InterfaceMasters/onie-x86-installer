#!/bin/sh

image_location=`echo "${onie_exec_url}" | sed -e 's/\.sh$/-image.bin/'`

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

[ ! -b ${target_dev} ] && {
echo "No target device detected."
exit 1
}

umount "${target_dev}1" 2>/dev/null
umount "${target_dev}2" 2>/dev/null
umount "${target_dev}3" 2>/dev/null
umount "${target_dev}4" 2>/dev/null
umount "${target_dev}5" 2>/dev/null

parted -ms "${target_dev}" \
 `parted -ms "${target_dev}" "unit s" "print" | \
 egrep "^[0-9]+:" | egrep -v "^1:" | cut -d: -f1 | sort -rn | \
 sed -e 's/^/"rm /' -e 's/:.\+$/"/' `

lastsector=`parted -ms "${target_dev}" "unit s" "print" | \
egrep "^1:" | cut -d: -f3 | tr -d 's'`

[ "$lastsector" = "" ] && {
  if [ -x /self-installer/format-installer.sh ] ; then
  /self-installer/format-installer.sh
  parted -ms "${target_dev}" \
  `parted -ms "${target_dev}" "unit s" "print" | \
  egrep "^[0-9]+:" | egrep -v "^1:" | cut -d: -f1 | sort -rn | \
   sed -e 's/^/"rm /' -e 's/:.\+$/"/' `
  lastsector=`parted -ms "${target_dev}" "unit s" "print" | \
  egrep "^1:" | cut -d: -f3 | tr -d 's'`
  [ "$lastsector" = "" ] && {
    echo "Installation failed."
    exit 1
    }
  else
    echo "Incompatible partition format on the device ${target_dev}."
    exit 1
  fi
}

newsector="$((${lastsector}+1))"
                                                                                
parted -msaoptimal "$target_dev" "mkpart primary ext4 ${newsector}s -1s"

sync
until blockdev --rereadpt "${target_dev}"
do sleep 1
done

echo "Installing image from ${image_location}..."
wget -O- "${image_location}" | bzip2 -dc | ./partclone.restore -q -s - -o "${target_dev}"2 || {
echo "Image installation failed."
exit 1
}

mkdir /mnt 2>/dev/null

echo "Mounting target root filesystem..."
until mount -t ext4 "${target_dev}2" /mnt
do sleep 1
done
echo "Done."

echo "Saving /boot directory on the target root filesystem..."
tar cz -C /mnt boot > /tmp/boot-fs.tar.gz
echo "Done."

echo "Removing /boot directory from the target root filesystem..."
rm -rf /mnt/boot
echo "Done."

echo "Creating empty /boot directory on the target root filesystem..."
mkdir /mnt/boot
echo "Done."

echo "Mounting target boot filesystem..."
until mount -t ext2 "${target_dev}1" /mnt/boot
do sleep 1
done
echo "Done."

echo "Restoring /boot directory to the boot filesystem"
tar xz -C /mnt < /tmp/boot-fs.tar.gz
rm /tmp/boot-fs.tar.gz
echo "Done."

echo "Mounting /dev, /sys, /proc directories on the target root filesystem..."
mount -t tmpfs tmpfs-dev /mnt/dev
tar c /dev | tar x -C /mnt
mount --bind /sys /mnt/sys
mount --bind /proc /mnt/proc
echo "Done."

echo "Copying disk utilities..."
mkdir /tmp/utils
cp /mnt/sbin/resize2fs /tmp/utils/
cp -a /mnt/lib/x86_64-linux-gnu /lib/x86_64-linux-gnu
cp -a /mnt/lib64 /lib64
cp -a /mnt/sbin/e2fsck /tmp/utils/
cp -a /mnt/sbin/fsck.ext2 /tmp/utils/
cp -a /mnt/sbin/fsck.ext4 /tmp/utils/
echo "Done."

echo "Updating target filesystems UUIDs..."
/mnt/sbin/tune2fs -U random "${target_dev}1"
/mnt/sbin/tune2fs -U random "${target_dev}2"
sync
BOOT_UUID=`/mnt/sbin/blkid -s UUID -o value -n ext2,ext3,ext4 "${target_dev}1"`
ROOT_UUID=`/mnt/sbin/blkid -s UUID -o value -n ext2,ext3,ext4 "${target_dev}2"`
rm -f "/mnt/dev/disk/by-uuid/${ROOT_UUID}"
ln -s "${target_dev}2" "/mnt/dev/disk/by-uuid/${ROOT_UUID}"
echo "Done."

#echo "Removing original GRUB..."
#
#rm -rf /mnt/boot/grub
#
#echo "Done."

echo "Generating list of mounted filesystems..."
rm -f /mnt/etc/mtab
egrep '^/dev/' /proc/mounts | grep '/mnt/' | sed -e 's@/mnt/@/@' > /mnt/etc/mtab
echo "Done."

echo "Generating /etc/fstab for the target root filesystem..."
cat > /mnt/etc/fstab <<___EOF___
# fstab
UUID=${ROOT_UUID}	/	ext4	errors=remount-ro,noatime	0	1
UUID=${BOOT_UUID}	/boot	ext2	defaults,noatime	0	1
___EOF___
echo "Done."

echo "Enabling login on the serial console..."
if [ -f /mnt/etc/inittab ] ; then
  sed -i -e 's/^#\+T0:/T0:/' -e 's/ttyS0 9600 vt100$/ttyS0 115200 vt100/' \
   /mnt/etc/inittab
  echo "Done."
else
  if [ -d /mnt/etc/init/ ] ; then
    cat > /mnt/etc/init/ttyS0.conf <<___EOF___
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

onie_kernel_file="`ls /mnt/boot/onie/vmlinuz-*-onie | head -n 1`"
onie_ramdisk_file="`ls /mnt/boot/onie/initrd.img-*-onie | head -n 1`"
if [ -f "${onie_kernel_file}" -a -f "${onie_ramdisk_file}" ]
  then
    echo "Adding ONIE files..."
    cp "${onie_kernel_file}" /mnt/boot/vmlinuz-00-onie
    cp "${onie_ramdisk_file}" /mnt/boot/initrd.img-00-onie
fi

echo "Updating GRUB..."
cat > /mnt/etc/default/grub <<___EOF___
# If you change this file, run 'update-grub' afterwards to update
# /boot/grub/grub.cfg.
# For full documentation of the options in this file, see:
#   info -f grub -n 'Simple configuration'

GRUB_DEFAULT=0
#GRUB_HIDDEN_TIMEOUT=0
GRUB_HIDDEN_TIMEOUT_QUIET=true
GRUB_TIMEOUT=10
GRUB_DISTRIBUTOR=\`lsb_release -i -s 2> /dev/null || echo Debian\`
GRUB_CMDLINE_LINUX_DEFAULT="quiet nomodeset"
GRUB_CMDLINE_LINUX="console=tty0 console=ttyS0,115200n8"

# Uncomment to enable BadRAM filtering, modify to suit your needs
# This works with Linux (no patch required) and with any kernel that obtains
# the memory map information from GRUB (GNU Mach, kernel of FreeBSD ...)
#GRUB_BADRAM="0x01234567,0xfefefefe,0x89abcdef,0xefefefef"

# Uncomment to disable graphical terminal (grub-pc only)
#GRUB_TERMINAL=console
GRUB_TERMINAL=serial
GRUB_SERIAL_COMMAND="serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1"

# The resolution used on graphical terminal
# note that you can use only modes which your graphic card supports via VBE
# you can see them in real GRUB with the command \`vbeinfo'
#GRUB_GFXMODE=640x480

# Uncomment if you don't want GRUB to pass "root=UUID=xxx" parameter to Linux
#GRUB_DISABLE_LINUX_UUID=true

# Uncomment to disable generation of recovery mode menu entries
#GRUB_DISABLE_RECOVERY="true"

# Uncomment to get a beep at grub start
#GRUB_INIT_TUNE="480 440 1"
___EOF___
cat > /mnt/etc/grub.d/50_onie_grub <<___EOF___
#!/bin/sh

#  Copyright (C) 2014 Curt Brune <curt@cumulusnetworks.com>
#  Copyright (C) 2015 Interface Masters Technologies, Inc.
#
#  SPDX-License-Identifier:     GPL-2.0

# This file provides a GRUB menu entry for ONIE.
#
# Place this file in /etc/grub.d on the installed system, and grub-mkconfig
# will use this file when generating a grub configuration file.
#
# This partition layout uses the same ONIE-BOOT partition for ONIE and OS boot
# files, so only one GRUB menu has to be updated.

tmp_mnt=
onie_umount_partition()
{
    umount \$tmp_mnt > /dev/null 2>&1
    rmdir \$tmp_mnt || {
        echo "ERROR: Problems removing temp directory: \$tmp_mnt"
        exit 1
    }
}

# Mount the ONIE partition
tmp_mnt=\$(mktemp -d)
trap onie_umount_partition EXIT

mount LABEL=ONIE-BOOT \$tmp_mnt || {
    echo "ERROR: Problems trying to mount ONIE-BOOT partition"
    exit 1
}

onie_root_dir="\${tmp_mnt}/onie"
[ -d "\$onie_root_dir" ] || {
    echo "ERROR: Unable to find ONIE root directory: \$onie_root_dir"
    exit 1
}

# add the ONIE machine configuration data
cat \$onie_root_dir/grub/grub-machine.cfg

# add ONIE configuration common to all ONIE boot modes
cat \$onie_root_dir/grub/grub-common.cfg

DEFAULT_CMDLINE="\$GRUB_CMDLINE_LINUX \$GRUB_CMDLINE_LINUX_DEFAULT \$GRUB_ONIE_PLATFORM_ARGS \$GRUB_ONIE_DEBUG_ARGS"
GRUB_ONIE_CMDLINE_LINUX=\${GRUB_ONIE_CMDLINE_LINUX:-"\$DEFAULT_CMDLINE"}

ONIE_CMDLINE="quiet \$GRUB_ONIE_CMDLINE_LINUX"
cat << EOF
submenu ONIE {
EOF
for mode in install rescue uninstall update embed ; do
    case "\$mode" in
        install)
            boot_message="ONIE: OS Install Mode ..."
            ;;
        rescue)
            boot_message="ONIE: Rescue Mode ..."
            ;;
        uninstall)
            boot_message="ONIE: OS Uninstall Mode ..."
            ;;
        update)
            boot_message="ONIE: ONIE Update Mode ..."
            ;;
        embed)
            boot_message="ONIE: ONIE Embed Mode ..."
            ;;
        *)
            ;;
    esac
      cat <<EOF
menuentry "\\\$onie_menu_\$mode" {
        onie_entry_start
        echo    "\$boot_message"
        linux   /onie/vmlinuz-\\\${onie_kernel_version}-onie \$ONIE_CMDLINE boot_reason=\$mode
        initrd  /onie/initrd.img-\\\${onie_kernel_version}-onie
        onie_entry_end
}
EOF
done
cat << EOF
}
EOF
___EOF___
chmod 755 /mnt/etc/grub.d/50_onie_grub

chroot /mnt grub-install "${target_dev}"
chroot /mnt update-grub
chroot /mnt grub-install "${target_dev}"
echo "Done."

echo "Un-mounting everything..."
until umount /mnt/proc ; do sleep 1 ; done
until umount /mnt/sys ; do sleep 1 ; done
until umount /mnt/dev ; do sleep 1 ; done
until umount /mnt/boot ; do sleep 1 ; done
until umount /mnt ; do sleep 1 ; done
echo "Done."

echo "Resizing the target root filesystem..."
/tmp/utils/fsck.ext4 -f -y "${target_dev}2"
/tmp/utils/resize2fs "${target_dev}2"
echo "Done."
echo "Installation finished successfully."
exit 0
