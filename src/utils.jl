function desc(code::Dict{Inflow, Vector{DateTime}})
    items = ["$(inflow.src) $(left_right[1]) $(left_right[2])" for (inflow, left_right) in code]
    return join(items, " ")
end

desc(x::Union{<:Number, <:Period}) = "$x"

function desc(code_or_number_vec::AbstractVector{<:Union{Dict{Inflow, Vector{DateTime}}, <:Number, <:Period}}, load_vec_vec, load_vec)
    lines = map(zip(code_or_number_vec, load_vec_vec, load_vec)) do (code_or_number, _load_vec, _load)
        "$(desc(code_or_number)) $_load_vec $_load"
    end
    return join(lines, "\n")
end

function desc(dt::DateTime)
    return "$(year(dt))-$(month(dt))-$(day(dt))+$(hour(dt))"
end

function desc(dt::StepRange{DateTime, <:Period})
    return "$(desc(dt.start))->$(desc(dt.stop))"
end

function simple_show(io::IO, so; thres=100)
    for fn in fieldnames(typeof(so))
        v = getfield(so, fn)
        vs = "$v"
        if length(vs) > thres
            vs = "OMMITED"
        end
        println(io, "$fn: $vs")
    end
end

struct Range4{T}
    undecided_range::StepRange{DateTime, T}
    interested_range::StepRange{DateTime, T}
    eval_range::StepRange{DateTime, T}
    project_range::StepRange{DateTime, T}
end

function Base.show(io::IO, r::Range4)
    print(io, "Range4(undecided_range=$(desc(r.undecided_range)), interested_range=$(desc(r.interested_range)), " * 
            " eval_range=$(desc(r.eval_range)), project_range=$(desc(r.project_range)))")
end

function Range4(hub_base::Hub, undecided_begin::DateTime, proposed_sep::DateTime, right_relax::Period, eval_lag::Period)
    _undecided_range = get_undecided_range(hub_base)
    @assert undecided_begin >= _undecided_range[1]
    @assert proposed_sep <= _undecided_range[end]

    undecided_range = undecided_begin : _undecided_range.step : _undecided_range[end]
    interested_range = undecided_begin : _undecided_range.step : min(proposed_sep + right_relax, _undecided_range[end])
    eval_range = undecided_begin : _undecided_range.step : min(ceil(proposed_sep + right_relax + eval_lag, Day) - Hour(1), _undecided_range[end])

    project_end_dt = floor(interested_range[end], Day) - Hour(1) # ⊐̸ Hour(1)
    project_range = undecided_begin:Hour(1):project_end_dt

    @debug "undecided_range=$undecided_range, interested_range=$interested_range, eval_range=$eval_range, project_range=$project_range"
    
    return Range4(undecided_range, interested_range, eval_range, project_range)
end
