#!/bin/bash
# directories:
# - ${BASE}/doc/stable-mt - the files in this dir
# - ${BASE}/source/linux-stable-mt - the kernel sources checked out from gitrepo
# - ${BASE}/result/stable-mt - the resulting kernel, modules etc. tar.gz files
# - ${CONFIG_DIR} - https://github.com/hexdump0815/kernel-config-options
# name: stb-mt8

# INFO this is for mt8183 based chromebooks - see also readme.cbm

BASE=`pwd`/../
PATCH_DIR=${BASE}/linux-mainline-mediatek-mt81xx-kernel
CONFIG_DIR=${BASE}/kernel-config-options
OUTPUT_DIR=${BASE}/result/stable-mt

[ -e scripts/kconfig/merge_config.sh ] || ( echo this script needs to be executed from within the linux-5.x.x directory; exit 1 )
[ -d ${PATCH_DIR} ] || ( echo ${PATCH_DIR} missing; exit 2 )
[ -d ${CONFIG_DIR} ] || ( echo ${CONFIG_DIR} missing; exit 3 )
[ -d ${OUTPUT_DIR} ] || mkdir -p ${OUTPUT_DIR}

do_patch() {
    # patches for mt8183/kukui
    for i in ${PATCH_DIR}/misc.cbm/patches/5.13.2/mt8183*.patch; do
        echo === $i
        patch -p1 < $i
    done
    for i in ${PATCH_DIR}/misc.cbm/patches/5.13.2/mt81xx*.patch; do
        echo === $i
        patch -p1 < $i
    done

    # add additional dts files from v5.14
    cp -v ${PATCH_DIR}/misc.cbm/misc/v5.14-dts/*.dts* arch/arm64/boot/dts/mediatek
    patch -p1 < ${PATCH_DIR}/misc.cbm/misc/v5.14-dts/add-v5.14-dts-files.patch
}

do_config() {
    # create kernel config
    export ARCH=arm64
    ./scripts/kconfig/merge_config.sh -m arch/arm64/configs/defconfig ${CONFIG_DIR}/chromebooks-aarch64.cfg ${CONFIG_DIR}/mediatek.cfg ${CONFIG_DIR}/docker-options.cfg ${CONFIG_DIR}/options-to-remove-generic.cfg ${PATCH_DIR}/misc.cbm/options/options-to-remove-special.cfg ${CONFIG_DIR}/additional-options-generic.cfg ${CONFIG_DIR}/additional-options-aarch64.cfg ${PATCH_DIR}/misc.cbm/options/additional-options-special.cfg

    ( cd ${CONFIG_DIR} ; git rev-parse --verify HEAD ) > ${PATCH_DIR}/misc.cbm/options/kernel-config-options.version

    make olddefconfig
    ./scripts/config --set-str CONFIG_LOCALVERSION "-stb-mt8"
}

do_build() {
    # build kernel
    make -j 8 Image dtbs modules
    cd tools/perf
    make
    cd ../power/cpupower
    make
    cd ../../..
}

do_install() {
    export kver=`make kernelrelease`
    echo ${kver}
    # remove debug info if there and not wanted
    #find . -type f -name '*.ko' | sudo xargs -n 1 objcopy --strip-unneeded
    make modules_install

    mkdir -p /lib/modules/${kver}/tools
    cp -v tools/perf/perf /lib/modules/${kver}/tools
    cp -v tools/power/cpupower/cpupower /lib/modules/${kver}/tools
    cp -v tools/power/cpupower/libcpupower.so.0.0.1 /lib/modules/${kver}/tools/libcpupower.so.0

    # make headers_install INSTALL_HDR_PATH=/usr
    cp -v .config /boot/config-${kver}
    cp -v arch/arm64/boot/Image /boot/Image-${kver}
    mkdir -p /boot/dtb-${kver}
    cp -v arch/arm64/boot/dts/mediatek/mt8183*.dtb /boot/dtb-${kver}
    cp -v System.map /boot/System.map-${kver}

    # start chromebook special - required: apt-get install liblz4-tool vboot-kernel-utils
    cp arch/arm64/boot/Image Image
    lz4 -f Image Image.lz4
    dd if=/dev/zero of=bootloader.bin bs=512 count=1
    cp ${PATCH_DIR}/misc.cbm/misc/cmdline cmdline

    mkimage -D "-I dts -O dtb -p 2048" -f auto -A arm64 -O linux -T kernel -C lz4 -a 0 -d Image.lz4 -b arch/arm64/boot/dts/mediatek/mt8183-kukui-jacuzzi-burnet.dtb -b arch/arm64/boot/dts/mediatek/mt8183-kukui-jacuzzi-damu.dtb -b arch/arm64/boot/dts/mediatek/mt8183-kukui-jacuzzi-fennel-sku6.dtb -b arch/arm64/boot/dts/mediatek/mt8183-kukui-jacuzzi-fennel14.dtb -b arch/arm64/boot/dts/mediatek/mt8183-kukui-jacuzzi-juniper-sku16.dtb -b arch/arm64/boot/dts/mediatek/mt8183-kukui-jacuzzi-kappa.dtb -b arch/arm64/boot/dts/mediatek/mt8183-kukui-jacuzzi-kenzo.dtb -b arch/arm64/boot/dts/mediatek/mt8183-kukui-jacuzzi-willow-sku0.dtb -b arch/arm64/boot/dts/mediatek/mt8183-kukui-jacuzzi-willow-sku1.dtb -b arch/arm64/boot/dts/mediatek/mt8183-kukui-kakadu.dtb -b arch/arm64/boot/dts/mediatek/mt8183-kukui-kodama-sku16.dtb -b arch/arm64/boot/dts/mediatek/mt8183-kukui-kodama-sku272.dtb -b arch/arm64/boot/dts/mediatek/mt8183-kukui-kodama-sku288.dtb -b arch/arm64/boot/dts/mediatek/mt8183-kukui-kodama-sku32.dtb -b arch/arm64/boot/dts/mediatek/mt8183-kukui-krane-sku0.dtb -b arch/arm64/boot/dts/mediatek/mt8183-kukui-krane-sku176.dtb -b arch/arm64/boot/dts/mediatek/mt8183-pumpkin.dtb kernel.itb kernel.itb

    vbutil_kernel --pack vmlinux.kpart --keyblock /usr/share/vboot/devkeys/kernel.keyblock --signprivate /usr/share/vboot/devkeys/kernel_data_key.vbprivk --version 1 --config cmdline --bootloader bootloader.bin --vmlinuz kernel.itb --arch arm

    cp -v vmlinux.kpart /boot/vmlinux.kpart-${kver}
    rm -f Image Image.lz4 cmdline bootloader.bin kernel.itb vmlinux.kpart
    # end chromebook special

    update-initramfs -c -k ${kver}
    #mkimage -A arm64 -O linux -T ramdisk -a 0x0 -e 0x0 -n initrd.img-${kver} -d initrd.img-${kver} uInitrd-${kver}
    tar cvzf ${kver}.tar.gz /boot/Image-${kver} /boot/System.map-${kver} /boot/config-${kver} /boot/dtb-${kver} /boot/initrd.img-${kver} /boot/vmlinux.kpart-${kver} /lib/modules/${kver}
    cp -v ${PATCH_DIR}/config.mt8 ${PATCH_DIR}/config.mt8.old
    cp -v .config ${PATCH_DIR}/config.mt8
    cp -v .config ${PATCH_DIR}/config.mt8-${kver}
    cp -v *.tar.gz ${OUTPUT_DIR}
}

case "$1" in
    patch)
        do_patch
        ;;
    config)
        set -e
        do_config
        ;;
    build)
        set -e
        do_build
        ;;
    install)
        set -e
        do_install
        ;;
    *)
        echo "Usage: $0 <patch|config|build|install>"
        ;;
esac

