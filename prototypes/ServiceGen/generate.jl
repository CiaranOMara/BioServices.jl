# Generate clients built on prototypes/ServiceRuntime from hand-written service descriptions, for services that publish no OpenAPI spec:
#
#   julia --project=prototypes/ServiceGen prototypes/ServiceGen/generate.jl prototypes/GGGenome prototypes/UMLS
#
# Each argument is a package directory; its gen/service.toml is read and its src/<name>.jl is written.
# description.jl reads the TOML into a `Service` description, and writer.jl writes a client from any `Service`.
module ServiceGen

include("description.jl")
include("writer.jl")

"Write the client of the package in `dir` from its gen/service.toml."
function generate(dir)
    source = joinpath(dir, "gen", "service.toml")
    s = read_service(source)
    out = joinpath(dir, "src", s.name * ".jl")
    relative = replace(relpath(abspath(source), dirname(@__DIR__) |> dirname), '\\' => '/')
    write(out, render(s, relative, read(source)))
    println("wrote ", out)
end

end # module

abspath(PROGRAM_FILE) == (@__FILE__) && foreach(ServiceGen.generate, ARGS)
