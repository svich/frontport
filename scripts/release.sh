#!/bin/bash
# Builds a Frontport release: a Developer ID–signed, notarized and stapled Frontport.app, zipped, with a signed Sparkle
# appcast entry for it. See scripts/README.md for the one-time setup and what to upload.
#
#     scripts/release.sh [--dry-run] [--profile <notarytool profile>] [--key-account <Sparkle Keychain account>]
#                        [--output <folder>] [--download-url-prefix <url>]
#
# --dry-run does every step that needs no credential (tools, project, Swift packages, Sparkle's tools, version,
# Info.plist), then stops before the first one that does.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dry_run=0
profile="${FRONTPORT_NOTARY_PROFILE:-frontport}"
key_account="${FRONTPORT_SPARKLE_ACCOUNT:-ed25519}"
output="${FRONTPORT_RELEASE_DIR:-$repo/build/release}"
download_prefix="${FRONTPORT_DOWNLOAD_URL_PREFIX:-}"
steamgriddb_service="frontport-steamgriddb"

usage() { sed -n '2,9p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

step() { printf '\n==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
die() {
    printf '\nerror: %s\n' "$1" >&2
    shift
    for line in "$@"; do printf '       %s\n' "$line" >&2; done
    exit 1
}

while (($#)); do
    case "$1" in
        --dry-run) dry_run=1 ;;
        --profile) profile="${2:?--profile needs a name}"; shift ;;
        --key-account) key_account="${2:?--key-account needs a name}"; shift ;;
        --output) output="${2:?--output needs a folder}"; shift ;;
        --download-url-prefix) download_prefix="${2:?--download-url-prefix needs a URL}"; shift ;;
        -h | --help) usage; exit 0 ;;
        *) usage >&2; die "Unknown option: $1" ;;
    esac
    shift
done

project="$repo/Frontport.xcodeproj"
derived="$output/DerivedData"
info_plist="$repo/App/Resources/Info.plist"
setup="See scripts/README.md, “One-time setup”."

# The identity and team come from App/Signing.local.xcconfig, which App/Signing.xcconfig includes, unless
# FRONTPORT_SIGNING_IDENTITY and FRONTPORT_TEAM_ID override them for this run.
overrides=()
if [[ -n "${FRONTPORT_SIGNING_IDENTITY:-}" ]]; then overrides+=("CODE_SIGN_IDENTITY=$FRONTPORT_SIGNING_IDENTITY"); fi
if [[ -n "${FRONTPORT_TEAM_ID:-}" ]]; then overrides+=("DEVELOPMENT_TEAM=$FRONTPORT_TEAM_ID"); fi

# MARK: Steps that need no credential

step "Checking tools"
for tool in xcodegen xcodebuild xcrun codesign ditto plutil spctl security file; do
    command -v "$tool" > /dev/null || die "$tool isn’t installed." "$setup"
done
for tool in notarytool stapler; do
    xcrun --find "$tool" > /dev/null 2>&1 || die "xcrun can’t find $tool; install Xcode 27 and select it with xcode-select."
done
note "xcodegen, Xcode $(xcodebuild -version | awk 'NR == 1 { print $2 }'), notarytool and stapler found"

step "Generating Frontport.xcodeproj"
(cd "$repo" && xcodegen generate --quiet)

step "Resolving Swift packages"
mkdir -p "$output"
xcodebuild -resolvePackageDependencies -project "$project" -scheme Frontport -derivedDataPath "$derived" -quiet
sparkle="$derived/SourcePackages/artifacts/sparkle/Sparkle/bin"
for tool in generate_appcast generate_keys; do
    [[ -x "$sparkle/$tool" ]] || die "Sparkle’s $tool isn’t in $sparkle." "Did the Sparkle package resolve?"
done
note "Sparkle’s tools: $sparkle"

step "Reading the Release build settings"
# ${overrides[@]+...} keeps an empty array from tripping `set -u` in macOS's bash 3.2.
settings="$(xcodebuild -project "$project" -scheme Frontport -configuration Release -derivedDataPath "$derived" \
    -showBuildSettings ${overrides[@]+"${overrides[@]}"} 2> /dev/null)"
setting() {
    awk -v key="$1" '
        /^Build settings for action / { in_app = ($NF == "Frontport:") }
        in_app && $1 == key && $2 == "=" { sub(/^[^=]*= ?/, ""); print; exit }
    ' <<< "$settings"
}
version="$(setting MARKETING_VERSION)"
build="$(setting CURRENT_PROJECT_VERSION)"
identity="$(setting CODE_SIGN_IDENTITY)"
team="$(setting DEVELOPMENT_TEAM)"
hardened="$(setting ENABLE_HARDENED_RUNTIME)"
[[ -n "$version" && -n "$build" ]] || die "The build settings have no MARKETING_VERSION or CURRENT_PROJECT_VERSION."
note "Frontport $version ($build)"

step "Checking Info.plist for Sparkle"
problems=()
public_key="$(plutil -extract SUPublicEDKey raw -o - "$info_plist" 2> /dev/null || true)"
feed="$(plutil -extract SUFeedURL raw -o - "$info_plist" 2> /dev/null || true)"
if [[ -z "$public_key" ]]; then
    problems+=("App/Resources/Info.plist has no SUPublicEDKey, so the release couldn’t update itself.")
fi
if [[ "$feed" != https://* || "$feed" == *.invalid/* ]]; then
    problems+=("App/Resources/Info.plist’s SUFeedURL is “$feed”, not the real https:// appcast URL.")
fi
if ((${#problems[@]})); then
    # A release stops on these once its credentials are checked.
    for problem in "${problems[@]}"; do note "problem: $problem"; done
else
    note "SUFeedURL $feed, SUPublicEDKey $public_key"
fi
if [[ -z "$download_prefix" && -n "$feed" ]]; then download_prefix="${feed%/*}/"; fi

# MARK: Steps that need credentials

if ((dry_run)); then
    step "Dry run: stopping before the first step that needs a credential"
    if [[ "$identity" == Developer\ ID\ Application* && -n "$team" ]]; then
        note "Next: sign with “$identity” (team $team), which must be in the login keychain."
    else
        note "Next: sign with a Developer ID Application identity. None is configured (CODE_SIGN_IDENTITY is"
        note "“$identity”), so a release would stop there. Set it in App/Signing.local.xcconfig, or set"
        note "FRONTPORT_SIGNING_IDENTITY and FRONTPORT_TEAM_ID."
    fi
    note "Then: notarize with the notarytool profile “$profile”, and sign the appcast with the Sparkle key in the"
    note "Keychain account “$key_account”. Neither was checked, nor the SteamGridDB key, which is optional."
    if ((${#problems[@]})); then
        note "A release would also stop at the Info.plist problems above, after these and before building."
        exit 1
    fi
    exit 0
fi

step "Checking the Developer ID identity"
if [[ "$identity" != Developer\ ID\ Application* || -z "$team" ]]; then
    die "No Developer ID Application identity is configured (CODE_SIGN_IDENTITY is “$identity”, DEVELOPMENT_TEAM is “$team”)." \
        "Set them in App/Signing.local.xcconfig, or set FRONTPORT_SIGNING_IDENTITY and FRONTPORT_TEAM_ID." "$setup"
fi
[[ "$hardened" == YES ]] || die "ENABLE_HARDENED_RUNTIME is “$hardened” for “$identity”; App/Signing.xcconfig should turn it on."
identities="$(security find-identity -v -p codesigning)"
grep -F "$identity" <<< "$identities" | grep -qF "($team)" ||
    die "The login keychain has no valid “$identity” certificate for team $team." "$setup"
note "$identity (team $team), hardened runtime on"

step "Checking the notarytool profile “$profile”"
xcrun notarytool history --keychain-profile "$profile" > /dev/null 2>&1 ||
    die "notarytool can’t use the Keychain profile “$profile”: it’s missing or its credentials don’t work." \
        "Create it with xcrun notarytool store-credentials \"$profile\" …, or pass --profile." "$setup"

step "Checking the Sparkle key in the Keychain account “$key_account” and Info.plist"
keychain_key="$("$sparkle/generate_keys" --account "$key_account" -p 2> /dev/null || true)"
[[ -n "$keychain_key" ]] ||
    die "The Keychain has no Sparkle EdDSA key for the account “$key_account”." \
        "Create one with $sparkle/generate_keys --account $key_account, or pass --key-account." "$setup"
((${#problems[@]} == 0)) || die "${problems[@]}" "$setup"
[[ "$keychain_key" == "$public_key" ]] ||
    die "Info.plist’s SUPublicEDKey isn’t the public half of the Keychain’s Sparkle key ($keychain_key)."
note "Info.plist’s SUPublicEDKey matches; the feed is $feed"

step "Reading the SteamGridDB key"
# Optional: a release without one asks each user for their own key. Ship one only with SteamGridDB's written permission.
steamgriddb_key="${FRONTPORT_STEAMGRIDDB_KEY:-}"
if [[ -z "$steamgriddb_key" ]]; then
    steamgriddb_key="$(security find-generic-password -s "$steamgriddb_service" -w 2> /dev/null || true)"
fi
if [[ -n "$steamgriddb_key" ]]; then
    note "Found; it goes into Info.plist as FrontportSteamGridDBKey"
else
    note "None in FRONTPORT_STEAMGRIDDB_KEY or the Keychain item “$steamgriddb_service”: users will need their own key"
fi

step "Archiving the Release build"
archive="$output/Frontport.xcarchive"
rm -rf "$archive" "$output/export"
xcodebuild archive -project "$project" -scheme Frontport -configuration Release -destination 'generic/platform=macOS' \
    -derivedDataPath "$derived" -archivePath "$archive" ${overrides[@]+"${overrides[@]}"} OTHER_CODE_SIGN_FLAGS=--timestamp \
    FRONTPORT_STEAMGRIDDB_KEY="$steamgriddb_key" -quiet

step "Exporting for Developer ID"
# Export re-signs everything inside, Sparkle's helpers included, with the identity, the hardened runtime and a timestamp.
options="$output/ExportOptions.plist"
cat > "$options" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>developer-id</string>
    <key>destination</key><string>export</string>
    <key>signingStyle</key><string>manual</string>
    <key>signingCertificate</key><string>Developer ID Application</string>
    <key>teamID</key><string>$team</string>
</dict>
</plist>
PLIST
xcodebuild -exportArchive -archivePath "$archive" -exportPath "$output/export" -exportOptionsPlist "$options" -quiet
app="$output/export/Frontport.app"
[[ -d "$app" ]] || die "The export left no Frontport.app in $output/export."
[[ "$(plutil -extract FrontportSteamGridDBKey raw -o - "$app/Contents/Info.plist" 2> /dev/null || true)" == "$steamgriddb_key" ]] ||
    die "Frontport.app’s FrontportSteamGridDBKey isn’t the SteamGridDB key the script read."

step "Verifying the signature"
codesign --verify --strict --deep --verbose=2 "$app"
details="$(codesign -dvv "$app" 2>&1)"
grep -q "^Authority=Developer ID Application: .*($team)" <<< "$details" || die "Frontport.app isn’t signed by the Developer ID of team $team."
grep -q "^Timestamp=" <<< "$details" || die "Frontport.app’s signature has no secure timestamp, which notarization requires."
entitlements="$(codesign -d --entitlements - --xml "$app" 2> /dev/null || true)"
[[ "$entitlements" != *get-task-allow* ]] || die "Frontport.app carries get-task-allow, which a release must not."
# Every executable, frontport-primer and Sparkle's helpers included, must run under the hardened runtime.
while IFS= read -r -d '' item; do
    [[ "$(file -b "$item")" == Mach-O*executable* ]] || continue
    flags="$(codesign -dv "$item" 2>&1 | sed -n 's/.*flags=\([^ ]*\).*/\1/p')"
    [[ "$flags" == *runtime* ]] || die "${item#"$app"/} isn’t signed with the hardened runtime (flags $flags)."
    note "hardened runtime: ${item#"$app"/}"
done < <(find "$app/Contents" -type f -perm -u+x -print0)

step "Notarizing"
upload="$output/Frontport-$version-notarization.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$upload"
result="$output/notarization.json"
xcrun notarytool submit "$upload" --keychain-profile "$profile" --wait --output-format json > "$result" || true
status="$(plutil -extract status raw -o - "$result" 2> /dev/null || echo "no answer")"
if [[ "$status" != Accepted ]]; then
    id="$(plutil -extract id raw -o - "$result" 2> /dev/null || true)"
    [[ -n "$id" ]] && xcrun notarytool log "$id" --keychain-profile "$profile" "$output/notarization-log.json" > /dev/null 2>&1 || true
    die "Notarization ended with status “$status”." "See $result and $output/notarization-log.json."
fi
rm -f "$upload"
note "Accepted"

step "Stapling"
xcrun stapler staple "$app"
xcrun stapler validate "$app"
assessment="$(spctl -a -vv -t exec "$app" 2>&1)"
note "$assessment"
grep -q "accepted" <<< "$assessment" && grep -q "source=Notarized Developer ID" <<< "$assessment" ||
    die "Gatekeeper doesn’t accept the stapled app as Notarized Developer ID."

step "Updating the Sparkle appcast"
updates="$output/updates"
mkdir -p "$updates"
archive_zip="$updates/Frontport-$version.zip"
rm -f "$archive_zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$archive_zip"
"$sparkle/generate_appcast" --account "$key_account" --download-url-prefix "$download_prefix" "$updates"
appcast="$updates/appcast.xml"
grep -qE "sparkle:version=\"$build\"|<sparkle:version>$build</sparkle:version>" "$appcast" ||
    die "The appcast has no entry for build $build."
grep -q "sparkle:edSignature=" "$appcast" || die "The appcast's entries aren't signed."

step "Done"
note "Upload $archive_zip to ${download_prefix}$(basename "$archive_zip")"
note "and $appcast to $feed."
