#!/usr/bin/env bash
# Update the vendored copy of Cloudflare's security-audit skill (plugin/skills/security-audit/)
# to the newest commit of cloudflare/security-audit-skill that is at least COOLDOWN_DAYS old
# (default 7, like Dependabot's cooldown). The pinned commit lives in
# .github/security-audit-skill.ref.
#
# Run from anywhere in the repository; it only changes the working tree (the skill directory
# and the ref file). .github/workflows/update-security-audit.yml commits the result and opens
# the pull request. Prints old=<sha> and new=<sha> (also appended to $GITHUB_OUTPUT when set);
# old == new means there is nothing to update.
#
# Exit codes: 0 up to date or updated; 1 the pinned commit is not an ancestor of the candidate
# (upstream history was rewritten: review by hand) or another error.
set -euo pipefail

upstream=https://github.com/cloudflare/security-audit-skill
ref_file=.github/security-audit-skill.ref
dest=plugin/skills/security-audit
cooldown_days=${COOLDOWN_DAYS:-7}

cd "$(git rev-parse --show-toplevel)"

old=$(tr -d '[:space:]' <"$ref_file")
if [[ ! $old =~ ^[0-9a-f]{40}$ ]]; then
  echo "error: $ref_file must hold one full commit sha" >&2
  exit 1
fi
if [[ ! $cooldown_days =~ ^[0-9]+$ ]]; then
  echo "error: COOLDOWN_DAYS must be a whole number of days" >&2
  exit 1
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
src=$tmp/src
git clone --quiet --filter=blob:none "$upstream" "$src"

new=$(git -C "$src" log -1 --format=%H --before="$cooldown_days days ago" HEAD)
if [[ -z $new ]]; then
  echo "error: no upstream commit is $cooldown_days days old yet" >&2
  exit 1
fi

report() {
  echo "old=$old"
  echo "new=$1"
  if [[ -n ${GITHUB_OUTPUT:-} ]]; then
    printf 'old=%s\nnew=%s\n' "$old" "$1" >>"$GITHUB_OUTPUT"
  fi
}

# Nothing newer than the pin has passed the cooldown.
if [[ $new == "$old" ]] || git -C "$src" merge-base --is-ancestor "$new" "$old" 2>/dev/null; then
  echo "security-audit skill is up to date (${old:0:7})"
  report "$old"
  exit 0
fi

if ! git -C "$src" merge-base --is-ancestor "$old" "$new" 2>/dev/null; then
  echo "error: pinned ${old:0:7} is not an ancestor of upstream ${new:0:7}; review by hand" >&2
  exit 1
fi

git -C "$src" checkout --quiet "$new"
rm -rf "$dest"
cp -R "$src/skills/security-audit" "$dest"
cp "$src/LICENSE" "$dest/LICENSE"
printf '%s\n' "$new" >"$ref_file"

echo "security-audit skill updated ${old:0:7} -> ${new:0:7}:"
git -C "$src" log --format='  %h %cs %s' "$old..$new"
report "$new"
