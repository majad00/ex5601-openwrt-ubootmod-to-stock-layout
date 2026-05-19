# UART free Zyxel ex5601 OpenWrt to OEM . and OpenWrt ubootmod to OpenWrt stock Converter ( Project B)
UART-free conversion between OpenWrt ubootmod, OpenWrt stock layout, and OEM Zyxel firmware for EX5601-T0 /T-56.
 If you have Openwrt ubootmod installed on EX5601-T0 / T-56 router
 With this tool you can 
 1) Convert Openwrt ubootmod to Openwrt stock layout
 2) Convert Openwrt to OEM zyxel firmware

> [!WARNING]
> Power loss during flash can brick the device.
> Keep backups of important MTD partitions before flash

## Installation

Download the three required files from latest release https://github.com/majad00/zyxel-ex5601-openwrt-to-OEM-converter/releases/tag/1.1

- `loader.sh`
- `openwrt_restore_bundle.tar.gz`
- `restore_bundle_ex5601.tar.gz`

Copy these two files to the router under `/tmp`:

- `loader.sh`
- `openwrt_restore_bundle.tar.gz`

Example:

```sh
scp loader.sh openwrt_restore_bundle.tar.gz root@192.168.1.1:/tmp/
```

SSH into the router and run:
```sh
cd /tmp
chmod +x loader.sh
./loader.sh
```

After the loader finishes, open LuCI and go to:
System > Matrix Installer
Upload this file from your computer when asked:

restore_bundle_ex5601.tar.gz

After the bundle is verified, choose the conversion option you want.
<img width="1099" height="627" alt="image" src="https://github.com/user-attachments/assets/cef461a1-9aca-4a30-a1db-dd773b203c08" />

### Building from source

Project A, B and C are part of main project and based on the source from 
https://github.com/majad00/ex5601_openwrt_loader


