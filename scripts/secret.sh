#!/usr/bin/env bash
# Usage: secret.sh <bucket> <file> <command...>
#
# Downloads <file> from the same key in <bucket>. When the bucket has none,
# runs the command to create <file> and uploads it, failing instead of
# overwriting if someone else uploaded one in the meantime.
set -euo pipefail

bucket="$1"
file="$2"
shift 2

umask 077
mkdir -p "$(dirname "$file")"

if aws s3api head-object --bucket "$bucket" --key "$file" >/dev/null 2>&1; then
	exec aws s3 cp --quiet "s3://$bucket/$file" "$file"
fi

trap 'rm -f "$file"' ERR
"$@"
aws s3api put-object --bucket "$bucket" --key "$file" --body "$file" --if-none-match '*' >/dev/null
