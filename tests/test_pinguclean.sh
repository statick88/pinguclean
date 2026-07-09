#!/usr/bin/env bash
#
# test_pinguclean.sh — Test suite for pinguclean.sh
# Run: sudo bash tests/test_pinguclean.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
SUT="$PROJECT_DIR/pinguclean.sh"

PASS=0
FAIL=0
TOTAL=0

# ── Helpers ────────────────────────────────────────────────────────────
color_green() { printf '\033[0;32m%s\033[0m' "$*"; }
color_red()   { printf '\033[0;31m%s\033[0m' "$*"; }
color_bold()  { printf '\033[1m%s\033[0m' "$*"; }

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    TOTAL=$((TOTAL + 1))
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS + 1))
        printf "  %s %s\n" "$(color_green '✓')" "$desc"
    else
        FAIL=$((FAIL + 1))
        printf "  %s %s\n" "$(color_red '✗')" "$desc"
        printf "    Expected: %s\n" "$expected"
        printf "    Actual:   %s\n" "$actual"
    fi
}

assert_contains() {
    local desc="$1" haystack="$2" needle="$3"
    TOTAL=$((TOTAL + 1))
    if echo "$haystack" | grep -qF "$needle"; then
        PASS=$((PASS + 1))
        printf "  %s %s\n" "$(color_green '✓')" "$desc"
    else
        FAIL=$((FAIL + 1))
        printf "  %s %s\n" "$(color_red '✗')" "$desc"
        printf "    Expected to contain: %s\n" "$needle"
    fi
}

assert_not_contains() {
    local desc="$1" haystack="$2" needle="$3"
    TOTAL=$((TOTAL + 1))
    if echo "$haystack" | grep -qF "$needle"; then
        FAIL=$((FAIL + 1))
        printf "  %s %s\n" "$(color_red '✗')" "$desc"
        printf "    Expected NOT to contain: %s\n" "$needle"
    else
        PASS=$((PASS + 1))
        printf "  %s %s\n" "$(color_green '✓')" "$desc"
    fi
}

assert_file_exists() {
    local desc="$1" file="$2"
    TOTAL=$((TOTAL + 1))
    if [ -f "$file" ]; then
        PASS=$((PASS + 1))
        printf "  %s %s\n" "$(color_green '✓')" "$desc"
    else
        FAIL=$((FAIL + 1))
        printf "  %s %s\n" "$(color_red '✗')" "$desc"
        printf "    File not found: %s\n" "$file"
    fi
}

assert_exit_code() {
    local desc="$1" expected="$2" actual="$3"
    TOTAL=$((TOTAL + 1))
    if [ "$expected" -eq "$actual" ]; then
        PASS=$((PASS + 1))
        printf "  %s %s\n" "$(color_green '✓')" "$desc"
    else
        FAIL=$((FAIL + 1))
        printf "  %s %s\n" "$(color_red '✗')" "$desc"
        printf "    Expected exit code: %s, Got: %s\n" "$expected" "$actual"
    fi
}

# ── Test Groups ────────────────────────────────────────────────────────

echo ""
echo "$(color_bold '═══ pinguclean.sh Test Suite ═══')"
echo ""

# ── 1. Static Analysis ────────────────────────────────────────────────
echo "$(color_bold '1. Static Analysis')"

# Check script exists and is executable-ready
assert_file_exists "Script file exists" "$SUT"

# Check shebang
HEAD=$(head -1 "$SUT")
assert_contains "Has bash shebang" "$HEAD" "#!/usr/bin/env bash"

# Check set -uo pipefail
HAS_PIPEFAIL=$(grep -c 'set -uo pipefail' "$SUT" || true)
assert_eq "Uses set -uo pipefail" "1" "$HAS_PIPEFAIL"

# Check no eval usage (should use bash -c instead)
HAS_EVAL=$(grep -c '^eval ' "$SUT" || true)
assert_eq "No eval in runq" "0" "$HAS_EVAL"

# Check shellcheck passes (if available)
if command -v shellcheck >/dev/null 2>&1; then
    SC_OUTPUT=$(shellcheck -x "$SUT" 2>&1 || true)
    SC_ERRORS=$(echo "$SC_OUTPUT" | grep -c '^In ' || true)
    assert_eq "Shellcheck: zero errors" "0" "$SC_ERRORS"
else
    printf "  %s Shellcheck not available — skipped\n" "$(color_bold '○')"
fi

echo ""

# ── 2. Critical Bug Fixes ─────────────────────────────────────────────
echo "$(color_bold '2. Critical Bug Fixes')"

# Fix: $SUDO_USER guard
HAS_SUDO_GUARD=$(grep -c 'SUDO_USER="${SUDO_USER:-root}"' "$SUT" || true)
assert_eq "Has SUDO_USER guard for set -u" "1" "$HAS_SUDO_GUARD"

# Fix: No rm -rf /tmp/.*
HAS_RM_TMP_DOT=$(grep -c 'rm -rf /tmp/\*' "$SUT" || true)
assert_eq "No 'rm -rf /tmp/*' (dangerous)" "0" "$HAS_RM_TMP_DOT"

# Fix: No .bashrc modification
HAS_SED_BASHRC=$(grep -c "sed -i.*bashrc" "$SUT" || true)
assert_eq "No sed on .bashrc" "0" "$HAS_SED_BASHRC"

# Fix: Uses $REAL_HOME not ~ for user paths
TILDE_USER_CACHE=$(grep -c "~/.npm/_cacache" "$SUT" || true)
TILDE_APPIMAGE=$(grep -c "~/.cache/appimagekit" "$SUT" || true)
TILDE_ICON=$(grep -c "~/.cache/icon-cache" "$SUT" || true)
assert_eq "No tilde in .npm path" "0" "$TILDE_USER_CACHE"
assert_eq "No tilde in appimagekit path" "0" "$TILDE_APPIMAGE"
assert_eq "No tilde in icon-cache path" "0" "$TILDE_ICON"

echo ""

# ── 3. Warning Fixes ──────────────────────────────────────────────────
echo "$(color_bold '3. Warning Fixes')"

# Fix: DOCKER_PRUNE_DAYS uses 'd' not 'h'
DOCKER_FILTER=$(grep -o "until=.*'" "$SUT" | head -1 || true)
assert_contains "Docker prune uses days (d)" "$DOCKER_FILTER" "d'"

# Fix: No system.journal deletion in non-aggressive
# Count occurrences — should only appear in the aggressive branch
JOURNAL_DELETE_COUNT=$(grep -c "system.journal" "$SUT" || true)
TOTAL=$((TOTAL + 1))
if [ "$JOURNAL_DELETE_COUNT" -le 2 ]; then
    PASS=$((PASS + 1))
    printf "  %s %s\n" "$(color_green '✓')" "system.journal deletion only in aggressive ($JOURNAL_DELETE_COUNT refs)"
else
    FAIL=$((FAIL + 1))
    printf "  %s %s\n" "$(color_red '✗')" "system.journal deletion outside aggressive ($JOURNAL_DELETE_COUNT refs)"
fi

# Fix: xargs -r for deborphan
HAS_XARGS_R=$(grep -c "xargs -r" "$SUT" || true)
assert_eq "Uses xargs -r for deborphan" "1" "$HAS_XARGS_R"

# Fix: docker rm $(docker ps -aq) removed
HAS_DOCKER_RM_ALL=$(grep -c 'docker rm.*docker ps -aq' "$SUT" || true)
assert_eq "No 'docker rm \$(docker ps -aq)'" "0" "$HAS_DOCKER_RM_ALL"

# Fix: swapoff guarded by memory check
HAS_MEM_CHECK=$(grep -c "MemAvailable" "$SUT" || true)
assert_eq "swapoff guarded by MemAvailable check" "1" "$HAS_MEM_CHECK"

# Fix: pip3 cache dir quoted
HAS_PIP_QUOTE=$(grep -c "pip3_cache=" "$SUT" || true)
assert_eq "pip3 cache dir captured in variable" "1" "$HAS_PIP_QUOTE"

# Fix: mapfile for REAL_USERS
HAS_MAPFILE=$(grep -c "mapfile" "$SUT" || true)
assert_eq "Uses mapfile for REAL_USERS" "1" "$HAS_MAPFILE"

# Fix: resolvectl fallback
HAS_RESOLVECTL=$(grep -c "resolvectl" "$SUT" || true)
TOTAL=$((TOTAL + 1))
if [ "$HAS_RESOLVECTL" -ge 1 ]; then
    PASS=$((PASS + 1))
    printf "  %s %s\n" "$(color_green '✓')" "Uses resolvectl with fallback"
else
    FAIL=$((FAIL + 1))
    printf "  %s %s\n" "$(color_red '✗')" "Uses resolvectl with fallback"
fi

# Fix: LOG_RETAIN_DAYS separate from JOURNAL
HAS_LOG_RETAIN=$(grep -c "LOG_RETAIN_DAYS" "$SUT" || true)
TOTAL=$((TOTAL + 1))
if [ "$HAS_LOG_RETAIN" -ge 1 ]; then
    PASS=$((PASS + 1))
    printf "  %s %s\n" "$(color_green '✓')" "Has separate LOG_RETAIN_DAYS variable"
else
    FAIL=$((FAIL + 1))
    printf "  %s %s\n" "$(color_red '✗')" "Has separate LOG_RETAIN_DAYS variable"
fi

echo ""

# ── 4. Structural Quality ─────────────────────────────────────────────
echo "$(color_bold '4. Structural Quality')"

# Check modular functions exist
for func in cleanup_apt cleanup_logs cleanup_tmp cleanup_user_caches cleanup_package_managers cleanup_docker cleanup_ram cleanup_optimizations cleanup_aggressive_extras; do
    HAS_FUNC=$(grep -c "^${func}()" "$SUT" || true)
    assert_eq "Has function: $func" "1" "$HAS_FUNC"
done

# Check main() entry point
HAS_MAIN=$(grep -c "^main()" "$SUT" || true)
assert_eq "Has main() entry point" "1" "$HAS_MAIN"

# Check main is called
MAIN_CALL=$(grep -c 'main "\$@"' "$SUT" || true)
assert_eq "main() is called with args" "1" "$MAIN_CALL"

# Check typed logging functions
for log_func in log_info log_warn log_error; do
    HAS_LOG=$(grep -c "^${log_func}()" "$SUT" || true)
    assert_eq "Has logging function: $log_func" "1" "$HAS_LOG"
done

# Check no unused run() function
HAS_RUN_FUNC=$(grep -c "^run()" "$SUT" || true)
assert_eq "No dead run() function" "0" "$HAS_RUN_FUNC"

# Check DRY-RUN prefix in runq
HAS_DRY_PREFIX=$(grep -c '\[DRY-RUN\]' "$SUT" || true)
TOTAL=$((TOTAL + 1))
if [ "$HAS_DRY_PREFIX" -ge 1 ]; then
    PASS=$((PASS + 1))
    printf "  %s %s\n" "$(color_green '✓')" "DRY-RUN prefix in runq"
else
    FAIL=$((FAIL + 1))
    printf "  %s %s\n" "$(color_red '✗')" "DRY-RUN prefix in runq"
fi

echo ""

# ── 5. CLI Argument Handling ──────────────────────────────────────────
echo "$(color_bold '5. CLI Argument Handling')"

# Check --help works
HELP_OUTPUT=$(bash "$SUT" --help 2>&1 || true)
assert_contains "--help shows usage" "$HELP_OUTPUT" "pinguclean.sh"

# Check --dry-run works (requires root, but we can check parsing)
# Just verify the flags are in the case statement
HAS_DEEP_CASE=$(grep -c '\-\-deep' "$SUT" || true)
HAS_AGGRESSIVE_CASE=$(grep -c '\-\-aggressive' "$SUT" || true)
HAS_DRYRUN_CASE=$(grep -c '\-\-dry-run' "$SUT" || true)
TOTAL=$((TOTAL + 3))
if [ "$HAS_DEEP_CASE" -ge 1 ] && [ "$HAS_AGGRESSIVE_CASE" -ge 1 ] && [ "$HAS_DRYRUN_CASE" -ge 1 ]; then
    PASS=$((PASS + 3))
    printf "  %s %s\n" "$(color_green '✓')" "All CLI flags handled (--deep, --aggressive, --dry-run)"
else
    FAIL=$((FAIL + 3))
    printf "  %s %s\n" "$(color_red '✗')" "Missing CLI flag handling"
fi

echo ""

# ── 6. Kali Linux Specific ────────────────────────────────────────────
echo "$(color_bold '6. Kali Linux Specific')"

# Check Kali tool logs are cleaned
for tool in metasploit beef bettercap wireshark aircrack-ng hashcat john; do
    HAS_TOOL=$(grep -c "$tool" "$SUT" || true)
    TOTAL=$((TOTAL + 1))
    if [ "$HAS_TOOL" -ge 1 ]; then
        PASS=$((PASS + 1))
        printf "  %s %s\n" "$(color_green '✓')" "Cleans Kali tool logs: $tool"
    else
        FAIL=$((FAIL + 1))
        printf "  %s %s\n" "$(color_red '✗')" "Missing Kali tool: $tool"
    fi
done

# Check Kali-specific user cache paths
for path in .msf4 .BurpSuite .recon-ng .sqlmap .nmap .wireshark; do
    HAS_PATH=$(grep -c "$path" "$SUT" || true)
    TOTAL=$((TOTAL + 1))
    if [ "$HAS_PATH" -ge 1 ]; then
        PASS=$((PASS + 1))
        printf "  %s %s\n" "$(color_green '✓')" "Cleans Kali user cache: $path"
    else
        FAIL=$((FAIL + 1))
        printf "  %s %s\n" "$(color_red '✗')" "Missing Kali user cache: $path"
    fi
done

echo ""

# ── Summary ────────────────────────────────────────────────────────────
echo "$(color_bold '═══ Test Summary ═══')"
echo ""
printf "  Total:  %d\n" "$TOTAL"
printf "  Passed: %s\n" "$(color_green "$PASS")"
printf "  Failed: %s\n" "$(color_red "$FAIL")"
echo ""

if [ "$FAIL" -eq 0 ]; then
    printf "  %s\n\n" "$(color_green 'ALL TESTS PASSED ✅')"
    exit 0
else
    printf "  %s\n\n" "$(color_red 'SOME TESTS FAILED ✗')"
    exit 1
fi
