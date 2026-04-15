#!/usr/bin/env julia
#
# Compare JuliaSyntax and tree-sitter parse results.
# Reads results from results/juliasyntax_results.json and results/treesitter_results.json
# Produces results/comparison_report.md and results/comparison.json

using JSON3

const RESULTS_DIR = joinpath(@__DIR__, "results")
const JS_RESULTS = joinpath(RESULTS_DIR, "juliasyntax_results.json")
const TS_RESULTS = joinpath(RESULTS_DIR, "treesitter_results.json")

# ── Comparison logic ─────────────────────────────────────────────

function load_results()
    if !isfile(JS_RESULTS)
        error("JuliaSyntax results not found at $JS_RESULTS — run juliasyntax_parse.jl first")
    end
    if !isfile(TS_RESULTS)
        error("Tree-sitter results not found at $TS_RESULTS — run treesitter_parse.jl first")
    end

    println("Loading JuliaSyntax results...")
    js = JSON3.read(read(JS_RESULTS, String))
    println("Loading tree-sitter results...")
    ts = JSON3.read(read(TS_RESULTS, String))
    return js, ts
end

function compare(js, ts)
    # Build path → result lookup
    js_by_path = Dict(String(f.path) => f for f in js.per_file)
    ts_by_path = Dict(String(f.path) => f for f in ts.per_file)

    all_paths = sort(collect(union(keys(js_by_path), keys(ts_by_path))))

    both_clean = String[]
    ts_only_errors = String[]
    js_only_errors = String[]
    both_errors = String[]
    ts_only_files = String[]
    js_only_files = String[]

    ts_error_details = Dict{String,Any}()

    for path in all_paths
        has_js = haskey(js_by_path, path)
        has_ts = haskey(ts_by_path, path)

        if !has_js
            push!(ts_only_files, path)
            continue
        end
        if !has_ts
            push!(js_only_files, path)
            continue
        end

        js_f = js_by_path[path]
        ts_f = ts_by_path[path]

        js_errs = js_f.error_count
        ts_errs = ts_f.error_count
        ts_missing = hasproperty(ts_f, :missing_count) ? ts_f.missing_count : 0
        ts_total_errs = ts_errs + ts_missing

        if ts_total_errs == 0 && js_errs == 0
            push!(both_clean, path)
        elseif ts_total_errs > 0 && js_errs == 0
            push!(ts_only_errors, path)
            ts_error_details[path] = ts_f.errors
        elseif ts_total_errs == 0 && js_errs > 0
            push!(js_only_errors, path)
        else
            push!(both_errors, path)
        end
    end

    return Dict(
        "total_files" => length(all_paths),
        "both_clean" => length(both_clean),
        "ts_only_errors" => length(ts_only_errors),
        "js_only_errors" => length(js_only_errors),
        "both_errors" => length(both_errors),
        "ts_only_error_files" => ts_only_errors,
        "js_only_error_files" => js_only_errors,
        "both_error_files" => both_errors,
        "ts_error_details" => ts_error_details,
    )
end

function extract_error_patterns(ts_error_details)
    pattern_counts = Dict{String,Int}()
    error_contexts = Dict{String,Vector{String}}()

    for (path, errors) in ts_error_details
        for err in errors
            ctx = String(hasproperty(err, :context) ? err.context : "")
            if length(ctx) > 100
                ctx = first(ctx, 100) * "..."
            end
            pattern = identify_pattern(ctx)
            pattern_counts[pattern] = get(pattern_counts, pattern, 0) + 1
            if !haskey(error_contexts, pattern)
                error_contexts[pattern] = String[]
            end
            if length(error_contexts[pattern]) < 5
                push!(error_contexts[pattern], "$(basename(path)):$(hasproperty(err, :line) ? err.line : "?") → $(ctx)")
            end
        end
    end

    return pattern_counts, error_contexts
end

function identify_pattern(ctx::String)
    ctx = strip(ctx)
    if occursin(r"\$\$", ctx); return "\$ interpolation/operator"
    elseif occursin(r"var\"", ctx); return "var\"...\" identifier"
    elseif occursin(r"@\w+", ctx); return "macro usage"
    elseif occursin(r"\.\w+\"", ctx); return "broadcast/dot operator"
    elseif occursin(r"[₀-₉₊₋]", ctx); return "subscript suffix"
    elseif occursin(r"^\s*;", ctx); return "semicolons"
    elseif occursin(r"public\s", ctx); return "public keyword"
    elseif occursin(r"~", ctx); return "tilde operator"
    elseif occursin(r"\bdo\b", ctx); return "do block"
    elseif occursin(r"\bwhere\b", ctx); return "where clause"
    elseif ctx == ""; return "empty context"
    else return "other"
    end
end

function write_report(comparison, pattern_counts, error_contexts, js, ts)
    report = IOBuffer()

    println(report, "# Parser Comparison Report")
    println(report, "")
    println(report, "Generated: ", Dates.now())
    println(report, "Corpus: 100 packages, $(comparison["total_files"]) files")
    println(report, "")
    println(report, "## Summary")
    println(report, "")
    println(report, "| Metric | Count |")
    println(report, "|--------|-------|")
    println(report, "| Total files | $(comparison["total_files"]) |")
    println(report, "| Both parsers clean | $(comparison["both_clean"]) |")
    println(report, "| tree-sitter errors only | $(comparison["ts_only_errors"]) |")
    println(report, "| JuliaSyntax errors only | $(comparison["js_only_errors"]) |")
    println(report, "| Both have errors | $(comparison["both_errors"]) |")
    println(report, "")

    clean_or_ts = comparison["both_clean"] + comparison["ts_only_errors"]
    if clean_or_ts > 0
        pct = round(comparison["both_clean"] / clean_or_ts * 100, digits=1)
        println(report, "**tree-sitter parse success rate** (where JuliaSyntax succeeds): $(pct)% ($(comparison["both_clean"])/$(clean_or_ts))")
        println(report, "")
    end

    # Error pattern breakdown
    if !isempty(pattern_counts)
        println(report, "## tree-sitter Error Patterns")
        println(report, "")
        println(report, "These are ERROR/MISSING nodes in files where JuliaSyntax parses cleanly.")
        println(report, "")
        println(report, "| Pattern | Error count |")
        println(report, "|---------|-------------|")
        for (pattern, count) in sort(collect(pattern_counts), by=x->-x[2])
            println(report, "| $(pattern) | $(count) |")
        end
        println(report, "")

        println(report, "### Examples by pattern")
        println(report, "")
        for (pattern, count) in sort(collect(pattern_counts), by=x->-x[2])
            println(report, "#### $(pattern) ($(count) errors)")
            println(report, "```")
            for ex in get(error_contexts, pattern, String[])
                println(report, ex)
            end
            println(report, "```")
            println(report, "")
        end
    end

    # Files with tree-sitter errors (first 50)
    ts_err_files = comparison["ts_only_error_files"]
    if !isempty(ts_err_files)
        println(report, "## Files with tree-sitter-only errors ($(length(ts_err_files)) files)")
        println(report, "")
        for f in first(ts_err_files, 50)
            short = replace(f, homedir() => "~")
            println(report, "- `$(short)`")
        end
        if length(ts_err_files) > 50
            println(report, "- ... and $(length(ts_err_files) - 50) more")
        end
        println(report, "")
    end

    # Node type histograms comparison (top 30)
    println(report, "## Global Node Type Distribution (top 30)")
    println(report, "")
    js_hist = Dict{String,Int}()
    for (k, v) in pairs(js.global_kind_histogram)
        js_hist[String(k)] = v
    end
    ts_hist = Dict{String,Int}()
    for (k, v) in pairs(ts.global_node_type_histogram)
        ts_hist[String(k)] = v
    end

    all_types = sort(collect(union(keys(js_hist), keys(ts_hist))))
    type_totals = [(t, get(js_hist, t, 0) + get(ts_hist, t, 0)) for t in all_types]
    sort!(type_totals, by=x->-x[2])

    println(report, "| Node Kind (JuliaSyntax) / Type (tree-sitter) | JuliaSyntax | tree-sitter |")
    println(report, "|----------------------------------------------|------------|-------------|")
    for (t, _) in first(type_totals, 30)
        js_count = get(js_hist, t, "-")
        ts_count = get(ts_hist, t, "-")
        println(report, "| $(t) | $(js_count) | $(ts_count) |")
    end
    println(report, "")

    report_str = String(take!(report))

    # Write report
    report_path = joinpath(RESULTS_DIR, "comparison_report.md")
    write(report_path, report_str)
    println("Report written to $report_path")

    # Write JSON comparison
    json_path = joinpath(RESULTS_DIR, "comparison.json")
    # Slim version for JSON (skip ts_error_details to keep it small)
    slim = Dict(
        "total_files" => comparison["total_files"],
        "both_clean" => comparison["both_clean"],
        "ts_only_errors" => comparison["ts_only_errors"],
        "js_only_errors" => comparison["js_only_errors"],
        "both_errors" => comparison["both_errors"],
        "ts_only_error_files" => comparison["ts_only_error_files"],
        "js_only_error_files" => comparison["js_only_error_files"],
        "both_error_files" => comparison["both_error_files"],
        "error_patterns" => pattern_counts,
    )
    open(json_path, "w") do io
        JSON3.pretty(io, slim)
    end
    println("JSON written to $json_path")

    # Print summary to stdout
    println()
    print(report_str)
end

using Dates

function main()
    println("Loading results...")
    js, ts = load_results()
    println("  JuliaSyntax: $(js.total_files) files ($(js.files_with_errors) with errors)")
    println("  tree-sitter: $(ts.total_files) files ($(ts.files_with_errors) with errors)")

    println("Comparing...")
    comparison = compare(js, ts)

    println("Analyzing error patterns...")
    pattern_counts, error_contexts = extract_error_patterns(comparison["ts_error_details"])

    println("Writing report...")
    write_report(comparison, pattern_counts, error_contexts, js, ts)
end

main()
