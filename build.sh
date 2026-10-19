#!/bin/bash
# Build script for HuaweiAudioControlMac

set -e

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${PROJECT_DIR}/.build"
RELEASE_DIR="${PROJECT_DIR}/releases"
APP_NAME="HuaweiAudioControlMac"
VERSION="$(plutil -extract CFBundleShortVersionString raw "${PROJECT_DIR}/Info.plist")"
VERSION="${VERSION:-1.0.0}"

echo "Building ${APP_NAME}..."

# Clean previous builds
rm -rf "${BUILD_DIR}"

# Build with Swift Package Manager
swift build -c release --package-path "${PROJECT_DIR}"

# Create app bundle
APP_BUNDLE="${BUILD_DIR}/release/${APP_NAME}.app"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

# Copy executable
cp "${BUILD_DIR}/release/${APP_NAME}" "${APP_BUNDLE}/Contents/MacOS/"

# Copy Info.plist
cp "${PROJECT_DIR}/Info.plist" "${APP_BUNDLE}/Contents/"

# Copy the app icon (regenerate it if the checked-in asset is missing)
if [ ! -f "${PROJECT_DIR}/Resources/AppIcon.icns" ]; then
    swift "${PROJECT_DIR}/Tools/make-icon.swift"
fi
cp "${PROJECT_DIR}/Resources/AppIcon.icns" "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"

# GPL-3.0 requires the license and attribution to travel with binaries.
cp "${PROJECT_DIR}/LICENSE" "${APP_BUNDLE}/Contents/Resources/LICENSE"
cp "${PROJECT_DIR}/NOTICE" "${APP_BUNDLE}/Contents/Resources/NOTICE"

# Compile Info.plist
plutil -convert binary1 "${APP_BUNDLE}/Contents/Info.plist" -o "${APP_BUNDLE}/Contents/Info.plist"

# Codesign (ad-hoc for development)
codesign --force --sign - --entitlements "${PROJECT_DIR}/${APP_NAME}.entitlements" "${APP_BUNDLE}"

# Build an installer disk image after every build. Users can mount it and drag
# the app into Applications.
mkdir -p "${RELEASE_DIR}"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/${APP_NAME}.XXXXXX")"
trap 'rm -rf "${STAGING_DIR}"' EXIT
ditto "${APP_BUNDLE}" "${STAGING_DIR}/${APP_NAME}.app"
ln -s /Applications "${STAGING_DIR}/Applications"

DMG_PATH="${RELEASE_DIR}/${APP_NAME}-${VERSION}.dmg"
rm -f "${DMG_PATH}"
hdiutil create \
    -volname "Huawei Audio Control ${VERSION}" \
    -srcfolder "${STAGING_DIR}" \
    -ov -format UDZO \
    "${DMG_PATH}"

echo "Build complete!"
echo "App located at: ${APP_BUNDLE}"
echo "Installer DMG: ${DMG_PATH}"
echo ""
echo "To run: open \"${APP_BUNDLE}\""
echo "To install: open \"${DMG_PATH}\" and drag the app to Applications."