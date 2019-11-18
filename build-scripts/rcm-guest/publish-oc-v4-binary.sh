#!/bin/bash
set -eux

rpm_name() {
    printf "${RPM}" "${arch}"
    [[ "${arch}" == x86_64 ]] && printf %s -redistributable
    printf %s "-*.git."
}

extract() {
    local arch rpm
    mkdir macosx windows
    for arch in x86_64 ${ARCH}; do
        rpm=$(ls $(rpm_name "${arch}")*)
        if [[ "${arch}" != x86_64 && ! -e "${rpm}" ]]; then continue; fi
        mkdir "${arch}"
        if [[ "${arch}" != x86_64 ]]; then
            rpm2cpio "${rpm}" | cpio -idm --quiet ./usr/bin/oc
            mv usr/bin/oc "${arch}"
        else
            rpm2cpio "${rpm}" | cpio -idm --quiet "./usr/share/*"
            # In 4.1, /usr/share/openshift. In 4.2 and subsequent, /usr/share/openshift-clients.
            mv usr/share/*/linux/oc x86_64/
            mv usr/share/*/macosx/oc macosx/
            mv usr/share/*/windows/oc.exe windows/
        fi
    done
}

pkg_tar() {
    local dir
    case "$1" in
        x86_64) dir=linux;;
        macosx) dir=macosx;;
        aarch64|ppc64le|s390x) dir=linux-${1};;
    esac
    mkdir "${OUTDIR}/${dir}"
    tar --owner 0 --group 0 -C "$1" -zc oc -f "${OUTDIR}/${dir}/oc.tar.gz"
}

OSE_VERSION=$1
VERSION=$2
PKG=${3:-atomic-openshift}
RPM=/mnt/rcm-guest/puddles/RHAOS/AtomicOpenShift/${OSE_VERSION}/building/%s
RPM=${RPM}/os/Packages/${PKG}-clients
ARCH='aarch64 ppc64le s390x'
TMPDIR=$(mktemp -dt ocbinary.XXXXXXXXXX)
trap "rm -rf '${TMPDIR}'" EXIT INT TERM
OUTDIR=${TMPDIR}/${VERSION}

cd "${TMPDIR}"
extract
mkdir "${OUTDIR}"
ln -sf ${VERSION} ${OSE_VERSION}
ln -sf ${VERSION} latest
for arch in ${ARCH}; do [[ -e "${arch}" ]] && pkg_tar "${arch}"; done
pkg_tar x86_64
pkg_tar macosx
mkdir "${OUTDIR}/windows"
zip --quiet --junk-path - windows/oc.exe > "${OUTDIR}/windows/oc.zip"
rsync \
    -av --delete-after --progress --no-g --omit-dir-times --chmod=Dug=rwX \
    -e "ssh -l jenkins_aos_cd_bot -o StrictHostKeyChecking=no" \
    "${OUTDIR}" ${OSE_VERSION} latest \
    use-mirror-upload.ops.rhcloud.com:/srv/pub/openshift-v4/x86_64/clients/oc/

retry() {
  local count exit_code
  count=0
  until "$@"; do
    exit_code="$?"
    count=$((count + 1))
    if [[ $count -lt 4 ]]; then
      sleep 5
    else
      return "$exit_code"
    fi
  done
}

# kick off mirror push
retry ssh -l jenkins_aos_cd_bot -o StrictHostKeychecking=no \
    use-mirror-upload.ops.rhcloud.com \
    timeout 15m /usr/local/bin/push.pub.sh openshift-v4/clients/oc -v
