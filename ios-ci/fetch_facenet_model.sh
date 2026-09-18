#!/bin/bash
set -euo pipefail

MODEL_PATH="TideLibrary/Facenet6.mlmodel"
MODEL_URL="https://github.com/daduz11/ios-facenet-id/raw/0ec634cf7f4f12c2bfa6334a72d5f2ab0a4afde4/XCode/faceID/ml/Facenet6.mlmodel"
EXPECTED_SHA256=""

if [ -f "$MODEL_PATH" ] && [ -s "$MODEL_PATH" ]; then
  echo "FaceNet model already present."
  exit 0
fi

echo "Fetching FaceNet Core ML model..."
curl -fL --retry 4 --retry-delay 2 "$MODEL_URL" -o "$MODEL_PATH"
test -s "$MODEL_PATH"
echo "Fetched $(du -h "$MODEL_PATH" | cut -f1) FaceNet model."
