# Live tests of EBIProteinsOpenAPI, the client OpenAPI.jl 1.x generates, against the real service.
#
# The checks are the calls a client of this API should be able to make, grouped by service, with a final "style-specific" testset for this client's quirks.
# This client returns data for none of the calls, because the spec doesn't describe what the service sends.
# So each check records how the call fails, with response validation on (the default client) and off.
# If OpenAPI.jl or the spec changes, the tests fail and show what changed.
# Checks the client has no way to make are @test_skip.

using Test
import EBIProteinsOpenAPI as O

const ACC = "P08069"   # IGF1R_HUMAN
const UPI = "UPI0000000114"
const UPID = "UP000005640"   # human reference proteome

const SchemaError = O.SchemaValidationError
const DecodeError = O.DecodeError
const NoCodec = O.UnsupportedMediaType
const EXPECTED = Union{SchemaError, DecodeError, NoCodec, O.ApiError, ArgumentError, TypeError, MethodError}

# Retry anything other than the failures under test, such as network errors.
function live(f; tries = 3)
    for i in 1:tries
        try
            return f()
        catch e
            (e isa EXPECTED || i == tries) && rethrow()
            sleep(5i)
        end
    end
end

const NOVALIDATE = O.Client(validate_responses = false)

# The call fails with `on` when responses are validated and with `off` when they aren't.
macro fails(on, off, call)
    quote
        @test_throws $(esc(on)) live(() -> $(esc(call))(O.DEFAULT_CLIENT))
        @test_throws $(esc(off)) live(() -> $(esc(call))(NOVALIDATE))
    end
end

@testset "EBIProteinsOpenAPI live" begin
    @testset "proteins" begin
        @fails SchemaError DecodeError c -> O.getbyaccession_2(ACC; client = c)
        @fails SchemaError DecodeError c -> O.search_2(; accession = ACC, client = c)
        @fails SchemaError DecodeError c -> O.search_2(; accession = ACC, accept = "text/x-fasta", client = c)
        @fails NoCodec NoCodec c -> O.search_2(; accession = ACC, accept = "application/xml", client = c)
        # Raw response: with_http_info returns the HTTP details only alongside a decoded value.
        @fails SchemaError DecodeError c -> O.getbyaccession_2(ACC; with_http_info = true, client = c)
    end

    @testset "features" begin
        @fails SchemaError DecodeError c -> O.getbyaccession_4(ACC; categories = "TOPOLOGY", client = c)
        @fails SchemaError DecodeError c -> O.search_4(; accession = ACC, accept = "text/x-gff", client = c)
    end

    @testset "variation" begin
        @fails SchemaError DecodeError c -> O.getvariation(ACC; client = c)
    end

    @testset "proteomics" begin
        @fails SchemaError DecodeError c -> O.getnonptmbyaccession(ACC; client = c)
        @fails SchemaError DecodeError c -> O.getbyaccession_10(ACC; confidence_score = "Gold", client = c)
    end

    @testset "antigen" begin
        @fails SchemaError DecodeError c -> O.getbyaccession(ACC; client = c)
    end

    @testset "genecentric" begin
        @fails SchemaError ArgumentError c -> O.getgenecentricbyaccession(ACC; client = c)
    end

    @testset "proteomes" begin
        @fails SchemaError DecodeError c -> O.getbyupid(UPID; client = c)
    end

    @testset "taxonomy" begin
        # The spec omits /taxonomy/*, and the client has no public way to call a path that isn't in the spec.
        @test !any(n -> occursin("taxonomy", lowercase(String(n))) && isdefined(O, n) && getfield(O, n) isa Function,
                   names(O; all = true))
        @test_skip "GET /taxonomy/id/9606"
    end

    @testset "uniparc" begin
        @fails SchemaError DecodeError c -> O.getuniparcentrybyupid(UPI; client = c)
        # The sequence of UPI0000000114, fetched directly, since the client can't decode the entry.
        resp = live(() -> O.HTTP.get("https://www.ebi.ac.uk/proteins/api/uniparc/upi/$UPI", ["Accept" => "application/json"]))
        seq = O.JSON.parse(String(resp.body))["sequence"]["content"]
        @fails SchemaError DecodeError c -> O.getbysequence(O.UniparcSequenceParam(sequence = seq); client = c)
        # In the spec, but the service returns no entries for any proteome.
        @test_broken !isempty(live(() -> O.getbyproteomeid(UPID; size = Int32(1))))
    end

    @testset "coordinates" begin
        @fails SchemaError DecodeError c -> O.getbyaccession_1(ACC; client = c)
        @fails SchemaError DecodeError c -> O.getgenomelocationbyaccession(ACC, Int32(10), Int32(20); client = c)
    end

    @testset "requests" begin
        @test_skip "the URL of a request"   # requests are built and sent in one call
        # Lists are comma-separated strings; a Vector is a TypeError.
        @test_throws TypeError O.search_2(; accession = ACC, taxid = [9606, 10090], reviewed = "true")
        @fails SchemaError DecodeError c -> O.getbyaccession_4(ACC; categories = "TOPOLOGY,PTM", client = c)
        @test_throws TypeError O.search_2(; offset = "10")
        @test_skip "paginate only searches"   # no pagination helper
    end

    @testset "paginate" begin
        @test_skip "pages of a search"   # no pagination helper
    end

    @testset "errors" begin
        # The accession is checked against the spec's pattern before anything is sent.
        @test_throws SchemaError O.getbyaccession_2("NOTANACCESSION")
        # An unknown format is sent, and the service rejects it.
        @test_throws O.ApiError O.getbyaccession_2(ACC; accept = "image/png")
    end

    @testset "style-specific" begin
        # Integer parameters are Int32, so a plain Int is a TypeError or MethodError.
        @test_throws TypeError O.getbyproteomeid(UPID; size = 1)
        @test_throws MethodError O.getgenomelocationbyaccession(ACC, 10, 20)
        # Booleans the spec declares as strings must be passed as strings.
        @test_throws TypeError O.search_2(; accession = ACC, reviewed = true)
    end
end
