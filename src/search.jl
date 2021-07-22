
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

function apply_code(hub_p::Hub, strap::Strap, code::Dict; 
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

function search_opt(f::Function, hub_base::Hub, strap::Strap, undecided_begin::DateTime, proposed_sep::DateTime, opt_dst::String;
                step=length(strap.inflow_vec), batch_window_size=24, sub_window_size=12, right_relex=Hour(6),
                pump_natural_anchor_time=Hour(48), pump_search_time_vec=Hour.([0, 1, 2, 3, 4, 5, 6, 8, 12, 24, 48, 72]),
                eval_lag=Hour(24),
                hub_running_mode=AutoRestartCutScheduler())
    @debug "search: undecided_begin=$undecided_begin, proposed_sep=$proposed_sep, opt_dst=$opt_dst, step=$step, " * 
           "batch_window_size=$batch_window_size, sub_window_size=$sub_window_size, right_relex=$right_relex, " *
           "pump_natural_anchor_time=$pump_natural_anchor_time, pump_search_time_vec=$pump_search_time_vec" *
           "hub_running_mode=$hub_running_mode"

    @assert batch_window_size % sub_window_size == 0

    _undecided_range = get_undecided_range(hub_base)
    @assert undecided_begin >= _undecided_range[1]
    @assert proposed_sep <= _undecided_range[end]

    undecided_range = undecided_begin : _undecided_range.step : _undecided_range[end]
    interested_range = undecided_begin : _undecided_range.step : min(proposed_sep + right_relex, _undecided_range[end])
    eval_range = undecided_begin : _undecided_range.step : min(ceil(proposed_sep + right_relex + eval_lag, Day) - Hour(1), _undecided_range[end])

    @debug "undecided_range=$undecided_range, interested_range=$interested_range, eval_range=$eval_range"

    inflow_mean_conc_map = Dict{Inflow, DateDataFrame}() # TODO: Make alternative options rather than mean?
    # Julia leverage object equivalence instead of memory address as key.

    for inflow in strap.inflow_vec
        conc = concentration(f, hub_base, inflow)
        inflow_mean_conc_map[inflow] = reduce(.+, conc) ./ length(conc)
    end

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

    code_vec = [Dict(max_inflow=>[max_dt, max_dt])]
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

    hub_p = _create_prototype(hub_base, strap, eval_range)

    min_load = +Inf
    min_load_code = Dict{Inflow, Vector{DateTime}}()

    for batch_window in Iterators.partition(code_vec[1:step:end], batch_window_size)
        hub_vec = map(batch_window) do code
            return apply_code(hub_p, strap, code; 
                            pump_natural_time=pump_natural_anchor_time, undecided_begin)
        end

        run_simulation!(hub_running_mode, hub_vec)

        _load_vec = loading.(f, opt_dst, hub_vec, strap, [eval_range])
        load_vec = mean.(_load_vec)
        @info "pump_natural_anchor_time=$pump_natural_anchor_time"
        @info desc(batch_window, _load_vec, load_vec)

        no_confidence = false
        @assert length(batch_window) == length(load_vec)
        for sub_idx_vec in Iterators.partition(1:length(batch_window), sub_window_size)
            sub_batch_window = batch_window[sub_idx_vec]
            sub_load_vec = load_vec[sub_idx_vec]

            idx = argmin(sub_load_vec)
            _min_load = sub_load_vec[idx]
            if _min_load < min_load
                if no_confidence
                    @warn "Nonmonotonic sub window detected, parameters may be not proper."
                end
                min_load = _min_load
                min_load_code = sub_batch_window[idx]
                no_confidence = false
            else
                no_confidence = true
            end
        end
        
        @debug "min_load=$min_load, no_confidence=$no_confidence, min_load_code=$min_load_code"

        if no_confidence
            break
        end
    end

    hub_vec = map(pump_search_time_vec) do pump_natural_time
        return apply_code(hub_p, strap, min_load_code; pump_natural_time, undecided_begin)
    end

    run_simulation!(hub_running_mode, hub_vec)

    _load_vec = loading.(f, opt_dst, hub_vec, strap, [eval_range])
    load_vec = mean.(_load_vec)

    @info "min_load_code=$(desc(min_load_code))"
    @info desc(pump_search_time_vec, _load_vec, load_vec)

    idx = argmin(load_vec)
    min_load_pump_natural_time = pump_search_time_vec[idx]

    return min_load_code, min_load_pump_natural_time
end
