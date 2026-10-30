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
