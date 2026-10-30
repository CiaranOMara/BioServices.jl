# Live tests of the FASTX and GFF3 package extensions of EBIProteinsRestClient.
# They follow the same checklist as the other prototypes' extension tests; only "style-specific" differs.

using Test
import EBIProteinsRestClient as R
using EBIProteinsRestClient.RestClient
using FASTX: FASTARecord, identifier, description, sequence, seqsize
import GFF3

const ACC = "P08069"   # IGF1R_HUMAN, 1367 residues

function live(f; tries = 3)
    for i in 1:tries
        try
            return f()
        catch e
            i == tries && rethrow()
            e isa ResponseError && e.response.status < 500 && rethrow()
            sleep(5i)
        end
    end
end

gff(text) = count(l -> !isempty(l) && !startswith(l, '#'), split(text, '\n'))

# A type whose format has no decoder, to check that the request is rejected before it is sent.
struct NoDecoder end
R.defaultformat(::Type{NoDecoder}) = :gff

@testset "EBIProteinsRestClient extensions" begin
    @test Base.get_extension(R, :EBIProteinsRestClientFASTXExt) !== nothing
    @test Base.get_extension(R, :EBIProteinsRestClientGFF3Ext) !== nothing

    @testset "FASTX" begin
        # The type picks the Accept header.
        @test R.defaultformat(Vector{FASTARecord}) == :fasta
        records = live(() -> R.proteins(accession = "$ACC,P01308", accept = Vector{FASTARecord}))
        @test records isa Vector{FASTARecord} && length(records) == 2
        igf1r = only(filter(r -> occursin("|$ACC|", identifier(r)), records))
        @test seqsize(igf1r) == 1367
        @test occursin("Insulin-like growth factor 1 receptor", description(igf1r))

        one = live(() -> R.proteins_by_accession(ACC, accept = FASTARecord))
        @test one isa FASTARecord && sequence(String, one) == sequence(String, igf1r)
        upi = live(() -> R.uniparc_upi_by_upi("UPI0000000114", accept = FASTARecord))
        @test startswith(identifier(upi), "UPI0000000114")

        # The JSON entry and the FASTA record describe the same sequence.
        @test live(() -> R.proteins_by_accession(ACC))["sequence"]["sequence"] == sequence(String, one)
    end

    @testset "GFF3" begin
        @test R.defaultformat(Vector{GFF3.Record}) == :gff
        text = live(() -> R.features_by_accession(ACC, accept = :gff))
        records = live(() -> R.features_by_accession(ACC, accept = Vector{GFF3.Record}))
        @test records isa Vector{GFF3.Record}
        @test length(records) == gff(text)   # nothing dropped by the normalisation
        @test all(r -> GFF3.seqid(r) == ACC, records)
        signal = first(filter(r -> GFF3.featuretype(r) == "SIGNAL", records))
        @test (GFF3.seqstart(signal), GFF3.seqend(signal)) == (1, 30)

        # /variation starts the attribute column with a bare value; it becomes a Note.
        variants = live(() -> R.variation_by_accession(ACC, accept = Vector{GFF3.Record}))
        @test !isempty(variants) && all(r -> GFF3.featuretype(r) == "VARIANT", variants)
        @test startswith(only(GFF3.attributes(variants[1], "Note")), "p.")
        @test !isempty(GFF3.attributes(variants[1], "Xref"))

        for f in (R.proteomics_nonptm_by_accession, R.coordinates_by_accession)
            text = live(() -> f(ACC, accept = :gff))
            @test length(live(() -> f(ACC, accept = Vector{GFF3.Record}))) == gff(text)
        end
    end

    @testset "errors" begin
        # With no decoder for the type's format, the request is rejected before anything is sent.
        @test_throws MalformedRequest R.proteins_by_accession(ACC, accept = NoDecoder)
        # A type that JSON.parse can't fill is sent, and fails while the JSON response is parsed into it.
        @test_throws MethodError R.proteins_by_accession(ACC, accept = Vector{Int})
    end

    @testset "style-specific" begin
        # accept is either a format or a type, so a type always requests its own format.
        @test RestClient.headers(R.ProteinsByAccessionEndpoint(accession = ACC, accept = FASTARecord)) == ["Accept" => "text/x-fasta"]
        @test RestClient.headers(R.ProteinsByAccessionEndpoint(accession = ACC, accept = Vector{GFF3.Record})) == ["Accept" => "text/x-gff"]
        # The extensions decode through RestClient's own interpretresponse, so a hand-made Request works too.
        req = Request{:get}(globalconfig(Val(R)), R.ProteinsByAccessionEndpoint(accession = ACC, accept = FASTARecord))
        @test identifier(live(() -> perform(req))) == "sp|$ACC|IGF1R_HUMAN"
    end
end
