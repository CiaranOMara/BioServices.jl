# Live tests of EBIProteinsRestClient against the real service.
#
# The prototypes' live tests follow one checklist: the same testsets, in the same order, with the same calls and checks wherever the client allows; only "style-specific" differs.
# They check the service, not the spec: an endpoint can stay in the spec and stop returning data (see the uniparc proteome case).

using Test
import EBIProteinsRestClient as R
using EBIProteinsRestClient.RestClient
using EBIProteinsRestClient.JSON: @kwarg

const ACC = "P08069"   # IGF1R_HUMAN
const UPI = "UPI0000000114"
const UPID = "UP000005640"   # human reference proteome

# Retry transient network failures and 5xx responses; RestClient retries rate-limited requests itself.
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

const CONFIG = globalconfig(Val(R))
url(e) = RestClient.url(Request{:get}(CONFIG, e))

# /taxonomy/* is missing from the spec, so no endpoint is generated for it; this defines one.
@endpoint struct TaxonomyByIdEndpoint <: R.EBIEndpoint
    "taxonomy/id/{R._value(self.id)}" -> R._responsetype(self)   # path values must be strings
    id::Int
    accept::Symbol = :json
end

# The fields of an entry the style-specific test needs, to parse the response into.
@kwarg struct Sequence
    length::Int
    sequence::String
end
@kwarg struct Entry
    accession::String
    id::String
    sequence::Sequence
end

@testset "EBIProteinsRestClient live" begin
    @testset "proteins" begin
        entry = live(() -> R.proteins_by_accession(ACC))
        @test entry["accession"] == ACC && entry["sequence"]["length"] > 1000
        found = live(() -> R.proteins(accession = ACC))
        @test found isa List && found.items[1]["accession"] == ACC
        @test startswith(live(() -> R.proteins(accession = ACC, accept = :fasta)), ">sp|$ACC|")
        @test occursin("<uniprot", live(() -> R.proteins(accession = ACC, accept = :xml)))
        @test_skip "raw response"   # perform returns the parsed result, not the HTTP response
    end

    @testset "features" begin
        f = live(() -> R.features_by_accession(ACC, categories = "TOPOLOGY"))
        @test f["accession"] == ACC && !isempty(f["features"])
        @test all(x -> x["category"] == "TOPOLOGY", f["features"])
        @test startswith(live(() -> R.features(accession = ACC, accept = :gff)), "##gff-version")
    end

    @testset "variation" begin
        v = live(() -> R.variation_by_accession(ACC))
        @test v["accession"] == ACC && !isempty(v["features"])
    end

    @testset "proteomics" begin
        @test live(() -> R.proteomics_nonptm_by_accession(ACC))["accession"] == ACC
        @test live(() -> R.proteomics_ptm_by_accession(ACC, confidence_score = "Gold"))["accession"] == ACC
    end

    @testset "antigen" begin
        @test live(() -> R.antigen_by_accession(ACC))["accession"] == ACC
    end

    @testset "genecentric" begin
        @test live(() -> R.genecentric_by_accession(ACC))["gene"]["accession"] == ACC
    end

    @testset "proteomes" begin
        p = live(() -> R.proteomes_by_upid(UPID))
        @test p["upid"] == UPID && p["taxonomy"] == 9606
    end

    @testset "taxonomy" begin
        # The service serves /taxonomy/*, but the spec omits it, so nothing is generated for it; TaxonomyByIdEndpoint above is defined by hand.
        @test !isdefined(R, :taxonomy_id_by_id)
        @test live(() -> perform(Request{:get}(CONFIG, TaxonomyByIdEndpoint(id = 9606))))["taxonomyId"] == 9606
    end

    @testset "uniparc" begin
        u = live(() -> R.uniparc_upi_by_upi(UPI))
        @test u["accession"] == UPI
        seq = u["sequence"]["content"]
        @test live(() -> R.uniparc_sequence(Dict("sequence" => seq)))["accession"] == UPI
        # In the spec, but the service returns no entries for any proteome.
        @test_broken !isempty(live(() -> R.uniparc_proteome_by_upid(UPID, size = 1)))
    end

    @testset "coordinates" begin
        c = live(() -> R.coordinates_by_accession(ACC))
        @test c["accession"] == ACC && !isempty(c["gnCoordinate"])
        loc = live(() -> R.coordinates_location_by_accession_pstart_pend(ACC, 10, 20))
        @test loc isa Vector || loc isa AbstractDict
    end

    @testset "requests" begin
        e = R.ProteinsEndpoint(accession = ACC, taxid = [9606, 10090], reviewed = true)
        @test url(e) == "https://www.ebi.ac.uk/proteins/api/proteins?accession=$ACC&reviewed=true&taxid=9606%2C10090"
        # A list parameter as a Vector is the same request as the comma-separated string.
        @test url(R.ProteinsEndpoint(accession = ACC, taxid = "9606,10090", reviewed = true)) == url(e)
        f = live(() -> R.features_by_accession(ACC, categories = ["TOPOLOGY", "PTM"]))
        @test Set(x["category"] for x in f["features"]) == Set(["TOPOLOGY", "PTM"])
        @test_throws TypeError R.proteins(offset = "10")
        # Only searches return a List that nextpage can continue.
        @test_throws MethodError nextpage(live(() -> R.proteins_by_accession(ACC)))
    end

    @testset "paginate" begin
        pages = live() do
            ps = [R.proteins(gene = "INS", taxid = 9606, size = 2)]
            while length(ps) < 3
                push!(ps, nextpage(ps[end]))
            end
            ps
        end
        @test length(pages) == 3 && all(p -> length(p.items) == 2, pages)
        @test allunique(x["accession"] for p in pages for x in p.items)
        # A search that fits in one page stops after it.
        @test live(() -> nextpage(R.proteins(accession = ACC))) === nothing
    end

    @testset "errors" begin
        @test_throws ResponseError R.proteins_by_accession("NOTANACCESSION")
        @test_throws ArgumentError R.proteins_by_accession(ACC, accept = :png)   # before sending
    end

    @testset "style-specific" begin
        # Every function also takes a RequestConfig first, to change the base URL, caching or timeout.
        uncached = RequestConfig("https://www.ebi.ac.uk/proteins/api"; cache = false)
        @test live(() -> R.proteins_by_accession(uncached, ACC))["accession"] == ACC
        # A type as `accept` parses the JSON response into it.
        entry = live(() -> R.proteins_by_accession(ACC, accept = Entry))
        @test entry isa Entry && entry.id == "IGF1R_HUMAN" && entry.sequence.length > 1000
        # The endpoint struct is the request, and perform runs it.
        @test live(() -> perform(Request{:get}(CONFIG, R.ProteinsByAccessionEndpoint(accession = ACC))))["accession"] == ACC
    end
end
