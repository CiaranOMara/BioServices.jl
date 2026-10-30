# Tests of UMLS: requests are built offline, and the live tests run against the real service when ENV["UMLS_API_KEY"] holds a UTS API key.

using Test
import UMLS as U
using UMLS.R.JSON: @kwarg
import UMLS.R.HTTP

const CUI = "C0009044"   # Closed fracture of carpal bone

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

@kwarg struct SearchResult
    ui::String
    name::String
end
@kwarg struct SearchResults
    results::Vector{SearchResult}
end

@testset "UMLS" begin
    @testset "requests" begin
        @test U.url(U.Concept(CUI = CUI)) == "https://uts-ws.nlm.nih.gov/rest/content/current/CUI/$CUI"
        @test U.url(U.Concept(version = "2024AA", CUI = CUI)) == "https://uts-ws.nlm.nih.gov/rest/content/2024AA/CUI/$CUI"
        @test U.url(U.Search(string = "carpal fracture", sabs = ["SNOMEDCT_US", "MSH"], semanticTypes = ["T046", "T047"])) ==
              "https://uts-ws.nlm.nih.gov/rest/search/current?string=carpal%20fracture&sabs=SNOMEDCT_US%2CMSH&semanticTypes=T046%7CT047"
        @test U.url(U.Crosswalk(source = "SNOMEDCT_US", id = "9468002", targetSource = "ICD10CM")) ==
              "https://uts-ws.nlm.nih.gov/rest/crosswalk/current/source/SNOMEDCT_US/9468002?targetSource=ICD10CM"
        @test_throws UndefKeywordError U.Search()
        @test_throws ArgumentError U.paginate(U.Concept(CUI = CUI))   # no pageNumber field
        @test U.paginate(U.ConceptRelations(CUI = CUI)) isa U.R.Pages
        withenv("UMLS_API_KEY" => nothing) do
            @test_throws ArgumentError U.send(U.Concept(CUI = CUI))   # nothing sent without a key
        end
        withenv("UMLS_API_KEY" => "not-a-key") do
            err = try
                U.send(U.Concept(CUI = CUI))
            catch e
                e
            end
            @test err isa HTTP.StatusError && err.status == 401
        end
    end

    if isempty(get(ENV, "UMLS_API_KEY", ""))
        @info "UMLS_API_KEY is not set, so the UMLS live tests are skipped"
        @testset "live (no UMLS_API_KEY)" begin
            @test_skip false
        end
    else
        @testset "live" begin
            c = live(() -> U.send(U.Concept(CUI = CUI)))   # the envelope's "result"
            @test c["ui"] == CUI && c["classType"] == "Concept"
            r = live(() -> U.send(U.Search(string = "fracture of carpal bone", searchType = "exact")))
            @test any(x -> x["ui"] == CUI, r["results"])
            typed = live(() -> U.send(U.Search(string = "fracture of carpal bone"), SearchResults))
            @test typed isa SearchResults && !isempty(typed.results)
            codes = live(() -> U.send(U.Search(string = CUI, sabs = "SNOMEDCT_US", returnIdType = "code")))
            @test !isempty(codes["results"])
            atoms = live(() -> U.send(U.ConceptAtoms(CUI = CUI, language = "ENG")))
            @test !isempty(atoms) && all(a -> a["language"] == "ENG", atoms)
            @test live(() -> U.send(U.SemanticType(TUI = "T037")))["name"] == "Injury or Poisoning"
            pages = collect(Iterators.take(U.paginate(U.ConceptRelations(CUI = CUI, pageSize = 2)), 2))
            @test length(pages) >= 1 && all(p -> p isa AbstractVector && length(p) <= 2, pages)
        end
    end
end
