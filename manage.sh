#!/usr/bin/env bash
#
# manage.sh - helper for the DVWA-with-flags challenge box.
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

usage() {
    cat <<'EOF'
Usage: ./manage.sh <command>

Commands:
  up            Build (if needed) and start the stack in the background.
  reset         Recreate the running container so the user & root flags are
                regenerated. Keeps the database volume.
                Use --hard to also wipe the database volume.
  clean         Stop and remove containers, the built image, and the volumes.
  flags         Print the current user and root flags from the running box.
  creds         Print the randomized DVWA login credentials for this run.
  status        Show the status of the stack.
  logs          Follow the container logs (Ctrl-C to stop).
  help          Show this help.

Examples:
  ./manage.sh up
  ./manage.sh reset            # new flags, DB preserved
  ./manage.sh reset --hard     # new flags, DB wiped too
  ./manage.sh clean            # remove everything this box created
EOF
}

is_up() {
    [ -n "$("${DC[@]}" ps -q "$SERVICE" 2>/dev/null)" ]
}

cmd_up() {
    "${DC[@]}" up -d --build
    echo
    echo "DVWA is starting on http://127.0.0.1:4280"
    echo "Run './manage.sh flags' once it is up to see the current flags."
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
        echo "error: the stack is not running. Start it with './manage.sh up'." >&2
        exit 1
    fi
    echo "user flag: $("${DC[@]}" exec -T "$SERVICE" cat /var/www/user.txt)"
    echo "root flag: $("${DC[@]}" exec -T -u root "$SERVICE" cat /root/root.txt)"
}

cmd_creds() {
    if ! is_up; then
        echo "error: the stack is not running. Start it with './manage.sh up'." >&2
        exit 1
    fi
    echo "DVWA login credentials for this run (user:password):"
    "${DC[@]}" exec -T -u root "$SERVICE" cat /var/www/dvwa-credentials.txt
    echo
    echo "These apply once the database is created/reset from the DVWA Setup page."
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
    up)      cmd_up ;;
    reset)   cmd_reset "${2:-}" ;;
    clean)   cmd_clean ;;
    flags)   cmd_flags ;;
    creds)   cmd_creds ;;
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
