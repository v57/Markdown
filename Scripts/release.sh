#!/bin/zsh
# Builds a release of the Markdown app.
#
#   Scripts/release.sh mac        Direct download: Developer ID signed, notarized and stapled
#                                 Markdown.zip and Markdown.dmg in build/release/, ready to
#                                 attach to a GitHub release (the script prints the command).
#   Scripts/release.sh appstore   Archives the macOS and iOS apps and uploads both to App
#                                 Store Connect.
#
# Needs Xcode signed in to the team (automatic signing creates the profiles) and, for
# `mac`, a notarytool keychain profile, created once with:
#   xcrun notarytool store-credentials notary --apple-id <id> --team-id AUCR797TMH
# (another profile name: NOTARY_PROFILE=<name> Scripts/release.sh mac).
set -euo pipefail
cd "${0:A:h}/.."

mode=${1:-}
out=build/release
project=Markdown.xcodeproj
scheme=Markdown
version=$(xcodebuild -project $project -scheme $scheme -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ MARKETING_VERSION /{print $2; exit}')

archive() { # platform archive-path [extra build settings...]
  local platform=$1 path=$2; shift 2
  xcodebuild archive -project $project -scheme $scheme -configuration Release \
    -destination "generic/platform=$platform" -archivePath "$path" \
    -allowProvisioningUpdates -quiet "$@"
}

notarize() { # file
  xcrun notarytool submit "$1" --keychain-profile "${NOTARY_PROFILE:-notary}" --wait
}

case $mode in
mac)
  rm -rf $out && mkdir -p $out
  # DIRECT_DISTRIBUTION turns on the GitHub Releases update check (not in App Store builds). LTO and
  # ld-archive-prelink drop unused package code (Xcode's per-package `ld -r` would keep it).
  archive macOS $out/Markdown.xcarchive \
    'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) DIRECT_DISTRIBUTION' \
    SWIFT_LTO=YES ALTERNATE_LINKER_PATH=$PWD/Scripts/ld-archive-prelink \
    'OTHER_SWIFT_FLAGS=$(inherited) -Xfrontend -internalize-at-link -Xfrontend -conditional-runtime-records'
  xcodebuild -exportArchive -archivePath $out/Markdown.xcarchive -exportPath $out/export \
    -exportOptionsPlist Scripts/ExportOptions-DeveloperID.plist -allowProvisioningUpdates
  app=$out/export/Markdown.app

  # The app: notarize a zip of it, staple the ticket to the app, zip the stapled app.
  ditto -c -k --keepParent $app $out/notarize.zip
  notarize $out/notarize.zip
  xcrun stapler staple $app
  rm $out/notarize.zip
  ditto -c -k --keepParent $app $out/Markdown.zip

  # The disk image: the app and an Applications link, signed, notarized and stapled.
  mkdir -p $out/dmg && cp -R $app $out/dmg/ && ln -s /Applications $out/dmg/Applications
  hdiutil create -volname Markdown -srcfolder $out/dmg -ov -format UDZO $out/Markdown.dmg
  rm -rf $out/dmg
  identity=$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/{print $2; exit}')
  codesign --sign "$identity" --timestamp $out/Markdown.dmg
  notarize $out/Markdown.dmg
  xcrun stapler staple $out/Markdown.dmg

  spctl --assess --type execute --verbose $app
  echo
  ls -lh $out/Markdown.zip $out/Markdown.dmg
  echo "\nPublish (stable links: https://github.com/v57/Markdown/releases/latest/download/Markdown.dmg):"
  echo "  gh release create v$version $out/Markdown.dmg $out/Markdown.zip --title \"Markdown $version\" --generate-notes"
  ;;
appstore)
  rm -rf $out/appstore && mkdir -p $out/appstore
  for platform in macOS iOS; do
    archive $platform $out/appstore/Markdown-$platform.xcarchive
    xcodebuild -exportArchive -archivePath $out/appstore/Markdown-$platform.xcarchive \
      -exportPath $out/appstore/$platform -exportOptionsPlist Scripts/ExportOptions-AppStore.plist \
      -allowProvisioningUpdates
  done
  echo "Uploaded Markdown $version (macOS and iOS) to App Store Connect."
  ;;
*)
  sed -n '2,13p' $0 | sed 's/^# \{0,1\}//'
  exit 1
  ;;
esac
