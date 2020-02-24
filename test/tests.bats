#!/usr/bin/env bats

setup() {
	. "solera.bash"
}

teardown() {
	:
}

@test "package_installed(): Call without arguments" {
	run package_installed
	[ "$status" -eq 1 ]
}

@test "package_installed(): Call with more than one arguments" {
	run package_installed "parameter1" "parameter2"
	[ "$status" -eq 1 ]
}

@test "package_installed(): Call with invalid package name" {
	run package_installed "  "
	[ "$status" -eq 2 ]
}

@test "package_installed(): Call with valid and uninstalled package name" {
	run package_installed "bash123"
	[ "$status" -eq 3 ]
}

@test "package_installed(): Call with valid and installed package name" {
	run package_installed "bash"
	[ "$status" -eq 0 ]
}
