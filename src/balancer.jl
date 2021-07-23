
function get_inflow_mean_flow_map(hub_base::Hub, strap::Strap)
    inflow_mean_flow_map = Dict{Inflow, DateDataFrame}() # TODO: Make alternative options rather than mean?
    # Julia leverage object equivalence instead of memory address as key.

    for inflow in strap.inflow_vec
        fl = flow(Limit(), hub_base, inflow)
        inflow_mean_flow_map[inflow] = reduce(.+, fl) ./ length(fl)
    end

    return inflow_mean_flow_map
end

function get_ditch_mean_flow_map(hub_base::Hub, strap::Strap)
    ditch_mean_flow_map = Dict{Ditch, DateDataFrame}() # TODO: Make alternative options rather than mean?
    # Julia leverage object equivalence instead of memory address as key.

    for ditch in strap.ditch_vec
        fl = flow(hub_base, ditch)
        ditch_mean_flow_map[ditch] = reduce(.+, fl) ./ length(fl)
    end

    return ditch_mean_flow_map
end



function pure_balancer(f::Function, hub_base::Hub, strap::Strap, undecided_begin::DateTime, proposed_sep::DateTime;
                    balancer_window::T=Hour(6), coef=1., coef_ditch=coef, coef_inflow=coef,
                    right_relax::T=Hour(6), eval_lag::T=Hour(24)) where T <: Period
    _range3::Range3{T}=Range3(hub_base, undecided_begin, proposed_sep, right_relax, eval_lag)

    # undecided_range::StepRange{DateTime, T}=_range3.undecided_range
    # interested_range::StepRange{DateTime, T}=_range3.interested_range
    eval_range::StepRange{DateTime, T}=_range3.eval_range

    inflow_mean_conc_map::Dict{Inflow, DateDataFrame}=get_inflow_mean_conc_map(f, hub_base, strap)
    inflow_mean_inflow_map = get_inflow_mean_flow_map(hub_base, strap)
    ditch_mean_inflow_map = get_ditch_mean_flow_map(hub_base, strap)

    pump_null_flow = sum(pump->pump.value * 3600, strap.pump_null_vec) # TODO: ⊐̸ m3/s -> m3/h
    @info "pump_null_flow=$pump_null_flow, coef=$coef, balancer_window=$balancer_window"

    inflow_dt_vec = Iterators.product(strap.inflow_vec, eval_range) |> collect |> vec
    inflow_dt_vec_desc = sort(inflow_dt_vec, by=inflow_dt->inflow_mean_conc_map[inflow_dt[1]][inflow_dt[2]], rev=true)

    ditch_dt_vec = Iterators.product(strap.ditch_vec, eval_range) |> collect |> vec

    quota_map = Dict(t=>pump_null_flow for t in eval_range)

    for (ditch, dt) in ditch_dt_vec
        challenge_flow = ditch_mean_inflow_map[ditch][dt] * coef_ditch
        balancer_begin = max(dt-balancer_window, undecided_begin)
        balancer_range = balancer_begin:Hour(1):dt # TODO: ⊐̸ Hour(1)

        for t in balancer_range
            if quota_map[t] == 0
                continue
            elseif challenge_flow > quota_map[t]
                challenge_flow -= quota_map[t]
                quota_map[t] = 0
            else
                quota_map[t] -= challenge_flow
                break
            end
        end
    end

    inflow_dt_vec_selected = filter(inflow_dt_vec_desc) do (inflow, dt)
        challenge_flow = inflow_mean_inflow_map[inflow][dt] * coef_inflow
        balancer_begin = max(dt-balancer_window, undecided_begin)
        balancer_range = balancer_begin:Hour(1):dt # TODO: ⊐̸ Hour(1)

        if sum(t->quota_map[t], balancer_range) < challenge_flow
            # @show inflow dt challenge_flow sum(t->quota_map[t], balancer_range)
            return false
        end

        for t in balancer_range
            if quota_map[t] == 0
                continue
            elseif challenge_flow > quota_map[t]
                challenge_flow -= quota_map[t]
                quota_map[t] = 0
            else
                quota_map[t] -= challenge_flow
                break
            end
        end

        return true
    end

    @info "pure_balancer: $(length(inflow_dt_vec)) -> $(length(inflow_dt_vec_selected))"

    return inflow_dt_vec_selected
end

function create_balanced_hub(hub_base::Hub, strap::Strap, eval_range, inflow_dt_vec_selected)
    hub = _create_prototype(hub_base, strap, eval_range)

    for (inflow, dt) in inflow_dt_vec_selected
        open!(hub, inflow, dt:Hour(1):dt) 
        # TODO: modify DateDataFrames to use `open!(hub, inflow, dt:Hour(1):dt)`.
        # TODO: Performance issue, ≈ 0.01s
        # TODO: ⊐̸ Hour(1)
    end

    return hub
end

