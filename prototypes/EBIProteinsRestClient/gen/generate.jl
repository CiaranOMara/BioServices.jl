# Generate prototypes/EBIProteinsRestClient/src/EBIProteinsRestClient.jl, one RestClient.jl `@endpoint` per operation, from the spec snapshot in prototypes/common/:
#
#   julia --project=prototypes/common prototypes/EBIProteinsRestClient/gen/generate.jl
#
# prototypes/common/generate.jl runs this with the other custom generators, and refreshes the snapshot with --fetch.
module EBIProteinsRestClientGenerator

include(joinpath(@__DIR__, "..", "..", "common", "spec.jl"))
include(joinpath(@__DIR__, "..", "..", "common", "render.jl"))

const GENERATOR = "prototypes/EBIProteinsRestClient/gen/generate.jl"
const OUT_PATH = normpath(joinpath(@__DIR__, "..", "src", "EBIProteinsRestClient.jl"))
const RUNTIME = joinpath(@__DIR__, "runtime")

"The generated module, from the spec's operations."
function render(spec, spec_bytes)
    ops = operations(spec)
    return join([
        header(GENERATOR, spec, spec_bytes, ops),
        docstring(module_doc(ops)) * "module EBIProteinsRestClient\n",
        "using RestClient\nimport JSON\n",
        "@globalconfig RequestConfig($(repr(BASE_URL)))\n\n" * mimes() * "\n" * runtime(RUNTIME, "client.jl"),
        map(endpoint, ops)...,
        "end # module\n",
    ], "\n")
end

module_doc(ops) = """
    Client for the EMBL-EBI Proteins REST API, generated from its OpenAPI specification, with one RestClient.jl `@endpoint` per operation.
    A prototype for comparison with `EBIProteinsFunctions` and `EBIProteinsKwarg`; it needs Julia 1.11.

    Every operation in the specification is a function named after its path, for example `proteins_by_accession("P08069")` for `GET /proteins/{accession}`, and an endpoint struct, here `ProteinsByAccessionEndpoint`.
    Path parameters are positional; query parameters are keywords with the names the API uses.
    Each function has a second method that takes a `RestClient.RequestConfig` first, to change the base URL, caching or timeout.
    Nothing is exported.

    Parameters are typed from the specification.
    Integers and comma-separated lists that it declares as strings also take their natural Julia types (`IntParam`, `ListParam`, `IntListParam`), so `taxid = [9606, 10090]` is sent as `taxid=9606,10090`.

    `accept` is the response format, one of the shorthands $(format_shorthands()), a MIME type string, or a type.
    JSON is parsed with `JSON.parse` and any other format is returned as a `String`.
    With a type, the response is decoded into it: JSON into any type `JSON.parse` can fill, for example a `JSON.@kwarg` struct with the fields you need, and other formats through package extensions.
    With FASTX loaded, `accept = Vector{FASTX.FASTA.Record}` (or `FASTX.FASTA.Record` for one entry) requests FASTA and returns records; with GFF3 loaded, `accept = Vector{GFF3.Record}` does the same for GFF.
    A type with no decoder for its format is rejected with a `RestClient.MalformedRequest` before the request is sent.

    Searches return a `RestClient.List`; `RestClient.nextpage(list)` fetches the next page, and returns `nothing` after the last one.
    Errors are thrown as `RestClient.ResponseError`; RestClient retries rate-limited requests and caches responses.

    Base URL: $BASE_URL

    $(table(["Function", "Endpoint"], [["`$(op.name)`", "`$(op.method) $(op.path)`"] for op in ops]))"""

"""
One operation's `@endpoint` struct.
Its first line is RestClient's shorthand, from the calling function through the body (for a POST) and the URL template to the response type, from which `@endpoint` writes the endpoint methods and the function.
"""
function endpoint(op)
    T = camel(op.name) * "Endpoint"
    call = op.name * "(" * join([[p.name for p in op.pathparams]; op.body === nothing ? String[] : ["body"]], ", ") * ")"
    url = repr(url_template(op))
    op.method == "GET" || (url = ":" * lowercase(op.method) * "(" * url * ")")
    flow = op.body === nothing ? [call, url] : [call, "body", url]
    fields = [["$(p.name)::$(something_or_any(julia_type(p)))" for p in op.pathparams];
              op.body === nothing ? String[] : ["body::Any"];
              [field(p) for p in op.queryparams];
              "accept::Union{Symbol, AbstractString, Type} = $(default_accept(op))"]
    return docstring(endpoint_doc(op, T)) *
           "@endpoint struct $T <: $(pageable(op) ? "EBIListEndpoint" : "EBIEndpoint")\n" *
           "    $(join(flow, " -> ")) -> _responsetype(self)\n" *
           join(["    $f\n" for f in fields]) *
           "end\n"
end

function endpoint_doc(op, T)
    positional = [[p.name for p in op.pathparams]; op.body === nothing ? String[] : ["body"]]
    keywords = [[p.name for p in op.queryparams]; "accept = " * default_accept(op)]
    signature = "$(op.name)($(join(positional, ", ")); $(join(keywords, ", ")))"
    doc = operation_doc(op, signature, ("Arguments", "Query parameters"), "sent as JSON, or as text if it is a `String`")
    return doc * "\nSee `EBIProteinsRestClient` for `accept` and the `$T` struct."
end

# The `@endpoint` URL template: path and query values come from the struct's fields.
# RestClient leaves out query parameters whose value is `nothing`, and escapes path values itself.
function url_template(op)
    value(name) = "{_value(self.$name)}"
    path = replace(lstrip(op.path, '/'), r"\{([^}]+)\}" => m -> value(m[2:end-1]))
    isempty(op.queryparams) && return path
    return path * "?" * join(["$(p.name)=$(value(p.name))" for p in op.queryparams], "&")
end

something_or_any(T) = isempty(T) ? "Any" : T

function generate(spec, bytes)
    write(OUT_PATH, render(spec, bytes))
    println("wrote ", OUT_PATH)
end

end # module

abspath(PROGRAM_FILE) == (@__FILE__) && EBIProteinsRestClientGenerator.generate(EBIProteinsRestClientGenerator.load_spec()...)
