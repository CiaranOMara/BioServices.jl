# The service description that ServiceGen writes clients from, and its reader for hand-written gen/service.toml files.
# The description is the generator's contract: any input that can be read into a `Service` gets the same client, so an OpenAPI reader (prototypes/common/spec.jl parses one) would be a second front end, not a second generator.

import TOML

"A path or query parameter."
struct Param
    name::String
    location::String              # "path" or "query"
    type::String                  # one of TYPES
    required::Bool
    default::Any                  # `nothing` for none
    enum::Vector{String}
    literal::Union{Nothing, String}   # a boolean path parameter that is this segment when true
    sep::Union{Nothing, String}       # the separator of a list parameter, when it is not a comma
    description::String
end

"One request: its path template, and its path parameters in template order followed by its query parameters."
struct Operation
    name::String
    method::String
    path::String
    summary::String
    description::String
    params::Vector{Param}
end

"A service: where it is, how it is asked for formats, authorised, paged and recognises failure, and its operations."
struct Service
    name::String
    title::String
    docs::String
    base_url::String
    formats::Vector{Pair{String, String}}   # shorthand => MIME type, the default first
    format_by::String                       # "header", "extension" or "query:<name>"
    auth::Dict{String, Any}                 # empty for none
    paging::Dict{String, Any}               # empty for none
    envelope::Union{Nothing, String}
    errors::Dict{String, Any}               # empty for none
    operations::Vector{Operation}
end

const TYPES = ("string", "integer", "boolean", "list")

# Each table's keys, so a misspelt key stops the generator instead of being ignored.
const SERVICE_KEYS = ("name", "title", "docs", "base_url", "formats", "default_format", "format_by", "auth", "paging", "envelope", "errors")
const PARAM_KEYS = ("type", "required", "optional", "default", "enum", "literal", "sep", "description")
const OPERATION_KEYS = ("name", "method", "path", "summary", "description", "query")

function checkkeys(table, allowed, where)
    extra = setdiff(keys(table), allowed)
    isempty(extra) || error("$where: unknown key(s) $(join(sort!(collect(extra)), ", ")); expected some of $(join(allowed, ", "))")
end

template_names(path) = [m[1] for m in eachmatch(r"\{(\w+)\}", path)]

"The parameter `name` from the shared `[params]` table, at `location`."
function param(params, name, location, where)
    haskey(params, name) || error("$where: parameter $name is not in [params]")
    t = params[name]
    checkkeys(t, PARAM_KEYS, "[params.$name]")
    type = get(t, "type", "string")
    type in TYPES || error("[params.$name]: type $type is not one of $(join(TYPES, ", "))")
    literal = get(t, "literal", nothing)
    literal === nothing || (type == "boolean" && location == "path") || error("[params.$name]: only a boolean path parameter can be a literal")
    default = get(t, "default", nothing)
    optional = get(t, "optional", false) || literal !== nothing
    # A path parameter is required unless it has a default or may be left out; a query parameter is optional unless it says otherwise.
    required = location == "path" ? default === nothing && !optional : get(t, "required", false)
    return Param(name, location, type, required, default, String.(get(t, "enum", String[])), literal,
                 get(t, "sep", nothing), strip(get(t, "description", "")))
end

function operation(t, params)
    checkkeys(t, OPERATION_KEYS, "[[operations]] $(get(t, "name", "?"))")
    name = t["name"]
    path = t["path"]
    where = "operation $name"
    ps = [[param(params, n, "path", where) for n in template_names(path)];
          [param(params, n, "query", where) for n in get(t, "query", String[])]]
    names = [p.name for p in ps]
    length(unique(names)) == length(names) || error("$where: a parameter appears twice")
    return Operation(name, uppercase(get(t, "method", "GET")), path,
                     strip(get(t, "summary", "")), strip(get(t, "description", "")), ps)
end

"""
    read_service(path)

The `Service` described by the TOML file at `path`: a `[service]` table, a shared `[params]` table and one `[[operations]]` table per request.
"""
function read_service(path)
    toml = TOML.parsefile(path)
    checkkeys(toml, ("service", "params", "operations"), path)
    s = toml["service"]
    checkkeys(s, SERVICE_KEYS, "[service]")
    default = get(s, "default_format", "json")
    formats = sort!([k => v for (k, v) in s["formats"]], by = f -> (f[1] != default, f[1]))
    formats[1][1] == default || error("[service]: default_format $default is not in formats")
    format_by = get(s, "format_by", "header")
    format_by in ("header", "extension") || startswith(format_by, "query:") || error("[service]: format_by $format_by is not header, extension or query:<name>")
    ops = [operation(t, get(toml, "params", Dict{String, Any}())) for t in toml["operations"]]
    names = [op.name for op in ops]
    length(unique(names)) == length(names) || error("$path: two operations share a name")
    return Service(s["name"], get(s, "title", s["name"]), get(s, "docs", ""), s["base_url"], formats, format_by,
                   get(s, "auth", Dict{String, Any}()), get(s, "paging", Dict{String, Any}()),
                   get(s, "envelope", nothing), get(s, "errors", Dict{String, Any}()), ops)
end
