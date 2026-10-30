# Decode GFF responses from any client built on ServiceRuntime into GFF3 records:
#
#     send(GGGenome.Search(sequence = "TTCATTGACAACATTGCGT", k = 2), Vector{GFF3.Record})
#
# One decoder serves every service, so the fixes for each service's GFF dialect live here together.
module ServiceRuntimeGFF3Ext

using ServiceRuntime: ServiceRuntime, Format
import GFF3

# Fixes that GFF3.jl needs before it can read the services' GFF.
# GGGenome writes a UCSC `track` line, which is not GFF3, and `### No items found. ###` for no matches, which GFF3.jl reads as a directive; both are dropped.
# EBI Proteins writes an empty attribute column as ".", which the GFF3 specification allows but GFF3.jl rejects; it becomes empty.
# EBI Proteins /variation starts the attribute column with a bare value such as `p.Met1Lys`, which is not `tag=value`; it becomes a `Note` attribute.
function _normalise(body)
    io = IOBuffer()
    for line in eachline(IOBuffer(body))
        (startswith(line, "track ") || (startswith(line, "### ") && endswith(line, " ###"))) && continue
        cols = split(line, '\t')
        if !startswith(line, '#') && length(cols) == 9
            attrs = cols[9] == "." ? SubString{String}[] : filter(!isempty, split(cols[9], ';'))
            attrs = [occursin('=', a) ? a : "Note=" * a for a in attrs]
            line = join(cols[1:8], '\t') * '\t' * join(attrs, ';')
        end
        println(io, line)
    end
    return seekstart(io)
end

function ServiceRuntime.decode(::Format{:gff}, resp, ::Type{Vector{GFF3.Record}})
    reader = GFF3.Reader(_normalise(resp.body))
    try
        return collect(reader)
    finally
        close(reader)
    end
end

ServiceRuntime.defaultformat(::Type{Vector{GFF3.Record}}) = :gff

end # module
