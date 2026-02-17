#!/bin/sh
# Convert a single .bru file to OpenCollection YAML.
# Usage: ./convert_single.sh <file.bru>

set -e

if [ -z "$1" ]; then
    echo "Usage: $0 <file.bru>"
    exit 1
fi

INPUT="$1"

if [ ! -f "$INPUT" ]; then
    echo "Error: file not found: $INPUT"
    exit 1
fi

# Preview with dry-run first
echo "=== Dry run ==="
bru2oc --dry-run -v "$INPUT"

echo ""
echo "=== Converting ==="
bru2oc -v "$INPUT"
echo "Done."
