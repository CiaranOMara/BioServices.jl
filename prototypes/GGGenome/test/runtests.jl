# Live tests of GGGenome against the real service.

using Test
import GGGenome as G
using GGGenome.R.JSON: @kwarg
import GGGenome.R.HTTP
import GFF3

const SEQ = "TTCATTGACAACATTGCGT"

# Retry transient network failures and 5xx responses.
function live(f; tries = 3)
    for i in 1:tries
        try
            return f()
        catch e
            i == tries && rethrow()
            e isa HTTP.StatusError && e.status < 500 && rethrow()
            e isa G.R.ServiceError && rethrow()
            sleep(5i)
        end
    end
end

# The fields of a match that the typed test needs, for `send(e, T)`.
@kwarg struct Match
    name::String
    strand::String
    position::Int
    position_end::Int
end
@kwarg struct Matches
    database::String
    results::Vector{Match}
end

@testset "GGGenome live" begin
    @testset "urls" begin
        @test G.url(G.Search(sequence = SEQ)) == "https://gggenome.dbcls.jp/hg38/$SEQ.json"
        @test G.url(G.Search(db = "mm10", k = 2, strand = "+", nogap = true, sequence = SEQ); accept = :txt) ==
              "https://gggenome.dbcls.jp/mm10/2/%2B/nogap/$SEQ.txt"
        @test_throws ArgumentError G.url(G.Search(sequence = SEQ); accept = :xml)
        @test_throws UndefKeywordError G.Search(k = 2)
    end

    @testset "json" begin
        r = live(() -> G.send(G.Search(sequence = SEQ, k = 2)))
        @test startswith(r["database"], "Human genome, GRCh38/hg38")
        @test r["error"] == "none" && length(r["results"]) > 10
        plus = live(() -> G.send(G.Search(sequence = SEQ, k = 2, strand = "+")))
        @test !isempty(plus["results"]) && all(m -> m["strand"] == "+", plus["results"])
        @test length(plus["results"]) < length(r["results"])
        @test isempty(live(() -> G.send(G.Search(sequence = SEQ)))["results"])   # no exact match in hg38
    end

    @testset "typed" begin
        m = live(() -> G.send(G.Search(sequence = SEQ, k = 2, strand = "+", nogap = true), Matches))
        @test m isa Matches && !isempty(m.results)
        @test all(x -> x.strand == "+" && x.position_end - x.position + 1 == length(SEQ), m.results)   # no gaps
    end

    @testset "text formats" begin
        txt = live(() -> G.send(G.Search(sequence = SEQ, k = 2); accept = :txt))
        @test startswith(txt, "# [ GGGenome") && occursin("# count:", txt)
        @test occursin("chr", live(() -> G.send(G.Search(sequence = SEQ, k = 2); accept = :csv)))
        @test startswith(live(() -> G.send(G.Search(sequence = SEQ, k = 2); accept = :bed)), "track name=GGGenome")
        @test live(() -> G.send(G.Search(sequence = SEQ, k = 2); parse = false)).status == 200   # raw response
    end

    @testset "GFF3 records" begin
        recs = live(() -> G.send(G.Search(sequence = SEQ, k = 2), Vector{GFF3.Record}))
        @test recs isa Vector{GFF3.Record} && length(recs) > 10
        @test all(r -> GFF3.featuretype(r) == "match" && GFF3.seqend(r) - GFF3.seqstart(r) + 1 >= length(SEQ) - 2, recs)
        @test isempty(live(() -> G.send(G.Search(sequence = SEQ), Vector{GFF3.Record})))   # "No items found"
    end

    @testset "errors reported with HTTP 200" begin
        @test_throws G.R.ServiceError live(() -> G.send(G.Search(sequence = SEQ, k = 9)))
        @test_throws G.R.ServiceError live(() -> G.send(G.Search(sequence = SEQ, k = 9); accept = :gff))
        @test_throws ArgumentError G.send(G.Search(sequence = SEQ), Vector{GFF3.Record}; accept = :txt)   # no decoder; nothing sent
        @test_throws ArgumentError G.paginate(G.Search(sequence = SEQ))
    end
end
