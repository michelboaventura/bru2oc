# bru2oc

Convert Bruno API Collection (`.bru`) files to OpenCollection YAML format.

![Tests](https://github.com/michel/bru2oc/actions/workflows/test.yml/badge.svg)
![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)

## Overview

`bru2oc` converts `.bru` files used by the [Bruno](https://www.usebruno.com/) API client into the OpenCollection YAML schema. It handles HTTP requests including headers, query/path params, body (JSON, XML, text, GraphQL), authentication (bearer, basic, OAuth2, AWS v4, digest), scripts, assertions, and variables.

### Features

- Single file and batch directory conversion
- Recursive directory traversal
- Dry-run mode to preview changes
- Custom output directory with preserved folder structure
- Cross-platform: Linux, macOS, Windows (x86_64 and aarch64)
- Zero dependencies beyond the Zig standard library

## Installation

### Download pre-built binaries

Download the latest release for your platform from the [Releases](https://github.com/michel/bru2oc/releases) page.

Available platforms:
- `bru2oc-linux-x86_64` - Linux x86_64
- `bru2oc-linux-aarch64` - Linux ARM64
- `bru2oc-macos-x86_64` - macOS Intel
- `bru2oc-macos-aarch64` - macOS Apple Silicon
- `bru2oc-windows-x86_64.exe` - Windows x86_64
- `bru2oc-windows-aarch64.exe` - Windows ARM64

### Build from source

Requires [Zig](https://ziglang.org/) 0.15.2 or later.

```sh
git clone https://github.com/michel/bru2oc.git
cd bru2oc
zig build -Doptimize=ReleaseSafe
```

The binary will be at `zig-out/bin/bru2oc`.

## Usage

```
Usage: bru2oc [options] <path>

Convert Bruno (.bru) files to OpenCollection (.yml) format.

Arguments:
  <path>              Path to .bru file or directory

Options:
  -r, --recursive     Recursively process directories
  -d, --delete        Delete original .bru files after conversion
  -o, --output <dir>  Output directory (default: in-place)
  --dry-run           Show what would be done without making changes
  -v, --verbose       Show detailed progress
  --keep-comments     Preserve comments in YAML output
  -h, --help          Show this help message
  --version           Show version
```

## Examples

Convert a single file (creates `request.yml` next to it):

```sh
bru2oc request.bru
```

Convert all `.bru` files in a directory:

```sh
bru2oc ./bruno-collection
```

Recursively convert a collection to a separate output directory:

```sh
bru2oc -r -o ./yaml-output ./bruno-collection
```

Preview what would be converted without writing files:

```sh
bru2oc --dry-run -r ./bruno-collection
```

Verbose output with delete originals after conversion:

```sh
bru2oc -rdv ./bruno-collection
```

## Supported Bru blocks

| Block | Description |
|---|---|
| `meta` | Request name, type, sequence |
| `get`, `post`, `put`, `delete`, `patch`, `options`, `head` | HTTP method and URL |
| `headers` | Request headers |
| `params:query`, `params:path` | Query and path parameters |
| `body:json`, `body:xml`, `body:text`, `body:graphql`, `body:sparql`, `body:form-urlencoded`, `body:multipart-form` | Request body |
| `auth:bearer`, `auth:basic`, `auth:oauth2`, `auth:awsv4`, `auth:digest` | Authentication |
| `script:pre-request`, `script:post-response` | Pre/post scripts |
| `assert` | Response assertions |
| `vars:pre-request`, `vars:post-response` | Variables |
| `docs` | Documentation |

## Troubleshooting

**Parse error** - Check that your `.bru` file has valid syntax with all blocks properly closed with `}`.

**File not found** - Verify the input path exists and is spelled correctly.

**Permission denied** - Ensure you have write permissions in the output directory.

## Contributing

```sh
# Build
zig build

# Run tests
zig build test

# Format code
zig fmt src/

# Cross-compile all targets
zig build cross
```

Contributions welcome. Please open an issue first to discuss changes.

## License

MIT License. See [LICENSE](LICENSE) for details.
