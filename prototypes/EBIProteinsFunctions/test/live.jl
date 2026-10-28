# Live tests of EBIProteinsFunctions against the real service.
#
# The two prototypes' live tests follow one checklist: the same testsets, in the same order, with the same calls and checks wherever the client allows; only "style-specific" differs.
# They check the service, not the spec: an endpoint can stay in the spec and stop returning data (see the uniparc proteome case).
# Without FASTX (Julia < 1.10) this file can be run on its own:
#
#   julia --project=prototypes/EBIProteinsFunctions prototypes/EBIProteinsFunctions/test/live.jl

using Test
import EBIProteinsFunctions as API

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
            e isa API.HTTP.StatusError && e.status < 500 && rethrow()
            sleep(5i)
        end
    end
end

@testset "EBIProteinsFunctions live" begin
    @testset "proteins" begin
        entry = live(() -> API.proteins_by_accession(ACC))
        @test entry["accession"] == ACC && entry["sequence"]["length"] > 1000
        found = live(() -> API.proteins(accession = ACC))
        @test found isa Vector && found[1]["accession"] == ACC
        @test startswith(live(() -> API.proteins(accession = ACC, accept = :fasta)), ">sp|$ACC|")
        @test occursin("<uniprot", live(() -> API.proteins(accession = ACC, accept = :xml)))
        @test live(() -> API.proteins_by_accession(ACC, parse = false)).status == 200   # raw response
    end

    @testset "features" begin
        f = live(() -> API.features_by_accession(ACC, categories = "TOPOLOGY"))
        @test f["accession"] == ACC && !isempty(f["features"])
        @test all(x -> x["category"] == "TOPOLOGY", f["features"])
        @test startswith(live(() -> API.features(accession = ACC, accept = :gff)), "##gff-version")
    end

    @testset "variation" begin
        v = live(() -> API.variation_by_accession(ACC))
        @test v["accession"] == ACC && !isempty(v["features"])
    end

    @testset "proteomics" begin
        @test live(() -> API.proteomics_nonptm_by_accession(ACC))["accession"] == ACC
        @test live(() -> API.proteomics_ptm_by_accession(ACC, confidence_score = "Gold"))["accession"] == ACC
    end

    @testset "antigen" begin
        @test live(() -> API.antigen_by_accession(ACC))["accession"] == ACC
    end

    @testset "genecentric" begin
        @test live(() -> API.genecentric_by_accession(ACC))["gene"]["accession"] == ACC
    end

    @testset "proteomes" begin
        p = live(() -> API.proteomes_by_upid(UPID))
        @test p["upid"] == UPID && p["taxonomy"] == 9606
    end

    @testset "taxonomy" begin
        # The service serves /taxonomy/*, but the spec omits it, so nothing is generated for it; the request is built by hand.
        @test !isdefined(API, :taxonomy_id_by_id)
        req = API.Request{:taxonomy_id}("GET", "/taxonomy/id/9606", API._query(), API.Format(:json))
        @test live(() -> API.send(req))["taxonomyId"] == 9606
    end

    @testset "uniparc" begin
        u = live(() -> API.uniparc_upi_by_upi(UPI))
        @test u["accession"] == UPI
        seq = u["sequence"]["content"]
        @test live(() -> API.uniparc_sequence(Dict("sequence" => seq)))["accession"] == UPI
        # In the spec, but the service returns no entries for any proteome.
        @test_broken !isempty(live(() -> API.uniparc_proteome_by_upid(UPID, size = 1)))
    end

    @testset "coordinates" begin
        c = live(() -> API.coordinates_by_accession(ACC))
        @test c["accession"] == ACC && !isempty(c["gnCoordinate"])
        loc = live(() -> API.coordinates_location_by_accession_pstart_pend(ACC, 10, 20))
        @test loc isa Vector || loc isa AbstractDict
    end

    @testset "requests" begin
        req = API.proteins(accession = ACC, taxid = [9606, 10090], reviewed = true, send = false)
        @test API.url(req) == "https://www.ebi.ac.uk/proteins/api/proteins?accession=$ACC&reviewed=true&taxid=9606%2C10090"
        # A list parameter as a Vector is the same request as the comma-separated string.
        @test API.url(API.proteins(accession = ACC, taxid = "9606,10090", reviewed = true, send = false)) == API.url(req)
        f = live(() -> API.features_by_accession(ACC, categories = ["TOPOLOGY", "PTM"]))
        @test Set(x["category"] for x in f["features"]) == Set(["TOPOLOGY", "PTM"])
        @test_throws TypeError API.proteins(offset = "10")
        @test_throws MethodError API.paginate(API.proteins_by_accession(ACC, send = false))
    end

    @testset "paginate" begin
        pages = live(() -> collect(Iterators.take(API.paginate(API.proteins(gene = "INS", taxid = 9606, size = 2, send = false)), 3)))
        @test length(pages) == 3 && all(p -> length(p) == 2, pages)
        @test allunique(x["accession"] for p in pages for x in p)
        # A search that fits in one page stops after it.
        @test live(() -> length(collect(API.paginate(API.proteins(accession = ACC, send = false))))) == 1
    end

    @testset "errors" begin
        @test_throws API.HTTP.StatusError API.proteins_by_accession("NOTANACCESSION")
        @test_throws ArgumentError API.proteins_by_accession(ACC, accept = :png)   # before sending
    end

    @testset "style-specific" begin
        # Every function builds a Request; send = false returns it to inspect or run later.
        req = API.proteins(accession = ACC, send = false)
        @test req isa API.Request{:proteins, API.Format{:json}, Nothing}
        @test live(() -> API.send(req))[1]["accession"] == ACC
        @test live(() -> API.send(req; parse = false)).status == 200
    end
end
