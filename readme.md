
# EFDCLGT_LR_Strategies

```julia
sep_mean_vec = [
    SepMeanSimple(strap.inflow_vec, strap.overflow_vec, percent), 
    SepMeanBased(strap.inflow_vec, strap.overflow_vec, percent)
]

find_right_cross(ROP, sep_mean_vec, hub_base, strap)
```

