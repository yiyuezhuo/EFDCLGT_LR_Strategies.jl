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
