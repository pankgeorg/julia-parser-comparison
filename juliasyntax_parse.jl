#!/usr/bin/env julia
#
# juliasyntax_parse.jl
#
# Parses Julia source files listed in corpus_files.txt using the built-in
# Base.JuliaSyntax parser (Julia 1.12+), collecting node statistics and
# error information. Outputs results as JSON.

const JS = Base.JuliaSyntax

const CORPUS_LIST   = joinpath(@__DIR__, "corpus_files.txt")
const OUTPUT_PATH   = joinpath(@__DIR__, "results", "juliasyntax_results.json")
const CONTEXT_CHARS = 30   # chars of source context around error nodes
const PROGRESS_EVERY = 100  # print progress every N files

# ---------------------------------------------------------------------------
# Minimal JSON serialiser (no external packages required)
# ---------------------------------------------------------------------------

function json_escape(s::AbstractString)::String
    buf = IOBuffer()
    for ch in s
        if ch == '"'
            write(buf, "\\\"")
        elseif ch == '\\'
            write(buf, "\\\\")
        elseif ch == '\n'
            write(buf, "\\n")
        elseif ch == '\r'
            write(buf, "\\r")
        elseif ch == '\t'
            write(buf, "\\t")
        elseif ch == '\b'
            write(buf, "\\b")
        elseif ch == '\f'
            write(buf, "\\f")
        elseif codepoint(ch) < 0x20
            # Control characters: emit \u00xx
            write(buf, "\\u$(lpad(string(UInt16(codepoint(ch)); base=16), 4, '0'))")
        else
            write(buf, ch)
        end
    end
    return String(take!(buf))
end

function to_json(io::IO, x::AbstractString; indent::Int=0, compact::Bool=false)
    print(io, '"', json_escape(x), '"')
end

function to_json(io::IO, x::Number; indent::Int=0, compact::Bool=false)
    if isnan(x) || isinf(x)
        print(io, "null")
    else
        print(io, x)
    end
end

function to_json(io::IO, x::Bool; indent::Int=0, compact::Bool=false)
    print(io, x ? "true" : "false")
end

function to_json(io::IO, ::Nothing; indent::Int=0, compact::Bool=false)
    print(io, "null")
end

function to_json(io::IO, v::AbstractVector; indent::Int=0, compact::Bool=false)
    if isempty(v)
        print(io, "[]")
        return
    end
    println(io, "[")
    ni = indent + 2
    pad = " " ^ ni
    for (i, item) in enumerate(v)
        print(io, pad)
        to_json(io, item; indent=ni, compact=compact)
        i < length(v) && print(io, ",")
        println(io)
    end
    print(io, " " ^ indent, "]")
end

function to_json(io::IO, d::AbstractDict; indent::Int=0, compact::Bool=false)
    if isempty(d)
        print(io, "{}")
        return
    end
    println(io, "{")
    ni = indent + 2
    pad = " " ^ ni
    keys_sorted = sort!(collect(keys(d)); by=string)
    for (i, k) in enumerate(keys_sorted)
        print(io, pad)
        to_json(io, string(k); indent=ni, compact=compact)
        print(io, ": ")
        to_json(io, d[k]; indent=ni, compact=compact)
        i < length(keys_sorted) && print(io, ",")
        println(io)
    end
    print(io, " " ^ indent, "}")
end

function to_json_string(x)::String
    buf = IOBuffer()
    to_json(buf, x)
    return String(take!(buf))
end

# ---------------------------------------------------------------------------
# Tree walking
# ---------------------------------------------------------------------------

"""
    walk_tree!(node, source, stats)

Recursively walk a JuliaSyntax SyntaxNode tree, accumulating statistics
into `stats` (a Dict with keys :total_nodes, :error_count, :errors,
:kind_histogram).
"""
function walk_tree!(node, source::AbstractString, stats::Dict)
    stats[:total_nodes] += 1

    k = JS.kind(node)
    kname = string(k)

    # Update kind histogram
    stats[:kind_histogram][kname] = get(stats[:kind_histogram], kname, 0) + 1

    # Check for error nodes
    if k == JS.K"error"
        stats[:error_count] += 1
        br = JS.byte_range(node)
        bstart = first(br)
        bend = last(br)

        # Extract context around the error
        ctx_start = max(1, bstart - CONTEXT_CHARS)
        ctx_end   = min(ncodeunits(source), bend + CONTEXT_CHARS)
        context = try
            source[ctx_start:ctx_end]
        catch
            # byte indexing can fail on multi-byte chars; fall back
            try
                source[thisind(source, ctx_start):thisind(source, ctx_end)]
            catch
                "<context extraction failed>"
            end
        end

        push!(stats[:errors], Dict(
            "byte_range" => [bstart, bend],
            "context"    => context,
        ))
    end

    # Recurse into children
    kids = JS.children(node)
    if kids !== nothing
        for child in kids
            walk_tree!(child, source, stats)
        end
    end
end

# ---------------------------------------------------------------------------
# Parse a single file
# ---------------------------------------------------------------------------

function parse_file(path::AbstractString)::Dict
    result = Dict(
        "path"           => path,
        "total_nodes"    => 0,
        "error_count"    => 0,
        "errors"         => Vector{Dict}(),
        "kind_histogram" => Dict{String,Int}(),
        "parse_error"    => nothing,
    )

    if !isfile(path)
        result["parse_error"] = "file not found"
        return result
    end

    local content::String
    try
        content = read(path, String)
    catch e
        result["parse_error"] = "read error: $(sprint(showerror, e))"
        return result
    end

    local tree
    try
        tree = JS.parseall(JS.SyntaxNode, content; filename=path)
    catch e
        result["parse_error"] = "parse error: $(sprint(showerror, e))"
        return result
    end

    stats = Dict(
        :total_nodes    => 0,
        :error_count    => 0,
        :errors         => Vector{Dict}(),
        :kind_histogram => Dict{String,Int}(),
    )

    try
        walk_tree!(tree, content, stats)
    catch e
        result["parse_error"] = "walk error: $(sprint(showerror, e))"
        # Still return partial stats
    end

    result["total_nodes"]    = stats[:total_nodes]
    result["error_count"]    = stats[:error_count]
    result["errors"]         = stats[:errors]
    result["kind_histogram"] = stats[:kind_histogram]

    return result
end

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

function main()
    if !isfile(CORPUS_LIST)
        error("Corpus file list not found: $CORPUS_LIST")
    end

    file_paths = filter(!isempty, strip.(readlines(CORPUS_LIST)))
    total_files = length(file_paths)
    println("JuliaSyntax parser comparison")
    println("  Julia version: $(VERSION)")
    println("  Files to parse: $total_files")
    println("  Output: $OUTPUT_PATH")
    println()

    per_file = Vector{Dict}()
    global_histogram = Dict{String,Int}()
    files_with_errors = 0
    files_clean = 0

    t0 = time()

    for (i, path) in enumerate(file_paths)
        result = parse_file(path)
        push!(per_file, result)

        # Merge into global histogram
        for (k, v) in result["kind_histogram"]
            global_histogram[k] = get(global_histogram, k, 0) + v
        end

        # Count files with/without errors
        if result["error_count"] > 0 || result["parse_error"] !== nothing
            files_with_errors += 1
        else
            files_clean += 1
        end

        # Progress
        if i % PROGRESS_EVERY == 0 || i == total_files
            elapsed = time() - t0
            rate = i / max(elapsed, 0.001)
            println("  [$i/$total_files] $(round(rate; digits=1)) files/sec, " *
                    "$(files_with_errors) with errors so far " *
                    "($(round(elapsed; digits=1))s elapsed)")
        end
    end

    # Remove parse_error key when it is nothing (cleaner JSON)
    for r in per_file
        if r["parse_error"] === nothing
            delete!(r, "parse_error")
        end
    end

    # Build final output
    output = Dict(
        "total_files"           => total_files,
        "files_with_errors"     => files_with_errors,
        "files_clean"           => files_clean,
        "per_file"              => per_file,
        "global_kind_histogram" => global_histogram,
    )

    # Write JSON
    mkpath(dirname(OUTPUT_PATH))
    open(OUTPUT_PATH, "w") do io
        to_json(io, output)
        println(io)  # trailing newline
    end

    println()
    println("Done. Results written to $OUTPUT_PATH")
    println("  Total files:       $total_files")
    println("  Files with errors: $files_with_errors")
    println("  Files clean:       $files_clean")
    total_errors = sum(r["error_count"] for r in per_file)
    println("  Total error nodes: $total_errors")
    println("  Unique node kinds: $(length(global_histogram))")
end

main()
