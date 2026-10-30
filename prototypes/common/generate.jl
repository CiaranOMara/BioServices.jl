# Regenerate the custom-generated prototype EBI Proteins clients from the committed OpenAPI spec snapshot:
#
#   julia --project=prototypes/common prototypes/common/generate.jl          # regenerate from openapi.json here
#   julia --project=prototypes/common prototypes/common/generate.jl --fetch  # refresh that snapshot first
#
# Each prototype has its own generator, in its package's gen/ directory, which can also be run on its own.
# Each includes spec.jl here, for the snapshot and the operations parsed from it, and render.jl, for the rendering helpers and the runtime files in runtime/:
#
# - prototypes/EBIProteinsFunctions/gen/generate.jl: one keyword function per operation.
# - prototypes/EBIProteinsKwarg/gen/generate.jl: one `JSON.@kwarg` request type per operation.
# - prototypes/EBIProteinsRestClient/gen/generate.jl: one RestClient.jl `@endpoint` per operation.
#
# The output depends only on the snapshot: same spec in, byte-identical files out.
# The snapshot is stored normalised (keys sorted, two-space indent), so a reordering of keys in the live spec is not a change.
# The generated code uses HTTP.jl and JSON.jl, or RestClient.jl and JSON.jl.
# This generator environment (Project.toml here) is not part of the prototypes/ workspace: it runs on Julia 1.6 with JSON 0.21, while EBIProteinsKwarg and EBIProteinsRestClient need JSON 1.x.

include(joinpath(@__DIR__, "spec.jl"))
include(joinpath(@__DIR__, "..", "EBIProteinsFunctions", "gen", "generate.jl"))
include(joinpath(@__DIR__, "..", "EBIProteinsKwarg", "gen", "generate.jl"))
include(joinpath(@__DIR__, "..", "EBIProteinsRestClient", "gen", "generate.jl"))

"--fetch" in ARGS && fetch_spec()
spec, bytes = load_spec()
EBIProteinsFunctionsGenerator.generate(spec, bytes)
EBIProteinsKwargGenerator.generate(spec, bytes)
EBIProteinsRestClientGenerator.generate(spec, bytes)
