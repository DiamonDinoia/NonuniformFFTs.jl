function interpolate!(gs, vp::AbstractArray, us, xp::AbstractArray)
    @assert axes(vp) === axes(xp)
    for i ∈ eachindex(vp)
        x⃗ = to_unit_cell(xp[i])
        vp[i] = interpolate(gs, us, x⃗)
    end
    vp
end

function interpolate(
        gs::NTuple{D, AbstractKernelData},
        us::NTuple{M, AbstractArray{T, D}} where {T},
        x⃗::NTuple{D},  # coordinates are assumed to be in [0, 2π]
    ) where {D, M}
    @assert M > 0
    map(Base.require_one_based_indexing, us)
    Ns = size(first(us))
    @assert all(u -> size(u) === Ns, us)

    # Evaluate 1D kernels.
    gs_eval = map(Kernels.evaluate_kernel, gs, x⃗)

    # Determine indices to load from `u` arrays.
    inds = map(gs_eval, gs, Ns) do gdata, g, N
        Kernels.kernel_indices(gdata.i, g, N)
    end

    vals = map(gs_eval, gs) do geval, g
        Δx = gridstep(g)
        geval.values .* Δx
    end

    interpolate_from_arrays(us, inds, vals)
end

interpolate(gs::NTuple, u::AbstractArray, x⃗) = only(interpolate(gs, (u,), x⃗))

function interpolate_from_arrays(
        us::NTuple{C, AbstractArray{T, D}} where {T},
        inds::NTuple{D, Tuple},
        vals::NTuple{D, Tuple},
    ) where {C, D}
    vs = ntuple(_ -> zero(eltype(first(us))), Val(C))
    inds_iter = CartesianIndices(map(eachindex, inds))
    @inbounds for ns ∈ inds_iter  # ns = (ni, nj, ...)
        is = map(getindex, inds, Tuple(ns))
        gs = map(getindex, vals, Tuple(ns))
        gprod = prod(gs)
        vs_new = ntuple(Val(C)) do j
            @inline
            gprod * us[j][is...]
        end
        vs = vs .+ vs_new
    end
    vs
end
