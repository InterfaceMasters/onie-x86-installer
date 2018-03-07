# Interface Masters Technologies, Inc. 2016 - present.

## OS Installer for ONIE on x86 platform.

This installer is intended to be used with ONIE.
It picks up an image produced with partclone and compressed with bzip2, installs it on the hard drive
(assuming that ONIE is already installed there), rebuilds GRUB configuration and installs GRUB as the
bootloader loaded from MBR.

The current version works with Interface Masters hardware, and is compatible with master branch of ONIE.
More details in ONIE repository:

[https://github.com/opencomputeproject/onie](https://github.com/opencomputeproject/onie)

[Interface Masters Technologies, ONIE installation instructions](https://github.com/opencomputeproject/onie/blob/master/machine/imt/im_n29xx_t40n/INSTALL)
