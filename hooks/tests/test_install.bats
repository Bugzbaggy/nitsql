#!/usr/bin/env bats
#
# Tests for plugins/sql-valid8/hooks/install.sh
#
# Run with:  bats plugins/sql-valid8/hooks/tests/test_install.bats
#
# Covers:
#   - --help output
#   - unknown-arg rejection
#   - local install writes core.hooksPath
#   - --remove unsets core.hooksPath
#   - refuses to overwrite a pre-existing core.hooksPath
#   - --force overrides that refusal
#   - --global install writes to ~/.gitconfig (redirected via HOME)

setup() {
	# Resolve paths relative to this test file so the suite is portable.
	HOOK_SRC_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
	INSTALL="$HOOK_SRC_DIR/install.sh"

	# Fresh temp git repo per test
	TEST_REPO="$(mktemp -d -t sv8-install-XXXXXX)"
	cd "$TEST_REPO"
	git init -q
	git config user.email "test@example.com"
	git config user.name  "test"
}

teardown() {
	if [ -n "${TEST_REPO:-}" ] && [ -d "$TEST_REPO" ]; then
		rm -rf "$TEST_REPO"
	fi
}

@test "install.sh --help prints usage with all flags" {
	run "$INSTALL" --help
	[ "$status" -eq 0 ]
	[[ "$output" == *"Install the sql-valid8 pre-commit hook."* ]]
	[[ "$output" == *"--global"* ]]
	[[ "$output" == *"--force"* ]]
	[[ "$output" == *"--remove"* ]]
}

@test "install.sh rejects unknown arguments" {
	run "$INSTALL" --nonsense
	[ "$status" -eq 1 ]
	[[ "$output" == *"unknown argument"* ]]
}

@test "install.sh (local) writes core.hooksPath in .git/config" {
	run "$INSTALL"
	[ "$status" -eq 0 ]
	run git config --local --get core.hooksPath
	[ "$status" -eq 0 ]
	[ -n "$output" ]
}

@test "install.sh --remove unsets core.hooksPath locally" {
	"$INSTALL" >/dev/null
	run "$INSTALL" --remove
	[ "$status" -eq 0 ]
	run git config --local --get core.hooksPath
	[ "$status" -ne 0 ]       # `git config --get` exits non-zero when unset
}

@test "install.sh refuses to overwrite an existing core.hooksPath without --force" {
	# Use a relative sentinel — git-bash on Windows normalises absolute
	# POSIX paths by prefixing the MSYS root, which would confuse the
	# post-run equality check.
	git config --local core.hooksPath "sentinel-other-hooks"
	expected="$(git config --local --get core.hooksPath)"
	run "$INSTALL"
	[ "$status" -eq 1 ]
	[[ "$output" == *"already set"* ]]
	[[ "$output" == *"--force"* ]]
	# Existing value must be preserved
	result="$(git config --local --get core.hooksPath)"
	[ "$result" = "$expected" ]
}

@test "install.sh --force overwrites an existing core.hooksPath" {
	git config --local core.hooksPath "sentinel-other-hooks"
	previous="$(git config --local --get core.hooksPath)"
	run "$INSTALL" --force
	[ "$status" -eq 0 ]
	result="$(git config --local --get core.hooksPath)"
	[ "$result" != "$previous" ]
	[ -n "$result" ]
}

@test "install.sh --global writes core.hooksPath to a redirected ~/.gitconfig" {
	# Redirect ~/.gitconfig by giving git a fake HOME.
	FAKE_HOME="$TEST_REPO/fakehome"
	mkdir -p "$FAKE_HOME"

	run env HOME="$FAKE_HOME" "$INSTALL" --global
	[ "$status" -eq 0 ]

	# Verify via the same redirected HOME
	result="$(env HOME="$FAKE_HOME" git config --global --get core.hooksPath)"
	[ -n "$result" ]
}

@test "install.sh --remove --global unsets core.hooksPath in redirected ~/.gitconfig" {
	FAKE_HOME="$TEST_REPO/fakehome"
	mkdir -p "$FAKE_HOME"
	env HOME="$FAKE_HOME" "$INSTALL" --global >/dev/null
	run env HOME="$FAKE_HOME" "$INSTALL" --remove --global
	[ "$status" -eq 0 ]
	run env HOME="$FAKE_HOME" git config --global --get core.hooksPath
	[ "$status" -ne 0 ]
}
