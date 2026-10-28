# Generate prototypes/EBIProteinsKwarg/src/EBIProteinsKwarg.jl, one `JSON.@kwarg` request type per operation, from the spec snapshot in prototypes/common/:
#
#   julia --project=prototypes/common prototypes/EBIProteinsKwarg/gen/generate.jl
#
# prototypes/common/generate.jl runs this and the EBIProteinsFunctions generator together, and refreshes the snapshot with --fetch.
module EBIProteinsKwargGenerator

include(joinpath(@__DIR__, "..", "..", "common", "shared.jl"))

const GENERATOR = "prototypes/EBIProteinsKwarg/gen/generate.jl"
const OUT_PATH = normpath(joinpath(@__DIR__, "..", "src", "EBIProteinsKwarg.jl"))


# Code emission
# -------------

camel(name) = join(uppercasefirst.(split(name, '_')))

function emit_body_type(io, spec, ref)
    name = schema_name(ref)
    schema = spec["components"]["schemas"][name]
    get(schema, "type", "") == "object" || error("request body $name is not an object")
    required = get(schema, "required", String[])
    println(io, "\"Request body schema `$name`, serialised with `JSON.json`.\"")
    println(io, "@kwarg struct $name")
    for prop in sort!(collect(keys(schema["properties"])))
        T = julia_type(Param(prop, "body", prop in required, schema["properties"][prop], ""))
        T = isempty(T) ? "Any" : T
        println(io, "    ", prop, prop in required ? "::$T" : "::Union{Nothing, $T} = nothing")
    end
    println(io, "end")
    return name
end

function emit_endpoint(io, op, bodytype)
    T = camel(op.name)
    params = op.body === nothing ? "" : "{B}"
    names = [p.name for p in op.pathparams]
    op.body === nothing || push!(names, "body")
    append!(names, [p.name for p in op.queryparams])
    signature = T * (isempty(names) ? "()" : "(; " * join(names, ", ") * ")")
    body = bodytype === nothing ? "any value `JSON.json` can serialise" :
           "for example `$bodytype(sequence = ...)`; a `String` is sent as `text/plain`, anything else as JSON"
    print_docstring(io, operation_doc(op, signature, ("Path fields and body", "Query fields"), body))
    println(io, "@kwarg struct ", T, params, " <: Endpoint{:", op.method, "}")
    for p in op.pathparams
        J = julia_type(p)
        println(io, "    ", p.name, "::", isempty(J) ? "Any" : J, " &(in = :path,)")
    end
    op.body === nothing || println(io, "    body::B &(in = :body,)")
    for p in op.queryparams
        J = julia_type(p)
        J = isempty(J) ? "Any" : J
        println(io, "    ", p.name, p.required ? "::$J" : "::Union{Nothing, $J} = nothing")
    end
    println(io, "end")
    println(io, "template(::Type{<:", T, "}) = ", repr(op.path))
    accept = default_accept(op)
    accept == ":json" || println(io, "defaultformat(::", T, ") = ", accept)
end


# Runtime code
# ------------

# Common to both prototypes; EBIProteinsFunctions' generator has its own copy, so each can change on its own.
# @BASE_URL@ and @FORMATS@ are substituted.
const COMMON_RUNTIME = raw"""
const BASE_URL = "@BASE_URL@"

const MIMES = Dict(@FORMATS@)

\"\"\"
    Format{S}

A response format, the type `decode` dispatches on.
`S` is a shorthand, one of the keys of `MIMES`, or any other MIME type as a `Symbol`.
`Format(:fasta)` and `Format("text/x-fasta")` are the same; an unknown shorthand throws an `ArgumentError` before any request is made.
\"\"\"
struct Format{S} end

Format(f::Format) = f
Format(s::Symbol) = haskey(MIMES, s) ? Format{s}() :
    throw(ArgumentError("unknown format :$s; use one of $(join(sort!(collect(keys(MIMES))), ", ")) or a MIME type string"))
function Format(m::AbstractString)
    for (s, v) in MIMES
        v == m && return Format{s}()
    end
    return Format{Symbol(m)}()
end

mime(::Format{S}) where {S} = get(MIMES, S, String(S))

\"\"\"
    decode(::Format, resp::HTTP.Response)

Turn a response body into a value.
JSON is parsed with `JSON.parse`; any other format is returned as a `String`.
Add methods to decode a format into richer types.
\"\"\"
decode(::Format, resp) = occursin("json", HTTP.header(resp, "Content-Type")) ? _json(resp) : String(resp.body)
decode(::Format{:json}, resp) = _json(resp)

_json(resp) = (text = String(resp.body); isempty(text) ? nothing : JSON.parse(text))

\"\"\"
    decode(::Format, resp::HTTP.Response, T::Type)

Decode a response body into a value of type `T`.
Package extensions add methods, for example `Vector{FASTX.FASTA.Record}` from `:fasta` once FASTX is loaded, and `Vector{GFF3.Record}` from `:gff` once GFF3 is loaded.
A request asking for a type with no method for its format throws an `ArgumentError` before it is sent.
\"\"\"
decode(::Format, ::Any, ::Type)

function _decodable(f::Format, ::Type{T}) where {T}
    hasmethod(decode, Tuple{typeof(f), HTTP.Response, Type{T}}) && return
    throw(ArgumentError("no decoder from $(mime(f)) to $T; it may need a package to be loaded, such as FASTX or GFF3"))
end
_decodable(::Format, ::Bool) = nothing

\"\"\"
    defaultformat(T::Type)

The format requested to decode a response into `T` when no `accept` is given.
The extensions that add `decode` methods set it, so `Vector{FASTX.FASTA.Record}` requests `:fasta`.
\"\"\"
defaultformat(::Type) = :json

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

_value(x) = string(x)
_value(x::AbstractVector) = join(map(_value, x), ",")

_segment(x) = HTTP.escapeuri(_value(x))

_query(pairs::Pair...) = Pair{String, String}[k => _value(v) for (k, v) in pairs if v !== nothing]

_url(path, query) = BASE_URL * path * (isempty(query) ? "" : "?" * HTTP.escapeuri(query))

# HTTP 429 is retried, honouring Retry-After.
function _request(method, url, headers; tries = 4, kwargs...)
    for i in 1:tries
        try
            return HTTP.request(method, url, headers; kwargs...)
        catch err
            (err isa HTTP.StatusError && err.status == 429 && i < tries) || rethrow()
            wait = tryparse(Int, HTTP.header(err.response, "Retry-After", ""))
            sleep(something(wait, 2^i))
        end
    end
end

# Request body encoding, by the type of the body.
_body!(headers, kwargs, ::Nothing) = kwargs
function _body!(headers, kwargs, body::AbstractString)
    push!(headers, "Content-Type" => "text/plain")
    kwargs[:body] = String(body)
    return kwargs
end
function _body!(headers, kwargs, body)
    push!(headers, "Content-Type" => "application/json")
    kwargs[:body] = JSON.json(body)
    return kwargs
end

_lastpage(page, size) = page === nothing || isempty(page)
_fullpage(page, size) = !(page isa AbstractVector) || length(page) >= size
"""

const KWARG_RUNTIME = raw"""
\"\"\"
    Endpoint{M}

Supertype of the request types, one per operation; `M` is the HTTP method as a `Symbol`.
Fields tagged `&(in = :path,)` fill the path template, the field tagged `&(in = :body,)` is the request body and every other field that is not `nothing` is a query parameter.
\"\"\"
abstract type Endpoint{M} end

method(::Endpoint{M}) where {M} = String(M)
defaultformat(::Endpoint) = :json

_in(::Type{E}, field) where {E} = get(StructUtils.fieldtags(StructUtils.DefaultStyle(), E, field), :in, :query)
_fields(::Type{E}, location) where {E} = filter(f -> _in(E, f) === location, fieldnames(E))

path(e::E) where {E<:Endpoint} =
    replace(template(E), r"\{\w+\}" => m -> _segment(getfield(e, Symbol(m[2:end-1]))))
query(e::E) where {E<:Endpoint} = _query((String(f) => getfield(e, f) for f in _fields(E, :query))...)
body(e::E) where {E<:Endpoint} = (b = _fields(E, :body); isempty(b) ? nothing : getfield(e, only(b)))
url(e::Endpoint) = _url(path(e), query(e))

\"\"\"
    send(e::Endpoint; accept = defaultformat(e), parse = true)
    send(e::Endpoint, T::Type; accept = defaultformat(T))

Run a request.
With `parse = true` the response is passed to `decode`; otherwise the `HTTP.Response` is returned.
With a type, the response is decoded into `T`: JSON with `JSON.parse(body, T)`, for example into a `@kwarg` struct with the fields you need, and other formats by the `decode(::Format, resp, T)` methods that are defined.
\"\"\"
send(e::Endpoint; accept = defaultformat(e), parse::Bool = true) = _send(e, Format(accept), parse)
send(e::Endpoint, ::Type{T}; accept = defaultformat(T)) where {T} = _send(e, Format(accept), T)

decode(::Format{:json}, resp, ::Type{T}) where {T} = JSON.parse(String(resp.body), T)

function _send(e::Endpoint, f::Format, parse)
    _decodable(f, parse)
    headers = ["Accept" => mime(f)]
    kwargs = _body!(headers, Dict{Symbol, Any}(), body(e))
    q = query(e)
    isempty(q) || (kwargs[:query] = q)
    resp = _request(method(e), BASE_URL * path(e), headers; kwargs...)
    return _result(e, f, resp, parse)
end

_result(e, f, resp, parse::Bool) = parse ? decode(e, f, resp) : resp
_result(e, f, resp, ::Type{T}) where {T} = decode(e, f, resp, T)

\"\"\"
    decode(e::Endpoint, f::Format, resp::HTTP.Response)

Called by `send` with `parse = true`.
The default dispatches on the format alone; a method such as `decode(::ProteinsByAccession, ::Format{:fasta}, resp)` overrides it for one endpoint.
\"\"\"
decode(::Endpoint, f::Format, resp) = decode(f, resp)
decode(::Endpoint, f::Format, resp, ::Type{T}) where {T} = decode(f, resp, T)

# A copy of `e` with some fields replaced, through the keyword constructor @kwarg defines.
_with(e::E; kwargs...) where {E<:Endpoint} =
    Base.typename(E).wrapper(; (f => getfield(e, f) for f in fieldnames(E))..., kwargs...)
"""

const KWARG_PAGING = raw"""
\"\"\"
    Pages{E<:Endpoint, F<:Format}

Iterator over the pages of a search, returned by `paginate`.
\"\"\"
struct Pages{E<:Endpoint, F<:Format}
    endpoint::E
    format::F
    offset::Int
    size::Int
end

\"\"\"
    paginate(e::Endpoint; accept = defaultformat(e))

Iterate over a search one decoded page at a time, starting at its `offset` (default 0) with pages of its `size` (default 100), until a page comes back short or empty.
Only endpoints with `offset` and `size` fields (`Pageable`) have a method.

    for page in paginate(Proteins(gene = "INS", reviewed = true, size = 50))
        ...
    end
\"\"\"
paginate(e::Pageable; accept = defaultformat(e)) =
    Pages(e, Format(accept), something(e.offset, 0), something(e.size, 100))

Base.IteratorSize(::Type{<:Pages}) = Base.SizeUnknown()

function Base.iterate(p::Pages, offset = p.offset)
    offset === nothing && return nothing
    page = _send(_with(p.endpoint; offset, size = p.size), p.format, true)
    _lastpage(page, p.size) && return nothing
    return page, _fullpage(page, p.size) ? offset + p.size : nothing
end
"""

function emit(spec, spec_bytes)
    ops = operations(spec)
    io = IOBuffer()
    header(io, GENERATOR, spec, spec_bytes, ops)
    println(io, "\"\"\"")
    println(io, "Client for the EMBL-EBI Proteins REST API, generated from its OpenAPI specification, with one `JSON.@kwarg` request type per operation.")
    println(io, "A prototype for comparison with `EBIProteinsFunctions`; it needs JSON.jl 1.x and Julia 1.10.")
    println(io)
    println(io, "Each operation is a subtype of `Endpoint{M}` named after its path, for example `ProteinsByAccession(accession = \"P08069\")` for `GET /proteins/{accession}`, with a keyword constructor whose keywords are the path and query parameters.")
    println(io, "Construct one, then:")
    println(io, "- `send(e; accept, parse)` runs it, and `send(e, T)` decodes the response into `T` (JSON into any `@kwarg` struct, other formats through `decode(::Format, resp, T)` methods);")
    println(io, "- `url(e)` is its full URL;")
    println(io, "- `paginate(e)` iterates over a search page by page (`Pageable` endpoints only).")
    println(io)
    println(io, "Fields are typed from the specification; integers and comma-separated lists that it declares as strings also take their natural Julia types (`IntParam`, `ListParam`, `IntListParam`).")
    println(io, "`accept` takes a `Format`, a MIME type string or one of ",
            join(["`$(repr(s))`" for (_, s) in FORMATS], ", "), ".")
    println(io)
    println(io, "Base URL: $BASE_URL")
    println(io)
    println(io, "| Type | Endpoint |")
    println(io, "|:-----|:---------|")
    for op in ops
        println(io, "| `$(camel(op.name))` | `$(op.method) $(op.path)` |")
    end
    println(io, "\"\"\"")
    println(io, "module EBIProteinsKwarg")
    println(io)
    println(io, "import HTTP")
    println(io, "import JSON")
    println(io, "using JSON: @kwarg, StructUtils")
    println(io)
    print(io, substitute(COMMON_RUNTIME))
    println(io)
    print(io, KWARG_RUNTIME)
    bodytypes = Dict{String, String}()
    for op in ops
        op.body === nothing && continue
        content = spec["paths"][op.path][lowercase(op.method)]["requestBody"]["content"]
        ref = get(first(values(content))["schema"], "\$ref", nothing)
        ref === nothing && continue
        haskey(bodytypes, ref) && continue
        println(io)
        bodytypes[ref] = emit_body_type(io, spec, ref)
    end
    for op in ops
        println(io)
        bodytype = nothing
        if op.body !== nothing
            content = spec["paths"][op.path][lowercase(op.method)]["requestBody"]["content"]
            bodytype = get(bodytypes, get(first(values(content))["schema"], "\$ref", ""), nothing)
        end
        emit_endpoint(io, op, bodytype)
    end
    println(io)
    println(io, "\"Endpoints that `paginate` accepts: those with `offset` and `size` fields.\"")
    println(io, "const Pageable = Union{", join([camel(op.name) for op in ops if pageable(op)], ", "), "}")
    println(io)
    print(io, KWARG_PAGING)
    println(io)
    println(io, "end # module")
    return String(take!(io))
end

function generate(spec, bytes)
    write(OUT_PATH, emit(spec, bytes))
    println("wrote ", OUT_PATH)
end

end # module

abspath(PROGRAM_FILE) == (@__FILE__) && EBIProteinsKwargGenerator.generate(EBIProteinsKwargGenerator.load_spec()...)
