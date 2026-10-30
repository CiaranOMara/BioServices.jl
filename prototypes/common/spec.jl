# The EBI Proteins OpenAPI spec as the prototype generators see it: the snapshot, its normalisation, and the operations parsed from it with the spec's defects patched.
# Every generator includes this file; prototypes/EBIProteinsOpenAPI/gen/generate.jl uses only the snapshot path, base URL and query-name fixups.

import Downloads
import JSON

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
