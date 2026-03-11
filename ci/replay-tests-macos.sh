#!/usr/bin/env bash
# Replay the GitHub macOS test workflow locally using an out-of-source build.

set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CURRENT_BRANCH=$(cd "$REPO_DIR" && git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "tests-macos")
CURRENT_BRANCH_SAFE=$(printf '%s' "$CURRENT_BRANCH" | sed 's#[^A-Za-z0-9._-]#_#g')
WORK_ROOT=${GMT_WORK_ROOT:-"$(cd "$REPO_DIR/.." && pwd)/gmt_builds"}
BUILD_NAME=${GMT_BUILD_NAME:-"$CURRENT_BRANCH_SAFE"}
JOB_ROOT="$WORK_ROOT/$BUILD_NAME"
BUILD_DIR="$JOB_ROOT/build"
INSTALLDIR="$JOB_ROOT/install"
COASTLINEDIR="$JOB_ROOT/coastline"
LOG_DIR="$JOB_ROOT/logs"
CTEST_LOG="$LOG_DIR/ctest.log"
CONFIGURE_LOG="$LOG_DIR/configure.log"
BUILD_LOG="$LOG_DIR/build.log"
INSTALL_LOG="$LOG_DIR/install.log"
SIMPLE_LOG="$LOG_DIR/simple-tests.log"
DVC_LOG="$LOG_DIR/dvc.log"

RUN_TESTS=${RUN_TESTS:-true}
BUILD_DOCS=${BUILD_DOCS:-false}
PACKAGE=${PACKAGE:-false}
EXCLUDE_OPTIONAL=${EXCLUDE_OPTIONAL:-false}
GMT_INSTALL_DEPS=${GMT_INSTALL_DEPS:-false}
GMT_DOWNLOAD_COASTLINES=${GMT_DOWNLOAD_COASTLINES:-auto}
GMT_PULL_DVC=${GMT_PULL_DVC:-true}
GMT_RUN_SIMPLE_TESTS=${GMT_RUN_SIMPLE_TESTS:-true}
GMT_RUN_CTEST=${GMT_RUN_CTEST:-true}
GMT_PULL_REMOTE_CACHE=${GMT_PULL_REMOTE_CACHE:-false}
GMT_SKIP_CONFIGURE=${GMT_SKIP_CONFIGURE:-false}
GMT_SKIP_BUILD=${GMT_SKIP_BUILD:-false}
GMT_SKIP_INSTALL=${GMT_SKIP_INSTALL:-false}
GMT_CTEST_ONLY=${GMT_CTEST_ONLY:-false}
GMT_DVC_ONLY=${GMT_DVC_ONLY:-false}
CTEST_ARGS=${CTEST_ARGS:-"--progress --output-on-failure --force-new-ctest-process -j4 --timeout 480"}

if [ "$GMT_CTEST_ONLY" = "true" ]; then
  GMT_INSTALL_DEPS=false
  GMT_DOWNLOAD_COASTLINES=false
  GMT_PULL_DVC=false
  GMT_RUN_SIMPLE_TESTS=false
  GMT_PULL_REMOTE_CACHE=false
  GMT_SKIP_CONFIGURE=true
  GMT_SKIP_BUILD=true
  GMT_SKIP_INSTALL=true
fi

if [ "$GMT_DVC_ONLY" = "true" ]; then
  GMT_INSTALL_DEPS=false
  GMT_DOWNLOAD_COASTLINES=false
  GMT_PULL_DVC=true
  GMT_RUN_SIMPLE_TESTS=false
  GMT_RUN_CTEST=false
  GMT_PULL_REMOTE_CACHE=false
  GMT_SKIP_CONFIGURE=true
  GMT_SKIP_BUILD=true
  GMT_SKIP_INSTALL=true
fi

export RUNNER_OS=macOS
export INSTALLDIR
export COASTLINEDIR
export RUN_TESTS
export BUILD_DOCS
export PACKAGE
export EXCLUDE_OPTIONAL
export GMT_END_SHOW=off

mkdir -p "$BUILD_DIR" "$INSTALLDIR" "$COASTLINEDIR" "$LOG_DIR"

prepend_path() {
  if [ -d "$1" ]; then
    export PATH="$1:$PATH"
  fi
}

prepend_path "/opt/homebrew/bin"
prepend_path "/opt/homebrew/sbin"
prepend_path "/usr/local/bin"

if [ -x "/Users/solarsmith/micromamba/envs/gmt-ci-tools/bin/gs" ]; then
  prepend_path "/Users/solarsmith/micromamba/envs/gmt-ci-tools/bin"
fi

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

if [ "$GMT_INSTALL_DEPS" = "true" ]; then
  require_command conda
  (
    cd "$REPO_DIR"
    bash ci/install-dependencies-macos.sh
  )
fi

for command in cmake ninja; do
  require_command "$command"
done

if [ "$GMT_PULL_DVC" = "true" ]; then
  require_command dvc
fi

if [ "$GMT_PULL_REMOTE_CACHE" = "true" ]; then
  require_command gh
fi

if [ "$GMT_DOWNLOAD_COASTLINES" = "true" ] || { [ "$GMT_DOWNLOAD_COASTLINES" = "auto" ] && [ ! -d "$COASTLINEDIR/gshhg" ]; }; then
  (
    cd "$REPO_DIR"
    bash ci/download-coastlines.sh
  )
fi

if [ "$GMT_SKIP_CONFIGURE" != "true" ]; then
  (
    cd "$REPO_DIR"
    bash ci/config-gmt-unix.sh
  )
fi

if [ "$GMT_SKIP_CONFIGURE" != "true" ]; then
  (
    cd "$BUILD_DIR"
    cmake -G Ninja "$REPO_DIR" 2>&1 | tee "$CONFIGURE_LOG"
  )
fi

if [ "$GMT_SKIP_BUILD" != "true" ]; then
  (
    cd "$BUILD_DIR"
    cmake --build . 2>&1 | tee "$BUILD_LOG"
  )
fi

if [ "$GMT_PULL_DVC" = "true" ]; then
  : > "$DVC_LOG"
  (
    cd "$REPO_DIR"
    if [ -n "${DAGSHUB_TOKEN:-}" ]; then
      dvc remote modify origin url "https://${DAGSHUB_TOKEN}@dagshub.com/GenericMappingTools/gmt.dvc" --local
    fi
    dvc pull --no-run-cache
    echo "=== Listing DVC-tracked files ==="
    dvc list . --dvc-only || true
    echo "=== Check for missing files ==="
    dvc status -c || true
    echo "=== Show local cache status ==="
    dvc status || true
    echo "=== Verify key baseline/example/script paths ==="
    ls -ld test/baseline doc/examples/images doc/scripts/images || true
    echo "=== Count pulled images ==="
    find test/baseline -type f | wc -l || true
    find doc/examples/images -type f | wc -l || true
    find doc/scripts/images -type f | wc -l || true
  ) 2>&1 | tee "$DVC_LOG"
fi

if [ "$GMT_SKIP_INSTALL" != "true" ]; then
  (
    cd "$BUILD_DIR"
    cmake --build . --target install 2>&1 | tee "$INSTALL_LOG"
  )
fi

if [ -d "$INSTALLDIR/bin" ]; then
  export PATH="$INSTALLDIR/bin:$PATH"
fi

if [ "$GMT_PULL_REMOTE_CACHE" = "true" ]; then
  mkdir -p "$HOME/.gmt/static"
  gh run download -n gmt-cache -D "$HOME/.gmt/static/"
fi

if [ "$GMT_RUN_SIMPLE_TESTS" = "true" ]; then
  (
    cd "$REPO_DIR"
    bash ci/simple-gmt-tests.sh
  ) 2>&1 | tee "$SIMPLE_LOG"
fi

if [ "$GMT_RUN_CTEST" = "true" ]; then
  if [ ! -f "$BUILD_DIR/CTestTestfile.cmake" ]; then
    echo "Cannot run ctest: expected build tree at $BUILD_DIR" >&2
    exit 1
  fi
  (
    cd "$BUILD_DIR"
    ctest ${CTEST_ARGS} || ctest ${CTEST_ARGS} --rerun-failed || ctest ${CTEST_ARGS} --rerun-failed
  ) 2>&1 | tee "$CTEST_LOG"
fi

echo ""
echo "Local macOS CI replay complete"
echo "  branch    : $CURRENT_BRANCH"
echo "  build dir : $BUILD_DIR"
echo "  install dir: $INSTALLDIR"
echo "  logs      : $LOG_DIR"
echo "  ctest log : $CTEST_LOG"
echo "  dvc log   : $DVC_LOG"
