"""
    Format{S}

A response format, the type `decode` dispatches on.
`S` is a shorthand, one of the keys of `MIMES`, or any other MIME type as a `Symbol`.
`Format(:fasta)` and `Format("text/x-fasta")` are the same; an unknown shorthand throws an `ArgumentError` before any request is made.
"""
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

"""
    decode(::Format, resp::HTTP.Response)

Turn a response body into a value.
JSON is parsed with `JSON.parse`; any other format is returned as a `String`.
Add methods to decode a format into richer types.
"""
decode(::Format, resp) = occursin("json", HTTP.header(resp, "Content-Type")) ? _json(resp) : String(resp.body)
decode(::Format{:json}, resp) = _json(resp)

_json(resp) = (text = String(resp.body); isempty(text) ? nothing : JSON.parse(text))

"""
    decode(::Format, resp::HTTP.Response, T::Type)

Decode a response body into a value of type `T`.
Package extensions add methods, for example `Vector{FASTX.FASTA.Record}` from `:fasta` once FASTX is loaded, and `Vector{GFF3.Record}` from `:gff` once GFF3 is loaded.
A request asking for a type with no method for its format throws an `ArgumentError` before it is sent.
"""
decode(::Format, ::Any, ::Type)

function _decodable(f::Format, ::Type{T}) where {T}
    hasmethod(decode, Tuple{typeof(f), HTTP.Response, Type{T}}) && return
    throw(ArgumentError("no decoder from $(mime(f)) to $T; it may need a package to be loaded, such as FASTX or GFF3"))
end
_decodable(::Format, ::Bool) = nothing

"""
    defaultformat(T::Type)

The format requested to decode a response into `T` when no `accept` is given.
The extensions that add `decode` methods set it, so `Vector{FASTX.FASTA.Record}` requests `:fasta`.
"""
defaultformat(::Type) = :json
