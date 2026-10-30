# Generate prototypes/EBIProteinsFunctions/src/EBIProteinsFunctions.jl, one keyword function per operation, from the spec snapshot in prototypes/common/:
#
#   julia --project=prototypes/common prototypes/EBIProteinsFunctions/gen/generate.jl
#
# prototypes/common/generate.jl runs this with the other custom generators, and refreshes the snapshot with --fetch.
module EBIProteinsFunctionsGenerator

include(joinpath(@__DIR__, "..", "..", "common", "spec.jl"))
include(joinpath(@__DIR__, "..", "..", "common", "render.jl"))

const GENERATOR = "prototypes/EBIProteinsFunctions/gen/generate.jl"
const OUT_PATH = normpath(joinpath(@__DIR__, "..", "src", "EBIProteinsFunctions.jl"))
const RUNTIME = joinpath(@__DIR__, "runtime")

"The generated module, from the spec's operations."
function render(spec, spec_bytes)
    ops = operations(spec)
    return join([
        header(GENERATOR, spec, spec_bytes, ops),
        docstring(module_doc(ops)) * "module EBIProteinsFunctions\n",
        "import HTTP\nimport JSON\n",
        base_url() * "\n" * mimes() * "\n" *
        runtime(COMMON_RUNTIME, "formats.jl") * "\n" *
        runtime(COMMON_RUNTIME, "parameters.jl") * "\n" *
        runtime(RUNTIME, "query.jl") * "\n" *
        runtime(COMMON_RUNTIME, "http.jl") * "\n" *
        runtime(COMMON_RUNTIME, "pages.jl"),
        runtime(RUNTIME, "request.jl"),
        map(operation, ops)...,
        pageable_union(ops),
        runtime(RUNTIME, "paging.jl"),
        "end # module\n",
    ], "\n")
end

module_doc(ops) = """
    Client for the EMBL-EBI Proteins REST API, generated from its OpenAPI specification, with one keyword function per operation.
    A prototype for comparison with `EBIProteinsKwarg`.

    Every operation in the specification is a function named after its path, for example `proteins_by_accession("P08069")` for `GET /proteins/{accession}`.
    Path parameters are positional; query parameters are keywords with the names the API uses.
    Nothing is exported.

    Parameters are typed from the specification.
    Integers and comma-separated lists that it declares as strings also take their natural Julia types (`IntParam`, `ListParam`, `IntListParam`), so `taxid = [9606, 10090]` is sent as `taxid=9606,10090`.

    All functions accept three further keywords:
    - `accept`: the response format, a `Format`, a MIME type string or one of the shorthands $(format_shorthands()).
      Without it, `defaultformat(T)` is requested when `parse` is a type, and otherwise `:json` where the specification lists it.
      Other MIME types are sent as given, because the service supports formats the specification does not always list.
    - `parse`: when `true` (the default), the response is passed to `decode`, which parses JSON with `JSON.parse` into `Dict`s and `Vector`s and returns any other format as a `String`; when `false`, the `HTTP.Response` is returned.
      When it is a type, the response is decoded into that type by `decode(::Format, resp, T)`.
      Package extensions add the methods: with FASTX loaded, `parse = Vector{FASTX.FASTA.Record}` (or `FASTX.FASTA.Record` for one entry) requests FASTA and returns records; with GFF3 loaded, `parse = Vector{GFF3.Record}` does the same for GFF.
    - `send`: when `false`, nothing is sent and the `Request` is returned instead, to inspect (`url(req)`), run later with `send(req)` or page through with `paginate(req)`.

    Errors other than HTTP 429 (which is retried) are thrown as `HTTP.StatusError`.

    Base URL: $BASE_URL

    $(table(["Function", "Endpoint"], [["`$(op.name)`", "`$(op.method) $(op.path)`"] for op in ops]))"""

"One operation's function, which builds a `Request` and sends it unless `send = false`."
function operation(op)
    positional = [p.name * required_type(julia_type(p)) for p in op.pathparams]
    keywords = [p.required ? p.name * required_type(julia_type(p)) : p.name * optional_type(julia_type(p)) * " = nothing"
                for p in op.queryparams]
    op.body === nothing || push!(positional, "body")
    push!(keywords, "accept = nothing", "parse::Union{Bool, Type} = true", "send::Bool = true")

    query = "_query(" * join(["$(repr(p.name)) => $(p.name)" for p in op.queryparams], ", ") * ")"
    body = op.body === nothing ? "" : ", body"
    return docstring(operation_docstring(op)) * """
        function $(op.name)($(join(positional, ", ")); $(join(keywords, ", ")))
            req = Request{:$(op.name)}($(repr(op.method)), $(path_expr(op)), $query, _accept(accept, parse, $(default_accept(op)))$body)
            return send ? _send(req, parse) : req
        end
        """
end

function operation_docstring(op)
    positional = [p.name for p in op.pathparams]
    op.body === nothing || push!(positional, "body")
    keywords = [[p.name for p in op.queryparams]; "accept = nothing"; "parse = true"; "send = true"]
    signature = "$(op.name)($(join(positional, ", ")); $(join(keywords, ", ")))"
    doc = operation_doc(op, signature, ("Arguments", "Query parameters"), "a `String` is sent as `text/plain`, anything else as JSON")
    return """
        $doc
        Without `accept` or a `parse` type, `$(default_accept(op))` is requested.
        See `EBIProteinsFunctions` for `accept`, `parse` and `send`."""
end

# The request path as a Julia expression: literal parts and escaped path parameters.
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

pageable_union(ops) = """
    "Requests that `paginate` accepts: those of operations with `offset` and `size` parameters."
    const Pageable = Union{$(join(["Request{:$(op.name)}" for op in ops if pageable(op)], ", "))}
    """

function generate(spec, bytes)
    write(OUT_PATH, render(spec, bytes))
    println("wrote ", OUT_PATH)
end

end # module

abspath(PROGRAM_FILE) == (@__FILE__) && EBIProteinsFunctionsGenerator.generate(EBIProteinsFunctionsGenerator.load_spec()...)
