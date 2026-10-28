# Decode FASTA responses from EBIProteinsFunctions into FASTX records:
#
#     proteins(accession = "P08069,P01308", parse = Vector{FASTARecord})
#     proteins_by_accession("P08069", parse = FASTARecord)
module EBIProteinsFunctionsFASTXExt

using EBIProteinsFunctions: EBIProteinsFunctions, Format
using FASTX: FASTARecord, FASTAReader

_records(resp) = FASTAReader(IOBuffer(resp.body)) do reader
    collect(reader)
end

EBIProteinsFunctions.decode(::Format{:fasta}, resp, ::Type{Vector{FASTARecord}}) = _records(resp)
EBIProteinsFunctions.decode(::Format{:fasta}, resp, ::Type{FASTARecord}) = only(_records(resp))

EBIProteinsFunctions.defaultformat(::Type{<:Union{FASTARecord, Vector{FASTARecord}}}) = :fasta

end # module
