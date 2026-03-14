#!/usr/bin/env bash
#
# runner.sh — Reads a JSON test-cases file, runs each script in bash,
# and writes a JSON expected-outputs file.
#
# Input:  JSON on stdin  (the cases file)
# Output: JSON on stdout (the expected file)
#
# Each case has: { "name", "script", "files"? }
# Each output:   { "name", "stdout", "stderr", "exit_code" }
#
# Files (if present) are written to the filesystem before running the script.
# Each case runs in a clean /tmp/jb_case_$$ directory.
#
set -euo pipefail

INPUT=$(cat)
COUNT=$(echo "$INPUT" | jq '.cases | length')
SUITE=$(echo "$INPUT" | jq -r '.suite')

# Start JSON output
echo '{"suite": "'"$SUITE"'", "results": ['

for (( i=0; i<COUNT; i++ )); do
  NAME=$(echo "$INPUT" | jq -r ".cases[$i].name")
  SCRIPT=$(echo "$INPUT" | jq -r ".cases[$i].script")
  CONTENT_HASH=$(echo "$INPUT" | jq -r ".cases[$i].content_hash")
  FILES=$(echo "$INPUT" | jq -r ".cases[$i].files // empty")

  # Create isolated working directory
  WORKDIR="/tmp/jb_case_$$_$i"
  mkdir -p "$WORKDIR"

  # Write any files specified in the case
  if [ -n "$FILES" ] && [ "$FILES" != "null" ]; then
    echo "$FILES" | jq -r 'to_entries[] | @base64' | while read entry; do
      FPATH=$(echo "$entry" | base64 -d | jq -r '.key')
      FCONTENTS=$(echo "$entry" | base64 -d | jq -r '.value')
      mkdir -p "$(dirname "$FPATH")"
      printf '%s' "$FCONTENTS" > "$FPATH"
    done
  fi

  # Run the script, capturing stdout, stderr, and exit code separately
  STDOUT_FILE="$WORKDIR/stdout"
  STDERR_FILE="$WORKDIR/stderr"

  set +e
  bash -c "$SCRIPT" >"$STDOUT_FILE" 2>"$STDERR_FILE"
  EXIT_CODE=$?
  set -e

  # Use jq --rawfile to read file contents and properly JSON-encode them
  # (handles newlines, tabs, special characters automatically)
  if [ $i -gt 0 ]; then echo ","; fi
  jq -n \
    --arg name "$NAME" \
    --arg content_hash "$CONTENT_HASH" \
    --rawfile stdout "$STDOUT_FILE" \
    --rawfile stderr "$STDERR_FILE" \
    --argjson exit_code "$EXIT_CODE" \
    '{name: $name, content_hash: $content_hash, stdout: $stdout, stderr: $stderr, exit_code: $exit_code}'

  # Cleanup
  rm -rf "$WORKDIR"
done

echo ']}'
