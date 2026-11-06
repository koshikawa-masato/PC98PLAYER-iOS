#!/bin/sh
set -eu
models=${1:?compiled model directory required}
bundle="${TARGET_BUILD_DIR:?}/${CONTENTS_FOLDER_PATH:?}"
for name in AdultContent HarmContent; do
  ditto "$models/$name.mlmodelc" "$bundle/$name.mlmodelc"
done
