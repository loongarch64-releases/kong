#!/bin/bash
set -euo pipefail

UPSTREAM_OWNER=Kong
UPSTREAM_REPO=kong

curl -s https://api.github.com/repos/"$UPSTREAM_OWNER"/"$UPSTREAM_REPO"/releases/latest \
     | jq -r ".tag_name"
