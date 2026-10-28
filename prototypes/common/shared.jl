# Shared by the prototype generators: the spec snapshot, its normalisation and parsing, and the docstring helpers that only depend on the spec.
# Each prototype's generator includes this file:
#
# - prototypes/EBIProteinsOpenAPI/gen/generate.jl, for the snapshot path and the query-name fixups
# - prototypes/EBIProteinsFunctions/gen/generate.jl
# - prototypes/EBIProteinsKwarg/gen/generate.jl
#
# The EBIProteinsFunctions and EBIProteinsKwarg generators add their own code emission and runtime, and prototypes/common/generate.jl runs both.

import Downloads
import JSON
import SHA

const SPEC_URL = "https://www.ebi.ac.uk/proteins/api/openapi.json"
# The spec has no `servers` entry, so the base URL is supplied here.
const BASE_URL = "https://www.ebi.ac.uk/proteins/api"
const SPEC_PATH = joinpath(@__DIR__, "openapi.json")

# Defects in the published spec, patched at generation time (the snapshot stays as published).
# Some query parameters carry their description as their `name`; these are the names the service actually accepts.
# An unlisted invalid name stops the generator.
const QUERY_NAME_FIXUPS = [
    "Category type(s):" => "categories",
    "Feature type(s):" => "types",
    "PTM Confidence score(s):" => "confidence_score",
]

# Response formats with a Symbol shorthand in the generated client.
const FORMATS = [
    "application/json" => :json,
    "application/xml" => :xml,
    "text/x-fasta" => :fasta,
    "text/x-flatfile" => :flatfile,
    "text/x-gff" => :gff,
    "text/x-peff" => :peff,
]


# Normalisation
# -------------

function write_sorted_json(io::IO, x, indent::Int = 0)
    pad = "  "^(indent + 1)
    if x isa AbstractDict
        if isempty(x)
            print(io, "{}")
            return
        end
        println(io, "{")
        ks = sort!(collect(keys(x)))
        for (i, k) in enumerate(ks)
            print(io, pad, JSON.json(k), ": ")
            write_sorted_json(io, x[k], indent + 1)
            println(io, i == length(ks) ? "" : ",")
        end
        print(io, "  "^indent, "}")
    elseif x isa AbstractVector
        if isempty(x)
            print(io, "[]")
            return
        end
        println(io, "[")
        for (i, v) in enumerate(x)
            print(io, pad)
            write_sorted_json(io, v, indent + 1)
            println(io, i == length(x) ? "" : ",")
        end
        print(io, "  "^indent, "]")
    else
        print(io, JSON.json(x))
    end
end

normalise(text::AbstractString) = sprint(write_sorted_json, JSON.parse(text)) * "\n"


# Spec model
# ----------

struct Param
    name::String
    location::String
    required::Bool
    schema::Dict{String, Any}
    description::String
end

struct Operation
    method::String
    path::String
    name::String
    summary::String
    description::String
    operation_id::String
    tags::Vector{String}
    deprecated::Bool
    pathparams::Vector{Param}
    queryparams::Vector{Param}
    body::Union{Nothing, String}
    formats::Vector{String}
    response::String
end

template_names(path) = [m[1] for m in eachmatch(r"\{([^}]+)\}", path)]

words(s) = filter(!isempty, split(lowercase(s), r"[^a-z0-9]+"))

# "/coordinates/location/{accession}:{pStart}-{pEnd}" => "coordinates_location_by_accession_pstart_pend"
function function_name(path)
    path == "/" && return "root"
    parts = String[]
    for seg in split(strip(path, '/'), '/')
        names = template_names(seg)
        if isempty(names)
            append!(parts, words(seg))
        else
            push!(parts, "by")
            foreach(n -> append!(parts, words(n)), names)
            append!(parts, words(replace(seg, r"\{[^}]+\}" => " ")))
        end
    end
    return join(parts, "_")
end

schema_name(ref) = last(split(ref, '/'))

function describe_schema(s)
    haskey(s, "\$ref") && return schema_name(s["\$ref"])
    get(s, "type", "") == "array" && return "Vector{" * describe_schema(get(s, "items", Dict())) * "}"
    return get(s, "type", "")
end

function fix_query_name(name, path)
    Base.isidentifier(name) && return name
    for (prefix, fixed) in QUERY_NAME_FIXUPS
        startswith(name, prefix) && return fixed
    end
    error("query parameter of $path has an invalid name; add it to QUERY_NAME_FIXUPS: $(repr(name))")
end

function parse_operation(path, method, op)
    tnames = template_names(path)
    pathparams = Param[]
    queryparams = Param[]
    for p in get(op, "parameters", [])
        desc = get(p, "description", "")
        schema = get(p, "schema", Dict{String, Any}())
        if p["in"] == "path"
            # Some path parameters are named differently from the template; match by position.
            name = tnames[length(pathparams) + 1]
            push!(pathparams, Param(name, "path", true, schema, desc))
        elseif p["in"] == "query"
            name = fix_query_name(p["name"], path)
            if name != p["name"] && isempty(desc)
                desc = p["name"]
            end
            push!(queryparams, Param(name, "query", get(p, "required", false), schema, desc))
        else
            error("unsupported parameter location $(p["in"]) in $method $path")
        end
    end
    length(pathparams) == length(tnames) || error("$method $path: path parameters do not match the template")
    for p in pathparams
        Base.isidentifier(p.name) || error("$method $path: path parameter $(repr(p.name)) is not an identifier")
    end

    body = nothing
    if haskey(op, "requestBody")
        content = op["requestBody"]["content"]
        body = join(sort!(collect(keys(content))), ", ") * " (" * describe_schema(first(values(content))["schema"]) * ")"
    end

    responses = op["responses"]
    ok = get(responses, "200", get(responses, "default", Dict{String, Any}()))
    content = get(ok, "content", Dict{String, Any}())
    formats = sort!(collect(keys(content)))
    response = isempty(formats) ? "" : describe_schema(get(content[formats[1]], "schema", Dict()))

    return Operation(uppercase(method), path, function_name(path),
                     strip(get(op, "summary", "")), strip(get(op, "description", "")),
                     get(op, "operationId", ""), get(op, "tags", String[]),
                     get(op, "deprecated", false), pathparams, queryparams, body, formats, response)
end

function operations(spec)
    ops = Operation[]
    for path in sort!(collect(keys(spec["paths"])))
        item = spec["paths"][path]
        for method in sort!(collect(keys(item)))
            method in ("get", "post", "put", "delete", "patch", "head") || error("unsupported key $method in $path")
            push!(ops, parse_operation(path, method, item[method]))
        end
    end
    # Paths such as /proteomics-ptm/{accession} and /proteomics/ptm/{accession} map to the same name; the deprecated one of a pair gets a suffix.
    for i in eachindex(ops)
        clash = any(j -> j != i && ops[j].name == ops[i].name, eachindex(ops))
        if clash && ops[i].deprecated
            o = ops[i]
            ops[i] = Operation(o.method, o.path, o.name * "_deprecated", o.summary, o.description,
                               o.operation_id, o.tags, o.deprecated, o.pathparams, o.queryparams,
                               o.body, o.formats, o.response)
        end
    end
    names = [o.name for o in ops]
    dups = sort!(unique(filter(n -> count(==(n), names) > 1, names)))
    isempty(dups) || error("generated function names clash: $(join(dups, ", "))")
    return ops
end


# Code emission
# -------------

# Text placed inside a "..." docstring.
function doctext(s)
    s = replace(s, "\r\n" => "\n")
    s = replace(s, "\\" => "\\\\")
    s = replace(s, "\$" => "\\\$")
    s = replace(s, "\"" => "\\\"")
    return join(rstrip.(split(s, '\n')), "\n")
end

function default_accept(op)
    "application/json" in op.formats && return ":json"
    isempty(op.formats) && return ":json"
    f = op.formats[1]
    for (mime, sym) in FORMATS
        mime == f && return repr(sym)
    end
    return repr(f)
end

# The Julia type a parameter accepts, or "" for no restriction.
# Many string parameters are integers or comma-separated lists in disguise (`taxid` has pattern ^[0-9]+(,[0-9]+)*$), so those also accept an Integer or a Vector; the aliases are defined in COMMON_RUNTIME.
function julia_type(p)
    s = p.schema
    t = get(s, "type", "")
    t == "integer" && return "Integer"
    t == "number" && return "Real"
    t == "boolean" && return "Bool"
    t == "array" && return "AbstractVector"
    t == "string" || return ""
    pattern = get(s, "pattern", "")
    pattern == "true|false" && return "Bool"
    numeric = startswith(lstrip(pattern, '^'), "[0-9]+")
    if occursin("(,", pattern)
        return numeric ? "IntListParam" : "ListParam"
    end
    return numeric ? "IntParam" : "AbstractString"
end

optional_type(T) = isempty(T) ? "" : "::Union{Nothing, $T}"
required_type(T) = isempty(T) ? "" : "::$T"

function param_doc(p)
    s = p.schema
    bits = String[]
    t = get(s, "type", "")
    isempty(t) || push!(bits, haskey(s, "format") ? "$t/$(s["format"])" : t)
    p.required && p.location == "query" && push!(bits, "required")
    haskey(s, "default") && push!(bits, "default `$(JSON.json(s["default"]))`")
    haskey(s, "enum") && push!(bits, "one of " * join(["`$(v)`" for v in s["enum"]], ", "))
    haskey(s, "pattern") && push!(bits, "pattern `$(s["pattern"])`")
    T = julia_type(p)
    line = "- `$(p.name)$(required_type(T))`" * (isempty(bits) ? "" : " (spec: " * join(bits, "; ") * ")")
    isempty(p.description) || (line *= ": " * replace(strip(p.description), r"\s*\n\s*" => " "))
    return line
end

pageable(op) = op.method == "GET" && all(n -> any(p -> p.name == n, op.queryparams), ("offset", "size"))

# The docstring body shared by both generators; `body` describes the request body argument.
function operation_doc(op, signature, headings, body)
    doc = IOBuffer()
    println(doc, "    ", signature)
    println(doc)
    isempty(op.summary) || println(doc, doctext(op.summary), "\n")
    isempty(op.description) || op.description == op.summary || println(doc, doctext(op.description), "\n")
    tag = isempty(op.tags) ? "" : ", tag `$(op.tags[1])`"
    println(doc, "`$(op.method) $(op.path)` (operationId `$(op.operation_id)`$tag)")
    op.deprecated && println(doc, "\n**Deprecated** in the API specification.")
    if !isempty(op.pathparams) || op.body !== nothing
        println(doc, "\n# ", headings[1])
        foreach(p -> println(doc, doctext(param_doc(p))), op.pathparams)
        op.body === nothing || println(doc, "- `body`: request body, $(doctext(op.body)); ", body)
    end
    if !isempty(op.queryparams)
        println(doc, "\n# ", headings[2])
        foreach(p -> println(doc, doctext(param_doc(p))), op.queryparams)
    end
    println(doc, "\n# Response")
    listed = isempty(op.formats) ? "none" : join(["`$f`" for f in op.formats], ", ")
    print(doc, "Formats listed in the spec: $listed.")
    isempty(op.response) || print(doc, "\nJSON schema: `$(op.response)`.")
    pageable(op) && print(doc, "\nSearches can be iterated page by page with `paginate`.")
    return String(take!(doc))
end

function print_docstring(io, text)
    println(io, "\"\"\"")
    println(io, text)
    println(io, "\"\"\"")
end

function header(io, generator, spec, spec_bytes, ops)
    info = spec["info"]
    println(io, "# This file is generated by ", generator, " from prototypes/common/openapi.json.")
    println(io, "# Do not edit it.")
    println(io, "# Spec: ", info["title"], " ", info["version"], " (OpenAPI ", spec["openapi"], "), ",
            length(ops), " operations, sha256 ", bytes2hex(SHA.sha256(spec_bytes)))
    println(io)
end

# The runtime code each generator emits has @BASE_URL@ and @FORMATS@ placeholders.
function substitute(runtime)
    s = replace(runtime, "@BASE_URL@" => BASE_URL)
    return replace(s, "@FORMATS@" => join(["$(repr(s)) => $(repr(m))" for (m, s) in FORMATS], ", "))
end


# Snapshot
# --------

function fetch_spec()
    live = String(take!(Downloads.download(SPEC_URL, IOBuffer())))
    write(SPEC_PATH, normalise(live))
    println("wrote ", SPEC_PATH)
end

# The parsed snapshot and its bytes (for the checksum in generated headers).
function load_spec()
    bytes = read(SPEC_PATH)
    text = String(copy(bytes))
    normalise(text) == text || error("$SPEC_PATH is not normalised; run prototypes/common/generate.jl --fetch or normalise it")
    return JSON.parse(text), bytes
end
