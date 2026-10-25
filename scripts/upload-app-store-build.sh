#!/bin/bash
# Run from a normal macOS Terminal with Xcode and signing configured.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
: "${ASC_KEY_ID:?Set ASC_KEY_ID locally}"
: "${ASC_ISSUER_ID:?Set ASC_ISSUER_ID locally}"
ASC_KEY_PATH=${ASC_KEY_PATH:-"$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8"}
[[ -f "$ASC_KEY_PATH" ]] || { echo 'App Store Connect private key not found.' >&2; exit 1; }
RELEASE_DIR=${RELEASE_DIR:-"$ROOT/output/releases/$(date +%Y%m%d-%H%M%S)"}
DERIVED_DATA=${DERIVED_DATA:-"$RELEASE_DIR/DerivedData"}
mkdir -p "$RELEASE_DIR"

xcodebuild -project MuxManager.xcodeproj -scheme MuxManager \
  -derivedDataPath "$DERIVED_DATA" -resolvePackageDependencies
# The pinned SwiftTerm release can omit its host generator from Xcode's graph.
GENERATOR="$DERIVED_DATA/SourcePackages/checkouts/SwiftTerm/Sources/SwiftTermBuildInfoGenerator/BuildInfoGenerator.swift"
if [[ -f "$GENERATOR" ]]; then
  mkdir -p "$DERIVED_DATA/Build/Products/Release"
  swiftc -parse-as-library "$GENERATOR" \
    -o "$DERIVED_DATA/Build/Products/Release/SwiftTermBuildInfoGenerator"
fi
xcodebuild -project MuxManager.xcodeproj -scheme MuxManager \
  -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED_DATA" -archivePath "$RELEASE_DIR/MuxManager.xcarchive" \
  -allowProvisioningUpdates -authenticationKeyPath "$ASC_KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID" archive

cat > "$RELEASE_DIR/ExportOptions.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>method</key><string>app-store-connect</string>
<key>destination</key><string>export</string>
<key>signingStyle</key><string>automatic</string>
<key>manageAppVersionAndBuildNumber</key><false/>
<key>stripSwiftSymbols</key><true/>
<key>uploadSymbols</key><true/>
</dict></plist>
PLIST
# Use Apple's rsync on both sides of Xcode's local packaging operation.
# A Homebrew rsync earlier in PATH can reject Apple's extended-attribute flags.
PATH=/usr/bin:/bin:/usr/sbin:/sbin xcodebuild -exportArchive \
  -archivePath "$RELEASE_DIR/MuxManager.xcarchive" \
  -exportOptionsPlist "$RELEASE_DIR/ExportOptions.plist" -exportPath "$RELEASE_DIR/export" \
  -allowProvisioningUpdates -authenticationKeyPath "$ASC_KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID"
IPA="$RELEASE_DIR/export/Mux Manager.ipa"
[[ -f "$IPA" ]] || { echo 'Export did not produce the expected IPA.' >&2; exit 1; }
xcrun altool --upload-app --type ios --file "$IPA" \
  --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
echo 'Upload accepted. Verify processing and answer export compliance in App Store Connect.'
echo 'No App Review or release submission has been sent.'
