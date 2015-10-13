##############################################################################
## 
## LSMR with diagonal preconditioner, ie A -> A / sqrt(A'A)
##
##############################################################################

type PMatrix{TA, Tx}
    A::TA
    normalization::Tx 
    tmp::Tx
end
eltype(A::PMatrix) = eltype(A.A)
size(A::PMatrix, i::Integer) = size(A.A, i)

function A_mul_B!{TA, Tx}(α::Number, pm::PMatrix{TA, Tx}, a::Tx, 
                β::Number, b)
    map!(*, pm.tmp, a, pm.normalization)
    A_mul_B!(α, pm.A, pm.tmp, β, b)
    return b
end

function Ac_mul_B!{TA, Tx}(α::Number, pm::PMatrix{TA, Tx}, a, 
                β::Number, b::Tx)
    T = eltype(b)
    β = convert(T, β)
    Ac_mul_B!(one(T), pm.A, a, zero(T), pm.tmp)
    map!(*, pm.tmp, pm.tmp, pm.normalization)
    if β != one(T)
        if β == zero(T)
            fill!(b, β)
        else
            scale!(b, β)
        end
    end
    axpy!(α, pm.tmp, b)
    return b
end

type PreconditionedMatrix{TA, Tx}
    A::TA
    normalization::Tx  # 1 / sqrt(diag(A'A))
    tmp::Tx # a storage vector of size(A, 2)
end


# use invoke when accepts keyboard argument https://github.com/JuliaLang/julia/issues/7045
function lsmr!(x, A::PreconditionedMatrix, r, v, h, hbar; kwargs...)
    PA = PMatrix(A.A, A.normalization, A.tmp)
    result = lsmr!(x, PA, r, v, h, hbar; kwargs...)
    map!(*, x, x, A.normalization)
    return result
end

##############################################################################
## 
## LSMR with matrix A = |J         |
##                      |diag(dtd) |
##
##############################################################################

type DampenedVector{Ty, Tx}
    y::Ty # dimension of f(x)
    x::Tx # dimension of x
end
eltype(a::DampenedVector) =  promote_type(eltype(a.y), eltype(a.x))
length(a::DampenedVector) = length(a.y) + length(a.x)

function scale!(a::DampenedVector, α::Number)
    scale!(a.y, α)
    scale!(a.x, α)
    return a
end

norm(a::DampenedVector) = sqrt(norm(a.y)^2 + norm(a.x)^2)

type DampenedMatrix{TA, Tx}
    A::TA
    diagonal::Tx 
end

eltype(A::DampenedMatrix) = promote_type(eltype(A.A), eltype(A.diagonal))
function size(A::DampenedMatrix, dim::Integer)
    m, n = size(A.A)
    l = length(A.diagonal)
    dim == 1 ? (m + l) : 
    dim == 2 ? n : 1
end

function A_mul_B!{TA, Tx, Ty}(α::Number, mw::DampenedMatrix{TA, Tx}, a::Tx, 
                β::Number, b::DampenedVector{Ty, Tx})
    if β != 1
        scale!(b, β)
    end
    A_mul_B!(α, mw.A, a, 1, b.y)
    map!((z, x, y)-> z + α * x * y, b.x, b.x, a, mw.diagonal)
    return b
end

function Ac_mul_B!{TA, Tx, Ty}(α::Number, mw::DampenedMatrix{TA, Tx}, a::DampenedVector{Ty, Tx}, 
                β::Number, b::Tx)
    T = eltype(b)
    β = convert(T, β)
    if β != one(T)
        if β == zero(T)
            fill!(b, β)
        else
            scale!(b, β)
        end
    end
    Ac_mul_B!(α, mw.A, a.y, one(T), b)
    map!((z, x, y)-> z + α * x * y, b, b, a.x, mw.diagonal)  
    return b
end

##############################################################################
## 
## solve J'J \ J'y (used in Dogleg)
##
## we use LSMR for the problem J'J \ J' fcur 
## with 1/sqrt(diag(J'J)) as preconditioner
##
##############################################################################

type LSMROperator{TJ, Tx1, Tx2, Tx3, Tx4, Tx5, Tx6, Ty} <: AbstractOperator
    J::TJ
    normalization::Tx1
    tmp::Tx2
    v::Tx3
    h::Tx4
    hbar::Tx5
    zerosvector::Tx6
    b::Ty
end

function AbstractOperator(nls::LeastSquaresProblem,
    ::Type{Val{:dogleg}}, ::Type{Val{:iterative}})
    LSMROperator(nls.J, _zeros(nls.x), _zeros(nls.x), _zeros(nls.x), 
        _zeros(nls.x), _zeros(nls.x),  _zeros(nls.x), _zeros(nls.y))
end

function solve!(x, A::AbstractOperator, y)
    J, normalization, tmp, v, h, hbar, b = A.J, A.normalization, A.tmp, A.v, A.h, A.hbar, A.b

    # prepare x
    fill!(x, 0)

    # prepare b
    copy!(b, y)

    # prepare A
    colsumabs2!(normalization, J)
    Tx = eltype(normalization)
    map!(x -> x > zero(Tx) ? 1 / sqrt(x) : zero(Tx), normalization, normalization)
    A = PreconditionedMatrix(J, normalization, tmp)

    # solve
    x, ch = lsmr!(x, A, b, v, h, hbar)
    return x, ch.mvps
end

##############################################################################
## 
## solve (J'J + λ dtd) \ J'y (used in LevenbergMarquardt)
## See "An Inexact Levenberg-Marquardt Method for Large Sparse Nonlinear Least Squares"
## Weight Holt (1985)
##
##############################################################################

type LSMRDampenedOperator{TJ, Tx1, Tx2, Tx3, Tx4, Tx5, Tx6, Ty} <: AbstractOperator
    J::TJ
    normalization::Tx1
    tmp::Tx2
    v::Tx3
    h::Tx4
    hbar::Tx5
    zerosvector::Tx6
    u::Ty
    function LSMRDampenedOperator(J, normalization, tmp, v, h, hbar, zerosvector, u)
        length(normalization) == length(tmp) || throw(DimensionMismatch("normalization and tmp must have the same length"))
        length(normalization) == length(v) || throw(DimensionMismatch("normalization and v must have the same length"))
        length(normalization) == length(h) || throw(DimensionMismatch("normalization and h must have the same length"))
        length(normalization) == length(hbar) || throw(DimensionMismatch("normalization and hbar must have the same length"))
        length(normalization) == length(zerosvector) || throw(DimensionMismatch("normalization and zerosvector must have the same length"))
        new(J, normalization, tmp, v, h, hbar, zerosvector, u)
    end
end

function LSMRDampenedOperator{TJ, Tx1, Tx2, Tx3, Tx4, Tx5, Tx6, Ty}(J::TJ, normalization::Tx1, tmp::Tx2, v::Tx3, h::Tx4, hbar::Tx5, zerosvector::Tx6, u::Ty)
    LSMRDampenedOperator{TJ, Tx1, Tx2, Tx3, Tx4, Tx5, Tx6, Ty}(J, normalization, tmp, v, h, hbar, zerosvector, u)
end


function AbstractOperator(nls::LeastSquaresProblem,
    ::Type{Val{:levenberg_marquardt}}, ::Type{Val{:iterative}})
    LSMRDampenedOperator(nls.J, _zeros(nls.x), _zeros(nls.x), 
        _zeros(nls.x), _zeros(nls.x), _zeros(nls.x), _zeros(nls.x), _zeros(nls.y))
end

function solve!(x, A::LSMRDampenedOperator, y, dtd, λ)
    J, normalization, tmp, v, h, hbar, zerosvector, u = 
            A.J, A.normalization, A.tmp, A.v, A.h, A.hbar, A.zerosvector, A.u
    
    # prepare x
    fill!(x, 0)

    # prepare b
    copy!(u, y)
    fill!(zerosvector, 0)
    b = DampenedVector(u, zerosvector)

    # prepare A
    fill!(tmp, 0)
    copy!(normalization, dtd)
    clamp!(dtd, MIN_DIAGONAL, MAX_DIAGONAL)
    scale!(dtd, λ)
    Tx = eltype(normalization)
    axpy!(one(Tx), dtd, normalization)
    map!(x -> x > zero(Tx) ? 1 / sqrt(x) : zero(Tx), normalization, normalization)
    map!(sqrt, dtd, dtd)
    A = PreconditionedMatrix(DampenedMatrix(J, dtd), normalization, tmp)

    # solve
    x, ch = lsmr!(x, A, b, v, h, hbar, btol = 0.5)
    return x, ch.mvps
end