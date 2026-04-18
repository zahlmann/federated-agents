#!/bin/zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="$repo_root/.build/arm64-apple-macosx/debug"
binary_path="$build_dir/FederatedAgentsReceiver"
app_bundle="$build_dir/FederatedAgentsReceiver.app"
contents_dir="$app_bundle/Contents"
macos_dir="$contents_dir/MacOS"
resources_dir="$contents_dir/Resources"
plist_path="$contents_dir/Info.plist"
bundle_binary_path="$macos_dir/FederatedAgentsReceiver"

cd "$repo_root"
swift build

# Clean up stale detached launches so a hidden old process does not make
# a fresh GUI launch look like a no-op.
pkill -f "$binary_path" >/dev/null 2>&1 || true
pkill -f "$app_bundle/Contents/MacOS/FederatedAgentsReceiver" >/dev/null 2>&1 || true
sleep 0.2

mkdir -p "$macos_dir" "$resources_dir"

cat > "$plist_path" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>FederatedAgentsReceiver</string>
    <key>CFBundleIdentifier</key>
    <string>com.federated-agents.receiver</string>
    <key>CFBundleName</key>
    <string>FederatedAgentsReceiver</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

rm -f "$bundle_binary_path"
ln -s "$binary_path" "$bundle_binary_path"

open "$app_bundle"
