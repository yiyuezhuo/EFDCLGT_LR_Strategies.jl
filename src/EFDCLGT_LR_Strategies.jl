module EFDCLGT_LR_Strategies

using Base: IteratorEltype
export find_right_cross, SepMutualSimple, SepMutualBased, SepMeanSimple, SepMeanBased,
        SearchOpt, solve!

using DateDataFrames
#=
EFDCLGT_LR_Strategies should not import "low level" packages such as EFDCLRGT_LR_Files and EFDCLGRT_LR_Routes,
if some names are required, they should be exported from EFDCLGT_LR_Routes.
=#
# using EFDCLRGT_LR_Files
# using EFDCLGRT_LR_Routes
using EFDCLGT_LR_Routes
using EFDCLGT_LR_Routes: AbstractRoute

using Dates
using Statistics

include("utils.jl")
include("separators.jl")
include("search.jl")
include("allocate.jl")

end # module
