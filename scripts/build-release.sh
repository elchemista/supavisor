#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
export MIX_ENV=prod
mix deps.get --only prod
mix compile
mix assets.setup
mix assets.deploy
mix release supavisor --overwrite
printf '\nRelease: %s/_build/prod/rel/supavisor\n' "$PWD"
