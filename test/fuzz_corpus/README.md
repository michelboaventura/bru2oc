# Fuzz Corpus

This directory stores crash-causing inputs discovered by fuzzing. Each file is a raw input that triggered a bug in the parser or tokenizer.

## Running fuzz tests

```sh
# Run fuzz tests (continuously searches for failures)
zig build test --fuzz

# Regular test run (runs fuzz corpus as regression tests)
zig build test
```

## Adding crash inputs

When the fuzzer discovers a crash, save the input as a file in this directory with a descriptive name (e.g., `unclosed-block-001.bru`). These inputs are automatically included as regression tests.
