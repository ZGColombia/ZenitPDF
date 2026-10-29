#!/bin/bash
#
# verify-app-launches.sh — start the assembled application, prove it is alive and answering, quit
# it, and prove nothing was left running.
#
# ---------------------------------------------------------------------------------------------
# Why this exists
# ---------------------------------------------------------------------------------------------
# On 2026-08-24 `Scripts/build-app.sh` reported success on a bundle that died in dyld before
# main():
#
#     Termination Reason: Namespace DYLD, Code 1, Library missing
#     Library not loaded: @rpath/<an embedded framework, since removed>
#
# `Scripts/verify-bundle-linkage.sh` was written that day and it is a good gate — it resolves
# every dependency exactly as dyld would, and it now also refuses a Hardened-Runtime bundle whose
# code is not all signed by one team. But it launches nothing, and static linkage analysis is not
# the same as starting. A bundle can pass every static check and still be dead on arrival: a
# throwing initialiser in a global, a missing Info.plist key, an entitlement the kernel refuses, a
# crash in `applicationWillFinishLaunching`, a main-thread deadlock. None of those are visible to
# a scan.
#
# ---------------------------------------------------------------------------------------------
# Why this script no longer reads the unified log
# ---------------------------------------------------------------------------------------------
# The first version of this gate grepped the unified log for three `ZENIT-LAUNCH` markers that
# `ZenitApplicationDelegate` emits. It could never pass. The markers go out through
#
#     NSLog("%@ %@ pid=%d", LaunchMarker.prefix, LaunchMarker.begin, …)
#
# and every string in that call is a `%@` argument. `os_log` treats dynamic strings and objects
# as private, so the unified log stores `<private>` and the marker text is not in the log at all.
# The gate failed on a bundle that launches perfectly. That was this script's bug, not the
# application's.
#
# There are two ways out. The first is to put the marker text in the format *literal*
# (`NSLog("ZENIT-LAUNCH begin pid=%d", pid)` or `%{public}@`), which is a one-line change in
# `Apps/ZenitPDF/Sources/ZenitPDFAppKit/App/ZenitApplicationDelegate.swift`. **This script does
# not take that route**, because a gate whose verdict is a `grep` over a log the operating system is free to
# redact, rate-limit, roll over or reformat is a fragile gate even when the format string is
# right.
#
# So the gate asks the system directly. `ZenitApplicationDelegate.LaunchMarker` still emits its
# three markers, and each one still has a check here — what changed is where the answer is read
# from. The mapping, marker by marker:
#
#   ZENIT-LAUNCH begin              -> check 1. A process exists for this bundle's executable and
#                                      LaunchServices knows it under this bundle's identifier.
#   ZENIT-LAUNCH ready              -> check 2. No launch or modal frame is left on the main
#                                      thread, so the delegate returned.
#   ZENIT-LAUNCH run-loop-serviced  -> check 3. The main thread is parked in the AppKit event
#                                      loop's `mach_msg` wait, twice, a second apart.
#
# Each replacement is answered by a mechanism that has no text for anything to redact, and each is
# strictly stronger than the marker it replaces: a marker says a line executed once, the stack
# says what the main thread is doing now and can be asked again. In detail:
#
#   1. STARTED       — a process exists for the bundle's own executable, and LaunchServices knows
#                      it under the bundle's own identifier. dyld reached `main()` and AppKit
#                      registered the application. The 2026-08-24 dyld death never gets here.
#
#   2. LAUNCH RETURNED — LaunchServices has a record of the application (its
#                      `NSRunningApplication.isFinishedLaunching` is true), **and** the main
#                      thread's live stack no longer has any launch frame on it. The second half
#                      is the one that carries the check, and it is there because the first half
#                      was measured and found insufficient: a stub whose
#                      `applicationDidFinishLaunching` never returns still reports
#                      `isFinishedLaunching=true`, because AppKit sets the LaunchServices flag on
#                      the way *into* `_postDidFinishNotification`, not on the way out. Measured
#                      2026-08-25 against a deliberately blocked bundle. What a blocked launch
#                      does leave behind is unambiguous, and it is on the stack:
#
#                          -[NSApplication _sendFinishLaunchingNotification]
#                            -[NSApplication _postDidFinishNotification]
#                              …
#                                applicationDidFinishLaunching(_:)      <- still executing
#                                  CFRunLoopRun                         <- the nested loop
#
#                      A modal alert presented during launch — the exact failure the old `ready`
#                      marker was written to catch — has the same shape with
#                      `-[NSApplication runModalForWindow:]` in place of `CFRunLoopRun`. So the
#                      gate refuses any main-thread stack still carrying a launch or modal frame.
#
#   3. MAIN RUN LOOP IS PARKED AT TOP LEVEL — `/usr/bin/sample` is taken twice, and in both
#                      reports the main thread must spend the majority of its samples in
#                      `__CFRunLoopServiceMachPort`, reached through AppKit's own top-level idle
#                      wait (`_DPSBlockUntilNextEventMatchingListInMode` / `ReceiveNextEventCommon`)
#                      beneath `-[NSApplication run]`. That is the event loop blocked in
#                      `mach_msg` with nothing left to dispatch. A main thread deadlocked on a
#                      lock parks in `__psynch_mutexwait` / `__ulock_wait` / `semaphore_wait`
#                      underneath a run-loop *callout*; a main thread spinning shows application
#                      frames on top. Both are alive in `pgrep` and alive in Activity Monitor,
#                      and both fail here — measured, see the negative tests below.
#
# What check 3 proves and what it does not: it proves the loop has drained everything queued
# before the sample and is waiting for the next event. It does not, on its own, prove that a
# *new* event would be dispatched — nothing short of sending one proves that, and every way of
# sending one either needs Automation consent (an Apple event puts a TCC dialog in front of
# whoever is using this Mac) or puts a window on their screen. Check 2 supplies the missing half:
# to get from `_postDidFinishNotification` to an idle top-level wait, the loop demonstrably
# delivered the launch notification and everything queued behind it.
#
# ---------------------------------------------------------------------------------------------
# Negative tests — measured 2026-08-25, `swiftc` stubs, `LSUIElement`, never on screen
# ---------------------------------------------------------------------------------------------
# A gate nobody has watched fail is a gate nobody has tested. Four bundles were built, each
# breaking exactly one thing, and this script was pointed at each of them:
#
#   healthy    launches, returns, idles                    -> exit 0, 100% parked, both samples
#   dyld       links a framework that is then deleted      -> exit 1 at check 1, "the bundle did
#                                                             not start" (15.7's own failure)
#   blocked    CFRunLoopRun() inside didFinishLaunching    -> exit 1 at check 2, launch frames
#                                                             still on the main thread's stack
#   deadlock   main queue waits on a semaphore for ever    -> exit 1 at check 3, 0% parked
#
# The `blocked` bundle is why check 2 is not `isFinishedLaunching` alone: on the first pass of
# this rewrite it went **green**, which is the same class of bug as the one being fixed.
#
# Any `ZENIT-` line that *is* readable in the log for the launch window is printed below the
# verdict as corroboration. Nothing in the verdict depends on it.
#
# ---------------------------------------------------------------------------------------------
# The user's screen
# ---------------------------------------------------------------------------------------------
# `open -gj` launches in the background AND hidden, so nothing comes to the front and no window
# appears over whatever the person is doing. The gate runs the application exactly once, quits it,
# and confirms with `pgrep` that neither the app nor its XPC services are left behind.
#
# The first-run author-name question is a modal alert presented just after launch, and a hidden
# launch shows it as an application-modal `runModal`. This script answers it for the one launch
# it makes, through the argument domain (`open --args -<identifier>.author.prompted YES`), which
# `UserDefaults.standard` reads and never writes to disk. So the gate behaves the same on a
# machine where the app has never run, it never touches the application's container, and the
# user's own first-run question is still waiting for them afterwards.
#
# Usage:  Scripts/verify-app-launches.sh [path/to/Some.app] [--build] [--timeout SECONDS]
#         defaults to build/Zenit PDF.app, and does not build unless asked
#
#         --print-contract  print the launch contract (marker|check|mechanism, one row per
#                           marker) and exit 0 without launching anything. This is the machine
#                           readable half of the gate: the app suite reads it instead of
#                           grepping this file's prose. See "The launch contract" below.
#
#         The bundle identifier and executable name are read out of the bundle's own Info.plist
#         rather than hard-coded, so this gate can be pointed at a deliberately broken copy —
#         which is how it is negative-tested. See Scripts/verify-app-launches.sh --help.
#
# Exit 0 = the application started, answered, quit, and left nothing running.

set -u
set -o pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"



BUNDLE="${ROOT}/build/Zenit PDF.app"
BUILD_FIRST=0
SELF_TEST=0
PRINT_CONTRACT=0
TIMEOUT=60

while [ "$#" -gt 0 ]; do
    case "$1" in
        --build) BUILD_FIRST=1; shift ;;
        --self-test) SELF_TEST=1; shift ;;
        --print-contract) PRINT_CONTRACT=1; shift ;;
        --timeout) TIMEOUT="$2"; shift 2 ;;
        -h|--help) sed -n '2,120p' "${BASH_SOURCE[0]}"; exit 0 ;;
        -*) printf 'verify-app-launches.sh: unknown option %s\n' "$1" >&2; exit 2 ;;
        *) BUNDLE="$1"; shift ;;
    esac
done

readonly BUILD_FIRST TIMEOUT PRINT_CONTRACT
readonly MARKER_PREFIX="ZENIT-LAUNCH"

# ---------------------------------------------------------------------------------------------
# The launch contract — the one place the marker-to-check mapping is written down
# ---------------------------------------------------------------------------------------------
# `ZenitApplicationDelegate.LaunchMarker` declares three markers, and this gate answers each of
# them with a check. Those two halves have to agree, and the way they used to be held together
# was an app-suite test that grepped this file for the marker words in a *comment*
# (`SearchAndOCRWiringTests.swift`, "The gate greps for the markers the application actually
# logs"). That is the wrong shape twice over: a test asserting the prose of a shell script, and a
# contract that lives in whichever paragraph happened to mention it. Rewriting the comment turned
# the whole app package red on 2026-08-25 without a line of behaviour changing.
#
# So the mapping is data. One row per marker, three `|`-separated fields:
#
#     <marker text>|<check that answers it>|<the mechanism that check uses>
#
# Both sides read this table and nothing else. The gate titles its own check sections out of it
# (`contract_check`), so a check cannot be renamed or reordered without this table following it,
# and the app suite reads it by *running* `verify-app-launches.sh --print-contract` and comparing
# the marker column against the product's own `LaunchMarker` constants — so a marker added,
# renamed or removed in the application fails the app package here, and nowhere else.
readonly LAUNCH_CONTRACT="\
${MARKER_PREFIX} begin|check 1: started|a live process for this bundle's own executable, known to LaunchServices under this bundle's identifier
${MARKER_PREFIX} ready|check 2: launch returned|LaunchServices reports finishedLaunching, and no launch, modal or sheet frame is left on the main thread's stack
${MARKER_PREFIX} run-loop-serviced|check 3: main run loop parked at top level|the main thread is parked in __CFRunLoopServiceMachPort beneath -[NSApplication run], twice, one second apart"

if [ "${PRINT_CONTRACT}" -eq 1 ]; then
    printf '%s\n' "${LAUNCH_CONTRACT}"
    exit 0
fi

# --- Who holds the tree -----------------------------------------------------------------------
#
# Two builds sharing one working tree and one `.build` interfere with each other, and nothing
# else records that the other one is there. `wave-marker.sh check` prints a warning when another
# run's fresh marker is present, and **always exits 0**: a marker is a convention, never a lock,
# and a leftover one must not be able to redden or wedge a gate. Stale markers expire.
if [ -x "${ROOT}/Scripts/wave-marker.sh" ]; then
    "${ROOT}/Scripts/wave-marker.sh" check Apps/ZenitPDF
fi

# The section title for check N, taken from the contract rather than written twice. A missing row
# is a broken gate, not a blank heading.
contract_check() {
    local title
    title="$(printf '%s\n' "${LAUNCH_CONTRACT}" \
        | /usr/bin/awk -F'|' -v n="$1" '$2 ~ ("^check " n ":") { print $2 }')"
    [ -n "${title}" ] || fail "the launch contract has no row for check $1"
    printf '%s' "${title}"
}

# The share of the main thread's samples that must be sitting in the AppKit run loop's
# `mach_msg` wait. A healthy idle application measures 1.00; the threshold is well below that so
# a burst of real work during the one-second sample cannot turn a green run red.
readonly RUNLOOP_SHARE_FLOOR=50

APP_PID=""
BUNDLE_ID=""
EXECUTABLE_NAME=""
PROMPTED_KEY=""
WORK_DIR=""

section() { printf '\n=== %s ===\n' "$1"; }

# Make sure nothing survives this script, whatever way it ends.
cleanup() {
    # Everything this bundle has running, not only the pid this run managed to name. A gate that
    # fails before it identifies the process must still not leave that process behind: three
    # stubs survived a --self-test run on 2026-08-25 for exactly that reason.
    local sweep name pid
    if [ -n "${EXECUTABLE_NAME}" ]; then
        sweep="$(bundle_pids "${EXECUTABLE_NAME}")"
        for name in ${XPC_SERVICES[@]+"${XPC_SERVICES[@]}"}; do
            sweep="${sweep}$(bundle_pids "${name}")"
        done
        for pid in ${sweep}; do
            kill -TERM "${pid}" 2>/dev/null
        done
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            sweep="$(bundle_pids "${EXECUTABLE_NAME}")"
            for name in ${XPC_SERVICES[@]+"${XPC_SERVICES[@]}"}; do
                sweep="${sweep}$(bundle_pids "${name}")"
            done
            [ -z "${sweep}" ] && break
            sleep 0.5
        done
        for pid in ${sweep}; do
            kill -KILL "${pid}" 2>/dev/null
        done
    fi
    [ -n "${WORK_DIR}" ] && rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

fail() {
    printf '\n=======================================================================\n'
    printf 'FAILED: %s\n' "$1"
    printf '=======================================================================\n'
    exit 1
}

# ---------------------------------------------------------------------------------------------
# 0. --self-test: prove this gate can go red
# ---------------------------------------------------------------------------------------------
#
# The previous version of this script could not pass, and nobody knew, because nobody had watched
# it fail on purpose. `--self-test` builds four one-file AppKit bundles that each break exactly
# one of the three checks, runs this same script against each of them, and asserts both the exit
# status and which check produced it. The stubs are `LSUIElement`, so none of them ever puts
# anything on the screen, and none of them is the real application.
#
# It does not run as part of the normal gate: it costs about a minute and needs `swiftc`.

run_self_test() {
    command -v swiftc >/dev/null 2>&1 || {
        printf 'self-test needs swiftc, which is not on PATH\n' >&2
        exit 2
    }
    local work; work="$(mktemp -d)" || exit 2
    trap 'rm -rf "${work}"' EXIT

    cat > "${work}/stub.swift" <<'SWIFT'
import AppKit
import Foundation

final class StubDelegate: NSObject, NSApplicationDelegate {
    let gate = DispatchSemaphore(value: 0)
    func applicationDidFinishLaunching(_ notification: Notification) {
        #if BLOCKED
        // A nested run loop entered from inside the delegate: the shape of a modal alert
        // presented during launch. The loop drains; the delegate never returns.
        CFRunLoopRun()
        #elseif DEADLOCK
        // Launch completes, then the main thread parks for ever. `pgrep` calls this alive.
        DispatchQueue.main.async { [gate] in gate.wait() }
        #endif
    }
}

let app = NSApplication.shared
let delegate = StubDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // never on the user's screen
app.run()
SWIFT

    make_stub() {
        local name="$1"; shift
        local app="${work}/${name}.app"
        mkdir -p "${app}/Contents/MacOS"
        swiftc -O "$@" -o "${app}/Contents/MacOS/${name}" "${work}/stub.swift" >/dev/null 2>&1 \
            || { printf 'self-test: could not build %s\n' "${name}" >&2; exit 2; }
        /usr/libexec/PlistBuddy \
            -c "Add :CFBundleIdentifier string com.zenitgroup.zpdf-launchgate-selftest.${name}" \
            -c "Add :CFBundleExecutable string ${name}" \
            -c "Add :CFBundleName string ${name}" \
            -c "Add :CFBundlePackageType string APPL" \
            -c "Add :CFBundleShortVersionString string 1.0" \
            -c "Add :CFBundleInfoDictionaryVersion string 6.0" \
            -c "Add :LSUIElement bool true" \
            "${app}/Contents/Info.plist" >/dev/null
        codesign -s - --force --timestamp=none "${app}/Contents/MacOS/${name}" >/dev/null 2>&1
        codesign -s - --force --timestamp=none "${app}" >/dev/null 2>&1
    }

    make_stub ZStubHealthy
    make_stub ZStubBlocked  -DBLOCKED
    make_stub ZStubDeadlock -DDEADLOCK

    # 15.7's own failure, reproduced: link a dylib, then delete it, so dyld dies before main().
    printf 'public func zstubMissing() -> Int { 42 }\n' > "${work}/missing.swift"
    mkdir -p "${work}/ZStubDyld.app/Contents/MacOS" "${work}/ZStubDyld.app/Contents/Frameworks"
    swiftc -emit-library -o "${work}/ZStubDyld.app/Contents/Frameworks/libZMissing.dylib" \
        -Xlinker -install_name -Xlinker "@rpath/libZMissing.dylib" "${work}/missing.swift" >/dev/null 2>&1
    swiftc -O -o "${work}/ZStubDyld.app/Contents/MacOS/ZStubDyld" "${work}/stub.swift" \
        -L "${work}/ZStubDyld.app/Contents/Frameworks" -lZMissing \
        -Xlinker -rpath -Xlinker "@executable_path/../Frameworks" >/dev/null 2>&1 \
        || { printf 'self-test: could not build ZStubDyld\n' >&2; exit 2; }
    /usr/libexec/PlistBuddy \
        -c "Add :CFBundleIdentifier string com.zenitgroup.zpdf-launchgate-selftest.ZStubDyld" \
        -c "Add :CFBundleExecutable string ZStubDyld" \
        -c "Add :CFBundleName string ZStubDyld" \
        -c "Add :CFBundlePackageType string APPL" \
        -c "Add :CFBundleShortVersionString string 1.0" \
        -c "Add :CFBundleInfoDictionaryVersion string 6.0" \
        -c "Add :LSUIElement bool true" \
        "${work}/ZStubDyld.app/Contents/Info.plist" >/dev/null
    codesign -s - --force --timestamp=none "${work}/ZStubDyld.app/Contents/MacOS/ZStubDyld" >/dev/null 2>&1
    codesign -s - --force --timestamp=none "${work}/ZStubDyld.app" >/dev/null 2>&1
    rm -f "${work}/ZStubDyld.app/Contents/Frameworks/libZMissing.dylib"

    local failures=0
    expect() {
        local name="$1" want_status="$2" want_text="$3" label="$4"
        local out="${work}/${name}.out" status=0
        "${BASH_SOURCE[0]}" "${work}/${name}.app" --timeout 12 > "${out}" 2>&1 || status=$?
        if [ "${status}" -ne "${want_status}" ]; then
            printf '  FAIL  %-14s exit %s, expected %s (%s)\n' "${name}" "${status}" "${want_status}" "${label}"
            sed -n '/FAILED/,$p' "${out}" | head -5
            failures=$(( failures + 1 ))
            return
        fi
        if [ -n "${want_text}" ] && ! grep -q "${want_text}" "${out}"; then
            printf '  FAIL  %-14s exit %s but the verdict does not name %s\n' "${name}" "${status}" "${label}"
            sed -n '/FAILED/,$p' "${out}" | head -5
            failures=$(( failures + 1 ))
            return
        fi
        printf '  ok    %-14s exit %s  (%s)\n' "${name}" "${status}" "${label}"
    }

    printf '\n=== self-test: this gate must go red for each broken bundle ===\n'
    expect ZStubHealthy  0 "starts, finishes launching"   "a working bundle passes"
    expect ZStubDyld     1 "did not start\|exited during launch" "check 1: dies in dyld before main()"
    expect ZStubBlocked  1 "launch is blocked"            "check 2: launch never returns"
    expect ZStubDeadlock 1 "waiting for events"           "check 3: main thread deadlocked"

    printf '\n=======================================================================\n'
    if [ "${failures}" -ne 0 ]; then
        printf 'SELF-TEST FAILED: %d of 4 (this gate cannot be trusted to go red)\n' "${failures}"
        printf '=======================================================================\n'
        exit 1
    fi
    printf 'Self-test passed: the gate is green on a working bundle and red on each of the\n'
    printf 'three failures it claims to catch.\n'
    printf '=======================================================================\n'
    exit 0
}

if [ "${SELF_TEST}" -eq 1 ]; then
    run_self_test
fi

# ---------------------------------------------------------------------------------------------
# Finding *our* processes, and nobody else's
# ---------------------------------------------------------------------------------------------
#
# `pgrep -x GeometryService` is not a question about this bundle; it is a question about the whole
# machine. On 2026-08-25 it made this gate red because another workstream's `swift test` had an
# `Apps/ZenitPDF` XPC service of the same name alive at that moment — a green launch reported as
# "the gate left processes running". Every lookup below is therefore filtered by executable path:
# a process counts only if its executable lives inside the bundle under test.
#
# The XPC service names are read out of `Contents/XPCServices` rather than hard-coded, so a
# service added to the application is covered without editing this script, and a bundle that has
# none (every --self-test stub) is not measured against another bundle's services.

bundle_pids() {
    local name="$1" pid path
    for pid in $(pgrep -x "${name}" 2>/dev/null); do
        path="$(ps -p "${pid}" -o comm= 2>/dev/null)"
        case "${path}" in "${BUNDLE}"/*) printf '%s ' "${pid}" ;; esac
    done
}

foreign_pids() {
    local name="$1" pid path
    for pid in $(pgrep -x "${name}" 2>/dev/null); do
        path="$(ps -p "${pid}" -o comm= 2>/dev/null)"
        case "${path}" in "${BUNDLE}"/*) ;; *) printf '%s ' "${pid}" ;; esac
    done
}

# ---------------------------------------------------------------------------------------------
# 1. The bundle
# ---------------------------------------------------------------------------------------------

if [ "${BUILD_FIRST}" -eq 1 ]; then
    section "build"
    "${ROOT}/Scripts/build-app.sh" --output "$(dirname "${BUNDLE}")" \
        || fail "Scripts/build-app.sh did not produce a bundle"
fi

section "bundle"
[ -d "${BUNDLE}" ] || fail "no bundle at ${BUNDLE} (pass --build, or run Scripts/build-app.sh first)"
# Resolve symlinks and /var -> /private/var before anything compares this against `ps -o comm=`,
# which always reports the physical path. Measured 2026-08-25: without this the path-scoped
# process lookups below match nothing at all, and the gate reports a running bundle as one that
# never started.
BUNDLE="$(cd "${BUNDLE}" && pwd -P)" || fail "cannot resolve ${BUNDLE}"
[ -f "${BUNDLE}/Contents/Info.plist" ] || fail "no Info.plist in ${BUNDLE}"

plist_value() {
    /usr/libexec/PlistBuddy -c "Print :$1" "${BUNDLE}/Contents/Info.plist" 2>/dev/null
}
BUNDLE_ID="$(plist_value CFBundleIdentifier)"
EXECUTABLE_NAME="$(plist_value CFBundleExecutable)"
[ -n "${BUNDLE_ID}" ] || fail "Info.plist has no CFBundleIdentifier"
[ -n "${EXECUTABLE_NAME}" ] || fail "Info.plist has no CFBundleExecutable"
readonly BUNDLE_ID EXECUTABLE_NAME
[ -x "${BUNDLE}/Contents/MacOS/${EXECUTABLE_NAME}" ] \
    || fail "no executable at ${BUNDLE}/Contents/MacOS/${EXECUTABLE_NAME}"

# The key AuthorIdentity.promptedKey reads; see "The user's screen" above.
PROMPTED_KEY="${BUNDLE_ID}.author.prompted"
readonly PROMPTED_KEY

printf '%s\n' "${BUNDLE}"
printf 'identifier: %s   executable: %s\n' "${BUNDLE_ID}" "${EXECUTABLE_NAME}"

XPC_SERVICES=()
if [ -d "${BUNDLE}/Contents/XPCServices" ]; then
    for service in "${BUNDLE}/Contents/XPCServices"/*.xpc; do
        [ -d "${service}" ] || continue
        service_exe="$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "${service}/Contents/Info.plist" 2>/dev/null)"
        [ -n "${service_exe}" ] && XPC_SERVICES+=("${service_exe}")
    done
fi
readonly XPC_SERVICES
printf 'xpc services in this bundle: %s\n' "${XPC_SERVICES[*]+${XPC_SERVICES[*]}}"

# A bundle that already has a copy of *itself* running would make every check below ambiguous.
# One such instance once survived a previous run by eight hours.
existing="$(bundle_pids "${EXECUTABLE_NAME}")"
[ -z "${existing}" ] || fail "a ${EXECUTABLE_NAME} process from this bundle is already running (pid ${existing%% }); quit it before running this gate"
for service in ${XPC_SERVICES[@]+"${XPC_SERVICES[@]}"}; do
    existing="$(bundle_pids "${service}")"
    [ -z "${existing}" ] || fail "a ${service} process from this bundle is already running (pid ${existing%% }); quit it before running this gate"
done
# Same-named processes from somewhere else are somebody else's business. Named, not judged.
for name in "${EXECUTABLE_NAME}" ${XPC_SERVICES[@]+"${XPC_SERVICES[@]}"}; do
    other="$(foreign_pids "${name}")"
    [ -z "${other}" ] || printf 'note: %s also running from outside this bundle (pid %s) — not launched by this gate, not counted\n' \
        "${name}" "${other%% }"
done

WORK_DIR="$(mktemp -d)" || fail "mktemp -d"

# ---------------------------------------------------------------------------------------------
# 2. Launch, hidden and in the background
# ---------------------------------------------------------------------------------------------

section "launch"
LAUNCH_AT="$(date '+%Y-%m-%d %H:%M:%S')"
# -g: do not bring to the foreground. -j: launch hidden. Together they keep the application off
# the screen of whoever is using this Mac: a person's screen is not a test rig. The argument
# answers the first-run question for this launch only; nothing is written.
open -gj "${BUNDLE}" --args "-${PROMPTED_KEY}" YES || fail "open(1) refused to launch the bundle"
printf 'launched with: open -gj --args -%s YES (first-run question answered for this launch only)\n' "${PROMPTED_KEY}"

deadline=$(( $(date +%s) + TIMEOUT ))

# ---------------------------------------------------------------------------------------------
# 3. Check 1 — STARTED
# ---------------------------------------------------------------------------------------------

section "$(contract_check 1)"
while :; do
    APP_PID="$(bundle_pids "${EXECUTABLE_NAME}")"
    APP_PID="${APP_PID%% *}"
    [ -n "${APP_PID}" ] && break
    if [ "$(date +%s)" -ge "${deadline}" ]; then
        fail "no ${EXECUTABLE_NAME} process appeared within ${TIMEOUT}s — the bundle did not start (dyld, entitlements, or a crash before main())"
    fi
    sleep 0.25
done
printf 'process alive: pid %s\n' "${APP_PID}"

# ---------------------------------------------------------------------------------------------
# 4. Check 2 — LAUNCH RETURNED
# ---------------------------------------------------------------------------------------------
#
# JavaScript for Automation with the ObjC bridge, so `NSRunningApplication` is read in-process.
# This is not an Apple event and asks nobody for Automation consent; it is the same
# LaunchServices record `NSWorkspace` publishes. Output is one parseable line, or `NONE`.

running_application_state() {
    osascript -l JavaScript <<JXA 2>/dev/null
ObjC.import('AppKit');
var apps = \$.NSRunningApplication.runningApplicationsWithBundleIdentifier('${BUNDLE_ID}');
if (apps.count === 0) {
    'NONE';
} else {
    var a = apps.objectAtIndex(0);
    'pid=' + a.processIdentifier +
    ' finishedLaunching=' + a.finishedLaunching +
    ' terminated=' + a.isTerminated +
    ' hidden=' + a.hidden;
}
JXA
}

section "$(contract_check 2)"
state=""
while :; do
    if ! kill -0 "${APP_PID}" 2>/dev/null; then
        fail "the process exited during launch — it started and did not stay up"
    fi
    state="$(running_application_state)"
    case "${state}" in
        *"finishedLaunching=true"*) break ;;
    esac
    if [ "$(date +%s)" -ge "${deadline}" ]; then
        printf 'LaunchServices state: %s\n' "${state:-<no answer>}"
        fail "the process is running but LaunchServices never recorded ${BUNDLE_ID} as launched within ${TIMEOUT}s — it started and AppKit never got as far as registering it"
    fi
    sleep 0.25
done
printf 'LaunchServices state: %s\n' "${state}"

# The record has to be about the process this gate launched, not some other instance.
ls_pid="$(printf '%s' "${state}" | sed -n 's/^pid=\([0-9][0-9]*\).*/\1/p')"
[ "${ls_pid}" = "${APP_PID}" ] \
    || fail "LaunchServices reports pid ${ls_pid} for ${BUNDLE_ID} but this gate launched pid ${APP_PID}"

# ---------------------------------------------------------------------------------------------
# The main thread, read through the kernel
# ---------------------------------------------------------------------------------------------
#
# `sample` walks the target's threads and reports a call graph per thread with a sample count on
# every frame, so what follows is a measurement and not a guess. One pass over the main thread's
# block answers both remaining questions at once. It prints five fields:
#
#     <total> <parked> <sawAppRun> <topLevelIdle> <stillLaunching>
#
#   total           samples attributed to com.apple.main-thread
#   parked          of those, the largest count on a `__CFRunLoopServiceMachPort` frame
#   sawAppRun       `-[NSApplication run]` is on the stack at all
#   topLevelIdle    the wait was reached through AppKit's own idle path, not through a callout
#   stillLaunching  a launch or modal frame is still executing on the main thread

# `sample` spells the main thread's header line two different ways, depending on how far into
# launch the process is (measured 2026-08-25):
#
#   t ~ 0, before libdispatch has named the main queue
#       742 Thread_1153105381: Main Thread   DispatchQueue_<multiple>
#   settled
#       788 Thread_1153104048   DispatchQueue_1: com.apple.main-thread  (serial)
#
# A rule that knows only the second spelling reports a perfectly healthy application as one with
# no main thread at all. Both spellings live here, in one place, and both readers below take this
# pattern as an `awk -v` variable rather than restating it. Written without backslashes on
# purpose: `awk -v` processes escape sequences in the value, so `[.]` is used for a literal dot.
readonly MAIN_THREAD_HEADER_RE='com[.]apple[.]main-thread|Thread_[0-9]+:[[:space:]]*Main Thread'

readonly MAIN_THREAD_BLOCK='
    /^[[:space:]]+[0-9]+[[:space:]]+Thread_/ { inmain = ($0 ~ main_thread) }
    /^(Total number|Binary Images|Sort by)/ { inmain = 0 }
    inmain
'

analyse_main_thread() {
    /usr/bin/awk -v main_thread="${MAIN_THREAD_HEADER_RE}" '
        /^[[:space:]]+[0-9]+[[:space:]]+Thread_/ {
            if ($0 ~ main_thread) { inmain = 1; total = $1 + 0 } else { inmain = 0 }
            next
        }
        /^(Total number|Binary Images|Sort by)/ { inmain = 0 }
        !inmain { next }
        /-\[NSApplication run\]/ { sawrun = 1 }
        /_DPSBlockUntilNextEventMatchingListInMode|ReceiveNextEventCommon/ { idle = 1 }
        # AppKit frames that exist only while launch, a modal or a sheet is still on the stack.
        /_sendFinishLaunchingNotification|_postDidFinishNotification|\[NSApplication finishLaunching\]|runModalForWindow|runModalSession|_NSModalSession|_NSSheetSession|\[NSAlert runModal\]/ { launching = 1 }
        # The delegate method itself — but a Swift closure declared inside it inherits its name
        # ("partial apply for closure #1 in …applicationDidFinishLaunching(_:)"), and a block the
        # run loop is *dispatching* is the opposite of a launch that has not returned. Measured
        # 2026-08-25: the deadlock stub was misattributed to check 2 until this line excluded them.
        /applicationWillFinishLaunching|applicationDidFinishLaunching/ {
            if ($0 !~ /closure #|partial apply|thunk for|reabstraction/) launching = 1
        }
        /__CFRunLoopServiceMachPort/ {
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^[0-9]+$/) { if ($i + 0 > parked) parked = $i + 0; break }
            }
        }
        END { printf "%d %d %d %d %d\n", total, parked, sawrun, idle, launching }
    ' "$1"
}


print_main_thread() {
    printf '\n--- main thread call graph (%s) ---\n' "$2"
    /usr/bin/awk -v main_thread="${MAIN_THREAD_HEADER_RE}" "${MAIN_THREAD_BLOCK}" "$1" | head -45
}

if [ ! -x /usr/bin/sample ]; then
    fail "/usr/bin/sample is not present; this gate cannot inspect the main thread without it"
fi

# Poll for launch to leave the stack. `sample` costs a second per pass, which is also the poll
# interval, so a slow launch is waited out rather than misreported.
attempt=0
while :; do
    attempt=$(( attempt + 1 ))
    report="${WORK_DIR}/sample-launch-${attempt}.txt"
    /usr/bin/sample "${APP_PID}" 1 -f "${report}" >/dev/null 2>&1 && [ -s "${report}" ] || \
        fail "/usr/bin/sample could not inspect pid ${APP_PID} — without a stack this gate cannot tell a waiting run loop from a blocked one, and it will not guess"
    set -- $(analyse_main_thread "${report}")
    total="$1"; parked="$2"; sawrun="$3"; idle="$4"; launching="$5"
    # No named main thread at all is the same class of answer as a launch frame still on the
    # stack: the process has not settled yet, and one sample is not a verdict.
    # Wait it out inside the loop that already exists for that; the deadline below still catches a
    # process that genuinely never presents a main thread.
    if [ "${total}" -eq 0 ]; then
        printf 'sample %d: no main thread named yet — the process is still coming up; re-sampling\n' "${attempt}"
        if [ "$(date +%s)" -ge "${deadline}" ]; then
            print_main_thread "${report}" "no main thread named"
            fail "sample never named a main thread in pid ${APP_PID} within ${TIMEOUT}s — the gate could not read the process"
        fi
        continue
    fi
    [ "${launching}" -eq 0 ] && break
    if [ "$(date +%s)" -ge "${deadline}" ]; then
        print_main_thread "${report}" "launch still on the stack"
        fail "applicationDidFinishLaunching has not returned after ${TIMEOUT}s — launch is blocked. A modal alert presented during launch looks exactly like this, and so does a nested run loop entered from the delegate."
    fi
done
printf 'no launch or modal frame remains on the main thread: the delegate returned\n'

# ---------------------------------------------------------------------------------------------
# 5. Check 3 — MAIN RUN LOOP PARKED AT TOP LEVEL
# ---------------------------------------------------------------------------------------------

section "$(contract_check 3)"
for pass in 1 2; do
    if [ "${pass}" -eq 2 ]; then
        sleep 1
        report="${WORK_DIR}/sample-idle-2.txt"
        /usr/bin/sample "${APP_PID}" 1 -f "${report}" >/dev/null 2>&1 && [ -s "${report}" ] || \
            fail "/usr/bin/sample could not inspect pid ${APP_PID} on the second pass"
        set -- $(analyse_main_thread "${report}")
        total="$1"; parked="$2"; sawrun="$3"; idle="$4"; launching="$5"
        [ "${total}" -gt 0 ] || fail "sample named no main thread in pid ${APP_PID} on the second pass, one second after it named one on the first"
    fi
    share=0
    [ "${total}" -gt 0 ] && share=$(( parked * 100 / total ))
    printf 'sample %d: %s/%s main-thread samples (%s%%) parked in __CFRunLoopServiceMachPort; -[NSApplication run] %s; top-level idle wait %s\n' \
        "${pass}" "${parked}" "${total}" "${share}" \
        "$([ "${sawrun}" -eq 1 ] && printf 'yes' || printf 'NO')" \
        "$([ "${idle}" -eq 1 ] && printf 'yes' || printf 'NO')"
    if [ "${launching}" -eq 1 ]; then
        print_main_thread "${report}" "sample ${pass}"
        fail "a launch, modal or sheet frame is on the main thread again — a nested run loop waits for events too, so it is not idle at top level"
    fi
    if [ "${sawrun}" -eq 0 ]; then
        print_main_thread "${report}" "sample ${pass}"
        fail "the main thread is not inside -[NSApplication run] — the application started and is not running an event loop"
    fi
    if [ "${idle}" -eq 0 ]; then
        print_main_thread "${report}" "sample ${pass}"
        fail "the main thread never reached AppKit's top-level wait for the next event — it is inside a callout or a nested loop, not idle and available"
    fi
    if [ "${share}" -lt "${RUNLOOP_SHARE_FLOOR}" ]; then
        print_main_thread "${report}" "sample ${pass}"
        fail "the main thread spent only ${share}% of one second waiting for events (floor ${RUNLOOP_SHARE_FLOOR}%) — it is blocked or spinning, not servicing its run loop"
    fi
done
printf 'the main run loop is drained and waiting at top level, twice, one second apart\n'

# It must still be up after all of that. A process that started, answered and then fell over is
# not a launch that succeeded.
kill -0 "${APP_PID}" 2>/dev/null || fail "the process exited after answering"
printf 'still alive after answering: pid %s\n' "${APP_PID}"

# ---------------------------------------------------------------------------------------------
# 6. Corroboration only: whatever the unified log did manage to keep
# ---------------------------------------------------------------------------------------------

section "unified log (corroboration, not a verdict)"
log_lines="$(log show --style compact --start "${LAUNCH_AT}" \
    --predicate "processImagePath CONTAINS \"${EXECUTABLE_NAME}\"" 2>/dev/null \
    | grep "${MARKER_PREFIX}" || true)"
if [ -n "${log_lines}" ]; then
    printf '%s\n' "${log_lines}"
else
    printf 'no readable %s line in the log for this launch.\n' "${MARKER_PREFIX}"
    printf 'Expected: the delegate emits them as NSLog("%%@ %%@ …") arguments, which os_log stores\n'
    printf 'as <private>. Checks 1-3 above do not depend on them.\n'
fi

# ---------------------------------------------------------------------------------------------
# 7. Quit, and leave nothing behind
# ---------------------------------------------------------------------------------------------
#
# SIGTERM rather than a quit Apple event: sending Apple events to another application needs an
# Automation consent prompt, and a gate that puts a TCC dialog in front of the user has defeated
# its own reason for using `open -gj`. The launched instance opens an untitled document and owns
# no project package, so there is no crash marker to disarm and nothing to autosave.

section "quit"
kill -TERM "${APP_PID}" 2>/dev/null
quit_deadline=$(( $(date +%s) + 20 ))
while kill -0 "${APP_PID}" 2>/dev/null; do
    if [ "$(date +%s)" -ge "${quit_deadline}" ]; then
        kill -KILL "${APP_PID}" 2>/dev/null
        sleep 1
        fail "the application did not exit within 20s of SIGTERM and had to be killed"
    fi
    sleep 0.25
done
printf 'exited on SIGTERM: pid %s\n' "${APP_PID}"
APP_PID=""

section "no orphans"
sleep 1
orphans=0
for name in "${EXECUTABLE_NAME}" ${XPC_SERVICES[@]+"${XPC_SERVICES[@]}"}; do
    left="$(bundle_pids "${name}")"
    if [ -n "${left}" ]; then
        printf '  still running from this bundle: %s (pid %s)\n' "${name}" "${left%% }"
        orphans=1
    fi
done
[ "${orphans}" -eq 0 ] || fail "the gate left processes running"
printf 'no %s and no XPC service processes remain\n' "${EXECUTABLE_NAME}"

printf '\n=======================================================================\n'
printf 'The assembled application starts, finishes launching, services its main run loop,\n'
printf 'and quits. It is not dead on arrival.\n'
printf '=======================================================================\n'
exit 0
