#!/usr/bin/env julia
#
# treesitter_parse.jl — Parse Julia files with tree-sitter and collect statistics.
#
# Reads file paths from corpus_files.txt, runs tree-sitter parse on each,
# extracts node counts, ERROR/MISSING info, and per-type histograms,
# then writes results as JSON to results/treesitter_results.json.

const TREE_SITTER_BIN = "/home/pgeorgakopoulos/.nvm/versions/node/v24.13.1/bin/tree-sitter"
const CORPUS_FILE = joinpath(@__DIR__, "corpus_files.txt")
const OUTPUT_FILE = joinpath(@__DIR__, "results", "treesitter_results.json")
const TIMEOUT_SECONDS = 10

# ---------------------------------------------------------------------------
# Minimal JSON serializer (no external packages)
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
            # Control character — emit \u00XX
            write(buf, "\\u00")
            write(buf, string(UInt16(ch); base=16, pad=2))
        else
            write(buf, ch)
        end
    end
    return String(take!(buf))
end

function to_json(val; indent::Int=0, compact::Bool=false)::String
    _to_json(val, indent, compact)
end

function _to_json(val::Nothing, ::Int, ::Bool)::String
    "null"
end

function _to_json(val::Bool, ::Int, ::Bool)::String
    val ? "true" : "false"
end

function _to_json(val::Integer, ::Int, ::Bool)::String
    string(val)
end

function _to_json(val::AbstractFloat, ::Int, ::Bool)::String
    isnan(val) || isinf(val) ? "null" : string(val)
end

function _to_json(val::AbstractString, ::Int, ::Bool)::String
    string('"', json_escape(val), '"')
end

function _to_json(val::AbstractVector, indent::Int, compact::Bool)::String
    isempty(val) && return "[]"
    if compact
        parts = [_to_json(v, indent, true) for v in val]
        return string("[", join(parts, ", "), "]")
    end
    next_indent = indent + 2
    pad = " " ^ next_indent
    close_pad = " " ^ indent
    parts = String[]
    for v in val
        push!(parts, string(pad, _to_json(v, next_indent, false)))
    end
    return string("[\n", join(parts, ",\n"), "\n", close_pad, "]")
end

function _to_json(val::AbstractDict, indent::Int, compact::Bool)::String
    isempty(val) && return "{}"
    if compact
        parts = [string('"', json_escape(string(k)), "\": ", _to_json(v, indent, true))
                 for (k, v) in sort(collect(val); by=first)]
        return string("{", join(parts, ", "), "}")
    end
    next_indent = indent + 2
    pad = " " ^ next_indent
    close_pad = " " ^ indent
    parts = String[]
    for (k, v) in sort(collect(val); by=first)
        push!(parts, string(pad, '"', json_escape(string(k)), "\": ", _to_json(v, next_indent, false)))
    end
    return string("{\n", join(parts, ",\n"), "\n", close_pad, "}")
end

# Fallback: convert to string
function _to_json(val, indent::Int, compact::Bool)::String
    _to_json(string(val), indent, compact)
end

# ---------------------------------------------------------------------------
# S-expression parser
# ---------------------------------------------------------------------------

struct ErrorInfo
    line::Int
    col_start::Int
    col_end::Int
    context::String
end

struct FileResult
    path::String
    total_nodes::Int
    error_count::Int
    missing_count::Int
    errors::Vector{ErrorInfo}
    node_type_histogram::Dict{String,Int}
    parse_succeeded::Bool
    parse_message::String
end

"""
    parse_sexp(sexp_text, filepath) -> (total_nodes, error_count, missing_count, errors, histogram)

Parse the S-expression output from `tree-sitter parse` and extract statistics.

Named nodes appear as `(node_type [row, col] - [row, col] ...)`.
ERROR nodes: `(ERROR [row, col] - [row, col] ...)`.
MISSING tokens: `(MISSING "token" [row, col] - [row, col])`.
"""
function parse_sexp(sexp_text::AbstractString, filepath::AbstractString)
    total_nodes = 0
    error_count = 0
    missing_count = 0
    errors = ErrorInfo[]
    histogram = Dict{String,Int}()

    # Pattern for named nodes: opening paren followed by a word, then a range.
    # Examples:
    #   (source_file [0, 0] - [3, 0]
    #   (identifier [0, 9] - [0, 12])
    #   (ERROR [1, 4] - [1, 10]
    node_re = r"\((\w+)\s+\[(\d+),\s*(\d+)\]\s*-\s*\[(\d+),\s*(\d+)\]"

    # Pattern for MISSING tokens (sometimes appear differently):
    #   (MISSING "end" [5, 0] - [5, 0])
    #   (MISSING "" [5, 0] - [5, 0])
    missing_re = r"\(MISSING\s+\"[^\"]*\"\s+\[(\d+),\s*(\d+)\]\s*-\s*\[(\d+),\s*(\d+)\]"

    # Read file bytes for extracting error context
    file_bytes = UInt8[]
    try
        file_bytes = read(filepath)
    catch
        # If we can't read the file, we'll just skip context extraction.
    end

    # Count all named node occurrences
    for m in eachmatch(node_re, sexp_text)
        node_type = m.captures[1]
        row_start = parse(Int, m.captures[2])
        col_start = parse(Int, m.captures[3])
        row_end = parse(Int, m.captures[4])
        col_end = parse(Int, m.captures[5])

        total_nodes += 1
        histogram[node_type] = get(histogram, node_type, 0) + 1

        if node_type == "ERROR"
            error_count += 1
            context = extract_context(file_bytes, row_start, col_start, row_end, col_end)
            push!(errors, ErrorInfo(row_start, col_start, col_end, context))
        end
    end

    # Count MISSING tokens separately (they may overlap with the node_re pattern
    # if MISSING is treated as a node type, but we want explicit tracking).
    for m in eachmatch(missing_re, sexp_text)
        missing_count += 1
    end

    # If MISSING was already counted as a node type, remove it from the histogram
    # and adjust total_nodes so it is not double-counted as a "named node".
    if haskey(histogram, "MISSING")
        total_nodes -= histogram["MISSING"]
        delete!(histogram, "MISSING")
    end

    return (total_nodes, error_count, missing_count, errors, histogram)
end

"""
    extract_context(file_bytes, row_start, col_start, row_end, col_end) -> String

Extract the source text corresponding to the given row/col range.
Rows and columns are 0-indexed (as tree-sitter uses). Columns are byte offsets.
Returns up to 200 characters of context.
"""
function extract_context(file_bytes::Vector{UInt8}, row_start::Int, col_start::Int,
                         row_end::Int, col_end::Int)::String
    isempty(file_bytes) && return ""
    try
        lines = split(String(copy(file_bytes)), '\n'; keepempty=true)
        if row_start + 1 > length(lines)
            return ""
        end
        if row_start == row_end
            line = lines[row_start + 1]  # 0-indexed -> 1-indexed
            line_bytes = Vector{UInt8}(codeunits(line))
            byte_start = min(col_start + 1, length(line_bytes) + 1)
            byte_end = min(col_end, length(line_bytes))
            if byte_start > byte_end
                return ""
            end
            ctx = String(line_bytes[byte_start:byte_end])
        else
            # Multi-line error: collect lines from row_start to row_end
            buf = IOBuffer()
            for r in row_start:min(row_end, length(lines) - 1)
                line = lines[r + 1]
                if r == row_start
                    line_bytes = Vector{UInt8}(codeunits(line))
                    byte_start = min(col_start + 1, length(line_bytes) + 1)
                    write(buf, String(line_bytes[byte_start:end]))
                elseif r == row_end
                    line_bytes = Vector{UInt8}(codeunits(line))
                    byte_end = min(col_end, length(line_bytes))
                    write(buf, "\n")
                    if byte_end >= 1
                        write(buf, String(line_bytes[1:byte_end]))
                    end
                else
                    write(buf, "\n")
                    write(buf, line)
                end
            end
            ctx = String(take!(buf))
        end
        # Truncate long contexts
        if length(ctx) > 200
            return ctx[1:200] * "..."
        end
        return ctx
    catch
        return ""
    end
end

"""
    run_tree_sitter(filepath) -> FileResult

Run `tree-sitter parse` on a file and return parsed results.

tree-sitter parse writes the S-expression to stdout and diagnostic info to stderr.
It exits with code 1 when there are parse errors, so we must handle non-zero exit.
We use a temporary file for stderr and `open(pipeline(...))` for stdout, plus a
timer-based timeout.
"""
function run_tree_sitter(filepath::AbstractString)::FileResult
    if !isfile(filepath)
        return FileResult(filepath, 0, 0, 0, ErrorInfo[], Dict{String,Int}(), false,
                          "File not found")
    end

    stderr_path = tempname()
    try
        cmd = `$TREE_SITTER_BIN parse $filepath`
        stdout_text = ""
        stderr_text = ""
        timed_out = false

        # Open the process with stderr redirected to a temp file.
        # `open(pipeline(...), "r")` does not throw on non-zero exit — it lets
        # us read stdout regardless of exit code.
        proc = open(pipeline(cmd; stderr=stderr_path), "r")
        read_task = @async read(proc, String)

        # Poll for completion with timeout
        deadline = time() + TIMEOUT_SECONDS
        while !istaskdone(read_task) && time() < deadline
            sleep(0.05)
        end

        if !istaskdone(read_task)
            timed_out = true
            try; kill(proc.processes[1]); catch; end
        else
            stdout_text = fetch(read_task)
        end

        try; close(proc); catch; end

        if timed_out
            try; isfile(stderr_path) && rm(stderr_path); catch; end
            return FileResult(filepath, 0, 0, 0, ErrorInfo[], Dict{String,Int}(), false,
                              "Timeout after $(TIMEOUT_SECONDS)s")
        end

        # Read stderr
        try
            stderr_text = isfile(stderr_path) ? read(stderr_path, String) : ""
        catch
            stderr_text = ""
        end
        try; isfile(stderr_path) && rm(stderr_path); catch; end

        # Combine stdout and stderr for parsing (MISSING tokens may appear in either)
        full_output = stdout_text * "\n" * stderr_text

        # Parse the S-expression
        (total_nodes, error_count, missing_count, errors, histogram) =
            parse_sexp(full_output, filepath)

        return FileResult(filepath, total_nodes, error_count, missing_count, errors,
                          histogram, true, "")

    catch e
        try; isfile(stderr_path) && rm(stderr_path); catch; end
        return FileResult(filepath, 0, 0, 0, ErrorInfo[], Dict{String,Int}(), false,
                          "Exception: $(sprint(showerror, e))")
    end
end

"""
    merge_histograms!(global_hist, local_hist)

Merge a per-file histogram into the global histogram.
"""
function merge_histograms!(global_hist::Dict{String,Int}, local_hist::Dict{String,Int})
    for (k, v) in local_hist
        global_hist[k] = get(global_hist, k, 0) + v
    end
end

"""
    file_result_to_dict(r::FileResult) -> Dict

Convert a FileResult to a Dict suitable for JSON serialization.
"""
function file_result_to_dict(r::FileResult)::Dict{String,Any}
    errors_list = [
        Dict{String,Any}(
            "line" => e.line,
            "col_start" => e.col_start,
            "col_end" => e.col_end,
            "context" => e.context
        )
        for e in r.errors
    ]
    d = Dict{String,Any}(
        "path" => r.path,
        "total_nodes" => r.total_nodes,
        "error_count" => r.error_count,
        "missing_count" => r.missing_count,
        "errors" => errors_list,
        "node_type_histogram" => r.node_type_histogram
    )
    if !r.parse_succeeded
        d["parse_error"] = r.parse_message
    end
    return d
end

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

function main()
    # Read corpus file list
    if !isfile(CORPUS_FILE)
        println(stderr, "ERROR: corpus_files.txt not found at $CORPUS_FILE")
        exit(1)
    end

    file_paths = filter(!isempty, strip.(readlines(CORPUS_FILE)))
    total_files = length(file_paths)
    println(stderr, "Processing $total_files files...")

    # Results accumulators
    per_file_results = Vector{Dict{String,Any}}()
    global_histogram = Dict{String,Int}()
    files_with_errors = 0
    files_clean = 0

    for (i, filepath) in enumerate(file_paths)
        result = run_tree_sitter(filepath)

        # Accumulate
        push!(per_file_results, file_result_to_dict(result))
        merge_histograms!(global_histogram, result.node_type_histogram)

        if result.error_count > 0
            files_with_errors += 1
        elseif result.parse_succeeded
            files_clean += 1
        end

        # Progress report every 100 files
        if i % 100 == 0 || i == total_files
            pct = round(100.0 * i / total_files; digits=1)
            println(stderr, "  [$i/$total_files] ($pct%) — errors so far in $files_with_errors files")
        end
    end

    # Build final JSON structure
    output = Dict{String,Any}(
        "total_files" => total_files,
        "files_with_errors" => files_with_errors,
        "files_clean" => files_clean,
        "per_file" => per_file_results,
        "global_node_type_histogram" => global_histogram
    )

    # Write JSON
    mkpath(dirname(OUTPUT_FILE))
    open(OUTPUT_FILE, "w") do io
        write(io, to_json(output))
        write(io, "\n")
    end

    println(stderr, "Done. Results written to $OUTPUT_FILE")
    println(stderr, "Summary: $total_files files, $files_clean clean, $files_with_errors with errors")
end

main()
