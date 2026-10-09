#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
: "${BS_NOTARY_PROFILE:?Set BS_NOTARY_PROFILE to an existing notarytool Keychain profile name}"
BS_APP="${BS_APP_PATH:-.build/Beep Source.app}"
BS_RELEASE_DIR="${BS_RELEASE_DIR:-.build/release}"
BS_VERSION="${BS_RELEASE_VERSION:-1.0.0}"
BS_ARCHIVE="BeepSource-$BS_VERSION-arm64.zip"
mkdir -p "$BS_RELEASE_DIR"
codesign --verify --strict --verbose=2 "$BS_APP"
ditto -c -k --sequesterRsrc --keepParent "$BS_APP" "$BS_RELEASE_DIR/$BS_ARCHIVE"
xcrun notarytool submit "$BS_RELEASE_DIR/$BS_ARCHIVE" \
  --keychain-profile "$BS_NOTARY_PROFILE" --wait --timeout 20m \
  --output-format json > "$BS_RELEASE_DIR/notarization.json"
python3 - "$BS_RELEASE_DIR/notarization.json" <<'PY'
import json, sys
result = json.load(open(sys.argv[1]))
if result.get('status') != 'Accepted':
    raise SystemExit('Apple did not accept the submission: ' + str(result))
print('Accepted notarization:', result['id'])
PY
xcrun stapler staple "$BS_APP"
xcrun stapler validate "$BS_APP"
codesign --verify --strict --verbose=2 "$BS_APP"
spctl --assess --type execute --verbose=4 "$BS_APP"
ditto -c -k --sequesterRsrc --keepParent "$BS_APP" "$BS_RELEASE_DIR/$BS_ARCHIVE"
(cd "$BS_RELEASE_DIR" && shasum -a 256 "$BS_ARCHIVE" > "BeepSource-$BS_VERSION-SHA256.txt")
printf 'Release archive and checksum: %s\n' "$BS_RELEASE_DIR"
