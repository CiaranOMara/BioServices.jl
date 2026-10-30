# Generate prototypes/EBIProteinsKwarg/src/EBIProteinsKwarg.jl, one `JSON.@kwarg` request type per operation, from the spec snapshot in prototypes/common/:
#
#   julia --project=prototypes/common prototypes/EBIProteinsKwarg/gen/generate.jl
#
# prototypes/common/generate.jl runs this with the other custom generators, and refreshes the snapshot with --fetch.
module EBIProteinsKwargGenerator

include(joinpath(@__DIR__, "..", "..", "common", "spec.jl"))
include(joinpath(@__DIR__, "..", "..", "common", "render.jl"))

const GENERATOR = "prototypes/EBIProteinsKwarg/gen/generate.jl"
const OUT_PATH = normpath(joinpath(@__DIR__, "..", "src", "EBIProteinsKwarg.jl"))
const RUNTIME = joinpath(@__DIR__, "runtime")

"The generated module, from the spec's operations."
function render(spec, spec_bytes)
    ops = operations(spec)
    bodies = body_types(spec, ops)
    return join([
        header(GENERATOR, spec, spec_bytes, ops),
        docstring(module_doc(ops)) * "module EBIProteinsKwarg\n",
        "import HTTP\nimport JSON\nusing JSON: @kwarg, StructUtils\n",
        base_url() * "\n" * mimes() * "\n" *
        runtime(COMMON_RUNTIME, "formats.jl") * "\n" *
        runtime(COMMON_RUNTIME, "parameters.jl") * "\n" *
        runtime(COMMON_RUNTIME, "http.jl") * "\n" *
        runtime(COMMON_RUNTIME, "pages.jl"),
        runtime(RUNTIME, "endpoint.jl"),
        [body_type(spec, ref) for ref in unique(values(bodies))]...,
        [endpoint(op, get(bodies, op.name, nothing)) for op in ops]...,
        pageable_union(ops),
        runtime(RUNTIME, "paging.jl"),
        "end # module\n",
    ], "\n")
end

module_doc(ops) = """
    Client for the EMBL-EBI Proteins REST API, generated from its OpenAPI specification, with one `JSON.@kwarg` request type per operation.
    A prototype for comparison with `EBIProteinsFunctions`; it needs JSON.jl 1.x and Julia 1.10.

    Each operation is a subtype of `Endpoint{M}` named after its path, for example `ProteinsByAccession(accession = "P08069")` for `GET /proteins/{accession}`, with a keyword constructor whose keywords are the path and query parameters.
    Construct one, then:
    - `send(e; accept, parse)` runs it, and `send(e, T)` decodes the response into `T` (JSON into any `@kwarg` struct, other formats through `decode(::Format, resp, T)` methods);
    - `url(e)` is its full URL;
    - `paginate(e)` iterates over a search page by page (`Pageable` endpoints only).

    Fields are typed from the specification; integers and comma-separated lists that it declares as strings also take their natural Julia types (`IntParam`, `ListParam`, `IntListParam`).
    `accept` takes a `Format`, a MIME type string or one of $(format_shorthands()).

    Base URL: $BASE_URL

    $(table(["Type", "Endpoint"], [["`$(camel(op.name))`", "`$(op.method) $(op.path)`"] for op in ops]))"""

# The request body schema of each operation that has one, by operation name.
function body_types(spec, ops)
    bodies = Dict{String, String}()
    for op in ops
        op.body === nothing && continue
        content = spec["paths"][op.path][lowercase(op.method)]["requestBody"]["content"]
        ref = get(first(values(content))["schema"], "\$ref", nothing)
        ref === nothing || (bodies[op.name] = ref)
    end
    return bodies
end

"A `@kwarg` struct for the request body schema `ref`, which `JSON.json` serialises."
function body_type(spec, ref)
    name = schema_name(ref)
    schema = spec["components"]["schemas"][name]
    get(schema, "type", "") == "object" || error("request body $name is not an object")
    required = get(schema, "required", String[])
    fields = [field(Param(prop, "body", prop in required, schema["properties"][prop], ""))
              for prop in sort!(collect(keys(schema["properties"])))]
    return "\"Request body schema `$name`, serialised with `JSON.json`.\"\n" * kwarg_struct(name, fields)
end

"One operation's `@kwarg` struct, with field tags for its path and body fields, and its path template."
function endpoint(op, bodyref)
    T = camel(op.name)
    fields = [["$(p.name)::$(something_or_any(julia_type(p))) &(in = :path,)" for p in op.pathparams];
              op.body === nothing ? String[] : ["body::B &(in = :body,)"];
              [field(p) for p in op.queryparams]]
    accept = default_accept(op)
    return docstring(endpoint_doc(op, bodyref)) *
           kwarg_struct("$T$(op.body === nothing ? "" : "{B}") <: Endpoint{:$(op.method)}", fields) *
           "template(::Type{<:$T}) = $(repr(op.path))\n" *
           (accept == ":json" ? "" : "defaultformat(::$T) = $accept\n")
end

function endpoint_doc(op, bodyref)
    names = [[p.name for p in op.pathparams]; op.body === nothing ? String[] : ["body"]; [p.name for p in op.queryparams]]
    signature = camel(op.name) * (isempty(names) ? "()" : "(; " * join(names, ", ") * ")")
    body = bodyref === nothing ? "any value `JSON.json` can serialise" :
           "for example `$(schema_name(bodyref))(sequence = ...)`; a `String` is sent as `text/plain`, anything else as JSON"
    return operation_doc(op, signature, ("Path fields and body", "Query fields"), body)
end

something_or_any(T) = isempty(T) ? "Any" : T

"`@kwarg struct \$declaration` with `fields`, one per line."
kwarg_struct(declaration, fields) = "@kwarg struct $declaration\n" * join(["    $f\n" for f in fields]) * "end\n"

pageable_union(ops) = """
    "Endpoints that `paginate` accepts: those with `offset` and `size` fields."
    const Pageable = Union{$(join([camel(op.name) for op in ops if pageable(op)], ", "))}
    """

function generate(spec, bytes)
    write(OUT_PATH, render(spec, bytes))
    println("wrote ", OUT_PATH)
end

end # module

abspath(PROGRAM_FILE) == (@__FILE__) && EBIProteinsKwargGenerator.generate(EBIProteinsKwargGenerator.load_spec()...)
