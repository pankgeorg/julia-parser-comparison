#!/usr/bin/env julia

# build_corpus.jl — Build a corpus of Julia source files from ~/.julia/packages/
#
# Selects ~100 packages (prioritized list + alphabetical fill), collects all .jl
# files under each package's src/ directory, and writes:
#   corpus_files.txt    — one absolute path per line
#   corpus_packages.txt — selected package names, one per line

const PACKAGES_DIR = expanduser("~/.julia/packages")
const OUTPUT_DIR = dirname(@__FILE__)
const TARGET_PACKAGE_COUNT = 100

# Priority packages grouped by category
const PRIORITY_PACKAGES = [
    # SciML core
    "ModelingToolkit", "ModelingToolkitBase", "ModelingToolkitStandardLibrary",
    "ModelingToolkitTearing", "Symbolics", "DiffEqBase", "OrdinaryDiffEqCore",
    "OrdinaryDiffEqDefault", "OrdinaryDiffEqRosenbrock", "DelayDiffEq",
    "JumpProcesses", "DiffEqCallbacks", "DiffEqNoiseProcess",
    # Macro-heavy
    "MacroTools", "JuMP", "Turing", "StaticArrays", "BenchmarkTools",
    "Makie", "GLMakie", "Pluto",
    # Popular
    "DataFrames", "CSV", "HTTP", "Revise", "Optim", "ForwardDiff",
    # AD/ML
    "EnzymeCore", "Optimisers", "Optimization", "OptimizationBase",
]

function find_package_src(pkg_name::String)::Union{String, Nothing}
    pkg_dir = joinpath(PACKAGES_DIR, pkg_name)
    isdir(pkg_dir) || return nothing

    # Each package has one or more hash subdirectories; pick the first one
    entries = readdir(pkg_dir)
    isempty(entries) && return nothing

    # Use the first hash directory that contains a src/ folder
    for entry in entries
        src_dir = joinpath(pkg_dir, entry, "src")
        if isdir(src_dir)
            return src_dir
        end
    end
    return nothing
end

function collect_jl_files(src_dir::String)::Vector{String}
    files = String[]
    for (root, _, filenames) in walkdir(src_dir)
        for f in filenames
            if endswith(f, ".jl")
                push!(files, joinpath(root, f))
            end
        end
    end
    return sort(files)
end

function is_jll_package(name::String)::Bool
    return endswith(name, "_jll")
end

function main()
    if !isdir(PACKAGES_DIR)
        error("Packages directory not found: $PACKAGES_DIR")
    end

    # Step 1: Start with priority packages (in order, skip missing)
    selected = String[]
    selected_set = Set{String}()

    for pkg in PRIORITY_PACKAGES
        src = find_package_src(pkg)
        if src !== nothing
            push!(selected, pkg)
            push!(selected_set, pkg)
        else
            println("  [skip] $pkg — not found in $PACKAGES_DIR")
        end
    end
    println("Priority packages found: $(length(selected))/$(length(PRIORITY_PACKAGES))")

    # Step 2: Fill up to TARGET_PACKAGE_COUNT from remaining packages (alphabetical, skip _jll)
    all_packages = sort(readdir(PACKAGES_DIR))
    for pkg in all_packages
        length(selected) >= TARGET_PACKAGE_COUNT && break
        pkg in selected_set && continue
        is_jll_package(pkg) && continue
        src = find_package_src(pkg)
        if src !== nothing
            push!(selected, pkg)
            push!(selected_set, pkg)
        end
    end
    println("Total packages selected: $(length(selected))")

    # Step 3: Collect all .jl files from src/ of each selected package
    pkg_file_counts = Pair{String, Int}[]
    all_files = String[]

    for pkg in selected
        src = find_package_src(pkg)
        if src === nothing
            continue
        end
        files = collect_jl_files(src)
        push!(pkg_file_counts, pkg => length(files))
        append!(all_files, files)
    end

    # Step 4: Write corpus_files.txt
    files_path = joinpath(OUTPUT_DIR, "corpus_files.txt")
    open(files_path, "w") do io
        for f in all_files
            println(io, f)
        end
    end

    # Step 5: Write corpus_packages.txt
    pkgs_path = joinpath(OUTPUT_DIR, "corpus_packages.txt")
    open(pkgs_path, "w") do io
        for pkg in selected
            println(io, pkg)
        end
    end

    # Step 6: Print summary
    println()
    println("=" ^ 60)
    println("CORPUS SUMMARY")
    println("=" ^ 60)
    println("Total packages: $(length(selected))")
    println("Total .jl files: $(length(all_files))")
    println()

    # Top 10 packages by file count
    sorted_counts = sort(pkg_file_counts, by=x -> x.second, rev=true)
    println("Top 10 packages by file count:")
    for (i, (pkg, count)) in enumerate(sorted_counts[1:min(10, length(sorted_counts))])
        println("  $(lpad(i, 2)). $(rpad(pkg, 40)) $count files")
    end

    # Bottom summary
    total_from_priority = sum(count for (pkg, count) in pkg_file_counts if pkg in Set(PRIORITY_PACKAGES))
    total_from_fill = length(all_files) - total_from_priority
    println()
    println("Files from priority packages: $total_from_priority")
    println("Files from fill packages:     $total_from_fill")
    println()
    println("Written: $files_path")
    println("Written: $pkgs_path")
end

main()
