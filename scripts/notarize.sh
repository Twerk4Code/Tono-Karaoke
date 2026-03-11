#!/bin/bash
# notarize.sh
#
# Zips the .app, submits it to Apple for notarization, waits for the result,
# then staples the notarization ticket to the app.
#
# Usage:
#   ./scripts/notarize.sh <path/to/Tono.app> <apple-id-email> <app-specific-password> <team-id>
#
# Example:
#   ./scripts/notarize.sh build/Tono.app you@example.com "abcd-efgh-ijkl-mnop" "ABCDE12345"
#
# Prerequisites:
#   - App must already be codesigned (run bundle_and_sign.sh first)
#   - Apple ID with Developer account
#   - App-specific password: generate at appleid.apple.com > Security > App-Specific Passwords
#   - Team ID: find in developer.apple.com/account or `xcrun notarytool history --apple-id ...`

set -euo pipefail

APP_PATH="${1:?Usage: $0 <path/to/Tono.app> <apple-id> <app-specific-password> <team-id>}"
APPLE_ID="${2:?Missing Apple ID}"
APP_PASSWORD="${3:?Missing app-specific password}"
TEAM_ID="${4:?Missing team ID}"

ZIP_PATH="${APP_PATH%.app}.zip"
APP_NAME=$(basename "${APP_PATH}")

echo "==> Zipping ${APP_NAME}..."
ditto -c -k --keepParent "${APP_PATH}" "${ZIP_PATH}"
echo "    Created ${ZIP_PATH}"

echo ""
echo "==> Submitting for notarization (this may take a few minutes)..."
xcrun notarytool submit "${ZIP_PATH}" \
    --apple-id "${APPLE_ID}" \
    --password "${APP_PASSWORD}" \
    --team-id "${TEAM_ID}" \
    --wait \
    --output-format json | tee /tmp/notarize_result.json

STATUS=$(python3 -c "import json,sys; d=json.load(open('/tmp/notarize_result.json')); print(d.get('status','unknown'))" 2>/dev/null || echo "unknown")

echo ""
if [ "${STATUS}" = "Accepted" ]; then
    echo "==> Notarization accepted!"
    echo "==> Stapling ticket to app..."
    xcrun stapler staple "${APP_PATH}"
    echo ""
    echo "==> All done. ${APP_NAME} is notarized and ready for distribution."
    echo "    You can now zip it for distribution: ditto -c -k --keepParent ${APP_PATH} Tono-release.zip"
else
    echo "ERROR: Notarization status: ${STATUS}"
    echo ""
    # Fetch the full log for diagnosis
    SUBMISSION_ID=$(python3 -c "import json,sys; d=json.load(open('/tmp/notarize_result.json')); print(d.get('id',''))" 2>/dev/null || echo "")
    if [ -n "${SUBMISSION_ID}" ]; then
        echo "==> Fetching notarization log..."
        xcrun notarytool log "${SUBMISSION_ID}" \
            --apple-id "${APPLE_ID}" \
            --password "${APP_PASSWORD}" \
            --team-id "${TEAM_ID}"
    fi
    exit 1
fi
