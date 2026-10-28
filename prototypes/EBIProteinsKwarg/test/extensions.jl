# Live tests of the FASTX and GFF3 package extensions of EBIProteinsKwarg.
# They follow the same checklist as EBIProteinsFunctions'; only "style-specific" differs.

using Test
import EBIProteinsKwarg as K
using FASTX: FASTARecord, identifier, description, sequence, seqsize
import GFF3
const HTTP = K.HTTP

const ACC = "P08069"   # IGF1R_HUMAN, 1367 residues

function live(f; tries = 3)
    for i in 1:tries
        try
            return f()
        catch e
            i == tries && rethrow()
            e isa HTTP.StatusError && e.status < 500 && rethrow()
            sleep(5i)
        end
    end
end

gff(text) = count(l -> !isempty(l) && !startswith(l, '#'), split(text, '\n'))

@testset "EBIProteinsKwarg extensions" begin
    @test Base.get_extension(K, :EBIProteinsKwargFASTXExt) !== nothing
    @test Base.get_extension(K, :EBIProteinsKwargGFF3Ext) !== nothing

    @testset "FASTX" begin
        # The type picks the Accept header.
        @test K.defaultformat(Vector{FASTARecord}) == :fasta
        records = live(() -> K.send(K.Proteins(accession = "$ACC,P01308"), Vector{FASTARecord}))
        @test records isa Vector{FASTARecord} && length(records) == 2
        igf1r = only(filter(r -> occursin("|$ACC|", identifier(r)), records))
        @test seqsize(igf1r) == 1367
        @test occursin("Insulin-like growth factor 1 receptor", description(igf1r))

        e = K.ProteinsByAccession(accession = ACC)
        one = live(() -> K.send(e, FASTARecord))
        @test one isa FASTARecord && sequence(String, one) == sequence(String, igf1r)
        upi = live(() -> K.send(K.UniparcUpiByUpi(upi = "UPI0000000114"), FASTARecord))
        @test startswith(identifier(upi), "UPI0000000114")

        # The JSON entry and the FASTA record describe the same sequence.
        @test live(() -> K.send(e))["sequence"]["sequence"] == sequence(String, one)
    end

    @testset "GFF3" begin
        @test K.defaultformat(Vector{GFF3.Record}) == :gff
        e = K.FeaturesByAccession(accession = ACC)
        text = live(() -> K.send(e; accept = :gff))
        records = live(() -> K.send(e, Vector{GFF3.Record}))
        @test records isa Vector{GFF3.Record}
        @test length(records) == gff(text)   # nothing dropped by the normalisation
        @test all(r -> GFF3.seqid(r) == ACC, records)
        signal = first(filter(r -> GFF3.featuretype(r) == "SIGNAL", records))
        @test (GFF3.seqstart(signal), GFF3.seqend(signal)) == (1, 30)

        # /variation starts the attribute column with a bare value; it becomes a Note.
        variants = live(() -> K.send(K.VariationByAccession(accession = ACC), Vector{GFF3.Record}))
        @test !isempty(variants) && all(r -> GFF3.featuretype(r) == "VARIANT", variants)
        @test startswith(only(GFF3.attributes(variants[1], "Note")), "p.")
        @test !isempty(GFF3.attributes(variants[1], "Xref"))

        for e in (K.ProteomicsNonptmByAccession(accession = ACC), K.CoordinatesByAccession(accession = ACC))
            text = live(() -> K.send(e; accept = :gff))
            @test length(live(() -> K.send(e, Vector{GFF3.Record}))) == gff(text)
        end
    end

    @testset "errors" begin
        # An explicit accept wins over the type.
        # With no decoder for the pair, an ArgumentError is thrown before anything is sent.
        e = K.ProteinsByAccession(accession = ACC)
        @test_throws ArgumentError K.send(e, Vector{GFF3.Record}; accept = :fasta)
        @test_throws ArgumentError K.send(e, Vector{Int}; accept = :fasta)
    end

    @testset "style-specific" begin
        # JSON has a decoder for every type (JSON.parse into it), so a type that only fits FASTA is sent, and fails while the JSON response is parsed into it.
        @test_throws ArgumentError K.send(K.ProteinsByAccession(accession = ACC), Vector{FASTARecord}; accept = :json)
    end
end
