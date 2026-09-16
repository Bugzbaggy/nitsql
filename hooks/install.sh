#!/usr/bin/env bash
# Install the nitsql pre-commit hook.
#
# Usage:
#   install.sh                     # install locally (current repo only)
#   install.sh --global            # install globally (all repos, one-time)
#   install.sh --force             # overwrite an existing core.hooksPath
#   install.sh --remove            # uninstall locally
#   install.sh --remove --global   # uninstall globally
#
# Local install sets core.hooksPath inside the current repo (.git/config).
# Global install sets it in ~/.gitconfig — one install covers every repo on
# the developer's machine. Since the hook gracefully no-ops when no
# analyzer is found and no SQL is staged, global install is safe for
# non-DB repos.
#
# IMPORTANT — core.hooksPath override:
#   Setting core.hooksPath REPLACES the hook directory for every repo in
#   scope. Any other hook framework in that scope (husky, pre-commit,
#   lefthook, Overcommit, ...) will be silently disabled. If an existing
#   core.hooksPath is already configured, this installer refuses to
#   overwrite it and asks you to re-run with --force.
#
# The hook analyzer auto-detects SQL dialect (MSSQL, PostgreSQL, Oracle,
# MySQL, SQLite) from each file — no configuration needed.

set -euo pipefail

# Parse flags
GLOBAL=0
REMOVE=0
FORCE=0
for arg in "$@"; do
	case "$arg" in
		--global) GLOBAL=1 ;;
		--remove|--uninstall) REMOVE=1 ;;
		--force) FORCE=1 ;;
		-h|--help)
			sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'
			exit 0
			;;
		*)
			echo "Error: unknown argument '$arg'. Use --global, --remove, --force, or --help."
			exit 1
			;;
	esac
done

GIT_CFG_SCOPE="--local"
SCOPE_LABEL="local (this repo)"
if [ $GLOBAL -eq 1 ]; then
	GIT_CFG_SCOPE="--global"
	SCOPE_LABEL="global (~/.gitconfig)"
fi

# Uninstall path
if [ $REMOVE -eq 1 ]; then
	git config $GIT_CFG_SCOPE --unset core.hooksPath 2>/dev/null || true
	echo "nitsql hook removed from $SCOPE_LABEL."
	exit 0
fi

# ---- Install path ----

# Resolve this script's absolute directory (portable on Windows via Git Bash)
SCRIPT_DIR_ABS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Verify the hook file exists next to this script
if [ ! -f "$SCRIPT_DIR_ABS/pre-commit" ]; then
	echo "Error: pre-commit hook not found at $SCRIPT_DIR_ABS/pre-commit"
	exit 1
fi

# Verify Python is available
PYTHON=""
for cmd in python python3 py; do
	if command -v "$cmd" &>/dev/null; then
		PYTHON="$cmd"
		break
	fi
done
if [ -z "$PYTHON" ]; then
	echo "Error: python not found. The nitsql analyzer requires Python 3.8+."
	echo "Ensure python, python3, or py is in your PATH."
	exit 1
fi

# Determine the path to set for core.hooksPath
if [ $GLOBAL -eq 1 ]; then
	# Global install: must use an absolute path since it applies to all repos
	HOOKS_PATH="$SCRIPT_DIR_ABS"
else
	# Local install: must be inside a git repo
	REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
		echo "Error: not inside a git repository. Use --global or run from a repo."
		exit 1
	}
	# Compute the path relative to repo root using git's own path resolution
	# (avoids Windows path format mismatch between Git Bash and native Python).
	SCRIPT_DIR_REL="$(cd "$SCRIPT_DIR_ABS" && git rev-parse --show-prefix 2>/dev/null)"
	SCRIPT_DIR_REL="${SCRIPT_DIR_REL%/}"
	if [ -n "$SCRIPT_DIR_REL" ]; then
		HOOKS_PATH="$SCRIPT_DIR_REL"
	else
		# Script isn't inside this repo — use absolute path
		HOOKS_PATH="$SCRIPT_DIR_ABS"
	fi
fi

# Refuse to silently disable another hook manager.
# If core.hooksPath is already set at the chosen scope and points somewhere
# else, bail out unless --force was passed. This protects users of husky,
# pre-commit, lefthook, Overcommit, etc., whose setups are driven entirely
# by core.hooksPath — overwriting it would silently disable all their hooks.
EXISTING_HOOKS_PATH="$(git config $GIT_CFG_SCOPE --get core.hooksPath 2>/dev/null || true)"
if [ -n "$EXISTING_HOOKS_PATH" ] && [ "$EXISTING_HOOKS_PATH" != "$HOOKS_PATH" ] && [ $FORCE -eq 0 ]; then
	echo "Error: core.hooksPath is already set at $SCOPE_LABEL:"
	echo "    $EXISTING_HOOKS_PATH"
	echo ""
	echo "Overwriting it would disable whichever hook framework put it there"
	echo "(e.g. husky, pre-commit, lefthook, Overcommit). Re-run with --force"
	echo "to replace it, or point that framework at $HOOKS_PATH yourself."
	exit 1
fi

git config $GIT_CFG_SCOPE core.hooksPath "$HOOKS_PATH"

echo "nitsql pre-commit hook installed ($SCOPE_LABEL)."
echo ""
echo "  Hook path:  $HOOKS_PATH/pre-commit"
echo "  Python:     $PYTHON"
echo "  Dialect:    auto-detect (MSSQL / PostgreSQL / Oracle / MySQL / SQLite)"
echo "  Behavior:   CRITICAL → block commit | HIGH/MEDIUM/LOW → warn only"
echo "  Bypass:     git commit --no-verify"
if [ $GLOBAL -eq 1 ]; then
	echo "  Uninstall:  $SCRIPT_DIR_ABS/install.sh --remove --global"
else
	echo "  Uninstall:  $HOOKS_PATH/install.sh --remove"
fi
