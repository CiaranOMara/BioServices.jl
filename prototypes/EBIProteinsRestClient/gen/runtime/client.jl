"""
    EBIEndpoint, EBIListEndpoint

Supertypes of the generated endpoint structs.
Searches, the operations with `offset` and `size` parameters, are `EBIListEndpoint`s: their JSON results come back as a `RestClient.List`, and `nextpage` fetches the next page.
"""
abstract type EBIEndpoint <: AbstractEndpoint end
abstract type EBIListEndpoint <: ListEndpoint end
@doc (@doc EBIEndpoint) EBIListEndpoint

const Endpoints = Union{EBIEndpoint, EBIListEndpoint}

# Parameter types.
# Integers and lists the spec declares as strings accept their natural Julia types too: `taxid = 9606`, `taxid = [9606, 10090]` and `taxid = "9606,10090"` are the same.
"""
An integer the spec declares as a string, such as `taxonomy`: `9606` or `"9606"`.
"""
const IntParam = Union{Integer, AbstractString}

"""
A comma-separated list: `"TOPOLOGY,PTM"` or `["TOPOLOGY", "PTM"]`.
"""
const ListParam = Union{AbstractString, AbstractVector}

"""
A comma-separated list of integers, such as `taxid`: `9606`, `[9606, 10090]` or `"9606,10090"`.
"""
const IntListParam = Union{Integer, ListParam}

_value(::Nothing) = nothing
_value(x) = string(x)
_value(x::AbstractVector) = join(map(_value, x), ",")

"""
    defaultformat(T::Type)

The format, as a key of `MIMES`, requested when `accept` is the type `T`.
The default is `:json`, which is parsed into `T` with `JSON.parse`; the extensions that decode other formats into `T` set it, so `Vector{FASTX.FASTA.Record}` requests `:fasta`.
"""
defaultformat(::Type) = :json

"""
    TextFormat{S}

A text response format, such as FASTA or GFF, that is decoded into a type rather than returned as a `String`.
`S` is its key in `MIMES`.
Package extensions add `RestClient.interpretresponse(data, ::TextFormat{S}, ::Type{T})` methods: with FASTX loaded, `Vector{FASTX.FASTA.Record}` from `:fasta`, and with GFF3 loaded, `Vector{GFF3.Record}` from `:gff`.
"""
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
