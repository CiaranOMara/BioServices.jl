# Offline tests of ServiceRuntime: request building, format and error strategies, envelopes and decoding, against a service defined here.
# The generated clients' own tests call the real services.

using Test
import ServiceRuntime as R
using ServiceRuntime: Endpoint, ListParam, send, url, paginate
using ServiceRuntime.JSON: @kwarg, StructUtils
import ServiceRuntime.HTTP
import GFF3

struct Demo <: R.Service end
R.base_url(::Demo) = "https://example.org/api"
R.formats(::Demo) = (json = "application/json", gff = "text/x-gff")
R.envelope(::Demo) = "result"
R.errors(::Demo) = R.ErrorRule("error", "none", r"^### ERROR : (.*) ###")

@kwarg struct Lookup <: Endpoint{Demo, :GET}
    db::String = "main" &(in = :path,)
    k::Union{Nothing, Int} = nothing &(in = :path,)
    exact::Bool = false &(in = :path, literal = "exact",)
    id::String &(in = :path,)
    tags::Union{Nothing, ListParam} = nothing
    types::Union{Nothing, ListParam} = nothing &(sep = "|",)
end
R.template(::Type{<:Lookup}) = "/{db}/{k}/{exact}/{id}"

response(body; status = 200) = HTTP.Response(status, Vector{UInt8}(body))

@testset "ServiceRuntime" begin
    @testset "paths and queries" begin
        @test R.path(Lookup(id = "X1")) == "/main/X1"
        @test R.path(Lookup(id = "X1", k = 2, exact = true)) == "/main/2/exact/X1"
        @test R.path(Lookup(id = "a/b")) == "/main/a%2Fb"
        @test R.query(Lookup(id = "X1", tags = ["a", "b"], types = ["T1", "T2"])) == ["tags" => "a,b", "types" => "T1|T2"]
        @test R.query(Lookup(id = "X1", tags = "a,b")) == ["tags" => "a,b"]
        @test isempty(R.query(Lookup(id = "X1")))
    end

    @testset "format strategies" begin
        e = Lookup(id = "X1", tags = ["a"])
        @test url(e) == "https://example.org/api/main/X1?tags=a"
        h = Pair{String, String}[]
        @test R._select(Demo(), R.ByHeader(), R.Format{:gff}(), "/p", Pair{String, String}[], h) == ("/p", Pair{String, String}[])
        @test h == ["Accept" => "text/x-gff"]
        @test R._select(Demo(), R.ByExtension(), R.Format{:gff}(), "/p", Pair{String, String}[], h)[1] == "/p.gff"
        @test R._select(Demo(), R.ByQuery("format"), R.Format{:gff}(), "/p", Pair{String, String}[], h)[2] == ["format" => "gff"]
        @test R.Format(Demo(), "text/x-gff") === R.Format{:gff}()
        @test_throws ArgumentError R.Format(Demo(), :xml)
        @test_throws ArgumentError R.Format(Demo(), "text/html")
    end

    @testset "credentials" begin
        q = Pair{String, String}[]
        withenv("DEMO_KEY" => "secret") do
            R._authorise!(R.QueryKey("apiKey", "DEMO_KEY"), q, Pair{String, String}[])
        end
        @test q == ["apiKey" => "secret"]
        withenv("DEMO_KEY" => nothing) do
            @test_throws ArgumentError R._authorise!(R.QueryKey("apiKey", "DEMO_KEY"), q, Pair{String, String}[])
        end
    end

    @testset "errors reported with HTTP 200" begin
        rule = R.errors(Demo())
        @test R._check(rule, R.Format{:json}(), response("""{"error": "none", "result": 1}""")) === nothing
        @test_throws R.ServiceError R._check(rule, R.Format{:json}(), response("""{"error": "too many mismatches"}"""))
        @test R._check(rule, R.Format{:json}(), response("[1, 2]")) === nothing
        err = try
            R._check(rule, R.Format{:gff}(), response("### ERROR : too many mismatches ###\n"))
        catch e
            e
        end
        @test err isa R.ServiceError && err.message == "too many mismatches"
        @test R._check(R.NoErrors(), R.Format{:json}(), response("""{"error": "x"}""")) === nothing
    end

    @testset "envelopes and decoding" begin
        resp = response("""{"pageCount": 1, "result": [{"ui": "C1", "name": "a", "extra": 0}]}""")
        @test R._decode(Demo(), R.Format{:json}(), resp, true)[1]["ui"] == "C1"
        @kwarg struct Item
            ui::String
            name::String
        end
        @test R._decode(Demo(), R.Format{:json}(), resp, Vector{Item}) == [Item("C1", "a")]
        @test R._decode(Demo(), R.Format{:gff}(), response("x"), true) == "x"   # only JSON has an envelope
        @test_throws ArgumentError R._decodable(R.Format{:gff}(), Vector{Item})
    end

    @testset "GFF3 extension" begin
        @test R.defaultformat(Vector{GFF3.Record}) == :gff
        R._decodable(R.Format{:gff}(), Vector{GFF3.Record})   # does not throw
        gff = """
            ##gff-version 3
            track name=GGGenome description="GGGenome matches"
            chr1\tGGGenome\tmatch\t11\t29\t.\t+\t.\tsnippet=ACGT
            P1\tUniProt\tChain\t1\t9\t.\t.\t.\t.
            P1\tUniProt\tVariant\t5\t5\t.\t.\t.\tp.Met1Lys;ftId=VAR_1
            """
        records = R.decode(R.Format{:gff}(), response(gff), Vector{GFF3.Record})
        @test length(records) == 3
        @test GFF3.seqid(records[1]) == "chr1" && GFF3.seqstart(records[1]) == 11
        @test isempty(GFF3.attributes(records[2]))
        @test GFF3.attributes(records[3], "Note") == ["p.Met1Lys"]
        none = "##gff-version 3\ntrack name=GGGenome\n### No items found. ###\n"
        @test isempty(R.decode(R.Format{:gff}(), response(none), Vector{GFF3.Record}))
    end

    @testset "paging" begin
        @test_throws ArgumentError paginate(Lookup(id = "X1"))   # Demo has no paging strategy
    end
end
