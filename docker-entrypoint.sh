#!/bin/sh
#
# DVWA-with-flags entrypoint.
#
# Drops two HackTheBox-style flags into the container on every start. Each flag
# is "flag{<md5>}" where <md5> is a freshly generated random MD5, so the values
# change every time the container comes up again.
#
#   user flag -> /var/www/user.txt   (readable by www-data: the foothold you
#                                      land on via DVWA's RCE/command injection)
#   root flag -> /root/root.txt      (root-only 0400: requires privilege
#                                      escalation to read)
#
set -e

gen_flag() {
    # 64 bytes of entropy -> md5, wrapped in the flag{...} format.
    printf 'flag{%s}\n' "$(head -c 64 /dev/urandom | md5sum | cut -d' ' -f1)"
}

# --- user flag ---------------------------------------------------------------
gen_flag > /var/www/user.txt
chown www-data:www-data /var/www/user.txt
chmod 0644 /var/www/user.txt

# --- root flag ---------------------------------------------------------------
gen_flag > /root/root.txt
chown root:root /root/root.txt
chmod 0400 /root/root.txt

# --- randomized DVWA user passwords ------------------------------------------
# The stock DVWA accounts ship with well-known passwords (password, abc123, ...)
# whose MD5 hashes are in every rainbow table. Generate a fresh random password
# for each account on every start and export it so dvwa/includes/DBMS/*.php seed
# the users table with MD5(<random>) instead. The values take effect the next
# time the database is (re)created from the DVWA "Setup" page (./run.sh reset).
gen_pw() {
    # 16 bytes of entropy -> 32 hex chars; hex is quote-safe inside the SQL seed.
    head -c 16 /dev/urandom | md5sum | cut -d' ' -f1
}

DVWA_PASS_ADMIN="$(gen_pw)"
DVWA_PASS_GORDONB="$(gen_pw)"
DVWA_PASS_1337="$(gen_pw)"
DVWA_PASS_PABLO="$(gen_pw)"
DVWA_PASS_SMITHY="$(gen_pw)"
export DVWA_PASS_ADMIN DVWA_PASS_GORDONB DVWA_PASS_1337 DVWA_PASS_PABLO DVWA_PASS_SMITHY

# Record the plaintext credentials for the operator (not reachable over HTTP:
# /var/www is above the /var/www/html web root, and the file is root-only).
cred_file=/var/www/dvwa-credentials.txt
{
    printf 'admin:%s\n'   "$DVWA_PASS_ADMIN"
    printf 'gordonb:%s\n' "$DVWA_PASS_GORDONB"
    printf '1337:%s\n'    "$DVWA_PASS_1337"
    printf 'pablo:%s\n'   "$DVWA_PASS_PABLO"
    printf 'smithy:%s\n'  "$DVWA_PASS_SMITHY"
    # Fixed convenience account, always seeded with this well-known password.
    printf 'user:user\n'
} > "$cred_file"
chown root:root "$cred_file"
chmod 0600 "$cred_file"

# --- privilege escalation vector (www-data -> root) --------------------------
# Intended path for the box: from the www-data shell (obtained via DVWA command
# injection / RCE), enumerate SUID binaries and abuse bash:
#
#   find / -perm -4000 -type f 2>/dev/null   # discover the SUID bash
#   /bin/bash -p                             # keep euid=0, spawn a root shell
#   cat /root/root.txt                       # read the root flag
#
chmod u+s /bin/bash

# --- automatic DVWA database setup -------------------------------------------
# DVWA normally needs a human to click "Create / Reset Database" on setup.php
# before the app is usable. Do it automatically so the box is playable the
# moment it is up. We drive setup.php over HTTP (grab the Anti-CSRF token with a
# GET, then POST create_db) rather than touching the DB directly, so the stock
# seeding logic in dvwa/includes/DBMS/MySQL.php stays the single source of truth
# and picks up the per-run randomized passwords exported above.
#
# This runs in the background: Apache is started by the exec below, and the DB
# lives in a separate container that may still be coming up, so we retry until
# setup.php reports success (or give up after ~2 minutes).
auto_setup() {
    set +e   # background helper: keep retrying, never abort on a transient error
    base_url="http://127.0.0.1"
    jar="$(mktemp)"

    i=0
    while [ "$i" -lt 60 ]; do
        i=$((i + 1))
        # GET setup.php -> session cookie + Anti-CSRF token (md5, 32 hex chars).
        token="$(curl -s -c "$jar" "$base_url/setup.php" \
            | sed -n "s/.*user_token' value='\([0-9a-f]\{32\}\).*/\1/p" | head -n1)"
        if [ -n "$token" ]; then
            # POST create_db with the matching cookie + token, following the
            # post-setup redirect so the flashed status messages render.
            if curl -s -L -b "$jar" -c "$jar" \
                    --data "create_db=1" \
                    --data "user_token=$token" \
                    "$base_url/setup.php" \
                    | grep -q "Setup successful"; then
                echo "[entrypoint] DVWA database created/reset automatically (security level: ${DEFAULT_SECURITY_LEVEL:-impossible})."
                rm -f "$jar"
                return 0
            fi
        fi
        sleep 2
    done

    echo "[entrypoint] WARNING: automatic DVWA setup did not complete; open /setup.php and click 'Create / Reset Database'." >&2
    rm -f "$jar"
    return 1
}

auto_setup &

# Hand off to the stock PHP/Apache entrypoint (default CMD: apache2-foreground).
exec docker-php-entrypoint "$@"
