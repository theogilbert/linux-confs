# Treesitter parsers

This directory contains various TreeSitter parsers from different languages.

## Python

The Python parser was downloaded from the [tree-sitter-python](https://github.com/tree-sitter/tree-sitter-python) repository.

It was compiled with the following command:

```bash
git clone https://github.com/tree-sitter/tree-sitter-python
cd tree-sitter-python
gcc -O2 -o python.so -I./src src/parser.c src/scanner.cc -shared -Os -lstdc++ -fPIC
```
