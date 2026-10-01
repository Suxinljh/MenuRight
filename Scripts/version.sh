#!/bin/bash
#
# Read or change the product version.
#
# `Config/Version.xcconfig` is the single source of truth: every target inherits
# it through the project-level build configuration, so a release touches one
# file instead of the sixteen build-setting lines this used to need.
#
#   Scripts/version.sh                  # print the current version
#   Scripts/version.sh set 1.1 2        # marketing 1.1, build 2
#   Scripts/version.sh bump build       # 1 -> 2 (build only)
#   Scripts/version.sh bump patch       # 1.0 -> 1.0.1, build + 1
#   Scripts/version.sh bump minor       # 1.0 -> 1.1,   build + 1
#   Scripts/version.sh bump major       # 1.0 -> 2.0,   build + 1
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FILE="$ROOT/Config/Version.xcconfig"

[ -f "$FILE" ] || { echo "missing $FILE" >&2; exit 1; }

read_value() {
  sed -n "s/^$1 *= *//p" "$FILE" | head -1
}

write_values() {
  local marketing="$1" build="$2"
  sed -i '' \
    -e "s/^MARKETING_VERSION = .*/MARKETING_VERSION = $marketing/" \
    -e "s/^CURRENT_PROJECT_VERSION = .*/CURRENT_PROJECT_VERSION = $build/" \
    "$FILE"
}

is_marketing_version() {
  [[ "$1" =~ ^[0-9]+(\.[0-9]+)*$ ]]
}

is_build_number() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

bump_component() {
  # bump_component <version> <index:0|1|2> — raises that component, drops the rest
  local version="$1" index="$2"
  local -a parts
  IFS='.' read -r -a parts <<<"$version"
  while [ "${#parts[@]}" -le "$index" ]; do parts+=(0); done
  parts[$index]=$((parts[index] + 1))
  local result="${parts[0]}"
  for ((i = 1; i <= index; i++)); do result="$result.${parts[i]}"; done
  echo "$result"
}

marketing="$(read_value MARKETING_VERSION)"
build="$(read_value CURRENT_PROJECT_VERSION)"
is_marketing_version "$marketing" || { echo "malformed MARKETING_VERSION in $FILE: $marketing" >&2; exit 1; }
is_build_number "$build" || { echo "malformed CURRENT_PROJECT_VERSION in $FILE: $build" >&2; exit 1; }

case "${1:-}" in
  "")
    echo "$marketing ($build)"
    ;;

  set)
    [ $# -ge 2 ] || { echo "usage: version.sh set <marketing> [build]" >&2; exit 2; }
    is_marketing_version "$2" || { echo "not a marketing version: $2" >&2; exit 2; }
    new_marketing="$2"
    new_build="${3:-$build}"
    is_build_number "$new_build" || { echo "not a build number: $new_build" >&2; exit 2; }
    write_values "$new_marketing" "$new_build"
    echo "version: $marketing ($build) -> $new_marketing ($new_build)"
    ;;

  bump)
    case "${2:-}" in
      build)
        new_marketing="$marketing"
        new_build=$((build + 1))
        ;;
      patch|minor|major)
        case "$2" in
          patch) index=2 ;;
          minor) index=1 ;;
          major) index=0 ;;
        esac
        new_marketing="$(bump_component "$marketing" "$index")"
        new_build=$((build + 1))
        ;;
      *)
        echo "usage: version.sh bump <build|patch|minor|major>" >&2
        exit 2
        ;;
    esac
    write_values "$new_marketing" "$new_build"
    echo "version: $marketing ($build) -> $new_marketing ($new_build)"
    ;;

  *)
    echo "usage: version.sh [set <marketing> [build] | bump <build|patch|minor|major>]" >&2
    exit 2
    ;;
esac
