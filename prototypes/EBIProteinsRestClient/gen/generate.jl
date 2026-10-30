# Generate prototypes/EBIProteinsRestClient/src/EBIProteinsRestClient.jl, one RestClient.jl `@endpoint` per operation, from the spec snapshot in prototypes/common/:
#
#   julia --project=prototypes/common prototypes/EBIProteinsRestClient/gen/generate.jl
#
# prototypes/common/generate.jl runs this with the other custom generators, and refreshes the snapshot with --fetch.
module EBIProteinsRestClientGenerator

include(joinpath(@__DIR__, "..", "..", "common", "shared.jl"))

const GENERATOR = "prototypes/EBIProteinsRestClient/gen/generate.jl"
const OUT_PATH = normpath(joinpath(@__DIR__, "..", "src", "EBIProteinsRestClient.jl"))


# Code emission
# -------------

camel(name) = join(uppercasefirst.(split(name, '_')))

# A path or query value in an `@endpoint` URL template.
# RestClient leaves out query parameters whose value is `nothing`, and escapes path values itself.
value(name) = "{_value(self.$name)}"

function url_template(op)
    path = replace(lstrip(op.path, '/'), r"\{([^}]+)\}" => m -> value(m[2:end-1]))
    isempty(op.queryparams) && return path
    return path * "?" * join(["$(p.name)=$(value(p.name))" for p in op.queryparams], "&")
end

function emit_endpoint(io, op)
    T = camel(op.name) * "Endpoint"
    positional = [p.name for p in op.pathparams]
    op.body === nothing || push!(positional, "body")
    keywords = [p.name for p in op.queryparams]
    push!(keywords, "accept = " * default_accept(op))
    signature = op.name * "(" * join(positional, ", ") * "; " * join(keywords, ", ") * ")"
    text = operation_doc(op, signature, ("Arguments", "Query parameters"),
                         "sent as JSON, or as text if it is a `String`")
    print_docstring(io, text * "\nSee `EBIProteinsRestClient` for `accept` and the `$T` struct.")

    supertype = pageable(op) ? "EBIListEndpoint" : "EBIEndpoint"
    url = repr(url_template(op))
    op.method == "GET" || (url = ":" * lowercase(op.method) * "(" * url * ")")
    flow = op.body === nothing ? [op.name * "(" * join(positional, ", ") * ")", url] :
                                 [op.name * "(" * join(positional, ", ") * ")", "body", url]
    println(io, "@endpoint struct ", T, " <: ", supertype)
    println(io, "    ", join(flow, " -> "), " -> _responsetype(self)")
    for p in op.pathparams
        J = julia_type(p)
        println(io, "    ", p.name, "::", isempty(J) ? "Any" : J)
    end
    op.body === nothing || println(io, "    body::Any")
    for p in op.queryparams
        J = julia_type(p)
        J = isempty(J) ? "Any" : J
        println(io, "    ", p.name, p.required ? "::$J" : "::Union{Nothing, $J} = nothing")
    end
    println(io, "    accept::Union{Symbol, AbstractString, Type} = ", default_accept(op))
    println(io, "end")
end


# Runtime code
# ------------

# @BASE_URL@ and @FORMATS@ are substituted.
const RUNTIME = raw"""
@globalconfig RequestConfig("@BASE_URL@")

const MIMES = Dict(@FORMATS@)

\"\"\"
    EBIEndpoint, EBIListEndpoint

Supertypes of the generated endpoint structs.
Searches, the operations with `offset` and `size` parameters, are `EBIListEndpoint`s: their JSON results come back as a `RestClient.List`, and `nextpage` fetches the next page.
\"\"\"
abstract type EBIEndpoint <: AbstractEndpoint end
abstract type EBIListEndpoint <: ListEndpoint end
@doc (@doc EBIEndpoint) EBIListEndpoint

const Endpoints = Union{EBIEndpoint, EBIListEndpoint}

# Parameter types.
# Integers and lists the spec declares as strings accept their natural Julia types too: `taxid = 9606`, `taxid = [9606, 10090]` and `taxid = "9606,10090"` are the same.
\"\"\"
An integer the spec declares as a string, such as `taxonomy`: `9606` or `"9606"`.
\"\"\"
const IntParam = Union{Integer, AbstractString}

\"\"\"
A comma-separated list: `"TOPOLOGY,PTM"` or `["TOPOLOGY", "PTM"]`.
\"\"\"
const ListParam = Union{AbstractString, AbstractVector}

\"\"\"
A comma-separated list of integers, such as `taxid`: `9606`, `[9606, 10090]` or `"9606,10090"`.
\"\"\"
const IntListParam = Union{Integer, ListParam}

_value(::Nothing) = nothing
_value(x) = string(x)
_value(x::AbstractVector) = join(map(_value, x), ",")

\"\"\"
    defaultformat(T::Type)

The format, as a key of `MIMES`, requested when `accept` is the type `T`.
The default is `:json`, which is parsed into `T` with `JSON.parse`; the extensions that decode other formats into `T` set it, so `Vector{FASTX.FASTA.Record}` requests `:fasta`.
\"\"\"
defaultformat(::Type) = :json

\"\"\"
    TextFormat{S}

A text response format, such as FASTA or GFF, that is decoded into a type rather than returned as a `String`.
`S` is its key in `MIMES`.
Package extensions add `RestClient.interpretresponse(data, ::TextFormat{S}, ::Type{T})` methods: with FASTX loaded, `Vector{FASTX.FASTA.Record}` from `:fasta`, and with GFF3 loaded, `Vector{GFF3.Record}` from `:gff`.
\"\"\"
struct TextFormat{S} <: AbstractFormat end

RestClient.mimetype(::Type{TextFormat{S}}) where {S} = MIMES[S]

# The response format: `accept` is a shorthand, a MIME type, or a type to decode the response into.
_mime(accept::Symbol) = haskey(MIMES, accept) ? MIMES[accept] :
    throw(ArgumentError("unknown format :$accept; use one of $(join(sort!(collect(keys(MIMES))), ", ")), a MIME type string or a type"))
_mime(accept::AbstractString) = String(accept)
_mime(T::Type) = _mime(defaultformat(T))

_responsetype(e::Endpoints) = _responsetype(e.accept)
_responsetype(T::Type) = T
_responsetype(accept) = _mime(accept) == MIMES[:json] ? Any : String

RestClient.headers(e::Endpoints) = ["Accept" => _mime(e.accept)]

# JSON responses are parsed with JSON.jl, other formats are returned as text unless a type asks for them decoded, and request bodies are sent as JSON unless they are text.
RestClient.dataformat(::Endpoints, T::Type) = defaultformat(T) === :json ? JSONFormat{:json}() : TextFormat{defaultformat(T)}()
RestClient.dataformat(::Endpoints, ::Type{<:AbstractString}) = RawFormat()

# A type with no decoder for its format is rejected before the request is sent.
function RestClient.validate(e::Endpoints)
    T = _responsetype(e)
    fmt = RestClient.dataformat(e, T)
    fmt isa TextFormat || return nothing
    hasmethod(RestClient.interpretresponse, Tuple{Vector{UInt8}, typeof(fmt), Type{T}}) && return nothing
    return "no decoder from $(RestClient.mimetype(typeof(fmt))) to $T; it may need a package to be loaded, such as FASTX or GFF3"
end
RestClient.postprocess(::Request{K, <:Endpoints}, data::Vector{UInt8}) where {K} = String(data)

# A search's JSON result is a list, so wrap it in a RestClient.List that `nextpage` can continue.
RestClient.postprocess(req::Request{K, E}, data::Vector{Any}) where {K, E <: EBIListEndpoint} =
    List{Any, E}(req, data, Dict{Symbol, Any}())

RestClient.nextpage(e::EBIListEndpoint) =
    setfield(e, :offset, something(e.offset, 0) + something(e.size, 100))

# A short or empty page is the last one.
function RestClient.nextpage(list::List{T, E}) where {T, E <: EBIListEndpoint}
    length(list.items) < something(list.request.endpoint.size, 100) && return nothing
    return perform(RestClient.nextpage(list.request))
end
"""

function emit(spec, spec_bytes)
    ops = operations(spec)
    io = IOBuffer()
    header(io, GENERATOR, spec, spec_bytes, ops)
    println(io, "\"\"\"")
    println(io, "Client for the EMBL-EBI Proteins REST API, generated from its OpenAPI specification, with one RestClient.jl `@endpoint` per operation.")
    println(io, "A prototype for comparison with `EBIProteinsFunctions` and `EBIProteinsKwarg`; it needs Julia 1.11.")
    println(io)
    println(io, "Every operation in the specification is a function named after its path, for example `proteins_by_accession(\"P08069\")` for `GET /proteins/{accession}`, and an endpoint struct, here `ProteinsByAccessionEndpoint`.")
    println(io, "Path parameters are positional; query parameters are keywords with the names the API uses.")
    println(io, "Each function has a second method that takes a `RestClient.RequestConfig` first, to change the base URL, caching or timeout.")
    println(io, "Nothing is exported.")
    println(io)
    println(io, "Parameters are typed from the specification.")
    println(io, "Integers and comma-separated lists that it declares as strings also take their natural Julia types (`IntParam`, `ListParam`, `IntListParam`), so `taxid = [9606, 10090]` is sent as `taxid=9606,10090`.")
    println(io)
    println(io, "`accept` is the response format, one of the shorthands ", join(["`$(repr(s))`" for (_, s) in FORMATS], ", "),
            ", a MIME type string, or a type.")
    println(io, "JSON is parsed with `JSON.parse` and any other format is returned as a `String`.")
    println(io, "With a type, the response is decoded into it: JSON into any type `JSON.parse` can fill, for example a `JSON.@kwarg` struct with the fields you need, and other formats through package extensions.")
    println(io, "With FASTX loaded, `accept = Vector{FASTX.FASTA.Record}` (or `FASTX.FASTA.Record` for one entry) requests FASTA and returns records; with GFF3 loaded, `accept = Vector{GFF3.Record}` does the same for GFF.")
    println(io, "A type with no decoder for its format is rejected with a `RestClient.MalformedRequest` before the request is sent.")
    println(io)
    println(io, "Searches return a `RestClient.List`; `RestClient.nextpage(list)` fetches the next page, and returns `nothing` after the last one.")
    println(io, "Errors are thrown as `RestClient.ResponseError`; RestClient retries rate-limited requests and caches responses.")
    println(io)
    println(io, "Base URL: $BASE_URL")
    println(io)
    println(io, "| Function | Endpoint |")
    println(io, "|:---------|:---------|")
    for op in ops
        println(io, "| `$(op.name)` | `$(op.method) $(op.path)` |")
    end
    println(io, "\"\"\"")
    println(io, "module EBIProteinsRestClient")
    println(io)
    println(io, "using RestClient")
    println(io, "import JSON")
    println(io)
    print(io, substitute(RUNTIME))
    for op in ops
        println(io)
        emit_endpoint(io, op)
    end
    println(io)
    println(io, "end # module")
    return String(take!(io))
end

function generate(spec, bytes)
    write(OUT_PATH, emit(spec, bytes))
    println("wrote ", OUT_PATH)
end

end # module

abspath(PROGRAM_FILE) == (@__FILE__) && EBIProteinsRestClientGenerator.generate(EBIProteinsRestClientGenerator.load_spec()...)
