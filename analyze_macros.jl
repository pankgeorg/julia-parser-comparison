#!/usr/bin/env julia
#
# Focused analysis of macro definitions and calls in the corpus.
# Parses with both JuliaSyntax and tree-sitter, comparing behavior
# on macro-heavy code specifically.

const JS = Base.JuliaSyntax
const CORPUS_FILE = joinpath(@__DIR__, "corpus_files.txt")
const RESULTS_DIR = joinpath(@__DIR__, "results")
const TS_CMD = `/home/pgeorgakopoulos/.nvm/versions/node/v24.13.1/bin/tree-sitter`

# ── JSON serializer (same as compare_results.jl) ────────────────

function to_json(x, indent=0)
    io = IOBuffer()
    _write_json(io, x, indent, 0)
    return String(take!(io))
end

function _write_json(io, x::Dict, indent, level)
    isempty(x) && (write(io, "{}"); return)
    write(io, "{\n")
    pairs = sort(collect(x), by=first)
    for (i, (k, v)) in enumerate(pairs)
        write(io, " "^(indent*(level+1)))
        _write_json(io, k, indent, level+1)
        write(io, ": ")
        _write_json(io, v, indent, level+1)
        i < length(pairs) && write(io, ",")
        write(io, "\n")
    end
    write(io, " "^(indent*level), "}")
end

function _write_json(io, x::AbstractVector, indent, level)
    isempty(x) && (write(io, "[]"); return)
    if all(v -> v isa Union{Number,AbstractString,Nothing,Bool}, x) && length(x) <= 10
        write(io, "[")
        for (i, v) in enumerate(x)
            _write_json(io, v, indent, level+1)
            i < length(x) && write(io, ", ")
        end
        write(io, "]")
        return
    end
    write(io, "[\n")
    for (i, v) in enumerate(x)
        write(io, " "^(indent*(level+1)))
        _write_json(io, v, indent, level+1)
        i < length(x) && write(io, ",")
        write(io, "\n")
    end
    write(io, " "^(indent*level), "]")
end

function _write_json(io, x::AbstractString, indent, level)
    write(io, '"')
    for c in x
        if c == '"'; write(io, "\\\"")
        elseif c == '\\'; write(io, "\\\\")
        elseif c == '\n'; write(io, "\\n")
        elseif c == '\r'; write(io, "\\r")
        elseif c == '\t'; write(io, "\\t")
        elseif codepoint(c) < 0x20; write(io, "\\u", lpad(string(UInt16(c), base=16), 4, '0'))
        else write(io, c)
        end
    end
    write(io, '"')
end

_write_json(io, x::Number, indent, level) = write(io, string(x))
_write_json(io, x::Bool, indent, level) = write(io, x ? "true" : "false")
_write_json(io, ::Nothing, indent, level) = write(io, "null")

# ── Extract macro definitions and calls from source ──────────────

struct MacroSnippet
    file::String
    line::Int
    kind::Symbol        # :definition or :call
    name::String        # macro name
    source::String      # full source text
    lines::Int          # line count
end

function extract_macros_from_file(path::String)
    snippets = MacroSnippet[]
    try
        content = read(path, String)
        lines = split(content, '\n')
    catch
        return snippets
    end
    lines = split(read(path, String), '\n')

    i = 1
    while i <= length(lines)
        line = lines[i]
        stripped = lstrip(line)

        # Macro definition: `macro name(...)`
        m = match(r"^macro\s+(\w+)", stripped)
        if m !== nothing
            name = m.captures[1]
            # Find the matching `end`
            depth = 1
            j = i + 1
            while j <= length(lines) && depth > 0
                l = strip(lines[j])
                # Count block openers/closers (rough heuristic)
                for kw in ["function ", "macro ", "if ", "for ", "while ", "let ", "begin ", "try ", "struct ", "module ", "quote ", "do "]
                    if startswith(l, kw) || (endswith(l, kw[1:end-1]) && length(l) == length(kw)-1)
                        depth += 1
                    end
                end
                if l == "end" || endswith(l, " end") || startswith(l, "end ")
                    depth -= 1
                end
                j += 1
            end
            src = join(lines[i:min(j, length(lines))], '\n')
            push!(snippets, MacroSnippet(path, i, :definition, name, src, j - i + 1))
            i = j
            continue
        end

        # Macro calls: `@name ...` (multi-line if inside block)
        m = match(r"@(\w+(?:\.\w+)*)", stripped)
        if m !== nothing
            name = m.captures[1]
            # Take just this line (macro calls are typically one line or a block)
            # For multi-line macro calls, try to capture the full expression
            src = String(line)
            nlines = 1

            # Check if line ends with begin/do or has unclosed parens
            if occursin(r"begin\s*$", stripped) || occursin(r"do\s*$", stripped)
                depth = 1
                j = i + 1
                while j <= length(lines) && depth > 0
                    l = strip(lines[j])
                    for kw in ["begin", "do"]
                        if endswith(l, kw)
                            depth += 1
                        end
                    end
                    if l == "end" || startswith(l, "end ")
                        depth -= 1
                    end
                    j += 1
                end
                src = join(lines[i:min(j, length(lines))], '\n')
                nlines = j - i + 1
            end

            push!(snippets, MacroSnippet(path, i, :call, name, src, nlines))
        end

        i += 1
    end

    return snippets
end

# ── Parse a snippet with both parsers ────────────────────────────

function parse_with_juliasyntax(code::String)
    try
        tree = JS.parseall(JS.SyntaxNode, code, ignore_warnings=true)
        has_error = _has_error(tree)
        return (success=!has_error, error=has_error, tree_summary=_tree_summary(tree))
    catch e
        return (success=false, error=true, tree_summary="PARSE_EXCEPTION: $(sprint(showerror, e))")
    end
end

function _has_error(node)
    if JS.kind(node) == JS.K"error"
        return true
    end
    cs = JS.children(node)
    isnothing(cs) && return false
    return any(_has_error, cs)
end

function _tree_summary(node, depth=0)
    k = string(JS.kind(node))
    cs = JS.children(node)
    if isnothing(cs) || isempty(cs)
        return k
    end
    children_str = join([_tree_summary(c, depth+1) for c in cs], ", ")
    return "$k($children_str)"
end

function parse_with_treesitter(code::String)
    try
        tmpfile = tempname() * ".jl"
        write(tmpfile, code)
        output = read(pipeline(`$TS_CMD parse $tmpfile`, stderr=devnull), String)
        rm(tmpfile, force=true)

        has_error = occursin("ERROR", output) || occursin("MISSING", output)
        # Count ERROR nodes
        error_count = length(collect(eachmatch(r"\(ERROR ", output)))
        missing_count = length(collect(eachmatch(r"\(MISSING ", output)))

        return (success=!has_error, error_count=error_count, missing_count=missing_count, sexp=output)
    catch e
        return (success=false, error_count=-1, missing_count=-1, sexp="PARSE_EXCEPTION: $(sprint(showerror, e))")
    end
end

# ── Main ─────────────────────────────────────────────────────────

function main()
    if !isfile(CORPUS_FILE)
        error("Corpus file not found at $CORPUS_FILE — run build_corpus.jl first")
    end

    files = filter(!isempty, readlines(CORPUS_FILE))
    println("Scanning $(length(files)) files for macros...")

    all_macros = MacroSnippet[]
    for (i, path) in enumerate(files)
        if i % 200 == 0
            println("  Scanned $i/$(length(files)) files, found $(length(all_macros)) macros so far")
        end
        append!(all_macros, extract_macros_from_file(path))
    end

    definitions = filter(m -> m.kind == :definition, all_macros)
    calls = filter(m -> m.kind == :call, all_macros)

    println("\nFound $(length(definitions)) macro definitions, $(length(calls)) macro calls")

    # Focus on long macro definitions (>10 lines) and SciML-specific macros
    long_defs = filter(m -> m.lines > 10, definitions)
    sciml_names = Set(["variables", "parameters", "mtkmodel", "mtkcompile", "mtkbuild",
                       "brownians", "register_symbolic", "register_array_symbolic",
                       "num_method", "parse_expr_to_symbolic", "derivatives",
                       "inline", "noinline", "generated", "eval", "doc", "testset",
                       "test", "assert", "enum", "kwdef", "static", "turbo"])

    sciml_macros = filter(m -> lowercase(m.name) in sciml_names, all_macros)

    println("Long definitions (>10 lines): $(length(long_defs))")
    println("SciML/common macro usage: $(length(sciml_macros))")

    # Parse long definitions with both parsers
    println("\n--- Parsing long macro definitions with both parsers ---")

    results = Dict{String,Any}[]
    ts_failures = 0
    js_failures = 0
    both_ok = 0

    test_set = vcat(long_defs, sciml_macros)
    # Deduplicate by source
    seen = Set{String}()
    unique_set = MacroSnippet[]
    for m in test_set
        key = m.source
        if !(key in seen) && length(key) < 50000  # skip huge macros
            push!(seen, key)
            push!(unique_set, m)
        end
    end

    println("Testing $(length(unique_set)) unique macro snippets...")

    for (i, m) in enumerate(unique_set)
        if i % 50 == 0
            println("  Parsed $i/$(length(unique_set))...")
        end

        js_result = parse_with_juliasyntax(m.source)
        ts_result = parse_with_treesitter(m.source)

        status = if js_result.success && ts_result.success
            both_ok += 1
            "both_ok"
        elseif !ts_result.success && js_result.success
            ts_failures += 1
            "ts_only_fail"
        elseif !js_result.success && ts_result.success
            js_failures += 1
            "js_only_fail"
        else
            "both_fail"
        end

        entry = Dict(
            "file" => m.file,
            "line" => m.line,
            "kind" => string(m.kind),
            "name" => m.name,
            "lines" => m.lines,
            "status" => status,
            "source_preview" => length(m.source) > 200 ? m.source[1:200] * "..." : m.source,
        )

        if status == "ts_only_fail"
            entry["ts_error_count"] = ts_result.error_count
            entry["ts_missing_count"] = ts_result.missing_count
            # Grab first 500 chars of sexp for debugging
            entry["ts_sexp_preview"] = length(ts_result.sexp) > 500 ? ts_result.sexp[1:500] * "..." : ts_result.sexp
        end

        push!(results, entry)
    end

    # Summary
    println("\n=== Macro Analysis Results ===")
    println("Total unique snippets tested: $(length(unique_set))")
    println("Both parsers OK: $both_ok")
    println("tree-sitter only fails: $ts_failures")
    println("JuliaSyntax only fails: $js_failures")
    println("Both fail: $(length(unique_set) - both_ok - ts_failures - js_failures)")

    # Group ts-failures by macro name
    ts_fail_results = filter(r -> r["status"] == "ts_only_fail", results)
    if !isempty(ts_fail_results)
        println("\n--- tree-sitter failures by macro name ---")
        name_counts = Dict{String,Int}()
        for r in ts_fail_results
            name_counts[r["name"]] = get(name_counts, r["name"], 0) + 1
        end
        for (name, count) in sort(collect(name_counts), by=x->-x[2])
            println("  @$name: $count failures")
        end

        println("\n--- First 10 tree-sitter failures ---")
        for r in first(ts_fail_results, 10)
            short_file = replace(r["file"], homedir() => "~")
            println("  $(short_file):$(r["line"]) @$(r["name"]) ($(r["lines"]) lines)")
            preview = replace(r["source_preview"], '\n' => "\\n")
            if length(preview) > 120
                preview = preview[1:120] * "..."
            end
            println("    $(preview)")
        end
    end

    # Write results
    mkpath(RESULTS_DIR)
    output = Dict(
        "total_snippets" => length(unique_set),
        "both_ok" => both_ok,
        "ts_only_fail" => ts_failures,
        "js_only_fail" => js_failures,
        "both_fail" => length(unique_set) - both_ok - ts_failures - js_failures,
        "results" => results,
    )
    outpath = joinpath(RESULTS_DIR, "macro_analysis.json")
    write(outpath, to_json(output, 2))
    println("\nResults written to $outpath")
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
