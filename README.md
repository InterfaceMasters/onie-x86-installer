OS Installer for ONIE on x86 platform.
######################################

This installer is intended to be used with ONIE. It picks up an image produced with partclone and compressed with bzip2,
installs it on the hard drive (assuming that ONIE is already installed there), rebuilds GRUB configuration and installs GRUB as the bootloader loaded from MBR.

The current version works with Interface Masters hardware, and is compatible with im_devel branch of ONIE.
