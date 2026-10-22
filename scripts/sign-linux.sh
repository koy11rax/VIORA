#!/usr/bin/env bash
set -euo pipefail
if [[ $# != 2 ]]; then
  echo 'Usage: sign-linux.sh /path/to/Viora.tar.gz OWNER_GPG_FINGERPRINT' >&2
  exit 1
fi
artifact="$(realpath -- "$1")"
fingerprint="$2"
[[ -f "$artifact" ]] || { echo 'Artifact is missing' >&2; exit 1; }
[[ "$fingerprint" =~ ^([[:xdigit:]]{40}|[[:xdigit:]]{64})$ ]] || { echo 'Use the full owner key fingerprint' >&2; exit 1; }
command -v gpg >/dev/null
[[ ! -e "$artifact.asc" && ! -e "$artifact.public-key.asc" ]] || { echo 'Signature outputs already exist' >&2; exit 1; }
if [[ -e "$artifact.sha256" ]]; then
  [[ ! -L "$artifact.sha256" ]] || { echo 'Linked checksum file' >&2; exit 1; }
  expected="$(awk 'NR==1 {print $1}' "$artifact.sha256")"
  [[ "$expected" =~ ^[0-9a-f]{64}$ && "$(sha256sum -- "$artifact" | cut -d' ' -f1)" == "$expected" ]] || { echo 'Existing checksum does not match artifact' >&2; exit 1; }
fi
gpg --local-user "$fingerprint" --armor --detach-sign --output "$artifact.asc" "$artifact"
gpg --verify "$artifact.asc" "$artifact"
if [[ ! -e "$artifact.sha256" ]]; then
  (cd -- "$(dirname -- "$artifact")"; sha256sum -- "$(basename -- "$artifact")") > "$artifact.sha256"
fi
gpg --armor --export "$fingerprint" > "$artifact.public-key.asc"
echo 'Detached signature verified. Distribute the public fingerprint through a trusted channel.'
