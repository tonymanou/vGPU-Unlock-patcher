#!/bin/bash

GNRL="NVIDIA-Linux-x86_64-510.73.05"
VGPU="NVIDIA-Linux-x86_64-510.73.06-vgpu-kvm"
GRID="NVIDIA-Linux-x86_64-510.73.08-grid"

SPOOF=true

VER_VGPU=`echo ${VGPU} | awk -F- '{print $4}'`
VER_GRID=`echo ${GRID} | awk -F- '{print $4}'`

CP="cp -a"

case `stat -f --format=%T .` in
    btrfs | xfs)
        CP="$CP --reflink"
        ;;
esac

VERIFY_BLOBPATCH=false
if [ -n "`which xxd`" ]; then
    VERIFY_BLOBPATCH=true
fi

vcfgclone() {
    echo "vcfgclone ${2#0x}:${3#0x} -> ${4#0x}:${5#0x}"
    sed -e '/<pgpu/ b found' -e b -e ':found' -e '/<\/pgpu>/ b clone' -e N -e 'b found' \
        -e ':clone' -e p -e "s/\(.* deviceId=\"\)${2}\(\" subsystemVendorId=\"\)0x10de\(\" subsystemId=\"\)${3}\(\".*\)/\1${4}\20x10de\3${5}\4/" -e t -e d -i ${1}
}

vcfgpatch() {
    echo "vcfgpatch ${2#0x}:${3#0x} -> ${4#0x}:${5#0x}"
    sed -e "s/\(.* deviceId=\"\)${2}\(\" subsystemVendorId=\"\)0x10de\(\" subsystemId=\"\)${3}\(\".*\)/\1${4}\20x10de\3${5}\4/" -i ${1}
}


DO_VGPU=false
DO_GRID=false
DO_MRGD=false

if [ "$1" = "--no-spoof" ]; then
    shift
    SPOOF=false
fi

case "$1" in
    vgpu*)
        DO_VGPU=true
        SOURCE="${VGPU}"
        TARGET="${VGPU}-patched"
        ;;
    grid)
        DO_GRID=true
        SOURCE="${GRID}"
        TARGET="${GRID}-patched"
        ;;
    general)
        DO_GRID=true
        GRID="${GNRL}"
        SOURCE="${GRID}"
        TARGET="${GRID}-patched"
        ;;
    grid-merge)
        DO_VGPU=true
        DO_GRID=true
        DO_MRGD=true
        MRGD="${GRID}-vgpu-kvm"
        SOURCE="${MRGD}"
        TARGET="${MRGD}-patched"
        ;;
    general-merge)
        DO_VGPU=true
        DO_GRID=true
        DO_MRGD=true
        GRID="${GNRL}"
        MRGD="${VGPU}-merged"
        SOURCE="${MRGD}"
        TARGET="${MRGD}-patched"
        ;;
    vcfg)
        shift
        [ $# -eq 5 -a -e "$1" ] || {
            echo "Usage: $0 vcfg xmlfile devid subdevid cdevid csubdevid"
            exit 1
        }
        vcfgclone "$@"
        #vcfgpatch "$@"
        exit $?
        ;;
    *)
        echo "Usage: $0 <vgpu-kvm | grid | general | grid-merge | general-merge | vcfg>"
        exit 1
        ;;
esac

VER_TARGET=`echo ${SOURCE} | awk -F- '{print $4}'`

die() {
    echo "$@"
    exit 1
}

extract() {
    [ -e ${1} ] || die "package ${1} not found"
    if [ -d ${1%.run} ]; then
        echo "WARNING: skipping extract of ${1} as it seems already extracted"
        return 0
    fi
    sh ${1} --extract-only
    chmod -R u+w ${1%.run}
}

blobpatch_byte() {
    echo -n "blobpatch ${2}: ${3} ${4}"
    CHK=""
    if $VERIFY_BLOBPATCH; then
        CHK=$(dd if=${1} skip=`printf "%d" 0x${2}` bs=1 count=1 2>/dev/null | xxd -u -i | sed -e 's/ *0[xX]//')
    fi
    if [ -z "${CHK}" -o "${CHK}" = "${3}" ]; then
        echo -e -n "\x${4}" | dd of=${1} seek=`printf "%d" 0x${2}` bs=1 count=1 conv=notrunc &>/dev/null
        if [ -n "${CHK}" ]; then
            echo " [x]"
        else
            echo
        fi
    else
        echo
        die "blobpatch failed: expected ${3} got ${CHK} instead"
    fi
}

blobpatch() {
    echo "blobpatch ${2}"
    local status=2
    while read addr a b && [ -n "${addr}" ]
    do
        if [ "${addr%:}" != "${addr}" ]; then
            blobpatch_byte ${1} ${addr%:} ${a} ${b} || break
        else
            sum=`sha256sum -b ${1} | awk '{print $1}'`
            [ "${sum}" != "${addr}" ] && break
            status=$(($status - 1))
        fi
    done < ${2}
    [ $status -ne 0 ] && echo "blobpatch of ${1} failed, status=$status"
    return $status
}

applypatch() {
    echo "applypatch ${2}"
    patch -d ${1} -p1 --no-backup-if-mismatch < patches/${2}
}

$DO_VGPU && extract ${VGPU}.run
$DO_GRID && extract ${GRID}.run

if $DO_MRGD; then
    echo "about to create merged driver"
    rm -rf ${SOURCE}
    mkdir ${SOURCE}
    $CP ${VGPU}/. ${SOURCE}
    rm ${SOURCE}/libnvidia-ml.so.${VER_VGPU}
    $CP ${GRID}/. ${SOURCE}
    if [ "${GRID/${TARGET_VER}}" = "${GRID}" ]; then
        USE_KVM_BLOB="kernel/nvidia/nv-kernel.o_binary"
    else
        USE_KVM_BLOB=""
    fi
    for i in LICENSE kernel/nvidia/nvidia-sources.Kbuild init-scripts/{post-install,pre-uninstall} nvidia-bug-report.sh ${USE_KVM_BLOB}
    do
        $CP ${VGPU}/$i ${SOURCE}/$i
    done
    sed -e '/^# VGX_KVM_BUILD/aVGX_KVM_BUILD=1' -i ${SOURCE}/kernel/conftest.sh
    sed -e 's/^\(nvidia .*nvidia-drm.*\)/\1 nvidia-vgpu-vfio/' -i ${SOURCE}/.manifest
    diff -u ${VGPU}/.manifest ${GRID}/.manifest \
    | grep -B 1 '^-.* MODULE:\(vgpu\|installer\)$' | grep -v '^--$' \
    | sed -e '/^ / s:/:\\/:g' -e 's:^ \(.*\):/\1/ a \\:' -e 's:^-\(.*\):\1\\:' | head -c -2 \
    | sed -e ':append' -e '/\\\n\// b found' -e N -e 'b append' -e ':found' -e 's:\\\n/:\n/:' \
    > manifest-merge.sed
    echo "merging .manifest file"
    sed -f manifest-merge.sed -i ${SOURCE}/.manifest
    rm manifest-merge.sed
    [ -e ${SOURCE}/nvidia-gridd ] && applypatch ${SOURCE} vgpu-kvm-merge-grid-scripts.patch
    applypatch ${SOURCE} disable-nvidia-blob-version-check.patch
fi

rm -rf ${TARGET}
mkdir -p ${TARGET}/kernel/unlock
$CP ${SOURCE}/. ${TARGET}

echo "applying vgpu_unlock hooks"
$CP unlock/kern.ld ${TARGET}/kernel/nvidia
$CP unlock/vgpu_unlock_hooks.c ${TARGET}/kernel/unlock
echo 'ldflags-y += -T $(src)/nvidia/kern.ld' >> ${TARGET}/kernel/nvidia/nvidia.Kbuild
sed -e 's:^\(#include "nv-time\.h"\):\1\n#include "../unlock/vgpu_unlock_hooks.c":' -i ${TARGET}/kernel/nvidia/os-interface.c
sed -i ${TARGET}/.manifest -e '/^kernel\/nvidia\/i2c_nvswitch.c / a \
kernel/unlock/vgpu_unlock_hooks.c 0644 KERNEL_MODULE_SRC INHERIT_PATH_DEPTH:1 MODULE:vgpu\
kernel/nvidia/kern.ld 0644 KERNEL_MODULE_SRC INHERIT_PATH_DEPTH:1 MODULE:vgpu'
applypatch ${TARGET} vgpu_unlock_hooks-510.patch

if $SPOOF; then
    echo "applying spoof devid kprobe hook"
    $CP patches/spoof_hook.c ${TARGET}/kernel/unlock
    echo 'NVIDIA_SOURCES += unlock/spoof_hook.c' >> ${TARGET}/kernel/nvidia/nvidia-sources.Kbuild
    sed -e '/^NVIDIA_CFLAGS += .*DEBUG/aNVIDIA_CFLAGS += -DSPOOF_ID' -i ${TARGET}/kernel/nvidia/nvidia.Kbuild
    sed -i ${TARGET}/.manifest -e '/^kernel\/nvidia\/i2c_nvswitch.c / a \
kernel/unlock/spoof_hook.c 0644 KERNEL_MODULE_SRC INHERIT_PATH_DEPTH:1 MODULE:vgpu'
    applypatch ${TARGET} setup-kprobe-for-spoofid-hook.patch
else
    echo "spoof devid kprobe hook NOT applied"
fi

blobpatch ${TARGET}/kernel/nvidia/nv-kernel.o_binary patches/blob-${VER_TARGET}.diff || exit 1

if $DO_VGPU; then
    vcfgclone ${TARGET}/vgpuConfig.xml 0x1E30 0x12BA 0x1E84 0x0000
fi
