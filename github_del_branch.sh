
#!/usr/bin/env bash
set -euo pipefail

REMOTE="origin"
BASE_BRANCH="main"
DAYS=365
DRY_RUN=true  # Change to false to delete

CUTOFF=$(($(date +%s) - DAYS * 86400))

git fetch "$REMOTE" --prune

while IFS='|' read -r branch timestamp; do
    branch="${branch#"$REMOTE"/}"

    # Skip protected branches
    case "$branch" in
        HEAD|main|master|develop)
            continue
            ;;
    esac

    # Check last commit age
    if (( timestamp < CUTOFF )); then

        # Only delete branches merged into main
        if ! git merge-base --is-ancestor \
            "refs/remotes/$REMOTE/$branch" \
            "refs/remotes/$REMOTE/$BASE_BRANCH"; then
            continue
        fi

        echo "Old branch: $branch"

        if [[ "$DRY_RUN" == false ]]; then
            git push "$REMOTE" --delete "$branch"
        fi
    fi
done < <(
    git for-each-ref \
        --format='%(refname:short)|%(committerdate:unix)' \
        "refs/remotes/$REMOTE"
)
