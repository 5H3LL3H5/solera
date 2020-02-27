#!/usr/bin/env bats

setup() {
	. "solera.bash"
}

teardown() {
	:
}

@test "is_apt_package_installed(): Call without arguments" {
	run is_apt_package_installed
	[ "$status" -eq 1 ]
}

@test "is_apt_package_installed(): Call with more than one arguments" {
	run is_apt_package_installed "parameter1" "parameter2"
	[ "$status" -eq 1 ]
}

@test "is_apt_package_installed(): Call with invalid package name" {
	run is_apt_package_installed "  "
	[ "$status" -eq 2 ]
}

@test "is_apt_package_installed(): Call with valid and uninstalled package name" {
	run is_apt_package_installed "no_valid_package_name"
	[ "$status" -eq 3 ]
}

@test "is_apt_package_installed(): Call with valid and installed package name" {
	run is_apt_package_installed "bash"
	[ "$status" -eq 0 ]
}

@test "is_npm_package_installed(): Call without arguments" {
	run is_npm_package_installed
	[ "$status" -eq 1 ]
}

@test "is_npm_package_installed(): Call with more than one arguments" {
	run is_npm_package_installed "parameter1" "parameter2"
	[ "$status" -eq 1 ]
}

@test "is_npm_package_installed(): Call with invalid package name" {
	run is_npm_package_installed "  "
	[ "$status" -eq 2 ]
}

@test "is_npm_package_installed(): Call with valid and uninstalled package name" {
	run is_npm_package_installed "pm2"
	[ "$status" -eq 3 ]
}

@test "is_npm_package_installed(): Call with valid and installed package name" {
	run npm install -g pm2
	run is_npm_package_installed "pm2"
	[ "$status" -eq 0 ]
}
