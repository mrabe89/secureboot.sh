# secureboot.sh

secureboot.sh is a very basic script to setup secureboot tailored specifically for my setup.

(Thinkpad running archlinux with dracut, systemd-boot and ESP mounted on /boot/efi)

I'd love to expand the usability further, but atm it works for me&trade;.

## Installing

AUR can be found [here](https://aur.archlinux.org/packages/secureboot.sh/)

## Setup

Initially a keypair must be genertated

```
secureboot.sh genKeys <CNBASE>
```

takes care of that and installs your in `/etc/secureboot/keys`.

CNBASE can be anything (f.e. hostname, full name, ...) and will be stored in the keys.

```
secureboot.sh installKeyTool
```
will install and sign the KeyTool (needed for loading the generated PK, KEK and db).

```
secureboot.sh signBootloader
```
will sign the installed systemd-boot UEFI binary. (`/boot/EFI/systemd/systemd-bootx64.efi`)

Finally to install/sign the unified UEFI kernel is done via.
```
secureboot.sh installKernel
```
This task will also run everytime the kernel is upgraded (via [secureboot.hook](secureboot.hook))
