abstract type AbstractReMat{T} <: AbstractMatrix{T} end

"""
    ReMat{T,S} <: AbstractMatrix{T}

A section of a model matrix generated by a random-effects term.

# Fields
- `trm`: the grouping factor as a `StatsModels.CategoricalTerm`
- `refs`: indices into the levels of the grouping factor as a `Vector{Int64}`
- `levels`: the levels of the grouping factor
- `cnames`: the names of the columns of the model matrix generated by the left-hand side of the term
- `z`: transpose of the model matrix generated by the left-hand side of the term
- `wtz`: a weighted copy of `z` (`z` and `wtz` are the same object for unweighted cases)
- `λ`: a `LowerTriangular` or `Diagonal` matrix of size `S×S`--->=== relative covariance factor
- `inds`: a `Vector{Int}` of linear indices of the potential nonzeros in `λ`
- `adjA`: the adjoint of the matrix as a `SparseMatrixCSC{T}`
- `scratch`: a `Matrix{T}`
"""

abstract type ReMat{T,S} <: AbstractReMat{T} end

mutable struct DefaultReMat{T,S} <: ReMat{T,S}
    trm::Any
    refs::Vector{Int64}
    levels::Any
    cnames::Vector{String}
    z::Matrix{T}
    wtz::Matrix{T}
    λ::Union{LowerTriangular{T,Matrix{T}},Diagonal{T,Vector{T}}}
    inds::Vector{Int}
    adjA::SparseMatrixCSC{T,Int64}
    scratch::Matrix{T}
end

mutable struct FlexReMat{T} <: ReMat{T,1}
    trm::Any
    refs::Vector{Int64}
    levels::Any
    cnames::Vector{String}
    z::Matrix{T}
    wtz::Matrix{T}
    λ::Union{LowerTriangular{T,Matrix{T}},Diagonal{T,Vector{T}}}
    inds::Vector{Int}
    adjA::SparseMatrixCSC{T,Int64}
    scratch::Matrix{T}
end

"""
    amalgamate(reterms::Vector{AbstractReMat})

Combine multiple ReMat with the same grouping variable into a single object.
"""
amalgamate(reterms::Vector{<:AbstractReMat{T}}) where {T} = _amalgamate(reterms, T)

function _amalgamate(reterms::Vector, T::Type)
    factordict = Dict{Symbol,Vector{Int}}()
    for (i, rt) in enumerate(reterms)
        push!(get!(factordict, fname(rt), Int[]), i)
    end
    length(factordict) == length(reterms) && return reterms
    value = AbstractReMat{T}[]
    for (f, inds) in factordict
        if isone(length(inds))
            push!(value, reterms[only(inds)])
        else
            trms = reterms[inds]
            trm1 = first(trms)
            trm = trm1.trm
            refs = refarray(trm1)
            levs = trm1.levels
            cnames = foldl(vcat, rr.cnames for rr in trms)
            z = foldl(vcat, rr.z for rr in trms)

            Snew = size(z, 1)
            btemp = Matrix{Bool}(I, Snew, Snew)
            offset = 0
            for m in indmat.(trms)
                sz = size(m, 1)
                inds = (offset + 1):(offset + sz)
                view(btemp, inds, inds) .= m
                offset += sz
            end
            inds = (1:abs2(Snew))[vec(btemp)]
            if inds == diagind(btemp)
                λ = Diagonal{T}(I(Snew))
            else
                λ = LowerTriangular(Matrix{T}(I, Snew, Snew))
            end
            scratch = foldl(vcat, rr.scratch for rr in trms)

            push!(
                value,
                DefaultReMat{T,Snew}(
                    trm, refs, levs, cnames, z, z, λ, inds, adjA(refs, z), scratch
                ),
            )
        end
    end
    return value
end

"""
    adjA(refs::AbstractVector, z::AbstractMatrix{T})

Returns the adjoint of an `ReMat` as a `SparseMatrixCSC{T,Int64}`
"""
function adjA(refs::AbstractVector, z::AbstractMatrix)
    S, n = size(z)
    length(refs) == n || throw(DimensionMismatch)
    J = Int64.(1:n)
    II = refs
    if S > 1
        J = repeat(J; inner=S)
        II = Int64.(vec([(r - 1) * S + j for j in 1:S, r in refs]))
    end
    return sparse(II, J, vec(z))
end

Base.size(A::ReMat) = (length(A.refs), length(A.scratch))

SparseArrays.sparse(A::ReMat) = adjoint(A.adjA)

Base.getindex(A::ReMat, i::Integer, j::Integer) = getindex(A.adjA, j, i)

"""
    nranef(A::ReMat)

Return the number of random effects represented by `A`.  Zero unless `A` is an `ReMat`.
"""
nranef(A::ReMat) = size(A.adjA, 1)

LinearAlgebra.cond(A::ReMat) = cond(A.λ)

StatsAPI.coefnames(re::MixedModels.AbstractReMat) = re.cnames

"""
    fname(A::ReMat)

Return the name of the grouping factor as a `Symbol`
"""
fname(A::ReMat) = fname(A.trm)
fname(A::CategoricalTerm) = A.sym
fname(A::InteractionTerm) = Symbol(join(fname.(A.terms), " & "))

getθ(A::ReMat{T}) where {T} = getθ!(Vector{T}(undef, nθ(A)), A)

"""
    getθ!(v::AbstractVector{T}, A::ReMat{T}) where {T}

Overwrite `v` with the elements of the blocks in the lower triangle of `A.Λ` (column-major ordering)
"""
function getθ!(v::AbstractVector{T}, A::ReMat{T}) where {T}
    length(v) == length(A.inds) || throw(DimensionMismatch("length(v) ≠ length(A.inds)"))
    m = A.λ
    @inbounds for (j, ind) in enumerate(A.inds)
        v[j] = m[ind]
    end
    return v
end

function DataAPI.levels(A::ReMat)
    # These checks are for cases where unused levels are present.
    # Such cases may never occur b/c of the way an ReMat is constructed.
    pool = A.levels
    present = falses(size(pool))
    @inbounds for i in A.refs
        present[i] = true
        all(present) && return pool
    end
    return pool[present]
end

"""
    indmat(A::ReMat)

Return a `Bool` indicator matrix of the potential non-zeros in `A.λ`
"""
function indmat end

indmat(::ReMat{T,1}) where {T} = ones(Bool, 1, 1)
#indmat(::FlexReMat{T}) where {T} = ones(Bool, 1, 1)
indmat(rt::DefaultReMat{T,S}) where {T,S} = reshape([i in rt.inds for i in 1:abs2(S)], S, S)

nlevs(A::ReMat) = length(A.levels)

"""
    nθ(A::ReMat)

Return the number of free parameters in the relative covariance matrix λ
"""
nθ(A::ReMat) = length(A.inds)

"""
    lowerbd{T}(A::ReMat{T})

Return the vector of lower bounds on the parameters, `θ` associated with `A`

These are the elements in the lower triangle of `A.λ` in column-major ordering.
Diagonals have a lower bound of `0`.  Off-diagonals have a lower-bound of `-Inf`.
"""
function lowerbd(A::ReMat{T}) where {T}
    k = size(A.λ, 1)  # construct diagind(A.λ) by hand following #52115
    return T[x ∈ range(1; step=k + 1, length=k) ? zero(T) : T(-Inf) for x in A.inds]
end

"""
    isnested(A::ReMat, B::ReMat)

Is the grouping factor for `A` nested in the grouping factor for `B`?

That is, does each value of `A` occur with just one value of B?
"""
function isnested(A::DefaultReMat, B::DefaultReMat)
    size(A, 1) == size(B, 1) || throw(DimensionMismatch("must have size(A,1) == size(B,1)"))
    bins = zeros(Int64, nlevs(A))
    @inbounds for (a, b) in zip(A.refs, B.refs)
        bba = bins[a]
        if iszero(bba)    # bins[a] not yet set?
            bins[a] = b   # set it
        elseif bba ≠ b    # set to another value?
            return false
        end
    end
    return true
end

function isnested(A::ReMat, B::ReMat)
    return false
end


function lmulΛ!(adjA::Adjoint{T,<:ReMat{T,1}}, B::Matrix{T}) where {T}
    return lmul!(only(adjA.parent.λ.data), B)
end

function lmulΛ!(adjA::Adjoint{T,<:ReMat{T,1}}, B::SparseMatrixCSC{T}) where {T}
    lmul!(only(adjA.parent.λ.data), nonzeros(B))
    return B
end

function lmulΛ!(adjA::Adjoint{T,<:ReMat{T,1}}, B::M) where {M<:AbstractMatrix{T}} where {T}
    return lmul!(only(adjA.parent.λ.data), B)
end

function lmulΛ!(adjA::Adjoint{T,<:ReMat{T,S}}, B::VecOrMat{T}) where {T,S}
    lmul!(adjoint(adjA.parent.λ), reshape(B, S, :))
    return B
end

function lmulΛ!(adjA::Adjoint{T,<:ReMat{T,S}}, B::BlockedSparse{T}) where {T,S}
    lmulΛ!(adjA, nonzeros(B.cscmat))
    return B
end

function lmulΛ!(adjA::Adjoint{T,<:ReMat{T,1}}, B::BlockedSparse{T,1,P}) where {T,P}
    lmul!(only(adjA.parent.λ), nonzeros(B.cscmat))
    return B
end

function lmulΛ!(adjA::Adjoint{T,<:ReMat{T,S}}, B::SparseMatrixCSC{T}) where {T,S}
    lmulΛ!(adjA, nonzeros(B))
    return B
end

LinearAlgebra.Matrix(A::ReMat) = Matrix(sparse(A))

"""
Default: Z'*Z if Z is indicator matrix  --> result will be a diagonal (same random intercept)
"""
function LinearAlgebra.mul!(
    C::Diagonal{T}, adjA::Adjoint{T,<:DefaultReMat{T,1}}, B::DefaultReMat{T,1}
) where {T}
    A = adjA.parent
    @assert A === B
    d = C.diag
    fill!(d, zero(T))
    @inbounds for (ri, Azi) in zip(A.refs, A.wtz)
        d[ri] += abs2(Azi)
    end
    return C
end



"""
Default: multiplication for two arbitrary random intercepts
"""
function Base.:(*)(adjA::Adjoint{T,<:DefaultReMat{T,1}}, B::DefaultReMat{T,1}) where {T}
    A = adjA.parent
    return if A === B
        mul!(Diagonal(Vector{T}(undef, size(B, 2))), adjA, B) # do the matrix multiplication and store it as diagnonal (since Z is generated from indicator columns  Z'Z is block-diagonal)
    else
        sparse(Int64.(A.refs), Int64.(B.refs), vec(A.wtz .* B.wtz)) # matrix multiplication from two different indicator-matrix generated blocks
    end
end

# """
# New: multiplication for two flexible FlexReMat
# """
# function Base.:(*)(adjA::Adjoint{T,<:FlexReMat{T}}, B::FlexReMat{T}) where {T}
#     A = mul!(adjA.parent.adjA, adjoint(B))

#     return A
# end


"""
multiplication for two arbitrary random effects

Covers  and FlexMat

--> most likely works because updateA is not using this function to apply the weights. hence with default weights = 1 this works
when two weighted matrices are multiplied with this function, the result would be wrong?
"""
#Base.:(*)(adjA::Adjoint{T,<:ReMat{T}}, B::ReMat{T}) where {T} = adjA.parent.adjA * sparse(B)

function Base.:(*)(adjA::Adjoint{T,<:ReMat{T}}, B::ReMat{T}) where {T}
    println("multiplication for two arbitrary random effects")
    A = adjA.parent 
    C = MixedModels.adjA(A.refs, A.wtz) * sparse(adjoint(MixedModels.adjA(B.refs, B.wtz)))
    return C
end

function Base.:(*)(adjA::Adjoint{T,<:DefaultReMat{T}}, B::FlexReMat{T}) where {T}
    println("multiplication for FlexRemat times ReMat")
    return MixedModels.adjA(adjA.parent.refs, adjA.parent.wtz) * adjoint(B.wtz)
end

function Base.:(*)(adjA::Adjoint{T,<:FlexReMat{T}}, B::DefaultReMat{T}) where {T}
    println("multiplication for ReMat times FlexReMat")
    return adjA.parent.wtz * adjoint(MixedModels.adjA(B.refs, B.wtz))
end

function Base.:(*)(adjA::Adjoint{T,<:FlexReMat{T}}, B::FlexReMat{T}) where {T}
    println("multiplication for ReMat times FlexReMat")
    return adjA.parent.wtz * adjoint(B.wtz)
end

"""
Multiplication of FE and arbitrary random effects
"""
function Base.:(*)(adjA::Adjoint{T,<:FeMat{T}}, B::ReMat{T}) where {T}
    return mul!(Matrix{T}(undef, size(adjA.parent, 2), size(B, 2)), adjA, B)
end

"""
multiplication of C, Xy with random intercept  -> X'WZ

αZ*X + Cβ 
"""
function LinearAlgebra.mul!(
    C::Matrix{T}, adjA::Adjoint{T,<:FeMat{T}}, B::DefaultReMat{T,1}, α::Number, β::Number
) where {T}
    A = adjA.parent
    Awt = A.wtxy # XY
    n, p = size(Awt) # numer of rows, # number of FR columns
    m, q = size(B) # number of rows, # number of RE columns
    size(C) == (p, q) && m == n || throw(DimensionMismatch()) # dim check
    isone(β) || rmul!(C, β) # scale C by beta if β not one
    zz = B.wtz

    # for each row (sample)
    @inbounds for (j, rrj) in enumerate(B.refs) # (row,col) index
        αzj = α * zz[j] # alpha*Z_B
        for i in 1:p
            C[i, rrj] = muladd(αzj, Awt[j, i], C[i, rrj]) # alpha*Z_B[j,]*X + C
        end
    end
    return C
end

"""
multiplication of C, Xy with flexible random intercept
"""
function LinearAlgebra.mul!(
    C::Matrix{T}, adjA::Adjoint{T,<:FeMat{T}}, B::FlexReMat{T}, α::Number, β::Number
) where {T}
    println("multiplication for FeMat times FlexReMat")
    n, p = size(adjA) # numer of rows, # number of FR columns
    m, q = size(B) # number of rows, # number of RE columns
    size(C) == (p, q) && m == n || throw(DimensionMismatch()) # dim check
    isone(β) || rmul!(C, β) # scale C by beta if β not one

    mul!(C, α*adjoint(adjA.parent.wtxy), adjoint(B.wtz))
    
    return C
end

"""
multiplication of C, Xy with arbitrary random effect
"""
function LinearAlgebra.mul!(
    C::Matrix{T}, adjA::Adjoint{T,<:FeMat{T}}, B::DefaultReMat{T,S}, α::Number, β::Number
) where {T,S}
    A = adjA.parent
    Awt = A.wtxy
    r = size(Awt, 2)
    rr = B.refs
    scr = B.scratch
    vscr = vec(scr)
    Bwt = B.wtz
    n = length(rr)
    q = length(scr)
    size(C) == (r, q) && size(Awt, 1) == n || throw(DimensionMismatch(""))
    isone(β) || rmul!(C, β)
    @inbounds for i in 1:r
        fill!(scr, 0)
        for k in 1:n
            aki = α * Awt[k, i]
            kk = Int(rr[k])
            for ii in 1:S
                scr[ii, kk] = muladd(aki, Bwt[ii, k], scr[ii, kk])
            end
        end
        for j in 1:q
            C[i, j] += vscr[j]
        end
    end
    return C
end

"""
multiplication of C with two random intercepts
"""
function LinearAlgebra.mul!(
    C::SparseMatrixCSC{T}, adjA::Adjoint{T,<:DefaultReMat{T,1}}, B::DefaultReMat{T,1}
) where {T}
    A = adjA.parent
    m, n = size(B)
    size(C, 1) == size(A, 2) && n == size(C, 2) && size(A, 1) == m ||
        throw(DimensionMismatch)
    Ar = A.refs
    Br = B.refs
    Az = A.wtz
    Bz = B.wtz
    nz = nonzeros(C)
    rv = rowvals(C)
    fill!(nz, zero(T))
    for k in 1:m       # iterate over rows of A and B
        i = Ar[k]      # [i,j] are Cartesian indices in C - find and verify corresponding position K in rv and nz
        j = Br[k]
        coljlast = Int(C.colptr[j + 1] - 1)
        K = searchsortedfirst(rv, i, Int(C.colptr[j]), coljlast, Base.Order.Forward)
        if K ≤ coljlast && rv[K] == i
            nz[K] = muladd(Az[k], Bz[k], nz[K])
        else
            throw(ArgumentError("C does not have the nonzero pattern of A'B"))
        end
    end
    return C
end

"""
New: multiplication of random intercept and Flex intercept
"""
function LinearAlgebra.mul!(
    C::Matrix{T}, adjA::Adjoint{T,<:DefaultReMat{T,1}}, B::FlexReMat{T}
) where {T}
    println("random intercept multiplied by flex mat")
    size(C, 1) == size(A, 2) && n == size(C, 2) && size(A, 1) == m ||
        throw(DimensionMismatch)

    A = adjA.parent 
    copyto!(C, MixedModels.adjA(A.refs, A.wtz) * adjoint(B.wtz))

    return C
end

"""
New: multiplication of C with two random intercepts
"""
function LinearAlgebra.mul!(
    C::Matrix{T}, adjA::Adjoint{T,<:FlexReMat{T}}, B::DefaultReMat{T,1}
) where {T}

    println("flex mat multiplied by ReMat")
    size(C, 1) == size(A, 2) && n == size(C, 2) && size(A, 1) == m ||
        throw(DimensionMismatch)

    A = adjA.parent 
    copyto!(C, A.wtz * adjoint(MixedModels.adjA(B.refs, B.wtz)))

    return C
end

"""
multiplication of C with the same random effects - same dimension
"""
function LinearAlgebra.mul!(
    C::UniformBlockDiagonal{T}, adjA::Adjoint{T,DefaultReMat{T,S}}, B::DefaultReMat{T,S}
) where {T,S}
    A = adjA.parent
    @assert A === B
    Cd = C.data
    size(Cd) == (S, S, nlevs(B)) || throw(DimensionMismatch(""))
    fill!(Cd, zero(T))
    Awtz = A.wtz
    for (j, r) in enumerate(A.refs)
        @inbounds for i in 1:S
            zij = Awtz[i, j]
            for k in 1:S
                Cd[k, i, r] = muladd(zij, Awtz[k, j], Cd[k, i, r])
            end
        end
    end
    return C
end

"""
multiplication of C with the same random effects - same dimension
"""
function LinearAlgebra.mul!(
    C::Matrix{T}, adjA::Adjoint{T,FlexReMat{T}}, B::DefaultReMat{T,S}
) where {T,S}
    println("flexmat times remat")
    A = adjA.parent 
    copyto!(C, A.wtz * adjoint(MixedModels.adjA(B.refs, B.wtz)))
    return C
end


"""
multiplication of C with the same random effects - same dimension
"""
function LinearAlgebra.mul!(
    C::Matrix{T}, adjA::Adjoint{T,DefaultReMat{T,S}}, B::FlexReMat{T}
) where {T,S}
    println("remat times flexmat")
    A = adjA.parent
    copyto!(C, adjoint(MixedModels.adjA(A.refs, A.wtz)) * adjoint(B.wtz))
    return C
end

"""
multiplication to C with the random effects of arbitrary dimensions
"""
function LinearAlgebra.mul!(
    C::Matrix{T}, adjA::Adjoint{T,DefaultReMat{T,S}}, B::DefaultReMat{T,P}
) where {T,S,P}
    A = adjA.parent
    m, n = size(A)
    p, q = size(B)
    m == p && size(C, 1) == n && size(C, 2) == q || throw(DimensionMismatch(""))
    fill!(C, zero(T))

    Ar = A.refs
    Br = B.refs
    if isone(S) && isone(P)
        for (ar, az, br, bz) in zip(Ar, vec(A.wtz), Br, vec(B.wtz))
            C[ar, br] += az * bz
        end
        return C
    end
    ab = S * P
    Az = A.wtz
    Bz = B.wtz
    for i in 1:m
        Ari = Ar[i]
        Bri = Br[i]
        ioffset = (Ari - 1) * S
        joffset = (Bri - 1) * P
        for jj in 1:P
            jjo = jj + joffset
            Bzijj = Bz[jj, i]
            for ii in 1:S
                C[ii + ioffset, jjo] = muladd(Az[ii, i], Bzijj, C[ii + ioffset, jjo])
            end
        end
    end
    return C
end

function LinearAlgebra.mul!(
    y::AbstractVector{<:Union{T,Missing}},
    A::DefaultReMat{T,1},
    b::AbstractVector{<:Union{T,Missing}},
    alpha::Number,
    beta::Number,
) where {T}
    m, n = size(A)
    length(y) == m && length(b) == n || throw(DimensionMismatch(""))
    isone(beta) || rmul!(y, beta)
    z = A.z
    @inbounds for (i, r) in enumerate(A.refs)
        # must be muladd and not fma because of potential missings
        y[i] = muladd(alpha * b[r], z[i], y[i])
    end
    return y
end

function LinearAlgebra.mul!(
    y::AbstractVector{<:Union{T,Missing}},
    A::DefaultReMat{T,1},
    B::AbstractMatrix{<:Union{T,Missing}},
    alpha::Number,
    beta::Number,
) where {T}
    return mul!(y, A, vec(B), alpha, beta)
end

function LinearAlgebra.mul!(
    y::AbstractVector{<:Union{T,Missing}},
    A::DefaultReMat{T,S},
    b::AbstractVector{<:Union{T,Missing}},
    alpha::Number,
    beta::Number,
) where {T,S}
    Z = A.z
    k, n = size(Z)
    l = nlevs(A)
    length(y) == n && length(b) == k * l || throw(DimensionMismatch(""))
    isone(beta) || rmul!(y, beta)
    @inbounds for (i, ii) in enumerate(A.refs)
        offset = (ii - 1) * k
        for j in 1:k
            # must be muladd and not fma because of potential missings
            y[i] = muladd(alpha * Z[j, i], b[offset + j], y[i])
        end
    end
    return y
end

"""
???
"""
function LinearAlgebra.mul!(
    y::AbstractVector{<:Union{T,Missing}},
    A::DefaultReMat{T,S},
    B::AbstractMatrix{<:Union{T,Missing}},
    alpha::Number,
    beta::Number,
) where {T,S}
    Z = A.z
    k, n = size(Z)
    l = nlevs(A)
    length(y) == n && size(B) == (k, l) || throw(DimensionMismatch(""))
    isone(beta) || rmul!(y, beta)
    @inbounds for (i, ii) in enumerate(refarray(A))
        for j in 1:k
            # must be muladd and not fma because of potential missings
            y[i] = muladd(alpha * Z[j, i], B[j, ii], y[i])
        end
    end
    return y
end

"""
y = A*b*alpha + C*beta
"""
function LinearAlgebra.mul!(
    y::AbstractVector{<:Union{T,Missing}},
    A::FlexReMat{T},
    b::AbstractVector{<:Union{T,Missing}},
    alpha::Number,
    beta::Number,
) where {T}
    
    k, n = size(Z)
    length(y) == n && length(b) == n || throw(DimensionMismatch(""))
    isone(beta) || rmul!(y, beta)

    copyto!(y, A.z*b.*alpha + y)

    return y
end

"""
???
"""
function LinearAlgebra.mul!(
    y::AbstractVector{<:Union{T,Missing}},
    A::FlexReMat{T},
    B::AbstractMatrix{<:Union{T,Missing}},
    alpha::Number,
    beta::Number,
) where {T}
    Z = A.z
    k, n = size(Z)
    l = nlevs(A)
    length(y) == n && size(B) == (k, l) || throw(DimensionMismatch(""))
    isone(beta) || rmul!(y, beta)
    copyto!(y, A.z*B.*alpha + y)
    return y
end

"""
Muiltiplication of randem effects with different number of slopes / intercepts
"""
function Base.:(*)(adjA::Adjoint{T,<:DefaultReMat{T,S}}, B::DefaultReMat{T,P}) where {T,S,P}
    A = adjA.parent
    if A === B
        return mul!(UniformBlockDiagonal(Array{T}(undef, S, S, nlevs(A))), adjA, A)
    end
    cscmat = A.adjA * adjoint(B.adjA)
    if nnz(cscmat) > *(0.25, size(cscmat)...)
        return Matrix(cscmat)
    end

    return BlockedSparse{T,S,P}(
        cscmat, reshape(cscmat.nzval, S, :), cscmat.colptr[1:P:(cscmat.n + 1)]
    )
end

function PCA(A::ReMat{T,1}; corr::Bool=true) where {T}
    val = ones(T, 1, 1)
    # TODO: use DataAPI
    return PCA(corr ? val : abs(only(A.λ)) * val, A.cnames; corr=corr)
end

# TODO: use DataAPI
PCA(A::ReMat{T,S}; corr::Bool=true) where {T,S} = PCA(A.λ, A.cnames; corr=corr)

DataAPI.refarray(A::ReMat) = A.refs

DataAPI.refpool(A::ReMat) = A.levels

DataAPI.refvalue(A::ReMat, i::Integer) = A.levels[i]

"""
Update Weights in Z
"""
function reweight!(A::ReMat, sqrtwts::Vector)
    if length(sqrtwts) > 0
        if A.z === A.wtz
            A.wtz = similar(A.z)
        end
        mul!(A.wtz, A.z, Diagonal(sqrtwts))
    end
    return A
end


# why nested where? force specialization to eliminate dynamic dispatch
function rmulΛ!(A::M, B::ReMat{T,1}) where {M<:Union{Diagonal{T},Matrix{T}}} where {T}
    return rmul!(A, only(B.λ))
end

function rmulΛ!(A::SparseMatrixCSC{T}, B::ReMat{T,1}) where {T}
    rmul!(nonzeros(A), only(B.λ))
    return A
end

function rmulΛ!(A::M, B::ReMat{T,S}) where {M<:Union{Diagonal{T},Matrix{T}}} where {T,S}
    m, n = size(A)
    q, r = divrem(n, S)
    iszero(r) || throw(DimensionMismatch("size(A, 2) is not a multiple of block size"))
    λ = B.λ
    for k in 1:q
        coloffset = (k - 1) * S
        rmul!(view(A, :, (coloffset + 1):(coloffset + S)), λ)
    end
    return A
end

function rmulΛ!(A::BlockedSparse{T,S,P}, B::ReMat{T,P}) where {T,S,P}
    cbpt = A.colblkptr
    csc = A.cscmat
    nzv = csc.nzval
    for j in 1:div(csc.n, P)
        rmul!(reshape(view(nzv, cbpt[j]:(cbpt[j + 1] - 1)), :, P), B.λ)
    end
    return A
end

rowlengths(A::ReMat{T,1}) where {T} = vec(abs.(A.λ.data))

function rowlengths(A::ReMat)
    ld = A.λ
    return if isa(ld, Diagonal)
        abs.(ld.diag)
    else
        [norm(view(ld, i, 1:i)) for i in 1:size(ld, 1)]
    end
end

"""
    copyscaleinflate!(L::AbstractMatrix, A::AbstractMatrix, Λ::ReMat)

Overwrite L with `Λ'AΛ + I`
"""
function copyscaleinflate! end

function copyscaleinflate!(Ljj::Diagonal{T}, Ajj::Diagonal{T}, Λj::ReMat{T,1}) where {T}
    Ldiag, Adiag = Ljj.diag, Ajj.diag
    lambsq = abs2(only(Λj.λ.data))
    @inbounds for i in eachindex(Ldiag, Adiag)
        Ldiag[i] = muladd(lambsq, Adiag[i], one(T))
    end
    return Ljj
end

function copyscaleinflate!(Ljj::Matrix{T}, Ajj::Diagonal{T}, Λj::ReMat{T,1}) where {T}
    fill!(Ljj, zero(T))
    lambsq = abs2(only(Λj.λ.data))
    @inbounds for (i, a) in enumerate(Ajj.diag)
        Ljj[i, i] = muladd(lambsq, a, one(T))
    end
    return Ljj
end

function copyscaleinflate!(
    Ljj::UniformBlockDiagonal{T},
    Ajj::UniformBlockDiagonal{T},
    Λj::ReMat{T,S},
) where {T,S}
    λ = Λj.λ
    dind = diagind(S, S)
    Ldat = copyto!(Ljj.data, Ajj.data)
    for k in axes(Ldat, 3)
        f = view(Ldat, :, :, k)
        lmul!(λ', rmul!(f, λ))
        for i in dind
            f[i] += one(T)  # inflate diagonal
        end
    end
    return Ljj
end

function copyscaleinflate!(
    Ljj::Matrix{T},
    Ajj::UniformBlockDiagonal{T},
    Λj::ReMat{T,S},
) where {T,S}
    copyto!(Ljj, Ajj)
    n = LinearAlgebra.checksquare(Ljj)
    q, r = divrem(n, S)
    iszero(r) || throw(DimensionMismatch("size(Ljj, 1) is not a multiple of S"))
    λ = Λj.λ
    offset = 0
    @inbounds for _ in 1:q
        inds = (offset + 1):(offset + S)
        tmp = view(Ljj, inds, inds)
        lmul!(adjoint(λ), rmul!(tmp, λ))
        offset += S
    end
    for k in diagind(Ljj)
        Ljj[k] += one(T)
    end
    return Ljj
end


function setθ!(A::ReMat{T}, v::AbstractVector{T}) where {T}
    A.λ.data[A.inds] = v
    return A
end

σvals(A::ReMat{T,1}, sc::Number) where {T} = (sc * abs(only(A.λ.data)),)

"""
    σvals!(v::AbstractVector, A::ReMat, sc::Number)

Overwrite v with the standard deviations of the random effects associated with `A`
"""
σvals!(v::AbstractVector, A::ReMat, sc::Number) = σvals!(v, A.λ, sc)

function σvals!(v::AbstractVector{T}, A::ReMat{T,1}, sc::Number) where {T}
    isone(length(v)) || throw(DimensionMismatch("length(v) = $(length(v)), should be 1"))
    @inbounds v[1] = sc * abs(only(A.λ.data))
    return v
end

function σvals!(v::AbstractVector{T}, λ::LowerTriangular{T}, sc::Number) where {T}
    fill!(v, zero(T))
    for j in axes(λ, 2)
        for i in j:size(λ, 1)
            @inbounds v[i] += abs2(λ[i, j])
        end
    end
    for i in axes(λ, 1)
        @inbounds v[i] = sqrt(v[i]) * sc
    end
    return v
end

function σvals!(v::AbstractVector{T}, λ::Diagonal{T}, sc::Number) where {T}
    return rmul!(copyto!(v, λ.diag), sc)
end

function σs(A::ReMat{T,1}, sc::Number) where {T}
    return NamedTuple{(Symbol(only(A.cnames)),)}(σvals(A, sc))
end

function σvals(λ::LowerTriangular{T}, sc::Number) where {T}
    return ntuple(size(λ, 1)) do i
        s = zero(T)
        for j in Base.OneTo(i)
            @inbounds s += abs2(λ[i, j])
        end
        sc * sqrt(s)
    end
end

function σvals(λ::Diagonal, sc::Number)
    v = λ.diag
    return ntuple(length(v)) do i
        @inbounds sc * v[i]
    end
end

σvals(A::ReMat, sc::Number) = σvals(A.λ, sc)

function σs(A::DefaultReMat{T}, sc::Number) where {T}
    return NamedTuple{(Symbol.(A.cnames)...,)}(σvals(A.λ, sc))
end

function σρs(A::DefaultReMat{T,1}, sc::T) where {T}
    return NamedTuple{(:σ, :ρ)}((
        NamedTuple{(Symbol(only(A.cnames)),)}((sc * abs(only(A.λ)),)), ()
    ))
end

function ρ(i, λ::AbstractMatrix{T}, im::Matrix{Bool}, indpairs, σs, sc::T)::T where {T}
    row, col = indpairs[i]
    if iszero(dot(view(im, row, :), view(im, col, :)))
        -zero(T)
    else
        dot(view(λ, row, :), view(λ, col, :)) * abs2(sc) / (σs[row] * σs[col])
    end
end

function _σρs(
    λ::LowerTriangular{T}, sc::T, im::Matrix{Bool}, cnms::Vector{Symbol}
) where {T}
    λ = λ.data
    k = size(λ, 1)
    indpairs = checkindprsk(k)
    σs = NamedTuple{(cnms...,)}(ntuple(i -> sc * norm(view(λ, i, 1:i)), k))
    return NamedTuple{(:σ, :ρ)}((
        σs, ntuple(i -> ρ(i, λ, im, indpairs, σs, sc), (k * (k - 1)) >> 1)
    ))
end

function _σρs(λ::Diagonal{T}, sc::T, im::Matrix{Bool}, cnms::Vector{Symbol}) where {T}
    dsc = sc .* λ.diag
    k = length(dsc)
    σs = NamedTuple{(cnms...,)}(NTuple{k,T}(dsc))
    return NamedTuple{(:σ, :ρ)}((σs, ntuple(i -> -zero(T), (k * (k - 1)) >> 1)))
end

function σρs(A::ReMat{T}, sc::T) where {T}
    return _σρs(A.λ, sc, indmat(A), Symbol.(A.cnames))
end

"""
    corrmat(A::ReMat)

Return the estimated correlation matrix for `A`.  The diagonal elements are 1
and the off-diagonal elements are the correlations between those random effect
terms

# Example

Note that trailing digits may vary slightly depending on the local platform.

```julia-repl
julia> using MixedModels

julia> mod = fit(MixedModel,
                 @formula(rt_trunc ~ 1 + spkr + prec + load + (1 + spkr + prec | subj)),
                 MixedModels.dataset(:kb07));

julia> VarCorr(mod)
Variance components:
             Column      Variance  Std.Dev.  Corr.
subj     (Intercept)     136591.782 369.583
         spkr: old        22922.871 151.403 +0.21
         prec: maintain   32348.269 179.856 -0.98 -0.03
Residual                 642324.531 801.452

julia> MixedModels.corrmat(mod.reterms[1])
3×3 LinearAlgebra.Symmetric{Float64,Array{Float64,2}}:
  1.0        0.214816   -0.982948
  0.214816   1.0        -0.0315607
 -0.982948  -0.0315607   1.0
```
"""
function corrmat(A::ReMat{T}) where {T}
    λ = A.λ
    λnorm = rownormalize!(copy!(zeros(T, size(λ)), λ))
    return Symmetric(λnorm * λnorm', :L)
end

vsize(::ReMat{T,S}) where {T,S} = S

#????
function zerocorr!(A::DefaultReMat{T}) where {T}
    λ = A.λ = Diagonal(A.λ)
    k = size(λ, 1)
    A.inds = intersect(A.inds, range(1; step=k + 1, length=k))
    return A
end
