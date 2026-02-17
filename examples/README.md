# Examples

## Sample Collection

The `collection/` directory contains a sample Bruno collection:

```
collection/
  auth/
    login.bru          # POST login with JWT token extraction
  users/
    list-users.bru     # GET with query params
    create-user.bru    # POST with JSON body, auth, assertions
    get-user.bru       # GET with path params
```

Convert it with:

```sh
bru2oc -r -v -o ./output ./collection
```

## Shell Scripts

| Script | Description |
|---|---|
| `convert_single.sh` | Convert one `.bru` file with dry-run preview |
| `convert_directory.sh` | Batch convert a directory with optional output dir |
| `migrate_collection.sh` | Full migration with backup and recursive conversion |

### Quick start

```sh
chmod +x *.sh

# Single file
./convert_single.sh collection/auth/login.bru

# Directory
./convert_directory.sh collection/users

# Full migration with backup
./migrate_collection.sh ./collection ./yaml-output
```
