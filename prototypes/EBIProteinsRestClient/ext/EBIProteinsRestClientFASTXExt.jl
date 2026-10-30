# Decode FASTA responses from EBIProteinsRestClient into FASTX records:
#
#     proteins(accession = "P08069,P01308", accept = Vector{FASTARecord})
#     proteins_by_accession("P08069", accept = FASTARecord)
module EBIProteinsRestClientFASTXExt

using EBIProteinsRestClient: EBIProteinsRestClient, TextFormat
using EBIProteinsRestClient.RestClient: RestClient
using FASTX: FASTARecord, FASTAReader

_records(data) = FASTAReader(IOBuffer(data)) do reader
    collect(reader)
end

RestClient.interpretresponse(data::AbstractVector{UInt8}, ::TextFormat{:fasta}, ::Type{Vector{FASTARecord}}) = _records(data)
RestClient.interpretresponse(data::AbstractVector{UInt8}, ::TextFormat{:fasta}, ::Type{FASTARecord}) = only(_records(data))

EBIProteinsRestClient.defaultformat(::Type{<:Union{FASTARecord, Vector{FASTARecord}}}) = :fasta

end # module
