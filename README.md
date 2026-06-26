### Convert Openwrt ubootmod ( Project B)

**This tool is for you If you have Openwrt ubootmod installed on EX5601-T0 / T-56 router
 and you want either**
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
```sh
cd /tmp

wget -O loader.sh "https://github.com/majad00/ex5601-openwrt-ubootmod-to-stock-layout/releases/download/1.1/loader.sh"
wget -O openwrt_restore_bundle.tar.gz "https://github.com/majad00/ex5601-openwrt-ubootmod-to-stock-layout/releases/download/1.1/openwrt_restore_bundle.tar.gz"

```

Make sure these two files are copied to router under `/tmp`:

- `loader.sh`
- `openwrt_restore_bundle.tar.gz`

you can use scp to do it for example:

```sh
scp loader.sh openwrt_restore_bundle.tar.gz root@192.168.1.1:/tmp/
```
Download this file and do not copy to router, it will stay at your PC.

```sh
wget -O restore_bundle_ex5601.tar.gz "https://github.com/majad00/ex5601-openwrt-ubootmod-to-stock-layout/releases/download/1.1/restore_bundle_ex5601.tar.gz"

```

SSH into the router and run:
```sh
cd /tmp
chmod +x loader.sh
./loader.sh
```

After the loader finishes, open LuCI and go to:
System > Matrix Installer
> Stage 2 will not start if you are not on Openwrt ubootmod layout

**AT THIS POINT JUST WAIT ABOUT TWO MIN, BEFORE PAGE REFRESH AND STAGE 2 STARTS.**

If you wait over two min and nothing happens, click the button to start stage 2 or manual enter url "http://192.168.1.1:18080/?v=1782494397729"

Upload this file that you lft on the computer, upload it from your computer when asked:

restore_bundle_ex5601.tar.gz

Once the second bundle file is uploaded, choose the conversion option you want. (See screenshot below)

<img width="1099" height="627" alt="image" src="https://github.com/user-attachments/assets/cef461a1-9aca-4a30-a1db-dd773b203c08" />

### Building from source

Project A, B and C are part of main project and based on the source from 
https://github.com/majad00/ex5601_openwrt_loader


