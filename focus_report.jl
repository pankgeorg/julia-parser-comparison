const JS = Base.JuliaSyntax
const TS_BIN = "/home/pgeorgakopoulos/.nvm/versions/node/v24.13.1/bin/tree-sitter"

function has_js_error(node)
    JS.kind(node) == JS.K"error" && return true
    cs = JS.children(node)
    cs === nothing && return false
    return any(has_js_error, cs)
end

function main()
    files = filter(!isempty, strip.(readlines(joinpath(@__DIR__, "corpus_focus.txt"))))
    println("Focus corpus: $(length(files)) files")

    pkg_stats = Dict{String,Vector{Int}}()  # [total, ts_only_err]

    for (i, path) in enumerate(files)
        m = match(r"packages/([^/]+)/", path)
        pkg = m === nothing ? "unknown" : m.captures[1]
        if !haskey(pkg_stats, pkg)
            pkg_stats[pkg] = [0, 0]
        end

        content = try
            read(path, String)
        catch
            continue
        end

        js_err = try
            tree = JS.parseall(JS.SyntaxNode, content; ignore_warnings=true)
            has_js_error(tree)
        catch
            true
        end

        ts_err = try
            out = read(pipeline(`$TS_BIN parse $path`, stderr=devnull), String)
            occursin("ERROR", out) || occursin("MISSING", out)
        catch
            true
        end

        pkg_stats[pkg][1] += 1
        if ts_err && !js_err
            pkg_stats[pkg][2] += 1
        end

        if i % 200 == 0
            println("  [$i/$(length(files))]")
        end
    end

    total_sum = 0
    fail_sum = 0

    println()
    println(rpad("Package", 40), rpad("Total", 8), rpad("TS-fail", 8), "TS-clean%")
    println("-"^65)

    for (pkg, s) in sort(collect(pkg_stats), by=x->-x[2][2])
        pct = round((s[1] - s[2]) / s[1] * 100, digits=1)
        println(rpad(pkg, 40), rpad(s[1], 8), rpad(s[2], 8), pct, "%")
        total_sum += s[1]
        fail_sum += s[2]
    end

    println("-"^65)
    pct = round((total_sum - fail_sum) / total_sum * 100, digits=1)
    println(rpad("TOTAL", 40), rpad(total_sum, 8), rpad(fail_sum, 8), pct, "%")
end

main()
