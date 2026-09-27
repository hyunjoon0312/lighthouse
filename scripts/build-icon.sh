#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
repo_root=${script_dir:h}
source_png="$repo_root/Resources/Brand/LighthouseIcon.png"
output_dir="$repo_root/Resources/App"
output_icns="$output_dir/Lighthouse.icns"

if [[ ! -f "$source_png" ]]; then
    print -u2 "Missing icon source: $source_png"
    exit 1
fi

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/lighthouse-icon.XXXXXX")
trap 'rm -rf -- "$work_dir"' EXIT
iconset_dir="$work_dir/Lighthouse.iconset"
mkdir -p "$iconset_dir" "$output_dir"

sizes=(16 32 128 256 512)
for size in $sizes; do
    sips -z "$size" "$size" "$source_png" \
        --out "$iconset_dir/icon_${size}x${size}.png" >/dev/null

    retina_size=$((size * 2))
    sips -z "$retina_size" "$retina_size" "$source_png" \
        --out "$iconset_dir/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$iconset_dir" -o "$output_icns"
print "Created $output_icns"
