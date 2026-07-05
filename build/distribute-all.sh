#!/bin/bash
# Archive + upload Yattee to App Store Connect.
# Usage: distribute-all.sh [iOS] [tvOS] [macOS]   (no args = all three)
# Note: must stay bash-3.2 compatible (no associative arrays) — /bin/bash on macOS.
cd "/Users/bmiller/Library/Mobile Documents/com~apple~CloudDocs/Git/yattee" || exit 1
BUILD=$(grep -m1 'CURRENT_PROJECT_VERSION' Yattee.xcodeproj/project.pbxproj | tr -dc '0-9')
# Auth uses Xcode's signed-in account (needed for cloud-managed signing certs).
# The ASC API key BF7K8Z5T46 (~/.appstoreconnect/private_keys, issuer
# 69a6de78-a308-47e3-e053-5b8c7c11a4d1) authenticates but lacks cloud-signing
# permission ("Cloud signing permission error") — usable via -authenticationKey*
# flags only if its role is upgraded to Admin in App Store Connect.
# "Failed to Use Accounts" errors are transient — retry the export later.
PLATFORMS=("$@")
[ ${#PLATFORMS[@]} -eq 0 ] && PLATFORMS=(iOS tvOS macOS)
SUMMARY=""
for P in "${PLATFORMS[@]}"; do
  case "$P" in
    iOS)   DEST="generic/platform=iOS" ;;
    tvOS)  DEST="generic/platform=tvOS" ;;
    macOS) DEST="generic/platform=macOS" ;;
    *) SUMMARY+="$P: UNKNOWN PLATFORM\n"; continue ;;
  esac
  arch="build/archives/Yattee-$P.xcarchive"
  rm -rf "$arch"
  echo "=== ARCHIVE $P ==="
  xcodebuild archive -project Yattee.xcodeproj -scheme Yattee -destination "$DEST" \
    -archivePath "$arch" -allowProvisioningUpdates \
    CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM=B59KA83MLJ > "build/dist-archive-$P.log" 2>&1
  if ! grep -q "ARCHIVE SUCCEEDED" "build/dist-archive-$P.log"; then
    SUMMARY+="$P: ARCHIVE FAILED (see build/dist-archive-$P.log)\n"; continue
  fi
  # Guard against archiving the wrong platform (empty/incorrect destination).
  if [ "$P" != "macOS" ] && [ -d "$arch/Products/Applications/Yattee.app/Contents" ]; then
    SUMMARY+="$P: ARCHIVE IS WRONG PLATFORM (macOS bundle layout) — NOT UPLOADED\n"; continue
  fi
  echo "=== UPLOAD $P ==="
  xcodebuild -exportArchive -archivePath "$arch" \
    -exportOptionsPlist "build/ExportOptions-$P.plist" \
    -exportPath "build/export-$BUILD/$P" -allowProvisioningUpdates > "build/dist-export-$P.log" 2>&1
  if grep -q "Upload succeeded" "build/dist-export-$P.log"; then
    SUMMARY+="$P: UPLOAD SUCCEEDED\n"
  else
    SUMMARY+="$P: UPLOAD FAILED (see build/dist-export-$P.log)\n"
  fi
done
echo "================ SUMMARY (build $BUILD) ================"
printf "$SUMMARY"
