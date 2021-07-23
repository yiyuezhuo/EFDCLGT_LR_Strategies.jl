
abstract type Sampler end

struct FixedStepSampler <: Sampler
    step::Int
end

function sample(s::FixedStepSampler, n::Int)
    return (1:n)[1:s.step:end]
end

struct IncStepSampler <: Sampler
    base::Float64
end

"""
base=6 ->

step:
1-6：1
7-9：2
10-11：3
12-13: 4
...
->
[1,2,3,4,5,6, 8,10,12, 15,18, 22,26, ...]

"""
function sample(s::IncStepSampler, n::Int)
    idx = 0
    yv = Int[]
    step = 1
    while idx <= n
        for _ in 1:ceil(Int, s.base / step)
            idx += step
            if idx > n
                break
            end
            push!(yv, idx)
        end
        step += 1
    end
    return yv
end
