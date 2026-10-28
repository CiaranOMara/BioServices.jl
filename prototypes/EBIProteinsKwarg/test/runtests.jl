# Live tests: they call the real EBI Proteins service.
# Each file runs in its own module.
module LiveTests
include("live.jl")
end

module ExtensionTests
include("extensions.jl")
end
