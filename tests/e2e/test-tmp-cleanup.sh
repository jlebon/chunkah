#!/bin/bash
# Test --prune-tmp flag for cleaning common temporary directories.
set -xeuo pipefail
shopt -s inherit_errexit

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/lib.sh
. "${SCRIPT_DIR}/lib.sh"

BASE_IMAGE="quay.io/fedora/fedora-minimal:latest"
CHUNKED_IMAGE_PRUNE_TMP="localhost/fedora-minimal-chunked-prune-tmp:test"
CHUNKED_IMAGE_NO_PRUNE_TMP="localhost/fedora-minimal-chunked-no-prune-tmp:test"

cleanup() {
    cleanup_images "${CHUNKED_IMAGE_PRUNE_TMP}" "${CHUNKED_IMAGE_NO_PRUNE_TMP}"
}
trap cleanup EXIT

podman pull "${BASE_IMAGE}"

# Test 1: With --prune-tmp flag
cat > Containerfile.prune-tmp <<EOF
FROM ${BASE_IMAGE} AS builder
RUN mkdir -p /run/testfile && echo "should be gone" > /run/testfile/data.txt
RUN mkdir -p /tmp/testfile && echo "should be gone" > /tmp/testfile/data.txt
RUN mkdir -p /var/tmp/testfile && echo "should be gone" > /var/tmp/testfile/data.txt
RUN mkdir -p /var/lib/myapp && echo "should stay" > /var/lib/myapp/data.txt

FROM ${CHUNKAH_IMG:?} AS chunkah
RUN --mount=from=builder,src=/,target=/chunkah,ro \\
    --mount=type=bind,target=/run/src,rw \\
        chunkah build --prune-tmp > /run/src/out.ociarchive

FROM oci-archive:out.ociarchive
EOF

buildah_build -t "${CHUNKED_IMAGE_PRUNE_TMP}" -f Containerfile.prune-tmp .

# Test 2: Without --prune-tmp flag
cat > Containerfile.no-prune-tmp <<EOF
FROM ${BASE_IMAGE} AS builder
RUN mkdir -p /run/testfile && echo "should stay" > /run/testfile/data.txt
RUN mkdir -p /tmp/testfile && echo "should stay" > /tmp/testfile/data.txt
RUN mkdir -p /var/tmp/testfile && echo "should stay" > /var/tmp/testfile/data.txt
RUN mkdir -p /var/lib/myapp && echo "should stay" > /var/lib/myapp/data.txt

FROM ${CHUNKAH_IMG:?} AS chunkah
RUN --mount=from=builder,src=/,target=/chunkah,ro \\
    --mount=type=bind,target=/run/src,rw \\
        chunkah build > /run/src/out.ociarchive

FROM oci-archive:out.ociarchive
EOF

buildah_build -t "${CHUNKED_IMAGE_NO_PRUNE_TMP}" -f Containerfile.no-prune-tmp .

# Verify --prune-tmp behavior: temporary directories and contents are pruned entirely
assert_path_not_exists "${CHUNKED_IMAGE_PRUNE_TMP}" /run/testfile
assert_path_not_exists "${CHUNKED_IMAGE_PRUNE_TMP}" /tmp/testfile
assert_path_not_exists "${CHUNKED_IMAGE_PRUNE_TMP}" /var/tmp/testfile

# Verify other directories are not affected
assert_path_exists "${CHUNKED_IMAGE_PRUNE_TMP}" /var/lib/myapp
assert_path_exists "${CHUNKED_IMAGE_PRUNE_TMP}" /var/lib/myapp/data.txt

# Verify without --prune-tmp: all contents are preserved
assert_path_exists "${CHUNKED_IMAGE_NO_PRUNE_TMP}" /run/testfile
assert_path_exists "${CHUNKED_IMAGE_NO_PRUNE_TMP}" /run/testfile/data.txt
assert_path_exists "${CHUNKED_IMAGE_NO_PRUNE_TMP}" /tmp/testfile
assert_path_exists "${CHUNKED_IMAGE_NO_PRUNE_TMP}" /tmp/testfile/data.txt
assert_path_exists "${CHUNKED_IMAGE_NO_PRUNE_TMP}" /var/tmp/testfile
assert_path_exists "${CHUNKED_IMAGE_NO_PRUNE_TMP}" /var/tmp/testfile/data.txt

# Verify other directories are still preserved
assert_path_exists "${CHUNKED_IMAGE_NO_PRUNE_TMP}" /var/lib/myapp
assert_path_exists "${CHUNKED_IMAGE_NO_PRUNE_TMP}" /var/lib/myapp/data.txt

echo "--prune-tmp flag tests passed"
