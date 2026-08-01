# H96 Max RK3528 Armbian patch

Small overlay for building a minimal Armbian kernel image for the H96
Max RK3528. 

Working:

- boot from SD-card with stock firmware
- Ethernet
- HDMI
- others not tested

The [original stock Android boot log](logs/stock-boot.log) is included for hardware
comparison.

The full device tree extracted from the original boot image is included for
reference as [original-rk3528-evb2-ddr3-v10.dts](dts/original-rk3528-evb2-ddr3-v10.dts).

Board photos and UART port locations: https://forum.armbian.com/topic/59122-h96-max-rk3528-cannot-boot-armbian-from-tfsd-card/

## Build

Clone this repository, then run the following from its root directory.  The
upstream Armbian checkout is created locally as `armbian-build/` and is
ignored by Git.

```bash
git clone --depth=1 https://github.com/armbian/build armbian-build
cp -R patches/* armbian-build/
cd armbian-build

./compile.sh build \
  BOARD=rk3528-h96max \
  BRANCH=vendor \
  BUILD_MINIMAL=yes \
  BUILD_DESKTOP=no \
  RELEASE=trixie \
  KERNEL_CONFIGURE=no \
  KERNEL_GIT=shallow
```

The finished image is written to `armbian-build/output/images/`.

## Writing to SD card

```bash

# Check location of SD card:
lsblk -o NAME,SIZE,MODEL,TRAN,MOUNTPOINTS

# Write the image to the SD card:
sudo dd \
  if=armbian-build/output/images/Armbian-unofficial_26.08.0-trunk_rk3528-h96max_trixie_vendor_6.1.115_minimal.img \
  of={SD card location} \
  bs=16M \
  oflag=direct \
  conv=fsync \
  status=progress

sync
```

## License

Licensed under [GPL-2.0](LICENSE).
