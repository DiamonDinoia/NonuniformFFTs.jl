abstract type AbstractNUFFTData{T <: Number, N} end

struct RealNUFFTData{
        T <: AbstractFloat, N,
        WaveNumbers <: NTuple{N, AbstractVector{T}},
        PlanFFT_fw <: FFTW.Plan{T},
        PlanFFT_bw <: FFTW.Plan{Complex{T}},
    } <: AbstractNUFFTData{T, N}
    ks      :: WaveNumbers  # wavenumbers in *non-oversampled* Fourier grid
    us      :: Array{T, N}  # values in oversampled grid
    ûs      :: Array{Complex{T}, N}  # Fourier coefficients in oversampled grid
    plan_fw :: PlanFFT_fw
    plan_bw :: PlanFFT_bw
end

struct ComplexNUFFTData{
        T <: AbstractFloat, N,
        WaveNumbers <: NTuple{N, AbstractVector{T}},
        PlanFFT_fw <: FFTW.Plan{Complex{T}},
        PlanFFT_bw <: FFTW.Plan{Complex{T}},
    } <: AbstractNUFFTData{Complex{T}, N}
    ks      :: WaveNumbers
    us      :: Array{Complex{T}, N}
    plan_fw :: PlanFFT_fw  # in-place transform
    plan_bw :: PlanFFT_bw  # inverse in-place transform
end

struct PlanNUFFT{
        T <: Number, N, M,
        Treal <: AbstractFloat,  # this is real(T)
        Kernels <: NTuple{N, AbstractKernelData{<:AbstractKernel, M, Treal}},
        Points <: StructVector{NTuple{N, Treal}},
        Data <: AbstractNUFFTData{T, N},
    }
    kernels :: Kernels
    σ       :: Treal   # oversampling factor (≥ 1)
    points  :: Points  # non-uniform points (real values)
    data    :: Data
end

"""
    size(p::PlanNUFFT) -> (N₁, N₂, ...)

Return the dimensions of arrays containing uniform values.

This corresponds to the number of Fourier modes in each direction.
"""
Base.size(p::PlanNUFFT) = map(length, p.data.ks)

# Case of real-to-complex transform.
# This constructor is generally not called directly.
function _PlanNUFFT(
        ::Type{T}, kernel::AbstractKernel, h::HalfSupport, σ_wanted, Ns::Dims{D};
        fftw_flags = FFTW.MEASURE,
    ) where {T <: AbstractFloat, D}
    ks = ntuple(Val(length(Ns))) do i
        N = Ns[i]
        # This assumes L = 2π:
        i == 1 ? FFTW.rfftfreq(N, T(N)) : FFTW.fftfreq(N, T(N))
    end
    # Determine dimensions of oversampled grid.
    Ñs = map(Ns) do N
        # We try to make sure that each dimension is a product of powers of small primes,
        # which is good for FFT performance.
        nextprod((2, 3, 5), floor(Int, σ_wanted * N))
    end
    σ::T = maximum(Ñs ./ Ns)  # actual oversampling factor
    kernel_data = map(Ns, Ñs) do N, Ñ
        @inline
        L = T(2π)  # assume 2π period
        Δx̃ = L / Ñ
        Kernels.optimal_kernel(kernel, h, Δx̃, Ñ / N)
    end
    points = StructVector(ntuple(_ -> T[], Val(D)))
    us = Array{T}(undef, Ñs)
    dims_out = (Ñs[1] ÷ 2 + 1, Base.tail(Ñs)...)
    ûs = Array{Complex{T}}(undef, dims_out)
    plan_fw = FFTW.plan_rfft(us; flags = fftw_flags)
    plan_bw = FFTW.plan_brfft(ûs, size(us, 1); flags = fftw_flags)
    nufft_data = RealNUFFTData(ks, us, ûs, plan_fw, plan_bw)
    PlanNUFFT(kernel_data, σ, points, nufft_data)
end

# Case of complex-to-complex transform.
# This constructor is generally not called directly.
function _PlanNUFFT(
        ::Type{S}, kernel::AbstractKernel, h::HalfSupport, σ_wanted, Ns::Dims{D};
        fftw_flags = FFTW.MEASURE,
    ) where {S <: Complex, D}
    T = real(S)
    ks = map(Ns) do N
        FFTW.fftfreq(N, T(N))  # this assumes L = 2π
    end
    # Determine dimensions of oversampled grid.
    Ñs = map(Ns) do N
        # We try to make sure that each dimension is a product of powers of small primes,
        # which is good for FFT performance.
        nextprod((2, 3, 5), floor(Int, σ_wanted * N))
    end
    σ::T = maximum(Ñs ./ Ns)  # actual oversampling factor
    kernel_data = map(Ns, Ñs) do N, Ñ
        @inline
        L = T(2π)  # assume 2π period
        Δx̃ = L / Ñ
        Kernels.optimal_kernel(kernel, h, Δx̃, Ñ / N)
    end
    points = StructVector(ntuple(_ -> T[], Val(D)))
    us = Array{Complex{T}}(undef, Ñs)
    plan_fw = FFTW.plan_fft!(us; flags = fftw_flags)
    plan_bw = FFTW.plan_bfft!(us; flags = fftw_flags)
    nufft_data = ComplexNUFFTData(ks, us, plan_fw, plan_bw)
    PlanNUFFT(kernel_data, σ, points, nufft_data)
end

function PlanNUFFT(
        ::Type{T}, Ns::Dims, h::HalfSupport;
        kernel::AbstractKernel = BackwardsKaiserBesselKernel(),
        σ::Real = real(T)(2), kws...,
    ) where {T <: Number}
    R = real(T)
    _PlanNUFFT(T, kernel, h, R(σ), Ns; kws...)
end

# This constructor relies on constant propagation to make the output fully inferred.
function PlanNUFFT(::Type{T}, Ns::Dims; m::Integer = 8, kws...) where {T <: Number}
    h = HalfSupport(m)
    PlanNUFFT(T, Ns, h; kws...)
end

# 1D case
function PlanNUFFT(::Type{T}, N::Integer, args...; kws...) where {T <: Number}
    PlanNUFFT(T, (N,), args...; kws...)
end

# Alternative constructor: use ComplexF64 data by default.
function PlanNUFFT(N::Union{Integer, Dims}, args...; kws...)
    PlanNUFFT(ComplexF64, N, args...; kws...)
end
