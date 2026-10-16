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
python3 -m unittest discover -s tests -v
```
