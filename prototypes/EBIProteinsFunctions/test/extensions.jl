# Live tests of the FASTX and GFF3 package extensions of EBIProteinsFunctions.
# They follow the same checklist as EBIProteinsKwarg's; only "style-specific" differs.

using Test
import EBIProteinsFunctions as API
using FASTX: FASTARecord, identifier, description, sequence, seqsize
import GFF3
const HTTP = API.HTTP

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

@testset "EBIProteinsFunctions extensions" begin
    @test Base.get_extension(API, :EBIProteinsFunctionsFASTXExt) !== nothing
    @test Base.get_extension(API, :EBIProteinsFunctionsGFF3Ext) !== nothing

    @testset "FASTX" begin
        # The type picks the Accept header.
        @test API.defaultformat(Vector{FASTARecord}) == :fasta
        records = live(() -> API.proteins(accession = "$ACC,P01308", parse = Vector{FASTARecord}))
        @test records isa Vector{FASTARecord} && length(records) == 2
        igf1r = only(filter(r -> occursin("|$ACC|", identifier(r)), records))
        @test seqsize(igf1r) == 1367
        @test occursin("Insulin-like growth factor 1 receptor", description(igf1r))

        one = live(() -> API.proteins_by_accession(ACC, parse = FASTARecord))
        @test one isa FASTARecord && sequence(String, one) == sequence(String, igf1r)
        upi = live(() -> API.uniparc_upi_by_upi("UPI0000000114", parse = FASTARecord))
        @test startswith(identifier(upi), "UPI0000000114")

        # The JSON entry and the FASTA record describe the same sequence.
        entry = live(() -> API.proteins_by_accession(ACC))
        @test entry["sequence"]["sequence"] == sequence(String, one)
    end

    @testset "GFF3" begin
        @test API.defaultformat(Vector{GFF3.Record}) == :gff
        text = live(() -> API.features_by_accession(ACC, accept = :gff))
        records = live(() -> API.features_by_accession(ACC, parse = Vector{GFF3.Record}))
        @test records isa Vector{GFF3.Record}
        @test length(records) == gff(text)   # nothing dropped by the normalisation
        @test all(r -> GFF3.seqid(r) == ACC, records)
        signal = first(filter(r -> GFF3.featuretype(r) == "SIGNAL", records))
        @test (GFF3.seqstart(signal), GFF3.seqend(signal)) == (1, 30)

        # /variation starts the attribute column with a bare value; it becomes a Note.
        variants = live(() -> API.variation_by_accession(ACC, parse = Vector{GFF3.Record}))
        @test !isempty(variants) && all(r -> GFF3.featuretype(r) == "VARIANT", variants)
        @test startswith(only(GFF3.attributes(variants[1], "Note")), "p.")
        @test !isempty(GFF3.attributes(variants[1], "Xref"))

        for f in (API.proteomics_nonptm_by_accession, API.coordinates_by_accession)
            text = live(() -> f(ACC, accept = :gff))
            @test length(live(() -> f(ACC, parse = Vector{GFF3.Record}))) == gff(text)
        end
    end

    @testset "errors" begin
        # An explicit accept wins over the type.
        # With no decoder for the pair, an ArgumentError is thrown before anything is sent.
        @test_throws ArgumentError API.proteins_by_accession(ACC, accept = :fasta, parse = Vector{GFF3.Record})
        @test_throws ArgumentError API.proteins_by_accession(ACC, accept = :fasta, parse = Vector{Int})
    end

    @testset "style-specific" begin
        # The unsent Request shows the format the type chose, or the explicit accept.
        @test API.proteins(accession = ACC, parse = Vector{FASTARecord}, send = false) isa API.Request{:proteins, API.Format{:fasta}}
        req = API.proteins_by_accession(ACC, accept = :json, parse = Vector{FASTARecord}, send = false)
        @test req isa API.Request{:proteins_by_accession, API.Format{:json}}
        # JSON can't be decoded into a type (JSON 0.21), so that pair has no decoder either.
        @test_throws ArgumentError API.send(req; parse = Vector{FASTARecord})
    end
end
