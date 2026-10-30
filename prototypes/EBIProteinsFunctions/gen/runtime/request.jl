"""
    Request{Op, F<:Format, B}

A prepared call: operation `Op` (the generated function's name as a `Symbol`), response format `F` and request body type `B` (`Nothing` when there is none).
Every operation builds one; call it with `send = false` to get the request instead of the response, then run it with `send`.
`url(req)` is the full URL.
`decode` dispatches on the whole type, so its handling can be changed for one operation and format.
"""
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

"""
    send(req::Request; parse = true)

Run a request made with `send = false`.
With `parse = true` the response is passed to `decode`; otherwise the `HTTP.Response` is returned.
"""
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

"""
    decode(req::Request, resp::HTTP.Response)
    decode(req::Request, resp::HTTP.Response, T::Type)

Called by `send` with `parse = true`, or with `parse = T`.
The default dispatches on the format alone; a method such as `decode(::Request{:proteins_by_accession, Format{:fasta}}, resp)` overrides it for one operation.
"""
decode(req::Request, resp) = decode(format(req), resp)
decode(req::Request, resp, ::Type{T}) where {T} = decode(format(req), resp, T)

_page(req::Request{Op, F, B}, offset, size) where {Op, F, B} =
    Request{Op, F, B}(req.method, req.path,
                      [filter(p -> !(first(p) in ("offset", "size")), req.query); "offset" => string(offset); "size" => string(size)],
                      req.body)
