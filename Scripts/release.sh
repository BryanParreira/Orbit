#!/usr/bin/env bash
#
# Build, sign, notarize and publish an Orbit release.
#
#   Scripts/release.sh 0.2.0                      full release to GitHub
#   Scripts/release.sh 0.2.0 --notes notes.md     with release notes (Markdown)
#   Scripts/release.sh 0.2.0 --draft              GitHub draft (not seen by the updater)
#   Scripts/release.sh 0.2.0 --skip-notarize --no-publish    local signed DMG only
#
# One-time setup is in README.md → "Releasing".

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# ---------------------------------------------------------------- arguments

VERSION="${1:-}"
shift || true
NOTES=""
NOTARIZE=1
PUBLISH=1
DRAFT=0
PLAIN_DMG="${ORBIT_PLAIN_DMG:-0}"
NOTARY_PROFILE="${ORBIT_NOTARY_PROFILE:-orbit-notary}"
SPARKLE_ACCOUNT="${ORBIT_SPARKLE_ACCOUNT:-orbit}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --notes) NOTES="$2"; shift 2 ;;
        --skip-notarize) NOTARIZE=0; shift ;;
        --no-publish) PUBLISH=0; shift ;;
        --draft) DRAFT=1; shift ;;
        --plain-dmg) PLAIN_DMG=1; shift ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
    echo "Usage: Scripts/release.sh <version, e.g. 0.2.0> [--notes FILE] [--draft] [--skip-notarize] [--no-publish] [--plain-dmg]" >&2
    exit 2
fi

# ---------------------------------------------------------------- helpers

bold=$'\e[1m'; dim=$'\e[2m'; green=$'\e[32m'; red=$'\e[31m'; reset=$'\e[0m'
step() { echo; echo "${bold}▸ $*${reset}"; }
ok()   { echo "  ${green}✓${reset} $*"; }
die()  { echo "  ${red}✗ $*${reset}" >&2; exit 1; }

xcconfig() { sed -nE "s/^$1 = (.*)$/\1/p" Config/Orbit.xcconfig | head -1; }

TEAM_ID="$(xcconfig ORBIT_TEAM_ID)"
REPO="$(xcconfig ORBIT_GITHUB_REPO)"
TAG="v$VERSION"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"
OUT="$ROOT/build/release/$VERSION"
ARCHIVE="$OUT/Orbit.xcarchive"
APP="$OUT/export/Orbit.app"
DMG="$OUT/Orbit-$VERSION.dmg"
DERIVED="$ROOT/build/DerivedData"
SPARKLE_BIN="$DERIVED/SourcePackages/artifacts/sparkle/Sparkle/bin"

# ---------------------------------------------------------------- preflight

step "Preflight"
for tool in xcodegen xcodebuild create-dmg python3; do
    command -v "$tool" >/dev/null || die "$tool is not installed (brew install $tool)"
done
[[ $PUBLISH == 0 ]] || command -v gh >/dev/null || die "gh is not installed (brew install gh)"
ok "tools"

IDENTITY="$(security find-identity -v -p codesigning | grep "Developer ID Application: .*($TEAM_ID)" | head -1 | awk '{print $2}')"
[[ -n "$IDENTITY" ]] || die "No 'Developer ID Application' certificate for team $TEAM_ID in your keychain"
ok "Developer ID Application certificate ($TEAM_ID)"

if [[ $NOTARIZE == 1 ]]; then
    xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
        || die "No notarization credentials. Run once:
      xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id YOUR_APPLE_ID --team-id $TEAM_ID"
    ok "notary profile '$NOTARY_PROFILE'"
fi

if [[ $PUBLISH == 1 ]]; then
    gh auth status >/dev/null 2>&1 || die "gh is not logged in (gh auth login)"
    gh repo view "$REPO" >/dev/null 2>&1 || die "GitHub repo $REPO not found. Create it with:
      gh repo create $REPO --public --source . --push"
    ! gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1 || die "Release $TAG already exists on $REPO"
    ok "GitHub $REPO"
fi

KEY="$(xcconfig ORBIT_SPARKLE_PUBLIC_KEY)"
[[ -n "$KEY" && "$KEY" != REPLACE* ]] || die "ORBIT_SPARKLE_PUBLIC_KEY is not set in Config/Orbit.xcconfig"
[[ "$KEY" != *//* ]] || die "Sparkle public key contains '//', which xcconfig treats as a comment. Regenerate it."
[[ -z "$NOTES" || -f "$NOTES" ]] || die "Release notes file not found: $NOTES"

# ---------------------------------------------------------------- version

step "Version $VERSION ($BUILD_NUMBER)"
sed -i '' -E "s/^MARKETING_VERSION = .*/MARKETING_VERSION = $VERSION/; s/^CURRENT_PROJECT_VERSION = .*/CURRENT_PROJECT_VERSION = $BUILD_NUMBER/" Config/Orbit.xcconfig
ok "Config/Orbit.xcconfig updated"

# ---------------------------------------------------------------- build

step "Archive"
rm -rf "$OUT"
mkdir -p "$OUT"
xcodegen generate --quiet
xcodebuild archive \
    -project Orbit.xcodeproj -scheme Orbit -configuration Release \
    -archivePath "$ARCHIVE" -derivedDataPath "$DERIVED" \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Developer ID Application" DEVELOPMENT_TEAM="$TEAM_ID" \
    OTHER_CODE_SIGN_FLAGS="--timestamp" \
    > "$OUT/archive.log" 2>&1 || { tail -30 "$OUT/archive.log"; die "Archive failed (log: $OUT/archive.log)"; }
ok "archived"

step "Export (Developer ID)"
sed "s/__TEAM_ID__/$TEAM_ID/" Distribution/ExportOptions.plist > "$OUT/ExportOptions.plist"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$OUT/export" -exportOptionsPlist "$OUT/ExportOptions.plist" \
    > "$OUT/export.log" 2>&1 || { tail -30 "$OUT/export.log"; die "Export failed (log: $OUT/export.log)"; }
codesign --verify --deep --strict "$APP" || die "Signature check failed"
# capture first: `grep -q` closing the pipe early would trip pipefail
ENTITLEMENTS="$(codesign -d --entitlements - "$APP" 2>/dev/null)"
SIGNATURE="$(codesign -dvv "$APP" 2>&1)"
[[ "$ENTITLEMENTS" == *com.apple.security.virtualization* ]] || die "Virtualization entitlement missing"
[[ "$SIGNATURE" == *"(runtime)"* ]] || die "Hardened runtime not enabled"
[[ "$SIGNATURE" == *"Timestamp="* ]] || die "Signature has no secure timestamp"
ok "signed: $(echo "$SIGNATURE" | sed -nE 's/^Authority=(Developer ID Application.*)/\1/p')"

notarize() {
    local file="$1"
    echo "  ${dim}submitting $(basename "$file") to Apple (usually 1–5 minutes)…${reset}"
    local result
    result="$(xcrun notarytool submit "$file" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json)" || true
    if [[ "$result" != *'"status":"Accepted"'* && "$result" != *'"status": "Accepted"'* ]]; then
        local id
        id="$(echo "$result" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))' 2>/dev/null || true)"
        [[ -n "$id" ]] && xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" || echo "$result"
        die "Notarization rejected $(basename "$file")"
    fi
    xcrun stapler staple -q "$file"
    ok "notarized and stapled $(basename "$file")"
}

if [[ $NOTARIZE == 1 ]]; then
    step "Notarize app"
    ditto -c -k --keepParent "$APP" "$OUT/Orbit-notarize.zip"
    notarize "$OUT/Orbit-notarize.zip"
    # the ticket is stapled to the app itself, so it opens offline too
    xcrun stapler staple -q "$APP"
    rm "$OUT/Orbit-notarize.zip"
fi

# ---------------------------------------------------------------- DMG

step "Disk image"
STAGE="$OUT/dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Orbit.app"
DMG_ARGS=(
    --volname "Orbit $VERSION"
    --volicon "$APP/Contents/Resources/AppIcon.icns"
    --background "Distribution/dmg-background.tiff"
    --window-pos 200 140 --window-size 660 428
    --icon-size 112 --text-size 13
    --icon "Orbit.app" 180 190 --hide-extension "Orbit.app"
    --app-drop-link 480 190
    --format ULFO --filesystem APFS
    --no-internet-enable
)
[[ $PLAIN_DMG == 1 ]] && DMG_ARGS+=(--skip-jenkins)
create-dmg "${DMG_ARGS[@]}" "$DMG" "$STAGE" > "$OUT/dmg.log" 2>&1 \
    || { tail -20 "$OUT/dmg.log"; die "create-dmg failed. If Finder automation was denied, rerun with --plain-dmg"; }
codesign --sign "$IDENTITY" --timestamp "$DMG"
ok "$(basename "$DMG") ($(du -h "$DMG" | cut -f1 | xargs))"

if [[ $NOTARIZE == 1 ]]; then
    step "Notarize disk image"
    notarize "$DMG"
    GATEKEEPER="$(spctl -a -t open --context context:primary-signature -v "$DMG" 2>&1 || true)"
    [[ "$GATEKEEPER" == *accepted* ]] && ok "Gatekeeper accepts the DMG" || die "Gatekeeper rejects the DMG: $GATEKEEPER"
fi

# ---------------------------------------------------------------- appcast

step "Update feed (Sparkle)"
FEED="$OUT/appcast"
mkdir -p "$FEED"
if [[ $PUBLISH == 1 ]]; then
    # keep every earlier release in the feed
    gh release download --repo "$REPO" --pattern appcast.xml --dir "$FEED" 2>/dev/null && ok "merged with the previous appcast" || ok "first release, new appcast"
fi
cp "$DMG" "$FEED/"
if [[ -n "$NOTES" ]]; then
    python3 - "$NOTES" "$FEED/Orbit-$VERSION.html" <<'PY'
import html, re, sys
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
out, in_list = [], False
def inline(t):
    t = html.escape(t)
    t = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", t)
    return re.sub(r"`(.+?)`", r"<code>\1</code>", t)
for line in lines:
    s = line.strip()
    if s.startswith(("- ", "* ")):
        if not in_list: out.append("<ul>"); in_list = True
        out.append(f"<li>{inline(s[2:])}</li>"); continue
    if in_list: out.append("</ul>"); in_list = False
    if s.startswith("#"):
        level = min(len(s) - len(s.lstrip("#")) + 1, 4)
        out.append(f"<h{level}>{inline(s.lstrip('#').strip())}</h{level}>")
    elif s:
        out.append(f"<p>{inline(s)}</p>")
if in_list: out.append("</ul>")
open(sys.argv[2], "w", encoding="utf-8").write("\n".join(out))
PY
fi
"$SPARKLE_BIN/generate_appcast" \
    --account "$SPARKLE_ACCOUNT" \
    --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" \
    --embed-release-notes \
    --link "https://github.com/$REPO" \
    -o "$FEED/appcast.xml" \
    "$FEED" > "$OUT/appcast.log" 2>&1 || { cat "$OUT/appcast.log"; die "generate_appcast failed"; }
APPCAST="$(cat "$FEED/appcast.xml")"
[[ "$APPCAST" == *sparkle:edSignature* ]] || die "appcast has no EdDSA signature"
[[ "$APPCAST" == *"<sparkle:version>$BUILD_NUMBER</sparkle:version>"* ]] || die "appcast is missing build $BUILD_NUMBER"
cp "$FEED/appcast.xml" "$OUT/appcast.xml"
ok "appcast.xml signed with Sparkle key '$SPARKLE_ACCOUNT'"

# ---------------------------------------------------------------- publish

if [[ $PUBLISH == 1 ]]; then
    step "Publish $TAG"
    NOTES_ARGS=(--generate-notes)
    [[ -n "$NOTES" ]] && NOTES_ARGS=(--notes-file "$NOTES")
    DRAFT_ARGS=()
    [[ $DRAFT == 1 ]] && DRAFT_ARGS=(--draft)
    gh release create "$TAG" --repo "$REPO" --title "Orbit $VERSION" "${NOTES_ARGS[@]}" "${DRAFT_ARGS[@]}" \
        "$DMG" "$OUT/appcast.xml"
    ok "https://github.com/$REPO/releases/tag/$TAG"
    [[ $DRAFT == 1 ]] && echo "  ${dim}Draft releases are invisible to the updater until you publish them.${reset}"
fi

step "Done"
echo "  DMG:     $DMG"
echo "  Appcast: $OUT/appcast.xml"
[[ $NOTARIZE == 0 ]] && echo "  ${dim}Not notarized: other Macs will block it. Drop --skip-notarize for a real release.${reset}"
[[ $PUBLISH == 0 ]] && echo "  ${dim}Not published. Upload the DMG and appcast.xml to release $TAG yourself, or rerun without --no-publish.${reset}"
exit 0
