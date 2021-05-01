#!/bin/sh

# This is a wrapper script to run x86 Wine through Box86

# Directory of this script when run
assets_arm_bin=$(dirname "$0")

# Run x86 Wine with Box86
exec "$assets_arm_bin/box86" "$assets_arm_bin/wine-x86"
