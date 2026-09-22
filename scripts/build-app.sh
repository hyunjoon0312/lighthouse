#!/bin/zsh
set -euo pipefail

repo_dir="${0:A:h:h}"
cd "$repo_dir"
swift build -c release

app_dir="$repo_dir/dist/Lighthouse.app/Contents"
mkdir -p "$app_dir/MacOS" "$app_dir/Resources"
cp "$repo_dir/.build/release/Lighthouse" "$app_dir/MacOS/Lighthouse"
cp "$repo_dir/Resources/Info.plist" "$app_dir/Info.plist"
if [[ -d "$repo_dir/Resources/App" ]]; then
    cp -R "$repo_dir/Resources/App/." "$app_dir/Resources/"
fi
if command -v codesign >/dev/null; then
    codesign --force --deep --sign - "$repo_dir/dist/Lighthouse.app"
fi
print "$repo_dir/dist/Lighthouse.app"
