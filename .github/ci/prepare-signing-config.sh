#!/usr/bin/env bash

set -euo pipefail

: "${SIGNING_REPOSITORY_DIR:?SIGNING_REPOSITORY_DIR is required}"
: "${SIGNING_APP_DIR:?SIGNING_APP_DIR is required}"
: "${SIGNING_OUTPUT_DIR:?SIGNING_OUTPUT_DIR is required}"

SIGNING_SOURCE_CONFIG_NAME="${SIGNING_SOURCE_CONFIG_NAME:-signingConfigs.json}"
source_config="$SIGNING_REPOSITORY_DIR/$SIGNING_APP_DIR/$SIGNING_SOURCE_CONFIG_NAME"
output_config="$SIGNING_OUTPUT_DIR/signingConfigs.json"

if [[ ! -s "$source_config" ]]; then
  echo "Missing signing configuration: $source_config" >&2
  exit 1
fi
mkdir -p "$SIGNING_OUTPUT_DIR"

jq \
  --arg repositoryRoot "$SIGNING_REPOSITORY_DIR" \
  --arg profileRoot "$SIGNING_REPOSITORY_DIR/$SIGNING_APP_DIR" \
  'map(
    .material.storeFile = ($repositoryRoot + "/" + (.material.storeFile | split("/") | last)) |
    .material.certpath = ($repositoryRoot + "/" + (.material.certpath | split("/") | last)) |
    .material.profile = ($profileRoot + "/" + (.material.profile | split("/") | last))
  )' \
  "$source_config" > "$output_config"
chmod 600 "$output_config"

jq -e '
  type == "array" and
  length > 0 and
  any(.[]; .name == "publish")
' "$output_config" >/dev/null

while IFS= read -r material_file; do
  if [[ ! -s "$material_file" ]]; then
    echo "Missing signing material: $material_file" >&2
    exit 1
  fi
done < <(
  jq -r '.[] | .material.storeFile, .material.certpath, .material.profile' \
    "$output_config"
)

while IFS= read -r store_file; do
  material_dir="$(dirname "$store_file")/material"
  for material_component in fd ac ce; do
    if [[ ! -d "$material_dir/$material_component" ]]; then
      echo "Missing encrypted-password material: $material_dir/$material_component" >&2
      exit 1
    fi
  done
done < <(jq -r '.[].material.storeFile' "$output_config")

echo "Prepared publish signing configuration from $SIGNING_SOURCE_CONFIG_NAME."
