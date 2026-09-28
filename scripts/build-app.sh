#!/bin/zsh
set -euo pipefail

repo_dir="${0:A:h:h}"
script_name="${0:t}"
cd "$repo_dir"

usage() {
    print "Usage: $script_name [--universal]"
}

universal=false
case "$#:${1-}" in
    0:)
        ;;
    1:--universal)
        universal=true
        ;;
    1:--help|1:-h)
        usage
        exit 0
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac

build_args=(-c release)
if [[ "$universal" == true ]]; then
    build_args+=(--arch arm64 --arch x86_64)
fi

swift build "${build_args[@]}"
bin_path="$(swift build "${build_args[@]}" --show-bin-path)"
built_executable="$bin_path/Lighthouse"
core_bundle="$bin_path/Lighthouse_LighthouseCore.bundle"

if [[ "$universal" == true ]]; then
    lipo "$built_executable" -verify_arch arm64 x86_64
fi
if [[ ! -d "$core_bundle" ]]; then
    print -u2 "Missing required LighthouseCore resource bundle: $core_bundle"
    exit 1
fi

app_dir="$repo_dir/dist/Lighthouse.app/Contents"
mkdir -p "$app_dir/MacOS" "$app_dir/Resources"
cp "$built_executable" "$app_dir/MacOS/Lighthouse"
cp "$repo_dir/Resources/Info.plist" "$app_dir/Info.plist"
if [[ -d "$repo_dir/Resources/App" ]]; then
    cp -R "$repo_dir/Resources/App/." "$app_dir/Resources/"
fi
packaged_core_bundle="$app_dir/Resources/Lighthouse_LighthouseCore.bundle"
rm -rf -- "$packaged_core_bundle"
cp -R "$core_bundle" "$packaged_core_bundle"
if command -v codesign >/dev/null; then
    codesign --force --deep --sign - "$repo_dir/dist/Lighthouse.app"
fi
print "$repo_dir/dist/Lighthouse.app"
