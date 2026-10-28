# Regenerate the EBIProteinsFunctions prototype client from the committed OpenAPI spec snapshot:
#
#   julia --project=prototypes/common prototypes/common/generate.jl          # regenerate from openapi.json here
#   julia --project=prototypes/common prototypes/common/generate.jl --fetch  # refresh that snapshot first
#
# The generator, prototypes/EBIProteinsFunctions/gen/generate.jl, is in its package's gen/ directory and can also be run on its own; it includes shared.jl here for the snapshot and the spec model.
#
# The output depends only on the snapshot: same spec in, byte-identical files out.
# The snapshot is stored normalised (keys sorted, two-space indent), so a reordering of keys in the live spec is not a change.
# The generated code uses only HTTP.jl and JSON.jl.
# This generator environment (Project.toml here) is not part of the prototypes/ workspace: it runs on Julia 1.6 with JSON 0.21.

include(joinpath(@__DIR__, "shared.jl"))
include(joinpath(@__DIR__, "..", "EBIProteinsFunctions", "gen", "generate.jl"))

"--fetch" in ARGS && fetch_spec()
spec, bytes = load_spec()
EBIProteinsFunctionsGenerator.generate(spec, bytes)
