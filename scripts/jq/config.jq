# SPDX-FileCopyrightText: © 2026 OpenCHAMI a Series of LF Projects, LLC
# SPDX-License-Identifier: MIT

# config/distributor.yaml (input, as JSON).

# Fills each repo's omitted settings with their defaults from the schema ($schema).
def fill_repo_defaults($schema):
  ($schema.properties.repos.additionalProperties.properties
    | with_entries(select(.value | has("default")) | .value |= .default)) as $d
  | .repos |= map_values($d + .);
