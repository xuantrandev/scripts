# Scripts

## Cloudflare DNS

`cf_dns.sh` interactively creates or updates **A** and **CNAME** records.
Requires **Bash 4+**, **curl 7.55+**, and **jq**.

Create a Cloudflare API token with **Zone → Zone → Read** and
**Zone → DNS → Edit**, scoped to the domain you want to manage.

```bash
./cf_dns.sh
```

Enter the token at the hidden prompt, or provide it through the
`CF_API_TOKEN` environment variable. The script never saves the token.

Enter your domain (`example.com`), a subdomain (`www`, `app.api`), and the
record type. Use `@` for the root, or an in-zone full name such as
`www.example.com`. A trailing dot marks an absolute name; absolute names
outside the selected zone are rejected. Wildcards such as `*.app` are supported.
For A records, enter an IPv4 address; for CNAME, enter a target hostname.

The script finds existing records and asks which to update if several match.
Press Enter to retain existing content, proxy status, or TTL. New records
default to DNS only and automatic TTL (`1`); custom TTL is 60–86400 seconds.
An existing Enterprise TTL of 30–59 seconds can be retained. Proxied records
always use automatic TTL. Review and confirm each change before it is sent.
Conflicting record types are reported without deleting or converting records.

Use `./cf_dns.sh --help` for usage. On a network error during a write, inspect
the record in Cloudflare before retrying, since the request may have arrived.

Run the offline checks with:

```bash
bash -n cf_dns.sh
bash -n codex_limit_check.sh
python3 -m unittest discover -s tests -v
```

## Codex limit check

`codex_limit_check.sh` watches the Codex 5-hour limit window and kicks it
with one cheap-model request only when the countdown was never scheduled.
Requires **Bash 4+**, **codex CLI** (logged in), **jq**, and **python3**.
Install codex first:

```bash
npm i -g @openai/codex
codex login
./codex_limit_check.sh --help
```

Each run takes two `account/rateLimits/read` snapshots (via
`codex app-server`, the same data `/status` shows) `WAIT` seconds apart. A
kick is sent only in two cases (both polls must broadly agree, so a single
glitchy read never kicks): the 5h window reports usage but **no reset time in
both snapshots** (countdown never scheduled), or a **reset >= 5h away**
(countdown stuck — a live 5h window always resets within 5h, so "resets in
5h 0m" or more means it isn't ticking; seconds of jitter between polls are
tolerated). Anything with a reset
under 5h away never kicks — an unchanged `resetsAt` between polls is normal
(it is the window expiry, not a ticking clock), so even 100% used with
"resets in 29m" just waits for the reset instead of burning more quota:

```bash
codex --ask-for-approval never exec --model gpt-5-mini --sandbox read-only --skip-git-repo-check "ping"
```

(The approval flag goes before `exec`: current CLIs reject it after the
subcommand. If a flag set is rejected, the script falls back to
`codex exec --model ... --sandbox read-only --skip-git-repo-check` and then
to bare `codex exec --model ...`.) Idle 0% with a healthy reset, an
already-passed reset, a transient single-glitch read, and weekly-only
accounts never trigger a kick — but 0% with a >= 5h reset still kicks,
since a live window never shows a full 5h reset. Use `--dry-run` to report
without sending anything.

One-shot cron example (every 5 minutes):

```bash
*/5 * * * * /path/to/codex_limit_check.sh --wait 150 >> ~/.cache/codex_limit_check/cron.log 2>&1

*/5 * * * * /home/ubuntu/solarwebapp/myscripts/codex_limit_check.sh --wait 150 >> ~/.cache/codex_limit_check/cron.log 2>&1
```

Exit codes: `0` ok (or kick sent), `1` runtime/kick failure, `2` usage or
missing-dependency error. State and history go to
`~/.cache/codex_limit_check/` (override with `--state-dir`).
