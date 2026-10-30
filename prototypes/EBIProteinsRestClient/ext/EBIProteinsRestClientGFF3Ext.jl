# Decode GFF responses from EBIProteinsRestClient into GFF3 records:
#
#     features_by_accession("P08069", accept = Vector{GFF3.Record})
module EBIProteinsRestClientGFF3Ext

using EBIProteinsRestClient: EBIProteinsRestClient, TextFormat
using EBIProteinsRestClient.RestClient: RestClient
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

function RestClient.interpretresponse(data::AbstractVector{UInt8}, ::TextFormat{:gff}, ::Type{Vector{GFF3.Record}})
    reader = GFF3.Reader(_normalise(data))
    try
        return collect(reader)
    finally
        close(reader)
    end
end

EBIProteinsRestClient.defaultformat(::Type{Vector{GFF3.Record}}) = :gff

end # module
