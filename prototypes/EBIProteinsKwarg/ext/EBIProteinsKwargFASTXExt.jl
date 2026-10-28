# Decode FASTA responses from EBIProteinsKwarg into FASTX records:
#
#     send(Proteins(accession = "P08069,P01308"), Vector{FASTARecord})
#     send(ProteinsByAccession(accession = "P08069"), FASTARecord)
module EBIProteinsKwargFASTXExt

using EBIProteinsKwarg: EBIProteinsKwarg, Format
using FASTX: FASTARecord, FASTAReader

_records(resp) = FASTAReader(IOBuffer(resp.body)) do reader
    collect(reader)
end

EBIProteinsKwarg.decode(::Format{:fasta}, resp, ::Type{Vector{FASTARecord}}) = _records(resp)
EBIProteinsKwarg.decode(::Format{:fasta}, resp, ::Type{FASTARecord}) = only(_records(resp))

EBIProteinsKwarg.defaultformat(::Type{<:Union{FASTARecord, Vector{FASTARecord}}}) = :fasta

end # module
