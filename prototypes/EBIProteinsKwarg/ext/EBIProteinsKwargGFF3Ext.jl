# Decode GFF responses from EBIProteinsKwarg into GFF3 records:
#
#     send(FeaturesByAccession(accession = "P08069"), Vector{GFF3.Record})
module EBIProteinsKwargGFF3Ext

using EBIProteinsKwarg: EBIProteinsKwarg, Format
import GFF3

# The service's GFF needs two fixes before GFF3.jl can read it.
# An empty attribute column is written as ".", which the GFF3 specification allows but GFF3.jl rejects; it becomes empty.
# /variation starts the attribute column with a bare value such as `p.Met1Lys`, which is not `tag=value`; it becomes a `Note` attribute.
function _normalise(body)
    io = IOBuffer()
    for line in eachline(IOBuffer(body))
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

function EBIProteinsKwarg.decode(::Format{:gff}, resp, ::Type{Vector{GFF3.Record}})
    reader = GFF3.Reader(_normalise(resp.body))
    try
        return collect(reader)
    finally
        close(reader)
    end
end

EBIProteinsKwarg.defaultformat(::Type{Vector{GFF3.Record}}) = :gff

end # module
