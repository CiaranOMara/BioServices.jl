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

_value(x) = string(x)
_value(x::AbstractVector) = join(map(_value, x), ",")

_segment(x) = HTTP.escapeuri(_value(x))

_query(pairs::Pair...) = Pair{String, String}[k => _value(v) for (k, v) in pairs if v !== nothing]

_url(path, query) = BASE_URL * path * (isempty(query) ? "" : "?" * HTTP.escapeuri(query))
