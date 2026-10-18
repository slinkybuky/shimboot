
#!/bin/bash

. ./common.sh
. ./image_utils.sh

print_help() {
  echo "Usage: ./build_complete.sh board_name"
  echo "Valid named arguments (specify with 'key=value'):"
  echo "  compress_img - Compress the final disk image into a zip file. Set this to any value to enable this option."
  echo "  rootfs_dir   - Use a different rootfs for the build. The directory you select will be copied before any patches are applied."
  echo "  quiet        - Don't use progress indicators which may clog up log files."
  echo "  desktop      - The desktop environment to install. This defaults to 'xfce'. Valid options include:"
  echo "                   gnome, xfce, kde, lxde, gnome-flashback, cinnamon, mate, lxqt"
  echo "  data_dir     - The working directory for the scripts. This defaults to ./data"
  echo "  arch         - The CPU architecture to build the shimboot image for. Set this to 'arm64' if you have an ARM Chromebook."
}

assert_root
assert_args "$1"
parse_args "$@"

compress_img="${args['compress_img']}"
rootfs_dir="${args['rootfs_dir']}"
quiet="${args['quiet']}"
desktop="${args['desktop']:-xfce}"
data_dir="${args['data_dir']}"
arch="${args['arch']:-amd64}"

# Remove accidental quote characters passed literally by workflow inputs.
arch="${arch//\'/}"
arch="${arch//\"/}"

case "$arch" in
  amd64|arm64)
    ;;
  *)
    echo "ERROR: unsupported architecture '$arch'. Use amd64 or arm64."
    exit 1
    ;;
esac

needed_deps="wget python3 unzip zip git debootstrap cpio binwalk pcregrep cgpt mkfs.ext4 mkfs.ext2 fdisk rsync depmod findmnt lz4"

if [ "$(check_deps "$needed_deps")" ]; then
  if [ -f "/etc/debian_version" ]; then
    echo "attempting to install build deps"
    apt-get update
    apt-get install wget python3-all unzip zip debootstrap cpio binwalk pcregrep cgpt rsync kmod pv -y
  fi
  assert_deps "$needed_deps"
fi

cleanup_path=""

sigint_handler() {
  if [ -n "$cleanup_path" ]; then
    rm -rf -- "$cleanup_path"
  fi
  exit 1
}

trap sigint_handler SIGINT

base_dir="$(realpath -m "$(dirname "$0")")"
board="$1"
shim_url="https://dl.cros.download/files/$board/$board.zip"
boards_url="https://chromiumdash.appspot.com/cros/fetch_serving_builds?deviceCategory=ChromeOS"

if [ -z "$data_dir" ]; then
  data_dir="$base_dir/data"
else
  data_dir="$(realpath -m "$data_dir")"
fi

shim_bin="$data_dir/shim_$board.bin"
shim_zip="$data_dir/shim_$board.zip"
reco_bin="$data_dir/reco_$board.bin"
reco_zip="$data_dir/reco_$board.zip"

mkdir -p "$data_dir"

echo "downloading list of recovery images"

reco_url="$(wget -qO- "$boards_url" | python3 -c '
import json, sys

all_builds = json.load(sys.stdin)
board = all_builds["builds"][sys.argv[1]]

if "models" in board:
    for device in board["models"].values():
        if device.get("pushRecoveries"):
            board = device
            break

recoveries = board.get("pushRecoveries", {})
if not recoveries:
    raise SystemExit("No recovery images found for board " + sys.argv[1])

print(list(recoveries.values())[-1])
' "$board")" || {
  echo "ERROR: failed to retrieve the recovery image URL"
  exit 1
}

if [ -z "$reco_url" ]; then
  echo "ERROR: recovery image URL is empty"
  exit 1
fi

echo "found url: $reco_url"

download_and_unzip() {
  local url="$1"
  local zip_path="$2"
  local bin_path="$3"
  local total_bytes

  if [ -s "$bin_path" ]; then
    echo "using existing $bin_path"
    return 0
  fi

  rm -f -- "$zip_path" "$bin_path"

  if [ -n "$quiet" ]; then
    wget -q "$url" -O "$zip_path"
  else
    wget --show-progress "$url" -O "$zip_path"
  fi || {
    rm -f -- "$zip_path"
    echo "ERROR: download failed: $url"
    return 1
  }

  if ! unzip -tq "$zip_path" >/dev/null; then
    rm -f -- "$zip_path"
    echo "ERROR: downloaded file is not a valid ZIP archive: $url"
    return 1
  fi

  cleanup_path="$bin_path"
  echo "extracting $zip_path"

  total_bytes="$(unzip -lq "$zip_path" | tail -1 | xargs | cut -d' ' -f1)"

  if [ -n "$quiet" ]; then
    unzip -p "$zip_path" > "$bin_path"
  else
    unzip -p "$zip_path" | pv -s "$total_bytes" > "$bin_path"
  fi || {
    rm -f -- "$bin_path" "$zip_path"
    cleanup_path=""
    echo "ERROR: extraction failed: $zip_path"
    return 1
  }

  if [ ! -s "$bin_path" ]; then
    rm -f -- "$bin_path" "$zip_path"
    cleanup_path=""
    echo "ERROR: extracted file is empty: $bin_path"
    return 1
  fi

  rm -f -- "$zip_path"
  cleanup_path=""
}

retry_cmd() {
  local attempt

  for attempt in 1 2 3 4 5; do
    if "$@"; then
      return 0
    fi

    echo "command failed (attempt $attempt/5)"
    sleep 2
  done

  echo "ERROR: command failed after 5 attempts"
  return 1
}

echo "downloading recovery image"
download_and_unzip "$reco_url" "$reco_zip" "$reco_bin" || exit 1

echo "downloading shim image from cros.download"
download_and_unzip "$shim_url" "$shim_zip" "$shim_bin" || exit 1

if [ -z "$rootfs_dir" ]; then
  rootfs_dir="$(realpath -m "$data_dir/rootfs_$board")"
  desktop_package="task-$desktop-desktop"

  if findmnt -T "$rootfs_dir/dev" >/dev/null 2>&1; then
    sudo umount -l "$rootfs_dir"/* 2>/dev/null || true
  fi

  rm -rf -- "$rootfs_dir"
  mkdir -p "$rootfs_dir"

  echo "building debian rootfs"

  ./build_rootfs.sh "$rootfs_dir" bookworm \
    "custom_packages=$desktop_package" \
    "hostname=shimboot-$board" \
    "username=user" \
    "user_passwd=user" \
    "arch=$arch" || exit 1
fi

echo "patching debian rootfs"
retry_cmd ./patch_rootfs.sh "$shim_bin" "$reco_bin" "$rootfs_dir" "quiet=$quiet" || exit 1

echo "building final disk image"
final_image="$data_dir/shimboot_$board.bin"
rm -f -- "$final_image"

retry_cmd ./build.sh "$final_image" "$shim_bin" "$rootfs_dir" "quiet=$quiet" "arch=$arch" || exit 1

echo "build complete! the final disk image is located at $final_image"

echo "cleaning up"
clean_loops

if [ -n "$compress_img" ]; then
  image_zip="$data_dir/shimboot_$board.zip"
  echo "compressing disk image into a zip file"
  zip -j "$image_zip" "$final_image" || exit 1
  echo "finished compressing the disk file"
  echo "the finished zip file can be found at $image_zip"
fi
