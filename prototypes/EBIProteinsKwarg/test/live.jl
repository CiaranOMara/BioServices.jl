# Live tests of EBIProteinsKwarg against the real service.
#
# The three prototypes' live tests follow one checklist: the same testsets, in the same order, with the same calls and checks wherever the client allows; only "style-specific" differs.
# They check the service, not the spec: an endpoint can stay in the spec and stop returning data (see the uniparc proteome case).

using Test
import EBIProteinsKwarg as K
using EBIProteinsKwarg.JSON: @kwarg
const HTTP = K.HTTP

const ACC = "P08069"   # IGF1R_HUMAN
const UPI = "UPI0000000114"
const UPID = "UP000005640"   # human reference proteome

# Retry transient network failures and 5xx responses; the client retries HTTP 429 itself.
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

# /taxonomy/* is missing from the spec, so no type is generated for it; this defines one.
@kwarg struct TaxonomyById <: K.Endpoint{:GET}
    id::Int &(in = :path,)
end
K.template(::Type{<:TaxonomyById}) = "/taxonomy/id/{id}"

# The fields of an entry the style-specific test needs, for `send(e, T)`.
@kwarg struct Sequence
    length::Int
    sequence::String
end
@kwarg struct Entry
    accession::String
    id::String
    sequence::Sequence
end

@testset "EBIProteinsKwarg live" begin
    @testset "proteins" begin
        entry = live(() -> K.send(K.ProteinsByAccession(accession = ACC)))
        @test entry["accession"] == ACC && entry["sequence"]["length"] > 1000
        found = live(() -> K.send(K.Proteins(accession = ACC)))
        @test found isa Vector && found[1]["accession"] == ACC
        @test startswith(live(() -> K.send(K.Proteins(accession = ACC); accept = :fasta)), ">sp|$ACC|")
        @test occursin("<uniprot", live(() -> K.send(K.Proteins(accession = ACC); accept = :xml)))
        @test live(() -> K.send(K.ProteinsByAccession(accession = ACC); parse = false)).status == 200   # raw response
    end

    @testset "features" begin
        f = live(() -> K.send(K.FeaturesByAccession(accession = ACC, categories = "TOPOLOGY")))
        @test f["accession"] == ACC && !isempty(f["features"])
        @test all(x -> x["category"] == "TOPOLOGY", f["features"])
        @test startswith(live(() -> K.send(K.Features(accession = ACC); accept = :gff)), "##gff-version")
    end

    @testset "variation" begin
        v = live(() -> K.send(K.VariationByAccession(accession = ACC)))
        @test v["accession"] == ACC && !isempty(v["features"])
    end

    @testset "proteomics" begin
        @test live(() -> K.send(K.ProteomicsNonptmByAccession(accession = ACC)))["accession"] == ACC
        @test live(() -> K.send(K.ProteomicsPtmByAccession(accession = ACC, confidence_score = "Gold")))["accession"] == ACC
    end

    @testset "antigen" begin
        @test live(() -> K.send(K.AntigenByAccession(accession = ACC)))["accession"] == ACC
    end

    @testset "genecentric" begin
        @test live(() -> K.send(K.GenecentricByAccession(accession = ACC)))["gene"]["accession"] == ACC
    end

    @testset "proteomes" begin
        p = live(() -> K.send(K.ProteomesByUpid(upid = UPID)))
        @test p["upid"] == UPID && p["taxonomy"] == 9606
    end

    @testset "taxonomy" begin
        # The service serves /taxonomy/*, but the spec omits it, so nothing is generated for it; TaxonomyById above is defined by hand.
        @test !isdefined(K, :TaxonomyIdById)
        @test live(() -> K.send(TaxonomyById(id = 9606)))["taxonomyId"] == 9606
    end

    @testset "uniparc" begin
        u = live(() -> K.send(K.UniparcUpiByUpi(upi = UPI)))
        @test u["accession"] == UPI
        seq = u["sequence"]["content"]
        @test live(() -> K.send(K.UniparcSequence(body = K.UniparcSequenceParam(sequence = seq))))["accession"] == UPI
        # In the spec, but the service returns no entries for any proteome.
        @test_broken !isempty(live(() -> K.send(K.UniparcProteomeByUpid(upid = UPID, size = 1))))
    end

    @testset "coordinates" begin
        c = live(() -> K.send(K.CoordinatesByAccession(accession = ACC)))
        @test c["accession"] == ACC && !isempty(c["gnCoordinate"])
        loc = live(() -> K.send(K.CoordinatesLocationByAccessionPstartPend(accession = ACC, pStart = 10, pEnd = 20)))
        @test loc isa Vector || loc isa AbstractDict
    end

    @testset "requests" begin
        e = K.Proteins(accession = ACC, taxid = [9606, 10090], reviewed = true)
        @test K.url(e) == "https://www.ebi.ac.uk/proteins/api/proteins?accession=$ACC&reviewed=true&taxid=9606%2C10090"
        # A list parameter as a Vector is the same request as the comma-separated string.
        @test K.url(K.Proteins(accession = ACC, taxid = "9606,10090", reviewed = true)) == K.url(e)
        f = live(() -> K.send(K.FeaturesByAccession(accession = ACC, categories = ["TOPOLOGY", "PTM"])))
        @test Set(x["category"] for x in f["features"]) == Set(["TOPOLOGY", "PTM"])
        @test_throws MethodError K.Proteins(offset = "10")
        @test_throws MethodError K.paginate(K.ProteinsByAccession(accession = ACC))
    end

    @testset "paginate" begin
        pages = live(() -> collect(Iterators.take(K.paginate(K.Proteins(gene = "INS", taxid = 9606, size = 2)), 3)))
        @test length(pages) == 3 && all(p -> length(p) == 2, pages)
        @test allunique(x["accession"] for p in pages for x in p)
        # A search that fits in one page stops after it.
        @test live(() -> length(collect(K.paginate(K.Proteins(accession = ACC))))) == 1
    end

    @testset "errors" begin
        @test_throws HTTP.StatusError K.send(K.ProteinsByAccession(accession = "NOTANACCESSION"))
        @test_throws ArgumentError K.send(K.ProteinsByAccession(accession = ACC); accept = :png)   # before sending
    end

    @testset "style-specific" begin
        # A request is a value: change it with the keyword constructor, parse into your own type.
        e = K.ProteinsByAccession(accession = ACC)
        @test K._with(K.Proteins(accession = ACC); size = 1) == K.Proteins(accession = ACC, size = 1)
        entry = live(() -> K.send(e, Entry))
        @test entry isa Entry && entry.id == "IGF1R_HUMAN" && entry.sequence.length > 1000
        @test K.UniparcSequence(body = K.UniparcSequenceParam(sequence = "MKV")) isa K.UniparcSequence{K.UniparcSequenceParam}
    end
end
