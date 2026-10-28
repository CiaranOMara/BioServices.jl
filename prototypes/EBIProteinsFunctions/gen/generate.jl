# Generate prototypes/EBIProteinsFunctions/src/EBIProteinsFunctions.jl, one keyword function per operation, from the spec snapshot in prototypes/common/:
#
#   julia --project=prototypes/common prototypes/EBIProteinsFunctions/gen/generate.jl
#
# prototypes/common/generate.jl runs this, and refreshes the snapshot with --fetch.
module EBIProteinsFunctionsGenerator

include(joinpath(@__DIR__, "..", "..", "common", "shared.jl"))

const GENERATOR = "prototypes/EBIProteinsFunctions/gen/generate.jl"
const OUT_PATH = normpath(joinpath(@__DIR__, "..", "src", "EBIProteinsFunctions.jl"))


# Code emission
# -------------

function path_expr(op)
    pieces = String[]
    last = 1
    for m in eachmatch(r"\{([^}]+)\}", op.path)
        lit = op.path[last:prevind(op.path, m.offset)]
        isempty(lit) || push!(pieces, repr(lit))
        push!(pieces, "_segment($(m[1]))")
        last = m.offset + ncodeunits(m.match)
    end
    lit = op.path[last:end]
    isempty(lit) || push!(pieces, repr(lit))
    return length(pieces) == 1 ? pieces[1] : "string(" * join(pieces, ", ") * ")"
end

function emit_operation(io, op)
    positional = [p.name * required_type(julia_type(p)) for p in op.pathparams]
    op.body === nothing || push!(positional, "body")
    kws = String[]
    for p in op.queryparams
        T = julia_type(p)
        push!(kws, p.required ? p.name * required_type(T) : p.name * optional_type(T) * " = nothing")
    end
    push!(kws, "accept = nothing", "parse::Union{Bool, Type} = true", "send::Bool = true")
    signature = op.name * "(" * join(positional, ", ") * "; " * join(kws, ", ") * ")"

    shortpos = [p.name for p in op.pathparams]
    op.body === nothing || push!(shortpos, "body")
    shortkw = [p.name for p in op.queryparams]
    push!(shortkw, "accept = nothing", "parse = true", "send = true")
    short = op.name * "(" * join(shortpos, ", ") * "; " * join(shortkw, ", ") * ")"
    text = operation_doc(op, short, ("Arguments", "Query parameters"),
                         "a `String` is sent as `text/plain`, anything else as JSON")
    print_docstring(io, text * "\nWithout `accept` or a `parse` type, `$(default_accept(op))` is requested.\n" *
                    "See `EBIProteinsFunctions` for `accept`, `parse` and `send`.")

    println(io, "function ", signature)
    query = "_query(" * join(["$(repr(p.name)) => $(p.name)" for p in op.queryparams], ", ") * ")"
    bodyarg = op.body === nothing ? "" : ", body"
    println(io, "    req = Request{:", op.name, "}(", repr(op.method), ", ", path_expr(op), ", ", query,
            ", _accept(accept, parse, ", default_accept(op), ")", bodyarg, ")")
    println(io, "    return send ? _send(req, parse) : req")
    println(io, "end")
end


# Runtime code
# ------------

# The runtime the generated client needs, emitted into it.
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

function _getquery(query, key, default)
    i = findfirst(p -> first(p) == key, query)
    return i === nothing ? default : Base.parse(Int, last(query[i]))
end

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

const FUNCTIONS_RUNTIME = raw"""
\"\"\"
    Request{Op, F<:Format, B}

A prepared call: operation `Op` (the generated function's name as a `Symbol`), response format `F` and request body type `B` (`Nothing` when there is none).
Every operation builds one; call it with `send = false` to get the request instead of the response, then run it with `send`.
`url(req)` is the full URL.
`decode` dispatches on the whole type, so its handling can be changed for one operation and format.
\"\"\"
struct Request{Op, F<:Format, B}
    method::String
    path::String
    query::Vector{Pair{String, String}}
    body::B
end

Request{Op}(method, path, query, format::F, body::B = nothing) where {Op, F<:Format, B} =
    Request{Op, F, B}(method, path, query, body)

operation(::Request{Op}) where {Op} = Op
format(::Request{Op, F}) where {Op, F} = F()
url(req::Request) = _url(req.path, req.query)

Base.show(io::IO, req::Request) =
    print(io, "Request{", repr(operation(req)), "}(", req.method, " ", url(req), ", Accept: ", mime(format(req)), ")")

\"\"\"
    send(req::Request; parse = true)

Run a request made with `send = false`.
With `parse = true` the response is passed to `decode`; otherwise the `HTTP.Response` is returned.
\"\"\"
send(req::Request; parse::Union{Bool, Type} = true) = _send(req, parse)

# The format requested: `accept` if given, otherwise the one for the `parse` type, otherwise the operation's default.
_accept(accept, parse, default) = Format(accept)
_accept(::Nothing, ::Type{T}, default) where {T} = Format(defaultformat(T))
_accept(::Nothing, ::Bool, default) = Format(default)

function _send(req::Request, parse)
    _decodable(format(req), parse)
    headers = ["Accept" => mime(format(req))]
    kwargs = _body!(headers, Dict{Symbol, Any}(), req.body)
    isempty(req.query) || (kwargs[:query] = req.query)
    resp = _request(req.method, BASE_URL * req.path, headers; kwargs...)
    return _result(req, resp, parse)
end

_result(req, resp, parse::Bool) = parse ? decode(req, resp) : resp
_result(req, resp, ::Type{T}) where {T} = decode(req, resp, T)

\"\"\"
    decode(req::Request, resp::HTTP.Response)
    decode(req::Request, resp::HTTP.Response, T::Type)

Called by `send` with `parse = true`, or with `parse = T`.
The default dispatches on the format alone; a method such as `decode(::Request{:proteins_by_accession, Format{:fasta}}, resp)` overrides it for one operation.
\"\"\"
decode(req::Request, resp) = decode(format(req), resp)
decode(req::Request, resp, ::Type{T}) where {T} = decode(format(req), resp, T)

_page(req::Request{Op, F, B}, offset, size) where {Op, F, B} =
    Request{Op, F, B}(req.method, req.path,
                      [filter(p -> !(first(p) in ("offset", "size")), req.query); "offset" => string(offset); "size" => string(size)],
                      req.body)
"""

const FUNCTIONS_PAGING = raw"""
\"\"\"
    Pages{R<:Request}

Iterator over the pages of a search, returned by `paginate`.
\"\"\"
struct Pages{R<:Request}
    request::R
    offset::Int
    size::Int
end

\"\"\"
    paginate(req::Request)

Iterate over a search one decoded page at a time, starting at the request's `offset` (default 0) with pages of its `size` (default 100), until a page comes back short or empty.
Only requests from operations with `offset` and `size` parameters (`Pageable`) have a method.

    for page in paginate(proteins(gene = "INS", reviewed = true, size = 50, send = false))
        ...
    end
\"\"\"
paginate(req::Pageable) = Pages(req, _getquery(req.query, "offset", 0), _getquery(req.query, "size", 100))

Base.IteratorSize(::Type{<:Pages}) = Base.SizeUnknown()

function Base.iterate(p::Pages, offset = p.offset)
    offset === nothing && return nothing
    page = _send(_page(p.request, offset, p.size), true)
    _lastpage(page, p.size) && return nothing
    return page, _fullpage(page, p.size) ? offset + p.size : nothing
end
"""

function emit(spec, spec_bytes)
    ops = operations(spec)
    io = IOBuffer()
    header(io, GENERATOR, spec, spec_bytes, ops)
    println(io, "\"\"\"")
    println(io, "Client for the EMBL-EBI Proteins REST API, generated from its OpenAPI specification, with one keyword function per operation.")
    println(io, "A prototype for comparison with `EBIProteinsOpenAPI`.")
    println(io)
    println(io, "Every operation in the specification is a function named after its path, for example `proteins_by_accession(\"P08069\")` for `GET /proteins/{accession}`.")
    println(io, "Path parameters are positional; query parameters are keywords with the names the API uses.")
    println(io, "Nothing is exported.")
    println(io)
    println(io, "Parameters are typed from the specification.")
    println(io, "Integers and comma-separated lists that it declares as strings also take their natural Julia types (`IntParam`, `ListParam`, `IntListParam`), so `taxid = [9606, 10090]` is sent as `taxid=9606,10090`.")
    println(io)
    println(io, "All functions accept three further keywords:")
    println(io, "- `accept`: the response format, a `Format`, a MIME type string or one of the shorthands ",
            join(["`$(repr(s))`" for (_, s) in FORMATS], ", "), ".")
    println(io, "  Without it, `defaultformat(T)` is requested when `parse` is a type, and otherwise `:json` where the specification lists it.")
    println(io, "  Other MIME types are sent as given, because the service supports formats the specification does not always list.")
    println(io, "- `parse`: when `true` (the default), the response is passed to `decode`, which parses JSON with `JSON.parse` into `Dict`s and `Vector`s and returns any other format as a `String`; when `false`, the `HTTP.Response` is returned.")
    println(io, "  When it is a type, the response is decoded into that type by `decode(::Format, resp, T)`.")
    println(io, "  Package extensions add the methods: with FASTX loaded, `parse = Vector{FASTX.FASTA.Record}` (or `FASTX.FASTA.Record` for one entry) requests FASTA and returns records; with GFF3 loaded, `parse = Vector{GFF3.Record}` does the same for GFF.")
    println(io, "- `send`: when `false`, nothing is sent and the `Request` is returned instead, to inspect (`url(req)`), run later with `send(req)` or page through with `paginate(req)`.")
    println(io)
    println(io, "Errors other than HTTP 429 (which is retried) are thrown as `HTTP.StatusError`.")
    println(io)
    println(io, "Base URL: $BASE_URL")
    println(io)
    println(io, "| Function | Endpoint |")
    println(io, "|:---------|:---------|")
    for op in ops
        println(io, "| `$(op.name)` | `$(op.method) $(op.path)` |")
    end
    println(io, "\"\"\"")
    println(io, "module EBIProteinsFunctions")
    println(io)
    println(io, "import HTTP")
    println(io, "import JSON")
    println(io)
    print(io, substitute(COMMON_RUNTIME))
    println(io)
    print(io, FUNCTIONS_RUNTIME)
    for op in ops
        println(io)
        emit_operation(io, op)
    end
    println(io)
    println(io, "\"Requests that `paginate` accepts: those of operations with `offset` and `size` parameters.\"")
    println(io, "const Pageable = Union{", join(["Request{:$(op.name)}" for op in ops if pageable(op)], ", "), "}")
    println(io)
    print(io, FUNCTIONS_PAGING)
    println(io)
    println(io, "end # module")
    return String(take!(io))
end

function generate(spec, bytes)
    write(OUT_PATH, emit(spec, bytes))
    println("wrote ", OUT_PATH)
end

end # module

abspath(PROGRAM_FILE) == (@__FILE__) && EBIProteinsFunctionsGenerator.generate(EBIProteinsFunctionsGenerator.load_spec()...)
