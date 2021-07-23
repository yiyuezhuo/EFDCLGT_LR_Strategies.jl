
# While it's more natural to use a pure function. 
# We need a stateful object to avoid call costy run_simulation! again and again for a tiny bug.



function get_initial_inflow_dt(strap::Strap, inflow_mean_conc_map, interested_range)
    max_conc = -Inf
    max_dt = typemin(DateTime)
    max_inflow = strap.inflow_vec[1]
    for inflow in strap.inflow_vec
        ddf = inflow_mean_conc_map[inflow]
        for dt in interested_range
            if ddf[dt] > max_conc
                max_conc = ddf[dt]
                max_dt = dt
                max_inflow = max_inflow
            end
        end
    end

    @assert max_conc > -Inf
    initial_dt = max_dt

    return max_inflow, initial_dt
end

function get_inflow_mean_conc_map(f::Function, hub_base::Hub, strap::Strap)
    inflow_mean_conc_map = Dict{Inflow, DateDataFrame}() # TODO: Make alternative options rather than mean?
    # Julia leverage object equivalence instead of memory address as key.

    for inflow in strap.inflow_vec
        conc = concentration(f, hub_base, inflow)
        inflow_mean_conc_map[inflow] = reduce(.+, conc) ./ length(conc)
    end

    return inflow_mean_conc_map
end

function build_code_vec(inflow_mean_conc_map, interested_range, initial_inflow, initial_dt)
    code_vec = [Dict(initial_inflow=>[initial_dt, initial_dt])]
    while true # TODO: step can be applied here and many deepcopy can be avoid, however, I leave them as it's easier to understand.
        code_prev = code_vec[end]

        conc_vec = Float64[]
        code_probe_vec = similar(code_vec, 0)

        for inflow in keys(inflow_mean_conc_map)
            if inflow in keys(code_prev)
                left_probe = code_prev[inflow][1] - Hour(1) # TODO ⊐̸ Hour(1)
                right_probe = code_prev[inflow][2] + Hour(1)
                if left_probe >= interested_range[1] 
                    push!(conc_vec, inflow_mean_conc_map[inflow][left_probe])
                    code = deepcopy(code_prev)
                    code[inflow][1] = left_probe
                    push!(code_probe_vec, code)
                end
                if right_probe <= interested_range[end]
                    push!(conc_vec, inflow_mean_conc_map[inflow][right_probe])
                    code = deepcopy(code_prev)
                    code[inflow][2] = right_probe
                    push!(code_probe_vec, code)
                end
            else
                push!(conc_vec, inflow_mean_conc_map[inflow][initial_dt])
                code = deepcopy(code_prev)
                code[inflow] = [initial_dt, initial_dt]
                push!(code_probe_vec, code)
            end
        end

        if length(conc_vec) == 0
            break
        else
            # @show code_probe_vec[argmax(conc_vec)]
            push!(code_vec, code_probe_vec[argmax(conc_vec)])
        end
    end

    @debug "length(code_vec)=$(length(code_vec))"

    return code_vec
end

function _create_prototype(hub_base::Hub, strap::Strap, eval_range)
    hub_p = copy(hub_base)

    set_sim_length!(hub_p, eval_range[end])

    for inflow in strap.inflow_vec
        close!(hub_p, inflow, eval_range)
    end
    for pump_null in strap.pump_null_vec
        open!(hub_p, pump_null, eval_range)
    end
    for pump_natural in strap.pump_natural_vec
        close!(hub_p, pump_natural, eval_range)
    end
    return hub_p
end

function apply_code(hub_p::Hub, strap::Strap, code::Dict, 
                    pump_natural_time::Period, undecided_begin::DateTime)
    hub = copy(hub_p)

    left_left = minimum([left_right[1] for left_right in values(code)])
    pump_natural_r = max(left_left - pump_natural_time, undecided_begin):Hour(1):(left_left-Hour(1)) # TODO, ⊐̸ Hour(1)
    if length(pump_natural_r) > 0
        for pump_natural in strap.pump_natural_vec
            open!(hub, pump_natural, pump_natural_r)
        end
    end
    for (inflow, left_right) in code
        r = left_right[1]:Hour(1):left_right[2]
        open!(hub, inflow, r)
    end
    
    return hub
end

Base.@kwdef mutable struct SearchOpt{F <: Function, ST <: Sampler, T <: Period, RT <: HubRunningMode, IT}
    f::F
    hub_base::Hub
    strap::Strap
    undecided_begin::DateTime
    proposed_sep::DateTime
    opt_dst::String

    # sampler::ST=FixedStepSampler(length(strap.inflow_vec))
    sampler::ST=IncStepSampler(length(strap.inflow_vec) * 2)
    batch_window_size::Int=24
    sub_window_size::Int=12
    right_relax::T=Hour(6)
    eval_lag::T=Hour(24)
    pump_natural_anchor_time::T=Hour(48)
    pump_search_time_vec::Vector{T}=Hour.([0, 1, 2, 3, 4, 5, 6, 8, 12, 24, 48, 72])
    # hub_running_mode::RT=NormalBatch()
    hub_running_mode::RT=AutoRestartCutScheduler()

    _range4::Range4{T}=Range4(hub_base, undecided_begin, proposed_sep, right_relax, eval_lag)

    undecided_range::StepRange{DateTime, T}=_range4.undecided_range
    interested_range::StepRange{DateTime, T}=_range4.interested_range
    eval_range::StepRange{DateTime, T}=_range4.eval_range
    project_range::StepRange{DateTime, T}=_range4.project_range

    # TODO: Generalization to other statistics, such as quantile, mean+coef*std etc...
    inflow_mean_conc_map::Dict{Inflow, DateDataFrame}=get_inflow_mean_conc_map(f, hub_base, strap)

    _initial_inflow_dt::Tuple{Inflow, DateTime}=get_initial_inflow_dt(strap, inflow_mean_conc_map, interested_range)
    
    initial_inflow::Inflow=_initial_inflow_dt[1]
    initial_dt::DateTime=_initial_inflow_dt[2]

    code_vec::Vector{Dict{Inflow, Vector{DateTime}}}=build_code_vec(inflow_mean_conc_map, interested_range, initial_inflow, initial_dt)

    hub_p::Hub=_create_prototype(hub_base, strap, eval_range)

    # The meaningful value of below attributions will be given in stateful method calling 
    hub_vec_vec::Vector{Vector{Hub}}=Vector{Hub}[]
    min_load::Float64=Inf
    min_load_code::Dict{Inflow, Vector{DateTime}}=Dict{Inflow, Vector{DateTime}}()

    batch_window::Vector{Dict{Inflow, Vector{DateTime}}}=Dict{Inflow, Vector{DateTime}}[]

    it::IT=Iterators.Stateful(Iterators.partition(code_vec[sample(sampler, length(code_vec))], batch_window_size))

    min_load_pump_natural_time::T=typemax(Hour)

    no_confidence::Bool=false
end

function SearchOpt(f::Function, hub_base::Hub, strap::Strap, undecided_begin::DateTime,
                     proposed_sep::DateTime, opt_dst::String; kwargs...)
    return SearchOpt(;f, hub_base, strap, undecided_begin, proposed_sep, opt_dst, kwargs...)
end

#=
function Base.show(io::IO, so::SearchOpt)
    for fn in fieldnames(typeof(so))
        v = getfield(so, fn)
        vs = "$v"
        if length(vs) > 100
            vs = "OMMITED"
        end
        println(io, "$fn: $vs")
    end
end
=#

Base.show(io::IO, so::SearchOpt) = simple_show(io, so)

function step_inflow_pre!(so::SearchOpt; batch_window=so.batch_window,
                                hub_p=so.hub_p, strap=so.strap, 
                                pump_natural_anchor_time=so.pump_natural_anchor_time, 
                                undecided_begin=so.undecided_begin,
                                hub_running_mode=so.hub_running_mode)

    hub_vec = map(batch_window) do code
        return apply_code(hub_p, strap, code, pump_natural_anchor_time, undecided_begin)
    end

    push!(so.hub_vec_vec, hub_vec)

    run_simulation!(hub_running_mode, hub_vec)
end

function step_inflow_post!(so::SearchOpt; batch_window=so.batch_window,
                            f=so.f, opt_dst=so.opt_dst, strap=so.strap, eval_range=so.eval_range,
                            pump_natural_anchor_time=so.pump_natural_anchor_time,
                            sub_window_size=so.sub_window_size,
                            no_confidence=so.no_confidence)

    hub_vec = so.hub_vec_vec[end]

    _load_vec = loading.(f, opt_dst, hub_vec, strap, [eval_range])
    load_vec = mean.(_load_vec)
    @info "pump_natural_anchor_time=$pump_natural_anchor_time"
    @info desc(batch_window, _load_vec, load_vec)

    @assert length(batch_window) == length(load_vec)
    for sub_idx_vec in Iterators.partition(1:length(batch_window), sub_window_size)
        sub_batch_window = batch_window[sub_idx_vec]
        sub_load_vec = load_vec[sub_idx_vec]

        idx = argmin(sub_load_vec)
        _min_load = sub_load_vec[idx]
        if _min_load < so.min_load
            if no_confidence
                @warn "Nonmonotonic sub window detected, parameters may be not proper."
            end
            so.min_load = _min_load
            so.min_load_code = sub_batch_window[idx]
            no_confidence = false
        else
            no_confidence = true
        end
    end
    
    @debug "min_load=$(so.min_load), min_load_code=$(so.min_load_code), no_confidence=$no_confidence"
    
    so.no_confidence = no_confidence
end

function step_inflow!(so::SearchOpt)
    so.batch_window = popfirst!(so.it)
    
    step_inflow_pre!(so)
    step_inflow_post!(so)
end

function solve_inflow!(so::SearchOpt)
    while !isempty(so.it) && !so.no_confidence
        step_inflow!(so)
    end
end

function solve_pump_pre!(so::SearchOpt; 
                        pump_search_time_vec = so.pump_search_time_vec, strap=so.strap, hub_p = so.hub_p,
                        min_load_code=so.min_load_code, undecided_begin=so.undecided_begin,
                        hub_running_mode=so.hub_running_mode)

    hub_vec = map(pump_search_time_vec) do pump_natural_time
        return apply_code(hub_p, strap, min_load_code, pump_natural_time, undecided_begin)
    end

    push!(so.hub_vec_vec, hub_vec)

    run_simulation!(hub_running_mode, hub_vec)
end

function solve_pump_post!(so::SearchOpt;
                        hub_vec=so.hub_vec_vec[end],
                        f=so.f, opt_dst=so.opt_dst, strap=so.strap, eval_range=so.eval_range,
                        min_load_code=so.min_load_code, pump_search_time_vec=so.pump_search_time_vec)
    _load_vec = loading.(f, opt_dst, hub_vec, strap, [eval_range])
    load_vec = mean.(_load_vec)

    @info "min_load_code=$(desc(min_load_code))"
    @info desc(pump_search_time_vec, _load_vec, load_vec)

    idx = argmin(load_vec)
    min_load_pump_natural_time = pump_search_time_vec[idx]
    min_load = load_vec[idx]

    so.min_load_pump_natural_time = min_load_pump_natural_time
    so.min_load = min_load
end

function solve_pump!(so::SearchOpt)
    solve_pump_pre!(so)
    solve_pump_post!(so)
end

function solve!(so::SearchOpt)
    solve_inflow!(so)
    solve_pump!(so)

    return so.min_load_code, so.min_load_pump_natural_time
end
