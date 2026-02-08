#!/bin/bash
# Compare two directory trees for equivalence using ostree.
#
# ostree compares content, permissions, and xattrs while ignoring timestamps,
# which makes it ideal for verifying that a chunked image is equivalent to its
# source. If differences are found, diffoscope is run on hardlink checkouts for
# human-readable detail, and xattr diffs are shown explicitly (since diffoscope
# doesn't compare xattrs).
#
# Usage: chunkah-differ.sh <dir1> <dir2> [--skip <path>]...
#
# Example:
#   podman run --rm \
#     --mount=type=image,src=original:latest,target=/image1 \
#     --mount=type=image,src=chunked:latest,target=/image2 \
#     localhost/chunkah-differ /image1 /image2 --skip /sysroot

set -euo pipefail
shopt -s inherit_errexit

DIR1=""
DIR2=""
SKIP_PATHS=()

REPO="/tmp/chunkah-differ-repo"
CO1="/tmp/chunkah-differ-co1"
CO2="/tmp/chunkah-differ-co2"

usage() {
    echo "Usage: $(basename "$0") <dir1> <dir2> [--skip <path>]..."
    echo "       $(basename "$0") --self-test"
    echo ""
    echo "Compare two directory trees for equivalence using ostree."
    echo ""
    echo "Options:"
    echo "    --skip <path>   Skip the given path from comparison (repeatable)."
    echo "                    Without trailing slash: skip the path and all its"
    echo "                    contents. With trailing slash: skip only the contents"
    echo "                    but still compare the directory itself."
    echo "    --self-test     Run built-in tests to verify diff detection"
    echo "    -h, --help      Show this help message"
}

main() {
    parse_args "$@"
    commit_trees
    compare
}

# Parse command-line arguments into global variables.
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --skip)
                if [[ $# -lt 2 ]]; then
                    echo "ERROR: --skip requires an argument" >&2
                    exit 1
                fi
                SKIP_PATHS+=("$2")
                shift 2
                ;;
            --self-test)
                self_test
                exit 0
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            -*)
                echo "ERROR: Unknown option: $1" >&2
                usage >&2
                exit 1
                ;;
            *)
                if [[ -z "${DIR1}" ]]; then
                    DIR1="$1"
                elif [[ -z "${DIR2}" ]]; then
                    DIR2="$1"
                else
                    echo "ERROR: Too many positional arguments" >&2
                    usage >&2
                    exit 1
                fi
                shift
                ;;
        esac
    done

    if [[ -z "${DIR1}" || -z "${DIR2}" ]]; then
        echo "ERROR: Two directory arguments are required" >&2
        usage >&2
        exit 1
    fi
}

# Commit both directory trees into a bare ostree repo.
commit_trees() {
    # Create a bare ostree repo (bare mode preserves all xattrs including
    # security.capability on both commit and checkout)
    ostree init --repo="${REPO}" --mode=bare

    local skiplist1="/tmp/chunkah-differ-skiplist1"
    local skiplist2="/tmp/chunkah-differ-skiplist2"
    build_skip_list "${DIR1}" "${skiplist1}"
    build_skip_list "${DIR2}" "${skiplist2}"

    ostree commit --repo="${REPO}" -b img1 \
        --tree=dir="${DIR1}" --skip-list="${skiplist1}" >/dev/null
    ostree commit --repo="${REPO}" -b img2 \
        --tree=dir="${DIR2}" --skip-list="${skiplist2}" >/dev/null
}

# Build a skip-list file for a given tree directory. Trailing slash in
# SKIP_PATHS means "skip only children" (enumerate that tree's children);
# no trailing slash means "skip the path and all its contents".
build_skip_list() {
    local tree_dir="$1"
    local skip_list_file="$2"

    # Enable dotglob so hidden files are included in children enumeration
    shopt -s dotglob

    : > "${skip_list_file}"
    for path in "${SKIP_PATHS[@]}"; do
        path="/${path#/}"
        if [[ "${path}" == */ ]]; then
            # Children-only: enumerate this tree's children
            local dir="${path%/}"
            local child
            for child in "${tree_dir}${dir}"/*; do
                if [[ -e "${child}" ]]; then
                    echo "${dir}/$(basename "${child}")"
                fi
            done | sort >> "${skip_list_file}"
        else
            # Exact: skip the path and everything under it
            echo "${path}" >> "${skip_list_file}"
        fi
    done

    shopt -u dotglob
}

# Compare the two commits. If differences are found, show ostree diff output,
# xattr diffs for modified files, and diffoscope detail on hardlink checkouts.
compare() {
    local diff_output
    diff_output=$(ostree diff --repo="${REPO}" img1 img2)

    if [[ -z "${diff_output}" ]]; then
        return 0
    fi

    # Differences found — show details
    echo "ostree diff:"
    echo "${diff_output}"
    echo ""

    # Checkout both commits for detailed comparison
    ostree checkout --repo="${REPO}" -H img1 "${CO1}"
    ostree checkout --repo="${REPO}" -H img2 "${CO2}"

    # Show xattr diffs for modified files (diffoscope doesn't compare xattrs)
    show_xattr_diffs "${diff_output}"

    # Run diffoscope for content/permission detail
    echo "diffoscope:"
    diffoscope "${CO1}" "${CO2}" || true

    return 1
}

# Show xattr differences for files listed in ostree diff output.
show_xattr_diffs() {
    local diff_output="$1"

    local has_xattr_diffs=false
    while IFS= read -r line; do
        # ostree diff lines look like: "M    /path/to/file"
        local prefix="${line%% *}"
        local path="${line##* }"

        # Only check modified files (not added/deleted)
        if [[ "${prefix}" != "M" ]]; then
            continue
        fi

        local xattrs1 xattrs2
        xattrs1=$(getfattr --no-dereference --absolute-names -d -m "." \
            "${CO1}${path}" 2>/dev/null | grep -v "^#" | grep -v "^$" | sort) || true
        xattrs2=$(getfattr --no-dereference --absolute-names -d -m "." \
            "${CO2}${path}" 2>/dev/null | grep -v "^#" | grep -v "^$" | sort) || true

        if [[ "${xattrs1}" != "${xattrs2}" ]]; then
            if ! ${has_xattr_diffs}; then
                echo "xattr differences:"
                has_xattr_diffs=true
            fi
            echo "  ${path}:"
            diff <(echo "${xattrs1}") <(echo "${xattrs2}") | sed 's/^/    /' || true
        fi
    done <<< "${diff_output}"

    if ${has_xattr_diffs}; then
        echo ""
    fi
}

# Reset global state between self-test cases.
reset_state() {
    DIR1="/tmp/chunkah-differ-self-test/t1"
    DIR2="/tmp/chunkah-differ-self-test/t2"
    SKIP_PATHS=()
    rm -rf "${REPO}" "${CO1}" "${CO2}" "${DIR1}" "${DIR2}"
    mkdir -p "${DIR1}/usr/bin" "${DIR2}/usr/bin"
}

# Assert that a diff is detected.
assert_diff() {
    local desc="$1"
    commit_trees
    local rc=0
    # shellcheck disable=SC2310  # intentionally capturing return code
    compare >/dev/null 2>&1 || rc=$?
    if [[ ${rc} -eq 0 ]]; then
        echo "FAIL: ${desc}: expected diff but none found" >&2
        exit 1
    fi
    echo "PASS: ${desc}"
}

# Assert that no diff is detected.
assert_no_diff() {
    local desc="$1"
    commit_trees
    local rc=0
    # shellcheck disable=SC2310  # intentionally capturing return code
    compare >/dev/null 2>&1 || rc=$?
    if [[ ${rc} -ne 0 ]]; then
        echo "FAIL: ${desc}: unexpected diff found" >&2
        exit 1
    fi
    echo "PASS: ${desc}"
}

# Run built-in tests to verify that various types of differences are detected.
self_test() {
    local test_count=0

    # Identical trees
    reset_state
    echo "hello" > "${DIR1}/usr/bin/foo"
    echo "hello" > "${DIR2}/usr/bin/foo"
    assert_no_diff "identical trees"
    test_count=$((test_count + 1))

    # Content change
    reset_state
    echo "hello" > "${DIR1}/usr/bin/foo"
    echo "world" > "${DIR2}/usr/bin/foo"
    assert_diff "content change"
    test_count=$((test_count + 1))

    # Permission change
    reset_state
    echo "hello" > "${DIR1}/usr/bin/foo"
    echo "hello" > "${DIR2}/usr/bin/foo"
    chmod 755 "${DIR1}/usr/bin/foo"
    chmod 644 "${DIR2}/usr/bin/foo"
    assert_diff "permission change"
    test_count=$((test_count + 1))

    # Xattr changed
    reset_state
    echo "hello" > "${DIR1}/usr/bin/foo"
    echo "hello" > "${DIR2}/usr/bin/foo"
    setfattr -n user.component -v "rpm/glibc" "${DIR1}/usr/bin/foo"
    setfattr -n user.component -v "rpm/bash" "${DIR2}/usr/bin/foo"
    assert_diff "xattr changed"
    test_count=$((test_count + 1))

    # Xattr missing
    reset_state
    echo "hello" > "${DIR1}/usr/bin/foo"
    echo "hello" > "${DIR2}/usr/bin/foo"
    setfattr -n user.component -v "rpm/glibc" "${DIR1}/usr/bin/foo"
    assert_diff "xattr missing"
    test_count=$((test_count + 1))

    # File added
    reset_state
    echo "hello" > "${DIR1}/usr/bin/foo"
    echo "hello" > "${DIR2}/usr/bin/foo"
    echo "extra" > "${DIR2}/usr/bin/bar"
    assert_diff "file added"
    test_count=$((test_count + 1))

    # File removed
    reset_state
    echo "hello" > "${DIR1}/usr/bin/foo"
    echo "hello" > "${DIR2}/usr/bin/foo"
    echo "extra" > "${DIR1}/usr/bin/bar"
    assert_diff "file removed"
    test_count=$((test_count + 1))

    # Timestamp change only (should not be detected)
    reset_state
    echo "hello" > "${DIR1}/usr/bin/foo"
    echo "hello" > "${DIR2}/usr/bin/foo"
    touch -t 202001010000 "${DIR1}/usr/bin/foo"
    touch -t 202501010000 "${DIR2}/usr/bin/foo"
    assert_no_diff "timestamp change only"
    test_count=$((test_count + 1))

    # Skip without trailing slash excludes directory and contents
    reset_state
    echo "hello" > "${DIR1}/usr/bin/foo"
    echo "hello" > "${DIR2}/usr/bin/foo"
    mkdir -p "${DIR1}/sysroot" "${DIR2}/sysroot"
    echo "a" > "${DIR1}/sysroot/data"
    echo "b" > "${DIR2}/sysroot/data"
    chmod 700 "${DIR1}/sysroot"
    chmod 755 "${DIR2}/sysroot"
    SKIP_PATHS=(/sysroot)
    assert_no_diff "skip without trailing slash excludes dir and contents"
    test_count=$((test_count + 1))

    # Skip with trailing slash excludes only contents
    reset_state
    echo "hello" > "${DIR1}/usr/bin/foo"
    echo "hello" > "${DIR2}/usr/bin/foo"
    mkdir -p "${DIR1}/sysroot" "${DIR2}/sysroot"
    echo "a" > "${DIR1}/sysroot/data"
    echo "b" > "${DIR2}/sysroot/data"
    SKIP_PATHS=(/sysroot/)
    assert_no_diff "skip with trailing slash excludes only contents"
    test_count=$((test_count + 1))

    # Skip with trailing slash still detects dir permission change
    reset_state
    echo "hello" > "${DIR1}/usr/bin/foo"
    echo "hello" > "${DIR2}/usr/bin/foo"
    mkdir -p "${DIR1}/sysroot" "${DIR2}/sysroot"
    echo "a" > "${DIR1}/sysroot/data"
    echo "b" > "${DIR2}/sysroot/data"
    chmod 700 "${DIR1}/sysroot"
    chmod 755 "${DIR2}/sysroot"
    SKIP_PATHS=(/sysroot/)
    assert_diff "skip with trailing slash detects dir permission change"
    test_count=$((test_count + 1))

    # Skip with trailing slash works when children differ between trees
    reset_state
    echo "hello" > "${DIR1}/usr/bin/foo"
    echo "hello" > "${DIR2}/usr/bin/foo"
    mkdir -p "${DIR1}/sysroot/ostree" "${DIR1}/sysroot/other"
    echo "data" > "${DIR1}/sysroot/ostree/file"
    mkdir -p "${DIR2}/sysroot"
    SKIP_PATHS=(/sysroot/)
    assert_no_diff "skip with trailing slash works when children differ"
    test_count=$((test_count + 1))

    # Skip with trailing slash handles hidden files
    reset_state
    echo "hello" > "${DIR1}/usr/bin/foo"
    echo "hello" > "${DIR2}/usr/bin/foo"
    mkdir -p "${DIR1}/sysroot" "${DIR2}/sysroot"
    echo "a" > "${DIR1}/sysroot/.hidden"
    echo "b" > "${DIR2}/sysroot/.hidden"
    SKIP_PATHS=(/sysroot/)
    assert_no_diff "skip with trailing slash handles hidden files"
    test_count=$((test_count + 1))

    echo ""
    echo "All ${test_count} tests passed."
}

main "$@"
