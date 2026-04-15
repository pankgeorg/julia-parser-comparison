# julia-parser-comparison

Compares [tree-sitter-julia](https://github.com/tree-sitter/tree-sitter-julia) against [JuliaSyntax.jl](https://github.com/JuliaLang/JuliaSyntax.jl) (Julia's built-in parser) across real-world packages.

## Motivation

We're building [topiary-julia](https://github.com/pankgeorg/topiary-julia), a Julia code formatter based on tree-sitter-julia. To understand where the tree-sitter grammar has gaps, we parse a large corpus with both parsers and compare.

## Results

### General corpus (100 packages, 1938 files)

**tree-sitter success rate: 95.4%** (1848/1938 files parse without ERROR/MISSING nodes)

90 files have tree-sitter errors where JuliaSyntax parses cleanly. 0 files have JuliaSyntax-only errors.

### Focused corpus (Turing + JuMP + SciML, 1379 files)

**tree-sitter success rate: 98.3%** (1356/1379)

| Package | Total | TS-fail | TS-clean% |
|---------|-------|---------|-----------|
| ModelingToolkit | 577 | 11 | 98.1% |
| ModelingToolkitBase | 426 | 6 | 98.6% |
| ModelingToolkitStandardLibrary | 81 | 1 | 98.8% |
| JuMP | 157 | 2 | 98.7% |
| Turing | 54 | 1 | 98.1% |
| DynamicPPL | 84 | 2 | 97.6% |

### Root causes

| Priority | Issue | Impact | Status |
|----------|-------|--------|--------|
| P0 | `~` parsed as assignment instead of binary op | ~500 MTK/Turing files | **Fixed** |
| P0 | `.~` broadcast tilde | MTK | **Fixed** |
| P0 | Whitespace-sensitive `~` (BINARY_TILDE scanner) | MTK | **Fixed** |
| P1 | `:keyword` quoted symbols (`:in`, `:for`) | ~16 JuMP files | **Fixed** |
| P2 | `primitive`, `abstract`, `mutable` as identifiers | ~33 general files | **Fixed** |
| P2.5 | Operator subscript/superscript suffixes (`+₁`, `→ₜ`) | Symbolics | **Fixed** |
| P3 | Emoji identifiers (BMP So + SMP scanner) | Pluto | **Fixed** (partial) |
| P3 | `import ..@macro` | SciML | **Fixed** |
| — | Semicolons in vectors `[a, b; c]` | JuMP | **Fixed** |

### Structural differences

Both parsers produce trees, but with different node taxonomies:

| Pattern | JuliaSyntax | tree-sitter |
|---------|------------|-------------|
| `x + y` | `call(x, +, y)` | `binary_expression(identifier, operator, identifier)` |
| `f(x)` | `call(f, x)` | `call_expression(identifier, argument_list(identifier))` |
| `f(; y=1)` | `call(f, parameters(=(y,1)))` | `call_expression(argument_list(assignment))` |
| `@foo x` | `macrocall(MacroName, x)` | `macrocall_expression(macro_identifier, macro_argument_list)` |
| `x -> x+1` | `->(tuple(x), call-i(x,+,1))` | `arrow_function_expression(identifier, binary_expression)` |

## Usage

### Prerequisites

- Julia 1.11+ (1.12 recommended)
- `tree-sitter` CLI with [pankgeorg/tree-sitter-julia](https://github.com/pankgeorg/tree-sitter-julia) configured

### Setup

```bash
# Install Julia dependencies
julia --project=. -e 'using Pkg; Pkg.instantiate()'

# Configure tree-sitter to find the grammar
# Add the parent directory of tree-sitter-julia to ~/.config/tree-sitter/config.json parser-directories
```

### Build the corpus

```bash
julia build_corpus.jl
```

Scans `~/.julia/packages/` for ~100 packages and writes file paths to `corpus_files.txt`. The focused corpus (`corpus_focus.txt`) adds Turing, JuMP, and SciML test files.

### Run parsers

```bash
# JuliaSyntax (fast, ~4s for 2000 files)
julia juliasyntax_parse.jl

# tree-sitter (slower, ~60s — one subprocess per file)
julia treesitter_parse.jl
```

Results go to `results/juliasyntax_results.json` and `results/treesitter_results.json`.

### Compare

```bash
julia --project=. compare_results.jl
```

Produces `results/comparison_report.md` and `results/comparison.json`.

### Focused analysis

```bash
# Per-package breakdown for Turing/JuMP/SciML
julia focus_report.jl

# Macro-specific analysis (long macro defs, SciML macros)
julia analyze_macros.jl
```

## File structure

| File | Purpose |
|------|---------|
| `build_corpus.jl` | Select packages and enumerate .jl files |
| `juliasyntax_parse.jl` | Parse corpus with Base.JuliaSyntax, output JSON |
| `treesitter_parse.jl` | Parse corpus with tree-sitter CLI, output JSON |
| `compare_results.jl` | Load both JSON results, produce comparison report |
| `focus_report.jl` | Per-package breakdown on focused corpus |
| `analyze_macros.jl` | Macro definition/call analysis |
| `corpus_files.txt` | Main corpus file list (generated, not committed) |
| `corpus_focus.txt` | Focused corpus for Turing/JuMP/SciML (generated) |
| `results/` | Output directory (not committed) |

## Related

- [topiary-julia](https://github.com/pankgeorg/topiary-julia) — Julia formatter using tree-sitter
- [pankgeorg/tree-sitter-julia](https://github.com/pankgeorg/tree-sitter-julia) — Our grammar fork with fixes
- [tree-sitter-julia](https://github.com/tree-sitter/tree-sitter-julia) — Upstream grammar
- [JuliaSyntax.jl](https://github.com/JuliaLang/JuliaSyntax.jl) — Julia's built-in parser
