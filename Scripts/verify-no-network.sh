#!/bin/bash
#
# verify-no-network.sh — Zenit PDF makes no network connection, proved on the assembled bundle.
#
# The claim: the application, its two XPC services, its two Quick Look extensions and its
# command-line tool never open a network connection. There is no updater, no update feed, no
# telemetry and no account. A newer version is installed by downloading it from the project's
# GitHub releases page.
#
# It is proved four ways, by file inspection only — nothing is launched:
#
#   1. **The kernel refuses it.** Every sandboxed piece (the app, each XPC service, each Quick
#      Look extension) is signed with `com.apple.security.app-sandbox` true and with neither
#      `com.apple.security.network.client` nor `com.apple.security.network.server`, and with no
#      `com.apple.security.temporary-exception.*` entitlement of any kind. Under the App Sandbox a
#      process without the network entitlements cannot open a network socket, whatever its code
#      tries. These are the entitlements actually attached to the signed bundle, read back with
#      `codesign`, not the source files.
#
#   2. **The code never asks.** No Mach-O in the bundle — including `Contents/Helpers/zenit`, the
#      one piece that runs outside the sandbox, in the person's own Terminal session — imports a
#      network entry point (BSD sockets, name resolution, URL loading, CFNetwork sockets,
#      Network.framework, WebKit) or links a networking framework.
#
#   3. **Nothing is configured to.** The built `Info.plist` carries no updater key (`SU*`), no
#      App Transport Security exception, no Bonjour service and no local-network usage string.
#
#   4. **No updater ships.** The bundle embeds no framework at all (`Contents/Frameworks` is
#      absent or empty) and nothing whose name contains "sparkle", "autoupdate" or "updater".
#
# ## Non-vacuity
#
# A scan that reads nothing passes everything, so each half proves it can fail first: the symbol
# scanner must flag a control program compiled here that calls `socket` and `connect`, and the
# entitlement checker must flag a control entitlement list that grants `network.client`. Then the
# real scan must have read at least MINIMUM_MACHOS binaries, MINIMUM_SANDBOXED sandboxed pieces
# and MINIMUM_UNDEFINED_SYMBOLS imported symbols.
#
# Usage:  Scripts/verify-no-network.sh [--app PATH]
#         --app PATH   inspect this bundle instead of build/Zenit PDF.app
#
# Exit 0 = no network capability found. Non-zero = the reason, printed.

set -u
set -o pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="${ROOT}/build/Zenit PDF.app"

# The bundle as built on 2026-10-27: the app, GeometryService, RepairService, ZenitQuickLook,
# ZenitQuickLookPreview and `zenit` — six Mach-O binaries, five of them sandboxed. Their imported
# symbols numbered well over a thousand; 200 only proves `nm` produced output at all.
readonly MINIMUM_MACHOS=6
readonly MINIMUM_SANDBOXED=5
readonly MINIMUM_UNDEFINED_SYMBOLS=200

while [[ $# -gt 0 ]]; do
    case "$1" in
        --app) APP_BUNDLE="$2"; shift 2 ;;
        -h|--help) sed -n '2,42p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) printf 'verify-no-network.sh: unknown option %s\n' "$1" >&2; exit 2 ;;
    esac
done

if [ -x "${ROOT}/Scripts/wave-marker.sh" ]; then
    "${ROOT}/Scripts/wave-marker.sh" check Apps
fi

section() { printf '\n\033[1m== %s\033[0m\n' "$1"; }
fail() { printf '\033[31mFAILED: %s\033[0m\n' "$1" >&2; exit 1; }
pass() { printf '  ok: %s\n' "$1"; }

for tool in clang codesign nm otool file plutil; do
    command -v "${tool}" >/dev/null || fail "${tool} is not on PATH"
done
PLISTBUDDY=/usr/libexec/PlistBuddy
[[ -x "${PLISTBUDDY}" ]] || fail "no ${PLISTBUDDY}"

WORK="$(mktemp -d)" || fail "mktemp -d"
trap 'rm -rf "${WORK}"' EXIT

# --- The two instruments ---------------------------------------------------------------------

# Imported C functions that are a network entry point, matched as whole symbols (`_socket`, not
# `_socketpair`, which only ever makes a local pipe).
NETWORK_FUNCTIONS=(
    '_socket' '_connect' '_getaddrinfo' '_gethostbyname' '_gethostbyname2' '_getnameinfo'
)
# Classes and API families that exist to reach the network, matched as substrings of the imported
# symbols, so an Objective-C class reference (`_OBJC_CLASS_$_NSURLSession`) and a Swift mangling
# that contains the name are both caught.
NETWORK_NAMES=(
    'URLSession' 'NSURLConnection' 'NSURLDownload' 'CFURLConnection' 'CFSocket'
    'CFStreamCreatePairWithSocket' 'CFHost' 'nw_connection' 'nw_endpoint' 'nw_listener'
    'NWConnection' 'NWBrowser' 'NWListener' 'SCNetworkReachability' 'SCNetworkConnection' 'WKWebView'
    'NSNetService'
    'MCSession' 'CKContainer'
)
# Frameworks whose only purpose is the network. SystemConfiguration is deliberately not listed: the
# persistence layer links it for `SCDynamicStoreCopyComputerName` (the Mac's name, for the session
# host record), which reads local configuration; its network half is caught by the
# `SCNetworkReachability` / `SCNetworkConnection` names above.
NETWORK_FRAMEWORKS=(
    'Network.framework' 'CFNetwork.framework' 'WebKit.framework' 'MultipeerConnectivity.framework'
    'CloudKit.framework'
)

# network_findings <mach-o> — prints one line per network import or networking framework.
network_findings() {
    local macho="$1" symbols linkage needle
    symbols="$(nm -u "${macho}" 2>/dev/null | sed -E 's/^[[:space:]]+//' || true)"
    linkage="$(otool -L "${macho}" 2>/dev/null || true)"
    # Here-strings, not `printf | grep -q`: under pipefail an early-exiting grep can SIGPIPE the
    # writer and turn a match into a failed pipeline exactly when the answer is yes.
    for needle in "${NETWORK_FUNCTIONS[@]}"; do
        if grep -qxF -- "${needle}" <<< "${symbols}"; then
            printf 'imports %s\n' "${needle}"
        fi
    done
    for needle in "${NETWORK_NAMES[@]}"; do
        if grep -qF -- "${needle}" <<< "${symbols}"; then
            printf 'imports %s\n' "${needle}"
        fi
    done
    for needle in "${NETWORK_FRAMEWORKS[@]}"; do
        case "${linkage}" in *"/${needle}/"*) printf 'links %s\n' "${needle}" ;; esac
    done
}

# entitlement_findings <entitlements.xml> <must-be-sandboxed: 1|0> — one line per problem.
entitlement_findings() {
    local plist="$1" sandboxed="$2" key
    for key in com.apple.security.network.client com.apple.security.network.server; do
        if "${PLISTBUDDY}" -c "Print :${key}" "${plist}" >/dev/null 2>&1; then
            printf 'grants %s\n' "${key}"
        fi
    done
    if grep -q '<key>com\.apple\.security\.temporary-exception\.' "${plist}" 2>/dev/null; then
        printf 'carries a temporary-exception entitlement: %s\n' \
            "$(grep -o '<key>com\.apple\.security\.temporary-exception\.[^<]*</key>' "${plist}" | sed 's/<[^>]*>//g' | tr '\n' ' ')"
    fi
    if [[ "${sandboxed}" == "1" ]]; then
        [[ "$("${PLISTBUDDY}" -c 'Print :com.apple.security.app-sandbox' "${plist}" 2>/dev/null)" == "true" ]] \
            || printf 'is not sandboxed (com.apple.security.app-sandbox is not true)\n'
    fi
}

# signed_entitlements <code> <out.xml> — the entitlements attached to the signature, as XML.
signed_entitlements() {
    codesign -d --entitlements - --xml "$1" 2>/dev/null | plutil -convert xml1 -o "$2" - 2>/dev/null \
        || printf '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict/></plist>\n' > "$2"
}

# --- Positive controls -----------------------------------------------------------------------

section "Positive controls — each instrument can fail"
cat > "${WORK}/control-probe.c" <<'CSOURCE'
#include <string.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

int main(void) {
    int s = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in address;
    memset(&address, 0, sizeof address);
    address.sin_family = AF_INET;
    address.sin_port = htons(443);
    inet_pton(AF_INET, "203.0.113.1", &address.sin_addr);   /* RFC 5737 TEST-NET-3; never run */
    return connect(s, (struct sockaddr *)&address, sizeof address);
}
CSOURCE
clang -o "${WORK}/control-probe" "${WORK}/control-probe.c" || fail "could not build the control probe"
control="$(network_findings "${WORK}/control-probe")"
case "${control}" in
    *"imports _socket"*"imports _connect"*) pass "the symbol scan flags a program that calls socket() and connect() (it was compiled, never run)" ;;
    *) fail "the symbol scan did not flag the control probe (found: '${control}'); every later zero would be meaningless" ;;
esac

cat > "${WORK}/control-entitlements.xml" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
	<key>com.apple.security.app-sandbox</key><true/>
	<key>com.apple.security.network.client</key><true/>
	<key>com.apple.security.temporary-exception.mach-lookup.global-name</key><array><string>x</string></array>
</dict></plist>
PLIST
control="$(entitlement_findings "${WORK}/control-entitlements.xml" 1)"
case "${control}" in
    *"grants com.apple.security.network.client"*"temporary-exception"*) pass "the entitlement check flags network.client and a temporary exception" ;;
    *) fail "the entitlement check did not flag the control entitlements (found: '${control}')" ;;
esac

# --- The bundle ------------------------------------------------------------------------------

[[ -d "${APP_BUNDLE}" ]] || fail "no bundle at ${APP_BUNDLE}; run Scripts/build-app.sh first, or pass --app PATH"
CONTENTS="${APP_BUNDLE}/Contents"
printf '\nbundle: %s\n' "${APP_BUNDLE}"

section "1. Sandboxed, with no network entitlement (read from the signature)"
sandboxed_pieces=("${APP_BUNDLE}")
shopt -s nullglob
for piece in "${CONTENTS}/XPCServices/"*.xpc "${CONTENTS}/PlugIns/"*.appex; do
    sandboxed_pieces+=("${piece}")
done
shopt -u nullglob
problems=0
index=0
for piece in "${sandboxed_pieces[@]}"; do
    index=$((index + 1))
    xml="${WORK}/entitlements-${index}.xml"
    signed_entitlements "${piece}" "${xml}"
    findings="$(entitlement_findings "${xml}" 1)"
    label="${piece#"${CONTENTS}/"}"
    [[ "${piece}" == "${APP_BUNDLE}" ]] && label="Zenit PDF.app"
    if [[ -n "${findings}" ]]; then
        printf '%s\n' "${findings}" | sed "s|^|  FAIL ${label} |" >&2
        problems=$((problems + 1))
    else
        pass "${label}: sandboxed, no network entitlement, no temporary exception"
    fi
done
# The command-line tool runs outside the sandbox by design; it must still carry no network grant.
if [[ -f "${CONTENTS}/Helpers/zenit" ]]; then
    xml="${WORK}/entitlements-zenit.xml"
    signed_entitlements "${CONTENTS}/Helpers/zenit" "${xml}"
    findings="$(entitlement_findings "${xml}" 0)"
    if [[ -n "${findings}" ]]; then
        printf '%s\n' "${findings}" | sed 's|^|  FAIL Helpers/zenit |' >&2
        problems=$((problems + 1))
    else
        pass "Helpers/zenit: no network entitlement (unsandboxed by design; covered by the symbol scan)"
    fi
fi
[[ "${problems}" -eq 0 ]] || fail "${problems} piece(s) of the bundle could reach the network through an entitlement"
[[ "${#sandboxed_pieces[@]}" -ge "${MINIMUM_SANDBOXED}" ]] \
    || fail "only ${#sandboxed_pieces[@]} sandboxed piece(s) were checked; the floor is ${MINIMUM_SANDBOXED}"

section "2. No network entry point imported, no networking framework linked"
machos=()
while IFS= read -r candidate; do
    case "$(file -b "${candidate}" 2>/dev/null)" in
        *Mach-O*) machos+=("${candidate}") ;;
    esac
done < <(find "${APP_BUNDLE}" -type f -not -name '*.plist' -not -name '*.strings' \
             -not -name '*.stringsdict' -not -name '*.txt' -not -name '*.icns' 2>/dev/null)
problems=0
undefined_total=0
for macho in ${machos[@]+"${machos[@]}"}; do
    count="$(nm -u "${macho}" 2>/dev/null | grep -c '^[[:space:]]*_' || true)"
    undefined_total=$((undefined_total + ${count:-0}))
    findings="$(network_findings "${macho}")"
    if [[ -n "${findings}" ]]; then
        printf '%s\n' "${findings}" | sed "s|^|  FAIL ${macho#"${CONTENTS}/"} |" >&2
        problems=$((problems + 1))
    else
        pass "${macho#"${CONTENTS}/"}: ${count} imported symbols, none of them a network entry point"
    fi
done
[[ "${problems}" -eq 0 ]] || fail "${problems} binary(ies) in the bundle import a network entry point"
[[ "${#machos[@]}" -ge "${MINIMUM_MACHOS}" ]] \
    || fail "only ${#machos[@]} Mach-O binaries were scanned; the floor is ${MINIMUM_MACHOS}"
[[ "${undefined_total}" -ge "${MINIMUM_UNDEFINED_SYMBOLS}" ]] \
    || fail "only ${undefined_total} imported symbols were read; the floor is ${MINIMUM_UNDEFINED_SYMBOLS}, so nm read nothing"

section "3. Nothing in Info.plist configures a network service"
PLIST="${CONTENTS}/Info.plist"
[[ -f "${PLIST}" ]] || fail "no Info.plist in the bundle"
keys="$(plutil -convert xml1 -o - "${PLIST}" | grep -o '<key>[^<]*</key>' | sed 's/<[^>]*>//g')"
[[ -n "${keys}" ]] || fail "could not read the keys of ${PLIST}"
updater_keys="$(printf '%s\n' "${keys}" | grep -E '^SU[A-Z]' || true)"
[[ -z "${updater_keys}" ]] || fail "the built Info.plist carries updater keys: $(printf '%s' "${updater_keys}" | tr '\n' ' ')"
for key in NSAppTransportSecurity NSBonjourServices NSLocalNetworkUsageDescription; do
    if grep -qx -- "${key}" <<< "${keys}"; then
        fail "the built Info.plist carries ${key}"
    fi
done
pass "no SU* updater key, no App Transport Security exception, no Bonjour service, no local-network usage string ($(printf '%s\n' "${keys}" | grep -c .) keys read)"

section "4. No updater, no embedded framework"
if [[ -d "${CONTENTS}/Frameworks" ]] && [[ -n "$(ls -A "${CONTENTS}/Frameworks" 2>/dev/null)" ]]; then
    fail "Contents/Frameworks is not empty: $(ls -A "${CONTENTS}/Frameworks" | tr '\n' ' ')"
fi
pass "Contents/Frameworks is absent or empty"
updater_files="$(find "${APP_BUNDLE}" \( -iname '*sparkle*' -o -iname '*autoupdate*' -o -iname '*updater*' \) 2>/dev/null || true)"
[[ -z "${updater_files}" ]] || fail "the bundle carries updater pieces: ${updater_files}"
pass "nothing named like an updater is in the bundle"

printf '\n\033[32mNo network: %d sandboxed pieces without a network entitlement, %d binaries without a network import, no updater.\033[0m\n' \
    "${#sandboxed_pieces[@]}" "${#machos[@]}"
exit 0
