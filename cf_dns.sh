#!/usr/bin/env bash

# Do not expose the API token when invoked with bash -x.
set +x
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: cf_dns.sh [--help]

Interactively create or update Cloudflare A and CNAME records.
Requires Bash 4+, curl 7.55+, and jq. Set CF_API_TOKEN in the environment,
or enter it at the hidden prompt. The token needs Zone Read and DNS Edit
permissions for the domain being managed. Tokens are never saved.

Enter a domain (example.com), then a relative record name (www, app.api),
an in-zone full name (www.example.com), or @ for the root. A trailing dot
marks an absolute name, which must belong to the selected zone.
New records default to DNS only and automatic TTL. Updates retain existing
values unless changed. Every write requires confirmation (default: No).
EOF
}

die() {
    local message=$*
    if [[ -n ${CF_API_TOKEN:-} ]]; then
        message=${message//"$CF_API_TOKEN"/[redacted]}
    fi
    printf 'Error: %s\n' "$message" >&2
    exit 1
}

prompt() {
    local label=$1 default=${2:-}
    printf '%s' "$label" >&2
    [[ -z $default ]] || printf ' [%s]' "$default" >&2
    printf ': ' >&2
    IFS= read -r REPLY || die 'Input ended; no further changes were sent.'
    REPLY=${REPLY#"${REPLY%%[![:space:]]*}"}
    REPLY=${REPLY%"${REPLY##*[![:space:]]}"}
    REPLY=${REPLY:-$default}
}

ask_yes_no() {
    local label=$1 default=$2
    while :; do
        prompt "$label (yes/no)" "$default"
        case ${REPLY,,} in
            y|yes) REPLY=true; return ;;
            n|no) REPLY=false; return ;;
            *) printf 'Please enter yes or no.\n' >&2 ;;
        esac
    done
}

valid_hostname() {
    local name=$1 label
    local -a labels
    [[ -n $name && ${#name} -le 253 && $name != *[!a-zA-Z0-9.-]* ]] || return 1
    [[ $name != .* && $name != *. && $name != *..* ]] || return 1
    IFS=. read -r -a labels <<< "$name"
    for label in "${labels[@]}"; do
        [[ ${#label} -le 63 && $label != -* && $label != *- ]] || return 1
    done
}

valid_ipv4() {
    local ip=$1 octet
    local -a octets
    [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    IFS=. read -r -a octets <<< "$ip"
    for octet in "${octets[@]}"; do
        [[ ${#octet} -le 3 && ( $octet == 0 || $octet != 0* ) ]] || return 1
        (( 10#$octet <= 255 )) || return 1
    done
}

# Sets API_RESPONSE. Authentication is passed over stdin, not curl's argv.
api() {
    local method=$1 path=$2 payload=$3 raw status message
    shift 3
    local -a args=(--disable --silent --show-error --connect-timeout 10 --max-time 30
        --request "$method" --header @- --write-out $'\n%{http_code}')
    if [[ $method == GET ]]; then
        args+=(--get "$@")
    else
        args+=(--data-raw "$payload")
    fi
    if ! raw=$(printf 'Authorization: Bearer %s\nContent-Type: application/json\n' "$CF_API_TOKEN" |
        curl "${args[@]}" "https://api.cloudflare.com/client/v4$path" 2>/dev/null); then
        die 'Cloudflare request failed (connection, TLS, or timeout). Check the record before retrying a write.'
    fi
    status=${raw##*$'\n'}
    API_RESPONSE=${raw%$'\n'*}
    if ! jq -e 'type == "object" and (.success | type == "boolean")' >/dev/null 2>&1 <<< "$API_RESPONSE"; then
        die "Cloudflare returned a malformed response (HTTP $status)."
    fi
    if [[ ! $status =~ ^2[0-9][0-9]$ ]] || ! jq -e '.success == true' >/dev/null <<< "$API_RESPONSE"; then
        message=$(jq -r '[.errors[]? | "\(.code // "unknown"): \(.message // "Unknown error")"] | join("; ")' <<< "$API_RESPONSE")
        die "Cloudflare request failed (HTTP $status): ${message:-Unknown API error}"
    fi
}

# Sets COLLECTION and follows pagination, including responses without total_pages.
fetch_collection() {
    local path=$1 page=1 pages count
    shift
    COLLECTION='[]'
    while :; do
        api GET "$path" '' "$@" --data-urlencode "page=$page" --data-urlencode 'per_page=50'
        jq -e '.result | type == "array"' >/dev/null <<< "$API_RESPONSE" || die 'Cloudflare returned an invalid list.'
        COLLECTION=$(jq -cn --argjson old "$COLLECTION" --argjson response "$API_RESPONSE" '$old + $response.result')
        count=$(jq '.result | length' <<< "$API_RESPONSE")
        pages=$(jq '.result_info.total_pages // 0' <<< "$API_RESPONSE")
        [[ $pages =~ ^[0-9]+$ ]] || die 'Cloudflare returned invalid pagination.'
        if (( pages > 0 )); then
            (( page < pages )) || break
        else
            (( count >= 50 )) || break
        fi
        page=$((page + 1))
    done
}

select_item() {
    local items=$1 count=$2
    while :; do
        prompt 'Select a number'
        if [[ $REPLY =~ ^[1-9][0-9]*$ && ${#REPLY} -le 6 ]] && (( REPLY <= count )); then
            SELECTED=$(jq -c --argjson index "$((REPLY - 1))" '.[$index]' <<< "$items")
            return
        fi
        printf 'Choose a number from 1 to %s.\n' "$count" >&2
    done
}

choose_zone() {
    local count
    while :; do
        prompt 'Cloudflare domain (example.com)'
        ZONE_NAME=${REPLY,,}
        ZONE_NAME=${ZONE_NAME%.}
        if valid_hostname "$ZONE_NAME" && [[ $ZONE_NAME == *.* ]]; then break; fi
        printf 'Enter a domain name without a URL or path.\n' >&2
    done
    fetch_collection /zones --data-urlencode "name=$ZONE_NAME"
    COLLECTION=$(jq -c --arg name "$ZONE_NAME" '[.[] | select((.name | ascii_downcase) == $name)]' <<< "$COLLECTION")
    count=$(jq length <<< "$COLLECTION")
    (( count > 0 )) || die "No accessible zone found for $ZONE_NAME. Check the domain and token permissions (Zone Read and DNS Edit)."
    if (( count == 1 )); then
        SELECTED=$(jq -c '.[0]' <<< "$COLLECTION")
    else
        jq -r 'to_entries[] | "\(.key + 1)) \(.value.name) — account: \(.value.account.name // "unknown") — zone: \(.value.id)"' <<< "$COLLECTION"
        select_item "$COLLECTION" "$count"
    fi
    ZONE_ID=$(jq -r '.id' <<< "$SELECTED")
    [[ $ZONE_ID =~ ^[a-fA-F0-9]{32}$ ]] || die 'Cloudflare returned an invalid zone ID.'
    printf 'Selected zone: %s\n' "$ZONE_NAME"
}

choose_record_name() {
    local name bare
    while :; do
        prompt 'Subdomain, full name, or @ for root' '@'
        name=${REPLY,,}
        if [[ $name == @ ]]; then
            RECORD_NAME=$ZONE_NAME
        elif [[ $name == *. ]]; then
            RECORD_NAME=${name%.}
            if [[ $RECORD_NAME != "$ZONE_NAME" && $RECORD_NAME != *."$ZONE_NAME" ]]; then
                printf 'Absolute names must belong to %s.\n' "$ZONE_NAME" >&2
                continue
            fi
        elif [[ $name == "$ZONE_NAME" || $name == *."$ZONE_NAME" ]]; then
            RECORD_NAME=$name
        else
            RECORD_NAME=$name.$ZONE_NAME
        fi
        bare=${RECORD_NAME#\*.}
        if valid_hostname "$bare" && (( ${#RECORD_NAME} <= 253 )); then return; fi
        printf 'Enter a valid DNS name; a wildcard is allowed only as the first label.\n' >&2
    done
}

manage_record() {
    local matches count existing='{}' id='' content proxy ttl payload action saved
    choose_record_name
    while :; do
        prompt 'Record type (A or CNAME)' A
        RECORD_TYPE=${REPLY^^}
        [[ $RECORD_TYPE == A || $RECORD_TYPE == CNAME ]] && break
        printf 'Supported types are A and CNAME.\n' >&2
    done
    fetch_collection "/zones/$ZONE_ID/dns_records" --data-urlencode "name=$RECORD_NAME"
    COLLECTION=$(jq -c --arg name "$RECORD_NAME" '[.[] | select((.name | ascii_downcase) == $name)]' <<< "$COLLECTION")
    if jq -e --arg type "$RECORD_TYPE" 'any(.[]; .type == "NS" or ($type == "A" and .type == "CNAME") or ($type == "CNAME" and .type != "CNAME"))' >/dev/null <<< "$COLLECTION"; then
        printf 'Conflicting records exist for %s:\n' "$RECORD_NAME" >&2
        jq -r '.[] | "  \(.type) \(.content)"' <<< "$COLLECTION" >&2
        die 'Resolve conflicting record types before retrying. No records were deleted or converted.'
    fi
    matches=$(jq -c --arg type "$RECORD_TYPE" '[.[] | select(.type == $type)]' <<< "$COLLECTION")
    count=$(jq length <<< "$matches")
    if (( count > 0 )); then
        printf 'Existing matching records:\n'
        jq -r 'to_entries[] | "\(.key + 1)) \(.value.type) \(.value.name) -> \(.value.content), proxy=\(.value.proxied), TTL=\(.value.ttl), ID=\(.value.id)"' <<< "$matches"
        if (( count == 1 )); then
            existing=$(jq -c '.[0]' <<< "$matches")
        else
            select_item "$matches" "$count"
            existing=$SELECTED
        fi
        id=$(jq -r '.id' <<< "$existing")
        [[ $id =~ ^[a-fA-F0-9]{32}$ ]] || die 'Cloudflare returned an invalid record ID.'
    fi
    while :; do
        if [[ $RECORD_TYPE == A ]]; then
            prompt 'IPv4 address' "$(jq -r '.content // empty' <<< "$existing")"
            content=$REPLY
            valid_ipv4 "$content" && break
            printf 'Enter four IPv4 octets from 0 to 255, without leading zeros.\n' >&2
        else
            prompt 'CNAME target hostname' "$(jq -r '.content // empty' <<< "$existing")"
            content=${REPLY,,}
            content=${content%.}
            if valid_hostname "$content" && ! valid_ipv4 "$content" && [[ ! $content =~ ^[0-9.]+$ && $content != "$RECORD_NAME" ]]; then break; fi
            printf 'Enter a hostname, without a URL, IP address, or reference to itself.\n' >&2
        fi
    done
    proxy=$(jq -r 'if .proxied == true then "yes" else "no" end' <<< "$existing")
    ask_yes_no 'Enable Cloudflare proxy' "$proxy"
    proxy=$REPLY
    ttl=$(jq -r '.ttl // 1' <<< "$existing")
    if [[ $proxy == true ]]; then
        ttl=1
        printf 'Proxied records use automatic TTL.\n'
    else
        while :; do
            prompt 'TTL seconds (1 = automatic; otherwise 60–86400)' "$ttl"
            if [[ $REPLY =~ ^[0-9]{1,5}$ ]] && (( 10#$REPLY == 1 || (10#$REPLY >= 60 && 10#$REPLY <= 86400) || (10#$REPLY == ttl && ttl >= 30 && ttl < 60) )); then
                ttl=$((10#$REPLY))
                break
            fi
            printf 'Use 1 for automatic or 60–86400 seconds.\n' >&2
        done
    fi
    payload=$(jq -cn --arg type "$RECORD_TYPE" --arg name "$RECORD_NAME" --arg content "$content" --argjson proxied "$proxy" --argjson ttl "$ttl" '{type: $type, name: $name, content: $content, proxied: $proxied, ttl: $ttl}')
    action=Create
    [[ -z $id ]] || action=Update
    printf '\n%s: %s %s -> %s (proxy=%s, TTL=%s)\n' "$action" "$RECORD_TYPE" "$RECORD_NAME" "$content" "$proxy" "$ttl"
    [[ -z $id ]] || printf 'Record ID: %s\n' "$id"
    ask_yes_no 'Apply this change' no
    if [[ $REPLY == false ]]; then
        printf 'Cancelled. No changes sent.\n'
        return
    fi
    if [[ -z $id ]]; then
        api POST "/zones/$ZONE_ID/dns_records" "$payload"
    else
        api PATCH "/zones/$ZONE_ID/dns_records/$id" "$payload"
    fi
    jq -e '.result | type == "object" and (.id | type == "string") and (.name | type == "string") and (.type | type == "string") and (.content | type == "string")' >/dev/null <<< "$API_RESPONSE" || die 'Cloudflare returned an invalid saved record. Check the record before retrying.'
    saved=$(jq -r '.result | "\(.type) \(.name) -> \(.content) (proxy=\(.proxied), TTL=\(.ttl), ID=\(.id))"' <<< "$API_RESPONSE")
    printf 'Saved: %s\n' "$saved"
}

main() {
    case ${1:-} in
        -h|--help) usage; return ;;
        '') ;;
        *) usage >&2; exit 1 ;;
    esac
    (( $# == 0 )) || die 'Unexpected arguments. Use --help for usage.'
    (( BASH_VERSINFO[0] >= 4 )) || die 'Bash 4 or newer is required.'
    local dependency
    for dependency in curl jq; do
        command -v "$dependency" >/dev/null 2>&1 || die "Missing dependency: $dependency"
    done
    if [[ -z ${CF_API_TOKEN:-} ]]; then
        printf 'Cloudflare API token (hidden): ' >&2
        IFS= read -rs CF_API_TOKEN || die 'No API token supplied.'
        printf '\n' >&2
    fi
    [[ -n $CF_API_TOKEN && $CF_API_TOKEN != *[$'\r\n']* ]] || die 'The API token must be nonempty and contain no line breaks.'
    trap 'printf "\nCancelled.\n" >&2; exit 130' INT
    choose_zone
    while :; do
        manage_record
        ask_yes_no 'Manage another record in this zone' no
        [[ $REPLY == true ]] || break
    done
}

main "$@"
