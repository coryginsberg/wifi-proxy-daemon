#!/bin/zsh
set -euo pipefail

# Increments the semantic version in VERSION and prints the new value.
# usage: bump-version.sh [major|minor|patch]

PROJECT_DIR="${0:A:h}"
VERSION_FILE="$PROJECT_DIR/VERSION"
PART="${1:-patch}"

if [[ ! -f "$VERSION_FILE" ]]; then
  echo "Missing version file: $VERSION_FILE" >&2
  exit 1
fi

CURRENT="$(<"$VERSION_FILE")"
CURRENT="${CURRENT//[[:space:]]/}"

if [[ ! "$CURRENT" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Invalid semantic version in $VERSION_FILE: $CURRENT" >&2
  exit 1
fi

MAJOR="${CURRENT%%.*}"
REST="${CURRENT#*.}"
MINOR="${REST%%.*}"
PATCH="${REST#*.}"

case "$PART" in
  major) MAJOR=$((MAJOR + 1)); MINOR=0; PATCH=0 ;;
  minor) MINOR=$((MINOR + 1)); PATCH=0 ;;
  patch) PATCH=$((PATCH + 1)) ;;
  *) echo "usage: bump-version.sh [major|minor|patch]" >&2; exit 1 ;;
esac

NEXT="$MAJOR.$MINOR.$PATCH"
printf '%s\n' "$NEXT" > "$VERSION_FILE"
printf '%s\n' "$NEXT"
