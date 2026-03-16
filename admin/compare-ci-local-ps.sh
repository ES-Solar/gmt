#!/usr/bin/env bash
set -euo pipefail

# Compare selected CI-generated PostScript test outputs with local outputs.
#
# Usage:
#   bash admin/compare-ci-local-ps.sh <ci_artifact_dir> <local_build_dir>
#
# Example:
#   bash admin/compare-ci-local-ps.sh \
#     /Users/you/Downloads/SelectedTestOutputs-macOS \
#     /Users/you/GMT/gmt_builds/8910ci-test/build
#
# Notes:
# - <ci_artifact_dir> should be the extracted artifact root that contains build/test/...
# - <local_build_dir> should be the local build directory that contains test/...

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <ci_artifact_dir> <local_build_dir>" >&2
  exit 1
fi

CI_ROOT="$1"
LOCAL_BUILD="$2"

if [[ ! -d "$CI_ROOT" ]]; then
  echo "CI artifact directory not found: $CI_ROOT" >&2
  exit 1
fi
if [[ ! -d "$LOCAL_BUILD" ]]; then
  echo "Local build directory not found: $LOCAL_BUILD" >&2
  exit 1
fi

TESTS=(
  "pscoast/oblsuite_N:oblsuite_N.ps"
  "grdview/texture2_modern:texture2_modern.ps"
)

have_gm=0
if command -v gm >/dev/null 2>&1; then
  have_gm=1
fi

echo "CI root      : $CI_ROOT"
echo "Local build  : $LOCAL_BUILD"
if [[ $have_gm -eq 1 ]]; then
  echo "gm compare   : enabled ($(gm version | head -1))"
else
  echo "gm compare   : not available (skipping RMS comparison)"
fi

echo

for t in "${TESTS[@]}"; do
  dir="${t%%:*}"
  ps="${t##*:}"

  ci_ps="$CI_ROOT/build/test/$dir/$ps"
  local_ps="$LOCAL_BUILD/test/$dir/$ps"

  echo "=== $dir/$ps ==="

  missing=0
  if [[ ! -f "$ci_ps" ]]; then
    echo "CI file missing    : $ci_ps"
    missing=1
  fi
  if [[ ! -f "$local_ps" ]]; then
    echo "Local file missing : $local_ps"
    missing=1
  fi
  if [[ $missing -eq 1 ]]; then
    echo
    continue
  fi

  ci_md5=$(md5 -q "$ci_ps")
  local_md5=$(md5 -q "$local_ps")

  echo "CI md5    : $ci_md5"
  echo "Local md5 : $local_md5"

  if cmp -s "$ci_ps" "$local_ps"; then
    echo "Result    : IDENTICAL"
    echo
    continue
  fi

  echo "Result    : DIFFERENT"

  if [[ $have_gm -eq 1 ]]; then
    # No max-error threshold so we always get metric output.
    gm_out=$(gm compare -density 200 -metric rmse "$local_ps" "$ci_ps" 2>&1 || true)
    total=$(printf '%s\n' "$gm_out" | perl -ne 'print $1 if /Total:\s+([0-9.]+)/')
    if [[ -n "$total" ]]; then
      echo "RMSE Total: $total"
    else
      echo "RMSE Total: N/A"
    fi
  fi

  echo "First diff lines:"
  diff -u "$ci_ps" "$local_ps" | sed -n '1,80p' || true
  echo

done
