using StaticArrays: SVector
using LinearAlgebra: dot, cross, norm

# ---------------------------------------------------------------------------------------- #
# EXPR UTILITIES

# extract all the `Symbol`s referenced in an `Expr`
function get_expr_symbols!(syms::Vector{Symbol}, ex::Expr)
    for arg in ex.args
        if arg isa Symbol
            arg ∈ syms || push!(syms, arg)
        elseif arg isa Expr
            get_expr_symbols!(syms, arg)
        end
    end
    return syms
end
get_expr_symbols(ex::Expr) = get_expr_symbols!(Symbol[], ex)

# ---------------------------------------------------------------------------------------- #
# LOAD CONSTANT GLOBAL `pointsd_Nd`, & `paramsd_Nd` DICTIONARIES (for N={2,3})
include(joinpath("..", "assets", "data-SeeK.jl"))
include(joinpath("..", "assets", "data-2d.jl"))

# ---------------------------------------------------------------------------------------- #
# CODEGEN TO CREATE FUNCTIONS FOR EXTENDED BRAVAIS TYPES

# Generate method definitions `$(bt)_points` (`bt` denotes the extended Bravais type) for
# each dataset using metaprogramming. If the datasets require arguments, the arguments are
# listed in the order :a, :b, :c, :β and includes only the featured set of arguments.
for (D, pointsd, paramsd) in zip((2,3), (pointsd_2d, pointsd_3d), (paramsd_2d, paramsd_3d))
    for (bt, points) in pointsd
        fn = Symbol(string(bt)*"_points")
        params = get(paramsd, bt, nothing)

        # --- build up an expression for the dictionary of k-point labels and vectors ---
        ex = :(Dict())
        for (klab, point_expr) in points
            point_expr′ = Expr(:call, SVector{D,Float64}, point_expr.args...) # convert to SVector
            push!(ex.args, Expr(:call, :(=>), QuoteNode(klab), point_expr′))
        end

        if params === nothing
            # --- only constant points; define "constant" function of `Rs` ---
            @eval $fn(Rs::Union{Nothing, AbstractVector{<:SVector{$D, <:Real}}}) = $ex

        else
            # --- free arguments; define constant dependent on `Rs` ---

            # write out the all the parameter definitions as expressions
            params_ex = quote end
            for (paramlab, param_expr) in params
                push!(params_ex.args, Expr(:(=), :($(paramlab)), param_expr))
            end
            # find out what the arguments are; can only be {:a, :b, :c} and {:sinβ, :cosβ}
            syms = get_expr_symbols(params_ex) # get all referenced symbol in `params_ex`
            # create list of typed arguments, e.g. (:(a::Real), :(b::Real), ...)
            setup_ex = quote end
            for (i, sym) in enumerate((:a, :b, :c))
                if sym ∈ syms
                    push!(setup_ex.args, Expr(:(=), sym, :(norm(Rs[$i]))))
                end
                #sym ∈ syms && push!(args, Expr( :(::), sym, :Real))
            end
            # define "cosβ = cos(β)" and "sinβ = sin(β)" if we can find :cosβ or :sinβ in the
            # argument list; in practice, they only ever occur together in SeeK, so we can just
            # check for one and add both.
            if :cosβ ∈ syms
                for (i, sym) in zip((1,3), (:a, :c))
                    # if :a or :c are not in argslist, then we need to add them, since we need
                    # them to compute :cosβ and :sinβ as dot and cross products; β is ∠(R₃, R₁)
                    sym ∉ syms && push!(setup_ex.args, Expr(:(=), sym, :(norm(Rs[$i]))))
                end
                push!(setup_ex.args, Expr(:(=), :cosβ, :(dot(Rs[3], Rs[1])/(c*a))))
                push!(setup_ex.args, Expr(:(=), :sinβ, :(sqrt(1 - cosβ^2)))) # acos(sin(x)) = √(1-x²)
            end

            # --- make function of the featured subset of :a, :b, :c, and :β, in that order ---
            @eval function $fn(Rs::AbstractVector{<:SVector{$D, <:Real}})
                $setup_ex
                $params_ex
                return $ex
            end
            errstr = "the irreducible path of a Bravais lattice of extended type " *
                     string(bt) * " cannot be constructed without knowledge of the " *
                     "lattice: provide a (conventional) direct lattice basis `Rs`"
            @eval $fn(::Nothing) = error($errstr)
        end

        #=
        # see what methods we generated and check that they "work":
        fn′ = getfield(Main, fn) # get the actual function, not just its symbol
        mth = only(methods(fn′))
        println("\n", mth)    
        display(fn′([rand(SVector{D,Float64}) for _ in 1:3])) 
        =#
    end
end

# ---------------------------------------------------------------------------------------- #
# CODEGEN FOR BRANCHTABLE TO ABOVE FUNCTIONS

# generate a branch-table function (just a lot of if-statements, that simply dispatch to
# `($ext_bt)_points(Rs)`, depending on the value of `ext_bt`:
for (D, pointsd) in zip((2,3), (pointsd_2d, pointsd_3d))

    branchtable = Expr(:if)
    let current = branchtable
        for (i,ext_bt) in enumerate(keys(pointsd))
            if i ≠ 1
                push!(current.args, Expr(:elseif))
                current = current.args[end]
            end
            push!(current.args, :(ext_bt == $(QuoteNode(ext_bt))))
            fn = Symbol(string(ext_bt)*"_points")
            push!(current.args, :($fn(Rs)))
        end
        # the final entry in the :if call block is implicitly an `else` block:
        push!(current.args, :(throw(DomainError(ext_bt, "invalid extended Bravais type"))))
    end

    f = Symbol(:get_points_, D, :d)
    @eval begin
        @doc """
            $($f)(ext_bt, Rs)

        Return the labels and points in the $($D)D **k**-path associated with an extended
        Bravais type `ext_bt` and a (conventional) direct basis `Rs` (can be `nothing` if
        there is no dependence on the basis) as a `Dict{Symbol, SVector{$($D), Float64}}`.
        """
        function $f(ext_bt::Symbol,
                    Rs::Union{Nothing, AVec{<:AVec{<:Real}}})
            $branchtable
        end
    end
end