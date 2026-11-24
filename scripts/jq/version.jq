# SPDX-FileCopyrightText: © 2026 OpenCHAMI a Series of LF Projects, LLC
# SPDX-License-Identifier: MIT

# Versions: major.minor.patch strings.

# "1.2.3" -> [1, 2, 3]
def parse_semver: split(".") | map(tonumber);

# Whether a version is exactly major.minor.patch.
def is_semver: test("^[0-9]+\\.[0-9]+\\.[0-9]+$");

# Whether a version is a prerelease: major.minor.patch, then ~ or -.
def is_prerelease: test("^[0-9]+\\.[0-9]+\\.[0-9]+[~-]");
