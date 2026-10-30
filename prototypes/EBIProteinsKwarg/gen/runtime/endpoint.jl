"""
    Endpoint{M}

Supertype of the request types, one per operation; `M` is the HTTP method as a `Symbol`.
Fields tagged `&(in = :path,)` fill the path template, the field tagged `&(in = :body,)` is the request body and every other field that is not `nothing` is a query parameter.
"""
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

"""
    send(e::Endpoint; accept = defaultformat(e), parse = true)
    send(e::Endpoint, T::Type; accept = defaultformat(T))

Run a request.
With `parse = true` the response is passed to `decode`; otherwise the `HTTP.Response` is returned.
With a type, the response is decoded into `T`: JSON with `JSON.parse(body, T)`, for example into a `@kwarg` struct with the fields you need, and other formats by the `decode(::Format, resp, T)` methods that are defined.
"""
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

"""
    decode(e::Endpoint, f::Format, resp::HTTP.Response)

Called by `send` with `parse = true`.
The default dispatches on the format alone; a method such as `decode(::ProteinsByAccession, ::Format{:fasta}, resp)` overrides it for one endpoint.
"""
decode(::Endpoint, f::Format, resp) = decode(f, resp)
decode(::Endpoint, f::Format, resp, ::Type{T}) where {T} = decode(f, resp, T)

# A copy of `e` with some fields replaced, through the keyword constructor @kwarg defines.
_with(e::E; kwargs...) where {E<:Endpoint} =
    Base.typename(E).wrapper(; (f => getfield(e, f) for f in fieldnames(E))..., kwargs...)
