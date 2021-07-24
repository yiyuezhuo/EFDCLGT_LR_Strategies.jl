
Base.@kwdef mutable struct DecisionState
    hub_base::Hub
    undecided_begin::DateTime
    
    proposed_sep::DateTime=typemax(DateTime) 
    # proposed_sep == typemax(DateTime) denote it had not been computed or there is no proposed sep (fast forward mode)
    range4::Union{Nothing, Range4}=nothing

    inflow_dt_vec_selected::Union{Nothing, Vector{Tuple{Inflow, DateTime}}}=nothing

    hub_p::Union{Nothing, Hub}=nothing

    so::Union{Nothing, SearchOpt}=nothing # TODO: How to specify many type parameters of SearchOpt easily?

    hub_project::Union{Nothing, Hub}=nothing
    hub_eval::Union{Nothing, Hub}=nothing
end

function DecisionState(hub_base::Hub, undecided_begin::DateTime; kwargs...)
    return DecisionState(;hub_base, undecided_begin, kwargs...)
end

function DecisionState(hub_base::Hub; kwargs...)
    undecided_begin = get_begin_day(DateTime, hub_base)
    return DecisionState(hub_base, undecided_begin; kwargs...)
end

function Base.show(io::IO, ds::DecisionState)
    println(io, "sim_range(hub_base)->$(get_sim_range(ds.hub_base))")
    if !isnothing(ds.hub_project)
        println(io, "sim_range(hub_project)->$(get_sim_range(ds.hub_project))")
    end
    if !isnothing(ds.hub_eval)
        println(io, "sim_range(hub_eval)->$(get_sim_range(ds.hub_eval))")
    end
    simple_show(io, ds, thres=200)
end

Base.@kwdef struct DecisionMaker{FT <: Function, ST <: Separator, T <: Period}
    f::FT
    separator_vec::Vector{ST}
    strap::Strap
    opt_dst::String
    state_vec::Vector{DecisionState}

    # Shared default parameters
    right_relax::T=Hour(6)
    eval_lag::T=Hour(24)

    # Specific default parameters
    find_right_cross_kwargs::NamedTuple=(;)
    pure_balancer_kwargs::NamedTuple=(;)
    SearchOpt_kwargs::NamedTuple=(;)
end

function DecisionMaker(f::Function, separator_vec::Vector{<:Separator}, strap::Strap,
                        opt_dst::String, state_initial::DecisionState; kwargs...)
    state_vec = [state_initial]
    return DecisionMaker(;f, separator_vec, strap, opt_dst, state_vec, kwargs...)
end

function Base.show(io::IO, dm::DecisionMaker)
    println(io, "length(state_vec)=$(length(dm.state_vec))")
    simple_show(io, dm, thres=200)
end

function find_right_cross!(dm::DecisionMaker, ds::DecisionState)
    dt = find_right_cross(dm.f, dm.separator_vec, ds.hub_base, dm.strap, ds.undecided_begin; 
                            dm.find_right_cross_kwargs...)
    ds.proposed_sep = dt
    if ds.proposed_sep == typemax(DateTime)
        return
    end
    ds.range4 = Range4(ds.hub_base, ds.undecided_begin, ds.proposed_sep, dm.right_relax, dm.eval_lag)
end

function balance!(dm::DecisionMaker, ds::DecisionState)
    ds.inflow_dt_vec_selected = pure_balancer(dm.f, ds.hub_base, dm.strap, ds.undecided_begin, ds.proposed_sep;
                                            dm.pure_balancer_kwargs..., right_relax=dm.right_relax, 
                                            eval_lag=dm.eval_lag)
    ds.hub_p = create_balanced_hub(ds.hub_base, dm.strap, ds.range4.eval_range, ds.inflow_dt_vec_selected)
end

function search!(dm::DecisionMaker, ds::DecisionState)
    ds.so = SearchOpt(dm.f, ds.hub_base, dm.strap, ds.undecided_begin, ds.proposed_sep, dm.opt_dst;
                        dm.SearchOpt_kwargs...,
                        hub_p=ds.hub_p, right_relax=dm.right_relax, eval_lag=dm.eval_lag)
    solve!(ds.so)
end

function project!(dm::DecisionMaker, ds::DecisionState)
    ds.hub_project, ds.hub_eval = hub_vec = map(1:2) do _
        return apply_code(ds.so.hub_p, dm.strap, ds.so.min_load_code, 
                            ds.so.min_load_pump_natural_time, ds.undecided_begin)
    end

    if length(ds.range4.project_range) == 0
        run_simulation!(ds.hub_eval)
    else
        set_sim_length!(ds.hub_project, ds.range4.project_range[end])
        
        # TODO: Enable different end scheduler or use restarting/auto_step manually.
        task_vec = map(hub_vec) do hub
            return @async run_simulation!(hub) # they have different sim_length, so call run_simulation! one by one.
        end
        foreach(wait, task_vec)
    end
end

function fork!(dm::DecisionMaker)
    ds = dm.state_vec[end]

    if is_over(ds.hub_project)
        hub_base = fork(ds.hub_project)
    else # when decision interval is < 1 day
        hub_base = copy(ds.hub_project)
    end

    ds_new = DecisionState(hub_base, ds.range4.interested_range[end] + Hour(1)) # TODO: ⊐̸ Hour(1)
    push!(dm.state_vec, ds_new)
end

function step!(dm::DecisionMaker)
    ds = dm.state_vec[end]

    find_right_cross!(dm, ds)

    @info "proposed_sep=$(ds.proposed_sep)"

    if ds.proposed_sep == typemax(DateTime)
        @warn "proposed_sep is not found, fast forward."
        return false
    end

    balance!(dm, ds)
    search!(dm, ds)
    project!(dm, ds)

    load_eval = loading(dm.f, dm.opt_dst, ds.hub_eval, dm.strap, ds.range4.eval_range)
    @info "load_eval=$(load_eval), " *
          "min_load=$(ds.so.min_load), " *
          "min_load_code=$(ds.so.min_load_code), " * 
          "min_load_pump_natural_time=$(ds.so.min_load_pump_natural_time), "

    fork!(dm)
    return true
end
