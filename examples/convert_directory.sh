#!/bin/sh
# Convert all .bru files in a directory.
# Usage: ./convert_directory.sh <directory> [output-directory]

set -e

if [ -z "$1" ]; then
    echo "Usage: $0 <directory> [output-directory]"
    exit 1
fi

INPUT_DIR="$1"
OUTPUT_DIR="$2"

if [ ! -d "$INPUT_DIR" ]; then
    echo "Error: directory not found: $INPUT_DIR"
    exit 1
fi

# Preview first
echo "=== Dry run ==="
if [ -n "$OUTPUT_DIR" ]; then
    bru2oc --dry-run -v -o "$OUTPUT_DIR" "$INPUT_DIR"
else
    bru2oc --dry-run -v "$INPUT_DIR"
fi

echo ""
echo "=== Converting ==="
if [ -n "$OUTPUT_DIR" ]; then
    bru2oc -v -o "$OUTPUT_DIR" "$INPUT_DIR"
else
    bru2oc -v "$INPUT_DIR"
fi
echo "Done."
