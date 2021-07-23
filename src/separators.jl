
function quantile_datetime_vec(dt_vec::AbstractVector{DateTime}, q)
    dt_vec = sort(dt_vec)
    idx = clamp(round(Int, length(dt_vec) * q), 1, length(dt_vec))
    return dt_vec[idx]
end

"""
Pre-computed info for separation
"""
struct SeparatorArgs
    hub_close::HubBacktrackView
    hub_open::HubBacktrackView
end

abstract type Separator end 

struct SepMutualSimple{IT <: AbstractRoute, OT <: AbstractRoute} <: Separator
    inflow_vec::Vector{IT}
    overflow_vec::Vector{OT}
    percent::Float64
end

struct SepMutualBased{IT <: AbstractRoute, OT <: AbstractRoute} <: Separator
    inflow_vec::Vector{IT}
    overflow_vec::Vector{OT}
    percent::Float64
end

struct SepMeanSimple{IT <: AbstractRoute, OT <: AbstractRoute} <: Separator
    inflow_vec::Vector{IT}
    overflow_vec::Vector{OT}
    percent::Float64
end

struct SepMeanBased{IT <: AbstractRoute, OT <: AbstractRoute} <: Separator
    inflow_vec::Vector{IT}
    overflow_vec::Vector{OT}
    percent::Float64
end


function separate(f::Function, sep::SepMutualSimple, sa::SeparatorArgs)
    hub = sa.hub_close

    earliest_dt = typemax(DateTime)
    for inflow in sep.inflow_vec
        ddf_vec_inflow = concentration(f, hub, inflow)
        for overflow in sep.overflow_vec
            ddf_vec_overflow = concentration(f, hub, overflow)
            dt_vec = DateTime[]
            for (ddf_inflow, ddf_overflow) in zip(ddf_vec_inflow, ddf_vec_overflow)
                ts = ddf_overflow.timestamp
                for (t_prev, t) in zip(ts[1:end-1], ts[2:end])
                    if (ddf_overflow[t] > ddf_inflow[t]) && (ddf_overflow[t_prev] < ddf_inflow[t_prev])
                        @debug inflow overflow ddf_overflow[[t_prev, t]] ddf_inflow[[t_prev, t]]
                        push!(dt_vec, t)
                        break
                    end
                end
            end
            if length(dt_vec) > 0
                dt = quantile_datetime_vec(dt_vec, sep.percent)
                earliest_dt = min(dt, earliest_dt)
            end
        end
    end
    return earliest_dt
end

function separate(f::Function, sep::SepMutualBased, sa::SeparatorArgs)
    hub = sa.hub_open
    hub_base = sa.hub_close

    earliest_dt = typemax(DateTime)
    for inflow in sep.inflow_vec
        ddf_vec_inflow = concentration(f, hub, inflow)
        for overflow in sep.overflow_vec
            ddf_vec_overflow = concentration(f, hub, overflow)
            ddf_base_vec_overflow = concentration(f, hub_base, overflow)
            dt_vec = DateTime[]
            for (ddf_inflow, ddf_overflow, ddf_base_overflow) in zip(ddf_vec_inflow, ddf_vec_overflow, ddf_base_vec_overflow)
                ts = ddf_overflow.timestamp
                for (t_prev, t) in zip(ts[1:end-1], ts[2:end])
                    if (ddf_overflow[t] > ddf_inflow[t]) && (ddf_overflow[t_prev] < ddf_inflow[t_prev])
                        if ddf_base_overflow[t] < ddf_overflow[t]
                            @debug inflow overflow ddf_overflow[[t_prev, t]] ddf_inflow[[t_prev, t]] ddf_base_overflow[[t_prev, t]]
                            push!(dt_vec, t)
                            break
                        end
                    end
                end
            end
            if length(dt_vec) > 0
                dt = quantile_datetime_vec(dt_vec, sep.percent)
                earliest_dt = min(dt, earliest_dt)
            end
        end
    end
    return earliest_dt
end

function separate(f::Function, sep::SepMeanSimple, sa::SeparatorArgs)
    hub = sa.hub_close

    ddf_inflow_vec = reduce(⊕, [concentration(f, hub, inflow) for inflow in sep.inflow_vec]) ⊘ length(sep.inflow_vec)
    ddf_overflow_vec = reduce(⊕, [concentration(f, hub, overflow) for overflow in sep.overflow_vec]) ⊘ length(sep.overflow_vec)
    
    dt_vec = DateTime[]

    for (ddf_inflow, ddf_overflow) in zip(ddf_inflow_vec, ddf_overflow_vec)
        ts = ddf_overflow.timestamp
        for (t_prev, t) in zip(ts[1:end-1], ts[2:end])
            if (ddf_overflow[t] > ddf_inflow[t]) && (ddf_overflow[t_prev] < ddf_inflow[t_prev])
                @debug sep.inflow_vec sep.overflow_vec ddf_overflow[[t_prev, t]] ddf_inflow[[t_prev, t]]
                push!(dt_vec, t)
                break
            end
        end
    end

    if length(dt_vec) > 0
        return quantile_datetime_vec(dt_vec, sep.percent)
    else
        return typemax(DateTime)
    end
end

# TODO: use dispatch refactor this one and the above one.
function separate(f::Function, sep::SepMeanBased, sa::SeparatorArgs)
    hub = sa.hub_open
    hub_base = sa.hub_close

    ddf_inflow_vec = reduce(⊕, [concentration(f, hub, inflow) for inflow in sep.inflow_vec]) ⊘ length(sep.inflow_vec)
    ddf_overflow_vec = reduce(⊕, [concentration(f, hub, overflow) for overflow in sep.overflow_vec]) ⊘ length(sep.overflow_vec)
    ddf_base_overflow_vec = reduce(⊕, [concentration(f, hub_base, overflow) for overflow in sep.overflow_vec]) ⊘ length(sep.overflow_vec)

    dt_vec = DateTime[]

    for (ddf_inflow, ddf_overflow, ddf_base_overflow) in zip(ddf_inflow_vec, ddf_overflow_vec, ddf_base_overflow_vec)
        ts = ddf_overflow.timestamp
        for (t_prev, t) in zip(ts[1:end-1], ts[2:end])
            if (ddf_overflow[t] > ddf_inflow[t]) && (ddf_overflow[t_prev] < ddf_inflow[t_prev])
                if ddf_base_overflow[t] < ddf_overflow[t]
                    @debug sep.inflow_vec sep.overflow_vec ddf_overflow[[t_prev, t]] ddf_inflow[[t_prev, t]] ddf_base_overflow[[t_prev, t]]
                    push!(dt_vec, t)
                    break
                end
            end
        end
    end

    if length(dt_vec) > 0
        return quantile_datetime_vec(dt_vec, sep.percent)
    else
        return typemax(DateTime)
    end
end


function _create_open_close_pair(hub_base::Hub, strap::Strap)
    undecided_range = get_undecided_range(hub_base)

    hub_vec = [copy(hub_base, detach=true) for _ in 1:2] # open, close

    for hub in hub_vec
        for pump_null in strap.pump_null_vec
            open!(hub, pump_null, undecided_range)
        end
        for pump_natural in strap.pump_natural_vec
            close!(hub, pump_natural, undecided_range)
        end
    end
    for inflow in strap.inflow_vec
        open!(hub_vec[1], inflow, undecided_range)
        close!(hub_vec[2], inflow, undecided_range)
    end

    return hub_vec
end

function find_right_cross(f::Function, separator_vec::AbstractVector{<:Separator}, hub_base::Hub, strap::Strap; step=Day(3))

    hub_vec = _create_open_close_pair(hub_base, strap) # open, close

    while true
        undecided_range = get_undecided_range(hub_vec[1])
        if length(undecided_range) == 0
            break
        end
        
        end_datetime = min.(get_begin_day.(DateTime, hub_vec) .+ step .- Hour(1), undecided_range[end]) # TODO: ⊐̸ 1 Hour
        set_sim_length!.(hub_vec, end_datetime)

        run_simulation!(hub_vec)

        sep_args = SeparatorArgs(HubBacktrackView.(hub_vec)...)

        right_cross_vec = map(separator_vec) do separator
            return separate(f, separator, sep_args)
        end

        @debug "right_cross_vec=$right_cross_vec"

        right_cross = minimum(right_cross_vec)
        if right_cross < typemax(DateTime)
            return right_cross
        end

        hub_vec = fork.(hub_vec)
    end
    
    return typemax(DateTime)
end
