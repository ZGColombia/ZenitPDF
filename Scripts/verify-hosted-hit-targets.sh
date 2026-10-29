#!/bin/bash
#
# verify-hosted-hit-targets.sh — no interactive control may be drawn transparent, and the
# Inspector's swatches must take a click in a binary stamped like the app.
#
# ## Why this gate exists
#
# LT3-01, 2026-09-23: clicking a colour swatch in the Inspector to recolour a markup did
# nothing. The swatch was a painted square over a system `ColorPicker` drawn at
# `.opacity(0.02)`, on the assumption that the nearly transparent well still took the click. In
# the shipped application it did not: SwiftUI's hit-testing depends on the SDK stamped into the
# main executable, the app is stamped with the macOS 14 SDK, and in that mode a hosted AppKit
# control that faint is left out of hit-testing. The click fell through to the container.
#
# Every package test runs inside `xctest`, which is stamped with the *current* SDK and
# hit-tests the modern way, where the same well is reachable. So the suites were green over a
# control nobody could click, and they would be green over the next one. This gate closes the
# class where it actually happens, in two halves:
#
#   1. A SOURCE SCAN over every UI source (`Packages/ZPDFUI*`, `Packages/ZPDFDesignSystem`,
#      `Apps/ZenitPDF/Sources`). It refuses an `.opacity(…)` modifier applied to a control that
#      SwiftUI hosts as an AppKit view — `ColorPicker`, `Stepper`, `TextField`, `SecureField`,
#      `TextEditor`, `Toggle`, `Slider`, `Picker`, `DatePicker`, `Menu`, and every
#      `NSViewRepresentable` declared in those sources — unless the argument is literally `1`.
#      It also refuses any control, `Button` included, drawn at a constant opacity below 1
#      (`.opacity(0)` on a zero-size button that exists only for its keyboard shortcut is the
#      same trick with a different control). A line may carry
#      `// hit-target-lint: allow <reason>` (on it or the line above) when the control is
#      disabled whenever the opacity is below 1; the reason is printed, so it stays reviewable.
#      The scan runs its own fixtures first (`--self-test`): the LT3-01 well, the old
#      opacity-0 Inspector stepper and the old zero-size cancel button must be caught, and the
#      decorative uses must not, or the gate refuses to vouch for anything.
#
#   2. THE PROBE, `zpdf-hit-probe` (Packages/ZPDFUIShell/Sources/ZPDFUIShellHitProbe). A
#      SwiftPM executable, so it is stamped with the package's macOS 14 deployment target like
#      the app — this script checks the stamp with `otool` and refuses a probe stamped with a
#      newer SDK, because such a probe would hit-test the way `xctest` does and prove nothing.
#      It hosts the real `InspectorPanel` in a window that is never ordered in (nothing reaches
#      the screen, the process never activates), requires every hosted AppKit control in it to
#      be reachable at its centre, clicks both swatches, picks from the palette, and requires
#      exactly one bulk style edit per pick. See the probe's header for the full list.
#
# ## Usage
#
#   Scripts/verify-hosted-hit-targets.sh                 # scan + probe
#   Scripts/verify-hosted-hit-targets.sh --scan-only     # scan (with its self-test) only
#   Scripts/verify-hosted-hit-targets.sh --self-test     # the scanner's fixtures only
#   Scripts/verify-hosted-hit-targets.sh --scan FILE...  # scan the named files (proving it bites)
#
#   ZENIT_SCRATCH_PATH=.build-x  builds the probe with `--scratch-path .build-x` (relative to the
#                                ZPDFUIShell package), for a run that keeps its own build tree.
#
# Exit status: 0 clean, 1 an offence or a probe failure, 2 the gate could not run.

set -u
set -o pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ---------------------------------------------------------------------------------------------
# The scanner
# ---------------------------------------------------------------------------------------------

SCANNER="$(mktemp)" || exit 2
trap 'rm -f "${SCANNER}"' EXIT
cat > "${SCANNER}" <<'PERL'
use strict;
use warnings;

# Controls SwiftUI hosts as AppKit views on macOS.
my @hosted = qw(ColorPicker Stepper TextField SecureField TextEditor Toggle Slider Picker DatePicker Menu);
# Controls of any kind: hosted ones, plus the SwiftUI controls a constant transparency hides.
my @controls = (@hosted, qw(Button Link));

my %representables;
my @files = @ARGV;

# Every NSViewRepresentable declared in the scanned sources is a hosted AppKit view too.
for my $file (@files) {
    open(my $fh, '<', $file) or next;
    while (my $line = <$fh>) {
        while ($line =~ /\b(?:struct|final\s+class|class)\s+(\w+)\s*(?:<[^>]*>)?\s*:\s*[^{]*\bNSViewRepresentable\b/g) {
            $representables{$1} = 1;
        }
    }
    close($fh);
}
push @hosted, keys %representables;

my $hosted_re = join('|', map { quotemeta } @hosted);
my $control_re = join('|', map { quotemeta } (@controls, keys %representables));
my $offences = 0;

sub indent_of { my ($l) = @_; $l =~ /^(\s*)/; my $i = $1; $i =~ s/\t/    /g; return length($i); }

for my $file (@files) {
    open(my $fh, '<', $file) or next;
    my @lines = <$fh>;
    close($fh);
    for (my $n = 0; $n < @lines; $n++) {
        my $line = $lines[$n];
        # The modifier form only: `.opacity(` opening a line. `color.opacity(0.2)` is a colour.
        next unless $line =~ /^\s*\.opacity\((.*)\)\s*(\/\/.*)?$/;
        my $arg = $1;
        next if $arg =~ /^\s*1(\.0+)?\s*$/;
        my $constant = ($arg =~ /^\s*0*\.?\d*\s*$/ || $arg =~ /^\s*0(\.\d+)?\s*$/) ? 1 : 0;
        my $allowed = ($line =~ /hit-target-lint:\s*allow\s+(.+)$/) ? $1
                    : ($n > 0 && $lines[$n - 1] =~ /hit-target-lint:\s*allow\s+(.+)$/) ? $1 : undef;
        # Walk up the modifier chain to the view it modifies: the nearest earlier line, at the
        # same or a shallower indent, that is not itself a modifier, a closing bracket, a
        # comment, blank, or the inside of a multi-line argument list.
        my $indent = indent_of($line);
        my $head = undef;
        my $depth = 0;
        for (my $k = $n - 1; $k >= 0 && $k >= $n - 60; $k--) {
            my $prev = $lines[$k];
            next if $prev =~ /^\s*$/ || $prev =~ /^\s*\/\//;
            my $opens = () = $prev =~ /[\(\[\{]/g;
            my $closes = () = $prev =~ /[\)\]\}]/g;
            $depth += $closes - $opens;
            next if $depth > 0;
            next if indent_of($prev) > $indent;
            next if $prev =~ /^\s*\./;
            next if $prev =~ /^\s*[\)\]\}]+\s*$/;
            $head = $prev;
            last;
        }
        next unless defined $head;
        my $hosted_head = ($head =~ /(?:^|[^\w.])($hosted_re)\s*(?:<[^>]*>)?\s*[\(\{]/) ? $1 : undef;
        my $control_head = ($head =~ /(?:^|[^\w.])($control_re)\s*(?:<[^>]*>)?\s*[\(\{]/) ? $1 : undef;
        my $why = undef;
        if (defined $hosted_head) {
            $why = "a hosted AppKit control ($hosted_head) under .opacity($arg)";
        } elsif (defined $control_head && $constant) {
            $why = "a control ($control_head) drawn at a constant .opacity($arg)";
        }
        next unless defined $why;
        my $where = sprintf("%s:%d", $file, $n + 1);
        if (defined $allowed) {
            print "ALLOWED  $where  $why — $allowed\n";
            next;
        }
        print "OFFENCE  $where  $why\n";
        $offences++;
    }
}
print "hit-target scan: $offences offence(s) in " . scalar(@files) . " file(s)\n";
exit($offences > 0 ? 1 : 0);
PERL

run_scan() { perl "${SCANNER}" "$@"; }

# The scanner's own fixtures. It must catch the three shipped offences and pass the decorative
# uses, or it is not trusted with the tree.
self_test() {
    local dir
    dir="$(mktemp -d)" || return 2
    cat > "${dir}/Offending.swift" <<'SWIFT'
struct LT301Well: View {
    var body: some View {
        HStack {
            ColorPicker("", selection: $draft, supportsOpacity: false)
                .labelsHidden()
                .frame(width: showsHex ? 34 : 28, height: showsHex ? nil : 28)
                .opacity(showsHex ? 1 : 0.02)
                .overlay { swatch.allowsHitTesting(false) }
        }
    }
}
struct OldStepper: View {
    var body: some View {
        HStack {
            Stepper(
                "",
                onIncrement: { nudge(by: step) },
                onDecrement: { nudge(by: -step) }
            )
            .labelsHidden()
            .controlSize(.mini)
            .opacity(showsStepper ? 1 : 0)
        }
    }
}
struct OldCancel: View {
    var body: some View {
        HStack {
            Button(NSLocalizedString("Cancel", comment: "")) {
                onClose()
            }
            .keyboardShortcut(.cancelAction)
            .frame(width: 0, height: 0)
            .opacity(0)
        }
    }
}
struct HiddenBridge: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
struct UsesBridge: View {
    var body: some View {
        HiddenBridge()
            .opacity(0.05)
    }
}
SWIFT
    cat > "${dir}/Clean.swift" <<'SWIFT'
struct Decorative: View {
    var body: some View {
        Button(action: action) {
            Text(title)
                .background {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.gray)
                        .opacity(isHovering ? 1 : 0)
                }
        }
        .buttonStyle(.plain)
        Rectangle()
            .fill(Color.blue.opacity(0.2))
            .opacity(isSelected ? 1 : 0)
        TextField("", text: $text)
            .opacity(1)
        Text(announcement)
            .frame(width: 1, height: 1)
            .opacity(0.001)
        Stepper("", value: $value)
            // hit-target-lint: allow disabled whenever dimmed
            .opacity(isEnabled ? 1 : 0.55)
            .disabled(!isEnabled)
    }
}
SWIFT
    local out rc=0
    out="$(run_scan "${dir}/Offending.swift")"
    local caught
    caught="$(printf '%s\n' "${out}" | grep -c '^OFFENCE')"
    if [ "${caught}" != "4" ]; then
        printf 'SELF-TEST FAIL: the scanner caught %s of the 4 fixture offences:\n%s\n' "${caught}" "${out}" >&2
        rc=1
    fi
    for needle in 'ColorPicker' 'Stepper' 'Button' 'HiddenBridge'; do
        if ! grep -q "OFFENCE.*${needle}" <<< "${out}"; then
            printf 'SELF-TEST FAIL: the %s fixture was not caught\n' "${needle}" >&2
            rc=1
        fi
    done
    out="$(run_scan "${dir}/Clean.swift")"
    if grep -q '^OFFENCE' <<< "${out}"; then
        printf 'SELF-TEST FAIL: the scanner flagged a decorative use:\n%s\n' "${out}" >&2
        rc=1
    fi
    if ! grep -q '^ALLOWED' <<< "${out}"; then
        printf 'SELF-TEST FAIL: an allow comment was not honoured and printed:\n%s\n' "${out}" >&2
        rc=1
    fi
    rm -rf "${dir}"
    if [ "${rc}" = "0" ]; then
        printf 'hit-target scan self-test: PASS (4 fixture offences caught, decorative uses passed)\n'
    fi
    return "${rc}"
}

ui_sources() {
    find "${ROOT}/Packages" -path '*/.build*' -prune -o -type f -name '*.swift' -print \
        | grep -E '/Packages/(ZPDFUI[A-Za-z]*|ZPDFDesignSystem)/Sources/'
    find "${ROOT}/Apps/ZenitPDF/Sources" -path '*/.build*' -prune -o -type f -name '*.swift' -print
}

scan_tree() {
    local files=()
    while IFS= read -r file; do files+=("${file}"); done < <(ui_sources)
    if [ "${#files[@]}" -lt 50 ]; then
        printf 'FAIL: the scan found only %s UI sources; it examined nothing worth trusting\n' "${#files[@]}" >&2
        return 2
    fi
    run_scan "${files[@]}"
}

case "${1:-}" in
    --self-test)
        self_test; exit $? ;;
    --scan)
        shift
        [ "$#" -gt 0 ] || { printf 'usage: %s --scan FILE...\n' "$0" >&2; exit 2; }
        self_test || exit 1
        run_scan "$@"; exit $? ;;
    --scan-only)
        self_test || exit 1
        scan_tree; exit $? ;;
    "") ;;
    *)
        printf 'usage: %s [--scan-only | --self-test | --scan FILE...]\n' "$0" >&2; exit 2 ;;
esac

# The full gate builds and runs the probe, so it says who else holds the tree (the scan-only
# forms above read files and nothing else, which is why the package suite may call them).
if [ -x "${ROOT}/Scripts/wave-marker.sh" ]; then
    "${ROOT}/Scripts/wave-marker.sh" check Packages/ZPDFUIShell Packages/ZPDFDesignSystem Apps/ZenitPDF/Sources
fi

printf '=== hosted hit targets: source scan ===\n'
self_test || exit 1
scan_tree
scan_rc=$?
[ "${scan_rc}" = "2" ] && exit 2

# ---------------------------------------------------------------------------------------------
# The probe
# ---------------------------------------------------------------------------------------------

printf '\n=== hosted hit targets: zpdf-hit-probe ===\n'
readonly SHELL_PACKAGE="${ROOT}/Packages/ZPDFUIShell"
scratch_flags=()
if [ -n "${ZENIT_SCRATCH_PATH:-}" ]; then
    scratch_flags=(--scratch-path "${ZENIT_SCRATCH_PATH}")
fi
cd "${SHELL_PACKAGE}" || exit 2
if ! swift build ${scratch_flags[@]+"${scratch_flags[@]}"} --product zpdf-hit-probe; then
    printf 'FAIL: zpdf-hit-probe did not build\n' >&2
    exit 1
fi
bin_dir="$(swift build ${scratch_flags[@]+"${scratch_flags[@]}"} --product zpdf-hit-probe --show-bin-path 2>/dev/null | tail -1)"
probe="${bin_dir}/zpdf-hit-probe"
if [ ! -x "${probe}" ]; then
    probe="$(find "${SHELL_PACKAGE}/${ZENIT_SCRATCH_PATH:-.build}" -type f -name zpdf-hit-probe -perm +111 2>/dev/null | head -1)"
fi
if [ -z "${probe}" ] || [ ! -x "${probe}" ]; then
    printf 'FAIL: no zpdf-hit-probe binary after the build\n' >&2
    exit 2
fi

# The stamp is the whole point: a probe stamped with a newer SDK hit-tests like xctest.
stamp="$(otool -l "${probe}" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{m=$2} f&&/ sdk /{s=$2; print m, s; exit}')"
minos="${stamp%% *}"
sdk="${stamp##* }"
printf 'probe: %s\nprobe stamp: minos %s, sdk %s\n' "${probe}" "${minos:-?}" "${sdk:-?}"
if [ -z "${sdk}" ] || [ "${sdk%%.*}" != "14" ]; then
    printf 'FAIL: the probe is stamped with sdk %s, not the macOS 14 SDK the shipped app carries;\n' "${sdk:-unknown}" >&2
    printf '      it would hit-test the modern way and could not see this class of defect\n' >&2
    exit 1
fi
app_binary="${ROOT}/build/Zenit PDF.app/Contents/MacOS/ZenitPDF"
if [ -f "${app_binary}" ]; then
    app_sdk="$(otool -l "${app_binary}" | awk '/LC_BUILD_VERSION/{f=1} f&&/ sdk /{print $2; exit}')"
    printf 'app stamp: sdk %s (%s)\n' "${app_sdk:-?}" "${app_binary}"
    if [ -n "${app_sdk}" ] && [ "${app_sdk%%.*}" != "${sdk%%.*}" ]; then
        printf 'FAIL: the app (sdk %s) and the probe (sdk %s) are stamped differently; the probe must\n' "${app_sdk}" "${sdk}" >&2
        printf '      hit-test the way the app does\n' >&2
        exit 1
    fi
fi

"${probe}"
probe_rc=$?

printf '\n'
if [ "${scan_rc}" != "0" ] || [ "${probe_rc}" != "0" ]; then
    printf 'verify-hosted-hit-targets: FAIL (scan rc=%s, probe rc=%s)\n' "${scan_rc}" "${probe_rc}"
    exit 1
fi
printf 'verify-hosted-hit-targets: PASS\n'
exit 0
