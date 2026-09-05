#!/usr/bin/env bash
# Analyses and tests every package the way the CI does.
#   bash tool/test_all.sh
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"

for pkg in lye_core lye_io lye_server; do
  echo "== $pkg"
  (cd "$root/packages/$pkg" && dart pub get >/dev/null && dart analyze --fatal-infos && dart test)
done

echo "== lye_realm"
(cd "$root/packages/lye_realm" && dart pub get >/dev/null && dart run realm_dart install >/dev/null \
  && dart run realm_dart generate >/dev/null && dart analyze --fatal-infos && dart test)

echo "== lye_flutter"
(cd "$root/packages/lye_flutter" && flutter pub get >/dev/null && dart analyze --fatal-infos && flutter test)

echo "== versions"
(cd "$root" && dart tool/check_versions.dart "${1:-}")
