#!/bin/sh
# Migrate an entire Bruno collection to OpenCollection YAML.
# Creates a backup before converting and preserves directory structure.
# Usage: ./migrate_collection.sh <collection-dir> <output-dir>

set -e

if [ -z "$1" ] || [ -z "$2" ]; then
    echo "Usage: $0 <collection-dir> <output-dir>"
    exit 1
fi

COLLECTION="$1"
OUTPUT="$2"

if [ ! -d "$COLLECTION" ]; then
    echo "Error: collection directory not found: $COLLECTION"
    exit 1
fi

# Create backup
BACKUP="${COLLECTION}.backup.tar.gz"
echo "Creating backup: $BACKUP"
tar czf "$BACKUP" -C "$(dirname "$COLLECTION")" "$(basename "$COLLECTION")"

# Preview
echo ""
echo "=== Dry run ==="
bru2oc --dry-run -r -v -o "$OUTPUT" "$COLLECTION"

# Convert
echo ""
echo "=== Migrating ==="
bru2oc -r -v -o "$OUTPUT" "$COLLECTION"

echo ""
echo "Migration complete."
echo "Backup saved to: $BACKUP"
echo "Output written to: $OUTPUT"
